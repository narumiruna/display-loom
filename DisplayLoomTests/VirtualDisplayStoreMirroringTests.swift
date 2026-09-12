import XCTest

@testable import DisplayLoom

@MainActor
final class VirtualDisplayStoreMirroringTests: XCTestCase {
  func testSelectingAndClearingMirrorSourcePersistsOnlySuccessfulChanges() async {
    let environment = VirtualDisplayTestEnvironment()
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let targetDisplayID = environment.backend.connections[profileID]!.displayID

    environment.store.setMirrorSource(source.id, for: profileID)

    XCTAssertEqual(environment.store.profile(id: profileID)?.mirrorSourceID, source.id)
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[profileID], source.id)
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: targetDisplayID, sourceID: source.id)
    )
    XCTAssertEqual(environment.repository.state.profiles[0].mirrorSourceID, source.id)

    environment.mirroringManager.setMirrorError = DisplayMirroringError.configurationFailed(1)
    environment.store.setMirrorSource(UUID(), for: profileID)

    XCTAssertEqual(environment.store.profile(id: profileID)?.mirrorSourceID, source.id)
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[profileID], source.id)
    XCTAssertNotNil(environment.store.takeLastErrorMessage())

    environment.mirroringManager.setMirrorError = nil
    environment.mirroringManager.onMirrorChange = {
      environment.store.handleDisplayReconfiguration()
    }
    environment.store.setMirrorSource(nil, for: profileID)

    XCTAssertNil(environment.store.profile(id: profileID)?.mirrorSourceID)
    XCTAssertNil(environment.store.activeMirrorSourceIDs[profileID])
    XCTAssertNil(environment.mirroringManager.mirrorSourceID(for: targetDisplayID))
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: targetDisplayID, sourceID: nil)
    )
  }

  func testStartRestoresPersistedMirrorAfterConnecting() async {
    let source = makeMirrorSource()
    let environment = makeEnvironment(restoring: source)
    let profile = environment.store.profiles[0]
    environment.mirroringManager.sources = [source]

    await environment.store.start()

    let targetDisplayID = environment.backend.connections[profile.id]!.displayID
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests,
      [MirrorRequest(targetDisplayID: targetDisplayID, sourceID: source.id)]
    )
    XCTAssertTrue(environment.store.isMirroring(profileID: profile.id))
    XCTAssertTrue(environment.mirroringManager.excludedDisplayIDSets.contains([targetDisplayID]))
  }

  func testRestoreFailureExposesActualStateAndClearsAfterRetry() async {
    let source = makeMirrorSource()
    let environment = makeEnvironment(restoring: source)
    let profile = environment.store.profiles[0]
    environment.mirroringManager.sources = [source]
    environment.mirroringManager.setMirrorError = DisplayMirroringError.configurationFailed(1)

    await environment.store.start()

    XCTAssertEqual(environment.store.profile(id: profile.id)?.mirrorSourceID, source.id)
    XCTAssertNil(environment.store.activeMirrorSourceIDs[profile.id])
    XCTAssertTrue(environment.store.hasMirrorRestoreFailure(profileID: profile.id))

    environment.mirroringManager.setMirrorError = nil
    environment.store.handleDisplayReconfiguration()

    XCTAssertEqual(environment.store.activeMirrorSourceIDs[profile.id], source.id)
    XCTAssertFalse(environment.store.hasMirrorRestoreFailure(profileID: profile.id))
  }

  func testReconnectUsesNewTargetAndKeepsDesiredMirrorSource() async {
    let environment = VirtualDisplayTestEnvironment()
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let firstTarget = environment.backend.connections[profileID]!.displayID
    environment.store.setMirrorSource(source.id, for: profileID)

    environment.store.disconnectProfile(id: profileID)
    await environment.store.connectProfile(id: profileID)

    let secondTarget = environment.backend.connections[profileID]!.displayID
    XCTAssertNotEqual(secondTarget, firstTarget)
    XCTAssertEqual(environment.store.profile(id: profileID)?.mirrorSourceID, source.id)
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests.suffix(2),
      [
        MirrorRequest(targetDisplayID: firstTarget, sourceID: nil),
        MirrorRequest(targetDisplayID: secondTarget, sourceID: source.id),
      ]
    )
  }

  func testUnavailableSourceRestoresWhenItReappearsWithoutReentrantLoop() async {
    let source = makeMirrorSource()
    let environment = makeEnvironment(restoring: source)
    let profile = environment.store.profiles[0]
    await environment.store.start()
    XCTAssertTrue(environment.mirroringManager.mirrorRequests.isEmpty)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.mirrorSourceID, source.id)
    XCTAssertFalse(environment.store.hasMirrorRestoreFailure(profileID: profile.id))

    environment.mirroringManager.sources = [source]
    environment.mirroringManager.onMirrorChange = {
      environment.store.handleDisplayReconfiguration()
    }
    environment.store.handleDisplayReconfiguration()

    let targetDisplayID = environment.backend.connections[profile.id]!.displayID
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests,
      [MirrorRequest(targetDisplayID: targetDisplayID, sourceID: source.id)]
    )
    XCTAssertTrue(environment.store.isMirroring(profileID: profile.id))
  }

  func testWakeRestoresMirrorIfSystemClearedIt() async {
    let environment = VirtualDisplayTestEnvironment()
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let targetDisplayID = environment.backend.connections[profileID]!.displayID
    environment.store.setMirrorSource(source.id, for: profileID)
    environment.mirroringManager.simulateActualMirror(
      targetDisplayID: targetDisplayID, sourceID: nil)

    await environment.store.retryDesiredConnectionsAfterWake()

    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: targetDisplayID, sourceID: source.id)
    )
    XCTAssertTrue(environment.store.isMirroring(profileID: profileID))
  }

  func testDisconnectRemoveAndTerminationClearActualMirror() async {
    let source = makeMirrorSource()

    let disconnectEnvironment = VirtualDisplayTestEnvironment()
    disconnectEnvironment.mirroringManager.sources = [source]
    await disconnectEnvironment.store.addDisplay(
      resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let disconnectedID = disconnectEnvironment.store.profiles[0].id
    let disconnectedTarget = disconnectEnvironment.backend.connections[disconnectedID]!.displayID
    disconnectEnvironment.store.setMirrorSource(source.id, for: disconnectedID)
    disconnectEnvironment.store.disconnectProfile(id: disconnectedID)
    XCTAssertEqual(
      disconnectEnvironment.store.profile(id: disconnectedID)?.mirrorSourceID, source.id)
    XCTAssertEqual(
      disconnectEnvironment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: disconnectedTarget, sourceID: nil)
    )

    let removeEnvironment = VirtualDisplayTestEnvironment()
    removeEnvironment.mirroringManager.sources = [source]
    await removeEnvironment.store.addDisplay(
      resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let removedID = removeEnvironment.store.profiles[0].id
    let removedTarget = removeEnvironment.backend.connections[removedID]!.displayID
    removeEnvironment.store.setMirrorSource(source.id, for: removedID)
    removeEnvironment.store.removeProfile(id: removedID)
    XCTAssertEqual(
      removeEnvironment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: removedTarget, sourceID: nil)
    )
    XCTAssertTrue(removeEnvironment.repository.state.profiles.isEmpty)

    let terminationEnvironment = VirtualDisplayTestEnvironment()
    terminationEnvironment.mirroringManager.sources = [source]
    await terminationEnvironment.store.addDisplay(
      resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let terminatedID = terminationEnvironment.store.profiles[0].id
    let terminatedTarget = terminationEnvironment.backend.connections[terminatedID]!.displayID
    terminationEnvironment.store.setMirrorSource(source.id, for: terminatedID)
    terminationEnvironment.backend.terminate(profileID: terminatedID)
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(
      terminationEnvironment.mirroringManager.mirrorRequests.last,
      MirrorRequest(targetDisplayID: terminatedTarget, sourceID: nil)
    )
    XCTAssertNil(terminationEnvironment.store.activeMirrorSourceIDs[terminatedID])
  }

  func testRenameClearsOldMirrorAndRestoresItOnNewConnection() async {
    let environment = VirtualDisplayTestEnvironment()
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let firstConnection = environment.backend.connections[profileID]!
    environment.store.setMirrorSource(source.id, for: profileID)

    await environment.store.renameProfile(id: profileID, to: "Studio")

    let secondConnection = environment.backend.connections[profileID]!
    XCTAssertTrue(firstConnection.invalidated)
    XCTAssertNotEqual(secondConnection.displayID, firstConnection.displayID)
    XCTAssertEqual(environment.store.profile(id: profileID)?.name, "Studio")
    XCTAssertEqual(environment.store.profile(id: profileID)?.mirrorSourceID, source.id)
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[profileID], source.id)
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests.suffix(2),
      [
        MirrorRequest(targetDisplayID: firstConnection.displayID, sourceID: nil),
        MirrorRequest(targetDisplayID: secondConnection.displayID, sourceID: source.id),
      ]
    )
  }

  func testDisconnectInvalidatesConnectionEvenWhenClearingMirrorFails() async {
    let environment = VirtualDisplayTestEnvironment()
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    let connection = environment.backend.connections[profileID]!
    environment.store.setMirrorSource(source.id, for: profileID)
    environment.mirroringManager.setMirrorError = DisplayMirroringError.configurationFailed(1)

    environment.store.disconnectProfile(id: profileID)

    XCTAssertTrue(connection.invalidated)
    XCTAssertEqual(environment.store.state(for: profileID), .disconnected)
    XCTAssertNil(environment.store.activeMirrorSourceIDs[profileID])
    XCTAssertFalse(environment.store.hasMirrorRestoreFailure(profileID: profileID))
    XCTAssertEqual(environment.store.profile(id: profileID)?.mirrorSourceID, source.id)
    XCTAssertEqual(environment.store.profile(id: profileID)?.desiredConnected, false)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
  }

  func testResolutionChangeIsRejectedWhileMirroring() async {
    let environment = VirtualDisplayTestEnvironment()
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: ResolutionPreset.preset(withID: "1920x1080")!)
    let profileID = environment.store.profiles[0].id
    environment.store.setMirrorSource(source.id, for: profileID)

    await environment.store.setResolution(
      ResolutionPreset.preset(withID: "2560x1440")!,
      for: profileID
    )

    XCTAssertEqual(environment.store.profile(id: profileID)?.resolutionID, "1920x1080")
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
    XCTAssertNotNil(environment.store.takeLastErrorMessage())
  }

  private func makeMirrorSource() -> DisplayMirrorSource {
    DisplayMirrorSource(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Studio Display"
    )
  }

  private func makeEnvironment(restoring source: DisplayMirrorSource)
    -> VirtualDisplayTestEnvironment
  {
    VirtualDisplayTestEnvironment(
      state: PersistedState(
        profiles: [
          VirtualDisplayProfile(
            name: "Mirrored",
            resolutionID: "1920x1080",
            mirrorSourceID: source.id
          )
        ],
        hasAttemptedLoginItemRegistration: true
      )
    )
  }
}
