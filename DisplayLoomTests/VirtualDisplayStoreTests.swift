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

    await environment.store.disconnectProfile(id: profileID)
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
    await environment.store.removeProfile(id: profileID)
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
    XCTAssertEqual(
      environment.store.takeNextErrorMessage(),
      VirtualDisplayBackendError.modeSwitchFailed.localizedDescription
    )
  }

  func testDisconnectedResolutionChangeIsSavedWithoutBackendCall() async {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    await environment.store.disconnectProfile(id: profileID)

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
      name: "Desired",
      resolutionID: "1920x1080",
      desiredConnected: true
    )
    let disabled = VirtualDisplayProfile(
      name: "Disabled",
      resolutionID: "1920x1200",
      desiredConnected: false
    )
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
    let connection = environment.backend.connections[profileID]!
    let terminated = expectation(description: "Terminated connection is invalidated")
    connection.onInvalidate = { terminated.fulfill() }
    defer { connection.onInvalidate = nil }

    environment.backend.terminate(profileID: profileID)
    await fulfillment(of: [terminated], timeout: 2)
    await environment.store.waitForDisplayUpdates()

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
    let expectedMessage = VirtualDisplayBackendError.creationFailed.localizedDescription
    XCTAssertEqual(environment.store.state(for: profile.id), .failed(message: expectedMessage))
    XCTAssertEqual(environment.store.takeNextErrorMessage(), expectedMessage)
  }

  func testDistinctFailuresRemainAvailableInReportOrderUntilConsumed() async {
    let environment = VirtualDisplayTestEnvironment()
    let firstError = VirtualDisplayBackendError.unexpected("First connection failure")
    let secondError = VirtualDisplayBackendError.unexpected("Second connection failure")
    let resolution = ResolutionPreset.preset(withID: "1920x1080")!
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
    XCTAssertNil(environment.store.takeNextErrorMessage())

    environment.backend.connectError = firstError
    await environment.store.addDisplay(resolution: resolution)
    environment.backend.connectError = secondError
    await environment.store.addDisplay(resolution: resolution)

    XCTAssertEqual(
      environment.store.pendingErrorMessages,
      [firstError.localizedDescription, secondError.localizedDescription]
    )
    XCTAssertEqual(environment.store.takeNextErrorMessage(), firstError.localizedDescription)
    XCTAssertEqual(environment.store.pendingErrorMessages, [secondError.localizedDescription])
    XCTAssertEqual(environment.store.takeNextErrorMessage(), secondError.localizedDescription)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
    XCTAssertNil(environment.store.takeNextErrorMessage())
  }

  func testIdenticalFailuresRemainAvailableUntilEachIsConsumed() async {
    let environment = VirtualDisplayTestEnvironment()
    let error = VirtualDisplayBackendError.creationFailed
    environment.backend.connectError = error

    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    await environment.store.connectProfile(id: profileID)

    XCTAssertEqual(
      environment.store.pendingErrorMessages,
      [error.localizedDescription, error.localizedDescription]
    )
    XCTAssertEqual(environment.store.takeNextErrorMessage(), error.localizedDescription)
    XCTAssertEqual(environment.store.pendingErrorMessages, [error.localizedDescription])
    XCTAssertEqual(environment.store.takeNextErrorMessage(), error.localizedDescription)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
    XCTAssertNil(environment.store.takeNextErrorMessage())
  }

  func testOverlappingOperationFailuresRemainAvailableInReportOrder() async throws {
    try await PerformanceChecks.overlappingOperationErrors()
  }

  func testUnexpectedBackendErrorsArePresentedWithoutDoubleWrapping() async {
    let environment = VirtualDisplayTestEnvironment()
    let connectionError = VirtualDisplayBackendError.unexpected("Connection detail")
    environment.backend.connectError = connectionError
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profile = environment.store.profiles[0]

    XCTAssertEqual(environment.store.takeNextErrorMessage(), connectionError.localizedDescription)
    XCTAssertEqual(
      environment.store.state(for: profile.id),
      .failed(message: connectionError.localizedDescription)
    )
    XCTAssertTrue(environment.repository.state.profiles[0].desiredConnected)

    environment.backend.connectError = nil
    await environment.store.connectProfile(id: profile.id)
    let resolutionError = VirtualDisplayBackendError.unexpected("Resolution detail")
    environment.backend.setResolutionError = resolutionError
    let savedState = environment.repository.state

    await environment.store.setResolution(
      ResolutionPreset.preset(withID: "2560x1440")!,
      for: profile.id
    )

    XCTAssertEqual(environment.store.takeNextErrorMessage(), resolutionError.localizedDescription)
    XCTAssertEqual(environment.repository.state, savedState)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.resolutionID, "1920x1080")
    XCTAssertTrue(environment.store.state(for: profile.id).isConnected)
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
