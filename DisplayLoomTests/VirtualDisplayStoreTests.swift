import XCTest

@testable import DisplayLoom

@MainActor
final class VirtualDisplayStoreTests: XCTestCase {
  func testAddConnectsAndPersistsProfile() async {
    let environment = VirtualDisplayTestEnvironment()
    let preset = ResolutionPreset.preset(withID: "1920x1080")!

    await environment.store.addDisplay(resolution: preset)

    XCTAssertEqual(environment.store.profiles.count, 1)
    XCTAssertEqual(environment.store.profiles[0].name, "Display Loom 1")
    XCTAssertEqual(environment.store.profiles[0].resolutionID, preset.id)
    XCTAssertTrue(environment.store.profiles[0].desiredConnected)
    XCTAssertTrue(environment.store.state(for: environment.store.profiles[0].id).isConnected)
    XCTAssertEqual(environment.backend.connectRequests.count, 1)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
  }

  func testMultipleDisplaysOperateIndependently() async {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1200")!)
    let first = environment.store.profiles[0]
    let second = environment.store.profiles[1]

    await environment.store.setResolution(
      ResolutionPreset.preset(withID: "3840x2400")!,
      for: second.id
    )

    XCTAssertEqual(environment.store.profile(id: first.id)?.resolutionID, "1920x1080")
    XCTAssertEqual(environment.store.profile(id: second.id)?.resolutionID, "3840x2400")
    XCTAssertEqual(environment.backend.resolutionRequests.count, 1)
    XCTAssertEqual(environment.backend.resolutionRequests[0].0, "3840x2400")
    XCTAssertTrue(environment.store.state(for: first.id).isConnected)
    XCTAssertTrue(environment.store.state(for: second.id).isConnected)
  }

  func testDisconnectReconnectRenameAndRemove() async {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let firstConnection = environment.backend.connections[profileID]!

    environment.store.disconnectProfile(id: profileID)
    XCTAssertTrue(firstConnection.invalidated)
    XCTAssertEqual(environment.store.state(for: profileID), .disconnected)
    XCTAssertFalse(environment.store.profile(id: profileID)!.desiredConnected)

    await environment.store.connectProfile(id: profileID)
    let secondConnection = environment.backend.connections[profileID]!
    XCTAssertTrue(environment.store.state(for: profileID).isConnected)

    await environment.store.renameProfile(id: profileID, to: "Studio")
    XCTAssertTrue(secondConnection.invalidated)
    XCTAssertEqual(environment.store.profile(id: profileID)?.name, "Studio")
    XCTAssertEqual(environment.backend.connectRequests.last?.0.name, "Studio")

    let latestConnection = environment.backend.connections[profileID]!
    environment.store.removeProfile(id: profileID)
    XCTAssertTrue(latestConnection.invalidated)
    XCTAssertTrue(environment.store.profiles.isEmpty)
    XCTAssertTrue(environment.repository.state.profiles.isEmpty)
  }

  func testConnectedResolutionChangeRollsBackOnFailure() async {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    environment.backend.setResolutionError = VirtualDisplayBackendError.modeSwitchFailed

    await environment.store.setResolution(
      ResolutionPreset.preset(withID: "3840x2160")!,
      for: profileID
    )

    XCTAssertEqual(environment.store.profile(id: profileID)?.resolutionID, "1920x1080")
    XCTAssertTrue(environment.store.state(for: profileID).isConnected)
    XCTAssertNotNil(environment.store.takeLastErrorMessage())
  }

  func testDisconnectedResolutionChangeIsSavedWithoutBackendCall() async {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    environment.store.disconnectProfile(id: profileID)

    await environment.store.setResolution(
      ResolutionPreset.preset(withID: "2560x1440")!,
      for: profileID
    )

    XCTAssertEqual(environment.store.profile(id: profileID)?.resolutionID, "2560x1440")
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
    XCTAssertEqual(environment.store.state(for: profileID), .disconnected)
  }

  func testStartRestoresOnlyDesiredConnections() async {
    let desired = VirtualDisplayProfile(
      name: "Desired", resolutionID: "1920x1080", desiredConnected: true)
    let disabled = VirtualDisplayProfile(
      name: "Disabled", resolutionID: "1920x1200", desiredConnected: false)
    let environment = VirtualDisplayTestEnvironment(
      state: PersistedState(
        profiles: [desired, disabled],
        hasAttemptedLoginItemRegistration: true
      )
    )

    await environment.store.start()

    XCTAssertEqual(environment.backend.connectRequests.map(\.0.id), [desired.id])
    XCTAssertTrue(environment.store.state(for: desired.id).isConnected)
    XCTAssertEqual(environment.store.state(for: disabled.id), .disconnected)
    XCTAssertEqual(environment.loginManager.registerCallCount, 0)
  }

  func testTerminationUpdatesStateAndWakeRetriesOnce() async {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id

    environment.backend.terminate(profileID: profileID)
    await Task.yield()
    await Task.yield()

    guard case .failed = environment.store.state(for: profileID) else {
      return XCTFail("Expected a failed state after termination")
    }
    let requestCountAfterTermination = environment.backend.connectRequests.count

    await environment.store.retryDesiredConnectionsAfterWake()

    XCTAssertEqual(environment.backend.connectRequests.count, requestCountAfterTermination + 1)
    XCTAssertTrue(environment.store.state(for: profileID).isConnected)
  }

  func testWakeReconnectsAnInvalidHandleWithoutTerminationCallback() async {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let firstConnection = environment.backend.connections[profileID]!
    firstConnection.invalidate()
    let initialRequestCount = environment.backend.connectRequests.count

    await environment.store.retryDesiredConnectionsAfterWake()

    XCTAssertEqual(environment.backend.connectRequests.count, initialRequestCount + 1)
    XCTAssertTrue(environment.store.state(for: profileID).isConnected)
    XCTAssertFalse(environment.backend.connections[profileID] === firstConnection)
  }

  func testConnectFailureKeepsDesiredProfileForRetry() async {
    let environment = VirtualDisplayTestEnvironment()
    environment.backend.connectError = VirtualDisplayBackendError.creationFailed

    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)

    let profile = environment.store.profiles[0]
    XCTAssertTrue(profile.desiredConnected)
    guard case .failed = environment.store.state(for: profile.id) else {
      return XCTFail("Expected failed state")
    }
    XCTAssertNotNil(environment.store.takeLastErrorMessage())
  }

  func test8KWarningAcknowledgementPersists() {
    let environment = VirtualDisplayTestEnvironment()
    let eightK = ResolutionPreset.preset(withID: "7680x4320")!

    XCTAssertTrue(environment.store.needs8KWarning(for: eightK))
    environment.store.acknowledge8KWarning()

    XCTAssertFalse(environment.store.needs8KWarning(for: eightK))
    XCTAssertTrue(environment.repository.state.hasAcknowledged8KWarning)
  }
}
