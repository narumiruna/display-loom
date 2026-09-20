import Combine
import XCTest

@testable import DisplayLoom

@MainActor
final class VirtualDisplayStorePersistenceTests: XCTestCase {
  func testFlagUpdatesPreserveProfilesAndEachOtherAfterReload() async throws {
    let profile = VirtualDisplayProfile(
      name: "Saved", resolutionID: "1920x1080", desiredConnected: false, mirrorSourceID: UUID())
    let environment = VirtualDisplayTestEnvironment(state: PersistedState(profiles: [profile]))
    XCTAssertTrue(environment.repository.savedStates.isEmpty)

    environment.store.acknowledge8KWarning()

    XCTAssertEqual(
      environment.repository.savedStates,
      [PersistedState(profiles: [profile], hasAcknowledged8KWarning: true)]
    )
    await environment.store.start()

    let expected = PersistedState(
      profiles: [profile], hasAcknowledged8KWarning: true, hasAttemptedLoginItemRegistration: true)
    XCTAssertEqual(environment.repository.savedStates.count, 2)
    XCTAssertEqual(environment.repository.state, expected)
    XCTAssertEqual(environment.loginManager.registerCallCount, 1)
    let decoded = try JSONDecoder().decode(
      PersistedState.self, from: JSONEncoder().encode(environment.repository.state))
    let reloaded = VirtualDisplayTestEnvironment(state: decoded)
    await reloaded.store.start()

    XCTAssertEqual(reloaded.store.profiles, [profile])
    XCTAssertFalse(
      reloaded.store.needs8KWarning(for: ResolutionPreset.preset(withID: "7680x4320")!))
    XCTAssertEqual(reloaded.loginManager.registerCallCount, 0)
    XCTAssertTrue(reloaded.repository.savedStates.isEmpty)
  }

  func testProfileMutationsPreserveFlagsOrderAndPublishedUpdatesAfterReload() async throws {
    var first = VirtualDisplayProfile(
      name: "First", resolutionID: "1920x1080", desiredConnected: false, mirrorSourceID: UUID())
    var second = VirtualDisplayProfile(
      name: "Second", resolutionID: "1920x1200", desiredConnected: false)
    let environment = VirtualDisplayTestEnvironment(
      state: PersistedState(
        profiles: [first, second],
        hasAcknowledged8KWarning: true,
        hasAttemptedLoginItemRegistration: true
      )
    )
    var publishedProfiles: [[VirtualDisplayProfile]] = []
    let subscription = environment.store.$profiles.sink { publishedProfiles.append($0) }
    defer { subscription.cancel() }

    await environment.store.renameProfile(id: first.id, to: "Studio")
    first.name = "Studio"
    await environment.store.setResolution(
      ResolutionPreset.preset(withID: "2560x1440")!, for: second.id)
    second.resolutionID = "2560x1440"

    XCTAssertEqual(environment.repository.state.profiles, [first, second])
    XCTAssertEqual(publishedProfiles.last, [first, second])
    environment.store.removeProfile(id: first.id)
    XCTAssertEqual(publishedProfiles.last, [second])
    XCTAssertEqual(publishedProfiles.count, 4)
    XCTAssertEqual(environment.repository.savedStates.count, 3)
    for state in environment.repository.savedStates {
      XCTAssertEqual(state.version, PersistedState.currentVersion)
      XCTAssertTrue(state.hasAcknowledged8KWarning)
      XCTAssertTrue(state.hasAttemptedLoginItemRegistration)
    }
    let decoded = try JSONDecoder().decode(
      PersistedState.self, from: JSONEncoder().encode(environment.repository.state))
    let reloaded = VirtualDisplayTestEnvironment(state: decoded)
    await reloaded.store.start()

    XCTAssertEqual(reloaded.store.profiles, [second])
    XCTAssertFalse(
      reloaded.store.needs8KWarning(for: ResolutionPreset.preset(withID: "7680x4320")!))
    XCTAssertEqual(reloaded.loginManager.registerCallCount, 0)
    XCTAssertTrue(reloaded.repository.savedStates.isEmpty)
  }

  func testSaveNormalizesVersionWithoutChangingOtherFields() {
    let profile = VirtualDisplayProfile(name: "Saved", resolutionID: "1920x1080")
    let environment = VirtualDisplayTestEnvironment(
      state: PersistedState(
        version: 999, profiles: [profile], hasAttemptedLoginItemRegistration: true)
    )

    environment.store.acknowledge8KWarning()

    XCTAssertEqual(
      environment.repository.state,
      PersistedState(
        profiles: [profile], hasAcknowledged8KWarning: true, hasAttemptedLoginItemRegistration: true
      )
    )
  }
}
