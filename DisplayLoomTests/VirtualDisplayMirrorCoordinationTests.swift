import AppKit
import Foundation
import XCTest

@testable import DisplayLoom

@MainActor
final class VirtualDisplayMirrorCoordinationTests: XCTestCase {
  private let source = DisplayMirrorSource(id: UUID(), name: "Studio Display")

  func testSelectionRestoresAnotherDisplayChangedBySynchronousNotification() async {
    let environment = await connectedEnvironment()
    let first = environment.store.profiles[0]
    let second = environment.store.profiles[1]
    let firstTarget = environment.backend.connections[first.id]!.displayID
    let secondTarget = environment.backend.connections[second.id]!.displayID
    environment.mirroringManager.sources = [source]
    await environment.store.setMirrorSource(source.id, for: first.id)
    environment.mirroringManager.onMirrorChange = {
      environment.mirroringManager.onMirrorChange = nil
      environment.mirroringManager.simulateActualMirror(targetDisplayID: firstTarget, sourceID: nil)
      environment.store.scheduleDisplayReconfiguration()
    }
    defer { environment.mirroringManager.onMirrorChange = nil }

    await environment.store.setMirrorSource(source.id, for: second.id)
    await environment.store.waitForDisplayUpdates()

    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests.suffix(2),
      [
        MirrorRequest(targetDisplayID: secondTarget, sourceID: source.id),
        MirrorRequest(targetDisplayID: firstTarget, sourceID: source.id),
      ]
    )
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[first.id], source.id)
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[second.id], source.id)
    XCTAssertEqual(
      environment.repository.state.profiles.map(\.mirrorSourceID),
      [source.id, source.id]
    )
    XCTAssertTrue(environment.store.mirrorRestoreFailures.isEmpty)
  }

  func testClearingDoesNotRestoreOldIntentDuringSynchronousNotification() async {
    let environment = await connectedEnvironment()
    let profile = environment.store.profiles[0]
    let target = environment.backend.connections[profile.id]!.displayID
    environment.mirroringManager.sources = [source]
    await environment.store.setMirrorSource(source.id, for: profile.id)
    environment.mirroringManager.onMirrorChange = {
      environment.store.scheduleDisplayReconfiguration()
    }
    defer { environment.mirroringManager.onMirrorChange = nil }
    let attemptsBeforeClearing = environment.mirroringManager.mirrorAttempts.count

    await environment.store.setMirrorSource(nil, for: profile.id)
    await environment.store.waitForDisplayUpdates()

    XCTAssertEqual(environment.mirroringManager.mirrorAttempts.count, attemptsBeforeClearing + 1)
    XCTAssertNil(environment.mirroringManager.mirrorSourceID(for: target))
    XCTAssertNil(environment.store.activeMirrorSourceIDs[profile.id])
    XCTAssertNil(environment.repository.state.profiles[0].mirrorSourceID)
    XCTAssertTrue(environment.store.mirrorRestoreFailures.isEmpty)
  }

  func testRestorationRevisitsAnEarlierDisplayChangedByALaterDisplay() async {
    let environment = await connectedEnvironment()
    let first = environment.store.profiles[0]
    let second = environment.store.profiles[1]
    let firstTarget = environment.backend.connections[first.id]!.displayID
    let secondTarget = environment.backend.connections[second.id]!.displayID
    environment.mirroringManager.sources = [source]
    await environment.store.setMirrorSource(source.id, for: first.id)
    await environment.store.setMirrorSource(source.id, for: second.id)
    environment.mirroringManager.simulateActualMirror(targetDisplayID: firstTarget, sourceID: nil)
    environment.mirroringManager.simulateActualMirror(targetDisplayID: secondTarget, sourceID: nil)
    environment.mirroringManager.onMirrorChange = {
      if environment.mirroringManager.mirrorSourceID(for: secondTarget) != nil {
        environment.mirroringManager.onMirrorChange = nil
        environment.mirroringManager.simulateActualMirror(
          targetDisplayID: firstTarget,
          sourceID: nil
        )
      }
      environment.store.scheduleDisplayReconfiguration()
    }
    defer { environment.mirroringManager.onMirrorChange = nil }
    let attemptsBeforeRestoring = environment.mirroringManager.mirrorAttempts.count
    let savedState = environment.repository.state

    await environment.store.handleDisplayReconfiguration()

    XCTAssertEqual(environment.mirroringManager.mirrorAttempts.count, attemptsBeforeRestoring + 3)
    XCTAssertEqual(
      environment.mirroringManager.mirrorAttempts.suffix(3),
      [
        MirrorRequest(targetDisplayID: firstTarget, sourceID: source.id),
        MirrorRequest(targetDisplayID: secondTarget, sourceID: source.id),
        MirrorRequest(targetDisplayID: firstTarget, sourceID: source.id),
      ]
    )
    XCTAssertEqual(environment.mirroringManager.mirrorSourceID(for: firstTarget), source.id)
    XCTAssertEqual(environment.mirroringManager.mirrorSourceID(for: secondTarget), source.id)
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[first.id], source.id)
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[second.id], source.id)
    XCTAssertEqual(environment.repository.state, savedState)
    XCTAssertTrue(environment.store.mirrorRestoreFailures.isEmpty)
  }

  func testRestorationRevisitsAnEarlierDisplayWhenItsSourceBecomesAvailable() async {
    let environment = await connectedEnvironment()
    let first = environment.store.profiles[0]
    let second = environment.store.profiles[1]
    let firstTarget = environment.backend.connections[first.id]!.displayID
    let secondTarget = environment.backend.connections[second.id]!.displayID
    let otherSource = DisplayMirrorSource(id: UUID(), name: "External Display")
    environment.mirroringManager.sources = [source, otherSource]
    await environment.store.setMirrorSource(source.id, for: first.id)
    await environment.store.setMirrorSource(otherSource.id, for: second.id)
    environment.mirroringManager.simulateActualMirror(targetDisplayID: firstTarget, sourceID: nil)
    environment.mirroringManager.simulateActualMirror(targetDisplayID: secondTarget, sourceID: nil)
    environment.mirroringManager.sources = [otherSource]
    environment.mirroringManager.onMirrorChange = { [source] in
      environment.mirroringManager.onMirrorChange = nil
      environment.mirroringManager.sources = [source, otherSource]
      environment.store.scheduleDisplayReconfiguration()
    }
    defer { environment.mirroringManager.onMirrorChange = nil }

    await environment.store.handleDisplayReconfiguration()

    XCTAssertEqual(environment.store.mirrorSources, [source, otherSource])
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[first.id], source.id)
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[second.id], otherSource.id)
    XCTAssertEqual(
      environment.repository.state.profiles.map(\.mirrorSourceID),
      [source.id, otherSource.id]
    )
    XCTAssertTrue(environment.store.mirrorRestoreFailures.isEmpty)
  }

  func testRepeatedFailureNotificationsKeepRestorationBoundedAndPreserveIntent() async {
    let environment = await connectedEnvironment()
    let profile = environment.store.profiles[0]
    let target = environment.backend.connections[profile.id]!.displayID
    environment.mirroringManager.sources = [source]
    await environment.store.setMirrorSource(source.id, for: profile.id)
    environment.mirroringManager.simulateActualMirror(targetDisplayID: target, sourceID: nil)
    let error = DisplayMirroringError.configurationFailed(1)
    environment.mirroringManager.setMirrorError = error
    environment.mirroringManager.onMirrorAttempt = {
      environment.store.scheduleDisplayReconfiguration()
    }
    defer { environment.mirroringManager.onMirrorAttempt = nil }
    let attemptsBeforeRestoring = environment.mirroringManager.mirrorAttempts.count

    await environment.store.handleDisplayReconfiguration()

    XCTAssertEqual(environment.mirroringManager.mirrorAttempts.count, attemptsBeforeRestoring + 1)
    XCTAssertNil(environment.store.activeMirrorSourceIDs[profile.id])
    XCTAssertTrue(environment.store.hasMirrorRestoreFailure(profileID: profile.id))
    XCTAssertNil(environment.store.takeLastErrorMessage())

    let rejectedSourceID = UUID()
    await environment.store.setMirrorSource(rejectedSourceID, for: profile.id)
    await environment.store.waitForDisplayUpdates()

    XCTAssertEqual(environment.mirroringManager.mirrorAttempts.count, attemptsBeforeRestoring + 3)
    XCTAssertEqual(
      environment.mirroringManager.mirrorAttempts.suffix(3),
      [
        MirrorRequest(targetDisplayID: target, sourceID: source.id),
        MirrorRequest(targetDisplayID: target, sourceID: rejectedSourceID),
        MirrorRequest(targetDisplayID: target, sourceID: source.id),
      ]
    )
    XCTAssertEqual(environment.store.takeLastErrorMessage(), error.localizedDescription)
    XCTAssertEqual(environment.repository.state.profiles[0].mirrorSourceID, source.id)
    XCTAssertNil(environment.store.activeMirrorSourceIDs[profile.id])
    XCTAssertTrue(environment.store.hasMirrorRestoreFailure(profileID: profile.id))
  }

  func testQueuedScreenNotificationRestoresActualStateAfterExplicitSelection() async {
    let environment = await connectedEnvironment()
    let profile = environment.store.profiles[0]
    let target = environment.backend.connections[profile.id]!.displayID
    environment.mirroringManager.sources = [source]
    await environment.store.setMirrorSource(source.id, for: profile.id)
    environment.mirroringManager.simulateActualMirror(targetDisplayID: target, sourceID: nil)
    let restored = expectation(description: "Queued screen notification restores mirroring")
    environment.mirroringManager.onMirrorChange = { restored.fulfill() }
    defer { environment.mirroringManager.onMirrorChange = nil }

    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
    await fulfillment(of: [restored], timeout: 2)
    await environment.store.waitForDisplayUpdates()

    XCTAssertEqual(environment.store.activeMirrorSourceIDs[profile.id], source.id)
    XCTAssertEqual(environment.repository.state.profiles[0].mirrorSourceID, source.id)
    XCTAssertTrue(environment.store.mirrorRestoreFailures.isEmpty)
  }

  private func connectedEnvironment() async -> VirtualDisplayTestEnvironment {
    let environment = VirtualDisplayTestEnvironment(
      state: PersistedState(
        profiles: [
          VirtualDisplayProfile(name: "First", resolutionID: "1920x1080"),
          VirtualDisplayProfile(name: "Second", resolutionID: "1920x1080"),
        ],
        hasAttemptedLoginItemRegistration: true
      )
    )
    await environment.store.start()
    return environment
  }
}
