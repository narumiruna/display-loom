import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import DisplayLoom

@MainActor
final class DisplayManagementTests: XCTestCase {
  func testBuiltAppSupportsDockAccess() {
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, false)
  }

  func testRecommendedResolutionIsFullHD() {
    XCTAssertEqual(
      DisplayActions.recommendedResolution,
      ResolutionPreset.preset(withID: "1920x1080")
    )
    XCTAssertFalse(DisplayActions.recommendedResolution.is8K)
  }

  func testAddDisplayConnectsAndPersistsChosenResolution() async throws {
    let environment = VirtualDisplayTestEnvironment()
    let actions = DisplayActions(store: environment.store)
    let resolution = ResolutionPreset.preset(withID: "1920x1200")!

    await actions.addDisplay(resolution)

    XCTAssertEqual(environment.store.profiles.count, 1)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    let connection = try XCTUnwrap(environment.backend.connections[profile.id])
    XCTAssertEqual(profile.resolutionID, resolution.id)
    XCTAssertTrue(profile.desiredConnected)
    XCTAssertEqual(
      environment.store.state(for: profile.id),
      .connected(displayID: connection.displayID)
    )
    XCTAssertEqual(environment.backend.connectRequests.map(\.0.id), [profile.id])
    XCTAssertEqual(environment.backend.connectRequests.first?.1, resolution)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testConnectRestoresOnlySelectedSavedProfile() async throws {
    let untouched = VirtualDisplayProfile(
      name: "Offline",
      resolutionID: "1920x1080",
      desiredConnected: false
    )
    let selected = VirtualDisplayProfile(
      name: "Studio",
      resolutionID: "1920x1200",
      desiredConnected: false
    )
    let environment = VirtualDisplayTestEnvironment(
      state: PersistedState(profiles: [untouched, selected])
    )
    let actions = DisplayActions(store: environment.store)

    await actions.connect(selected)

    let connection = try XCTUnwrap(environment.backend.connections[selected.id])
    XCTAssertEqual(environment.backend.connectRequests.map(\.0.id), [selected.id])
    XCTAssertEqual(environment.backend.connectRequests.first?.1.id, selected.resolutionID)
    XCTAssertEqual(
      environment.store.state(for: selected.id),
      .connected(displayID: connection.displayID)
    )
    XCTAssertEqual(environment.store.profile(id: selected.id)?.desiredConnected, true)
    XCTAssertEqual(environment.store.profile(id: untouched.id), untouched)
    XCTAssertEqual(environment.store.state(for: untouched.id), .disconnected)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    XCTAssertEqual(environment.loginManager.registerCallCount, 0)
  }

  func testDisconnectKeepsOtherDisplayConnectedAndPersistsProfile() async throws {
    let environment = VirtualDisplayTestEnvironment()
    let actions = DisplayActions(store: environment.store)
    await actions.addDisplay(ResolutionPreset.preset(withID: "1920x1080")!)
    await actions.addDisplay(ResolutionPreset.preset(withID: "1920x1200")!)
    let untouched = try XCTUnwrap(environment.store.profiles.first)
    let selected = try XCTUnwrap(environment.store.profiles.last)
    let untouchedConnection = try XCTUnwrap(environment.backend.connections[untouched.id])
    let selectedConnection = try XCTUnwrap(environment.backend.connections[selected.id])

    await actions.disconnect(selected)

    XCTAssertTrue(selectedConnection.invalidated)
    XCTAssertFalse(untouchedConnection.invalidated)
    XCTAssertEqual(environment.store.state(for: selected.id), .disconnected)
    XCTAssertEqual(environment.store.profile(id: selected.id)?.desiredConnected, false)
    XCTAssertTrue(environment.store.state(for: untouched.id).isConnected)
    XCTAssertEqual(environment.store.profile(id: untouched.id), untouched)
    XCTAssertEqual(environment.store.profiles.count, 2)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    XCTAssertEqual(environment.backend.connectRequests.count, 2)
  }

  func testSelectResolutionChangesOnlySelectedConnectedDisplay() async throws {
    let environment = VirtualDisplayTestEnvironment()
    let actions = DisplayActions(store: environment.store)
    await actions.addDisplay(ResolutionPreset.preset(withID: "1920x1080")!)
    await actions.addDisplay(ResolutionPreset.preset(withID: "1920x1200")!)
    let untouched = try XCTUnwrap(environment.store.profiles.first)
    let selected = try XCTUnwrap(environment.store.profiles.last)
    let connection = try XCTUnwrap(environment.backend.connections[selected.id])
    let resolution = ResolutionPreset.preset(withID: "2560x1600")!

    await actions.selectResolution(resolution, for: selected.id)

    XCTAssertEqual(environment.store.profile(id: untouched.id), untouched)
    XCTAssertEqual(environment.store.profile(id: selected.id)?.resolutionID, resolution.id)
    XCTAssertEqual(environment.backend.resolutionRequests.map(\.0), [resolution.id])
    XCTAssertEqual(environment.backend.resolutionRequests.map(\.1), [connection.displayID])
    XCTAssertEqual(environment.backend.appliedResolutionIDs[connection.displayID], resolution.id)
    XCTAssertTrue(environment.store.state(for: untouched.id).isConnected)
    XCTAssertEqual(
      environment.store.state(for: selected.id),
      .connected(displayID: connection.displayID)
    )
    XCTAssertEqual(environment.backend.connectRequests.count, 2)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
  }

  func testDisconnectedResolutionSelectionIsUsedOnNextConnect() async throws {
    let profile = VirtualDisplayProfile(
      name: "Studio",
      resolutionID: "1920x1080",
      desiredConnected: false
    )
    let environment = VirtualDisplayTestEnvironment(
      state: PersistedState(profiles: [profile])
    )
    let actions = DisplayActions(store: environment.store)
    let resolution = ResolutionPreset.preset(withID: "2560x1440")!

    await actions.selectResolution(resolution, for: profile.id)

    XCTAssertEqual(environment.store.profile(id: profile.id)?.resolutionID, resolution.id)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.desiredConnected, false)
    XCTAssertEqual(environment.store.state(for: profile.id), .disconnected)
    XCTAssertTrue(environment.backend.connectRequests.isEmpty)
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)

    await actions.connect(profile)

    let connection = try XCTUnwrap(environment.backend.connections[profile.id])
    XCTAssertEqual(environment.backend.connectRequests.count, 1)
    XCTAssertEqual(environment.backend.connectRequests.first?.1, resolution)
    XCTAssertEqual(environment.backend.appliedResolutionIDs[connection.displayID], resolution.id)
    XCTAssertTrue(environment.store.state(for: profile.id).isConnected)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.desiredConnected, true)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
  }

  func testSelectingAndClearingMirrorSourceAffectsOnlySelectedDisplay() async throws {
    let environment = VirtualDisplayTestEnvironment()
    let actions = DisplayActions(store: environment.store)
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await actions.addDisplay(ResolutionPreset.preset(withID: "1920x1080")!)
    await actions.addDisplay(ResolutionPreset.preset(withID: "1920x1200")!)
    let untouched = try XCTUnwrap(environment.store.profiles.first)
    let selected = try XCTUnwrap(environment.store.profiles.last)
    let connection = try XCTUnwrap(environment.backend.connections[selected.id])

    await actions.setMirrorSource(source.id, for: selected.id)

    XCTAssertEqual(environment.store.profile(id: selected.id)?.mirrorSourceID, source.id)
    XCTAssertEqual(environment.store.activeMirrorSourceIDs, [selected.id: source.id])
    XCTAssertEqual(environment.store.profile(id: untouched.id), untouched)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests,
      [MirrorRequest(targetDisplayID: connection.displayID, sourceID: source.id)]
    )

    await actions.setMirrorSource(nil, for: selected.id)

    XCTAssertNil(environment.store.profile(id: selected.id)?.mirrorSourceID)
    XCTAssertTrue(environment.store.activeMirrorSourceIDs.isEmpty)
    XCTAssertNil(environment.mirroringManager.mirrorSourceID(for: connection.displayID))
    XCTAssertEqual(environment.store.profile(id: untouched.id), untouched)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests,
      [
        MirrorRequest(targetDisplayID: connection.displayID, sourceID: source.id),
        MirrorRequest(targetDisplayID: connection.displayID, sourceID: nil),
      ]
    )
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
  }

  func testReconnectRestoresSelectedMirrorOnNewConnection() async throws {
    let environment = VirtualDisplayTestEnvironment()
    let actions = DisplayActions(store: environment.store)
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await actions.addDisplay(ResolutionPreset.preset(withID: "1920x1080")!)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    let firstConnection = try XCTUnwrap(environment.backend.connections[profile.id])
    await actions.setMirrorSource(source.id, for: profile.id)

    await actions.disconnect(profile)

    XCTAssertTrue(firstConnection.invalidated)
    XCTAssertFalse(environment.store.isMirroring(profileID: profile.id))
    XCTAssertEqual(environment.store.profile(id: profile.id)?.mirrorSourceID, source.id)
    XCTAssertEqual(environment.store.state(for: profile.id), .disconnected)

    await actions.connect(profile)

    let secondConnection = try XCTUnwrap(environment.backend.connections[profile.id])
    XCTAssertNotEqual(firstConnection.displayID, secondConnection.displayID)
    XCTAssertTrue(environment.store.state(for: profile.id).isConnected)
    XCTAssertEqual(environment.store.activeMirrorSourceIDs[profile.id], source.id)
    XCTAssertEqual(
      environment.mirroringManager.mirrorRequests,
      [
        MirrorRequest(targetDisplayID: firstConnection.displayID, sourceID: source.id),
        MirrorRequest(targetDisplayID: firstConnection.displayID, sourceID: nil),
        MirrorRequest(targetDisplayID: secondConnection.displayID, sourceID: source.id),
      ]
    )
    XCTAssertEqual(environment.backend.connectRequests.count, 2)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
  }

  func testEmptyManagementViewLaysOutWithoutStartingServices() {
    let environment = VirtualDisplayTestEnvironment()

    assertManagementViewLaysOut(store: environment.store)

    XCTAssertTrue(environment.store.profiles.isEmpty)
    XCTAssertTrue(environment.backend.connectRequests.isEmpty)
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
    XCTAssertTrue(environment.mirroringManager.mirrorAttempts.isEmpty)
    XCTAssertTrue(environment.repository.savedStates.isEmpty)
    XCTAssertEqual(environment.loginManager.registerCallCount, 0)
    XCTAssertEqual(environment.loginManager.openSettingsCallCount, 0)
  }

  func testPopulatedManagementViewLaysOutWithoutChangingDisplays() async throws {
    let offline = VirtualDisplayProfile(
      name: "Offline",
      resolutionID: "1920x1080",
      desiredConnected: false
    )
    let environment = VirtualDisplayTestEnvironment(
      state: PersistedState(profiles: [offline])
    )
    let actions = DisplayActions(store: environment.store)
    let source = makeMirrorSource()
    environment.mirroringManager.sources = [source]
    await actions.addDisplay(ResolutionPreset.preset(withID: "1920x1080")!)
    await actions.addDisplay(ResolutionPreset.preset(withID: "1920x1200")!)
    let mirrored = try XCTUnwrap(environment.store.profiles.last)
    await actions.setMirrorSource(source.id, for: mirrored.id)
    let profiles = environment.store.profiles
    let mirrorAttempts = environment.mirroringManager.mirrorAttempts
    let savedStateCount = environment.repository.savedStates.count

    assertManagementViewLaysOut(store: environment.store)

    XCTAssertEqual(environment.store.profiles, profiles)
    XCTAssertEqual(environment.store.state(for: offline.id), .disconnected)
    XCTAssertTrue(environment.store.isMirroring(profileID: mirrored.id))
    XCTAssertEqual(environment.backend.connectRequests.count, 2)
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
    XCTAssertEqual(environment.mirroringManager.mirrorAttempts, mirrorAttempts)
    XCTAssertEqual(environment.repository.savedStates.count, savedStateCount)
    XCTAssertEqual(environment.loginManager.registerCallCount, 0)
    XCTAssertEqual(environment.loginManager.openSettingsCallCount, 0)
  }

  func testAutomaticNoticesWaitForApplicationActivation() async {
    let environment = VirtualDisplayTestEnvironment()
    environment.loginManager.status = .requiresApproval
    environment.store.setLaunchAtLoginEnabled(true)
    await environment.store.renameProfile(id: UUID(), to: "")
    await environment.store.connectProfile(id: UUID())
    let messages = environment.store.pendingErrorMessages
    XCTAssertEqual(messages.count, 2)
    XCTAssertNotEqual(messages.first, messages.last)
    var isActive = false
    var notices: [String] = []
    let actions = DisplayActions(
      store: environment.store,
      isApplicationActive: { isActive },
      showError: { notices.append($0) },
      showLaunchAtLoginApproval: { openSettings in
        XCTAssertFalse(environment.store.shouldShowLaunchAtLoginApproval)
        notices.append("approval")
        openSettings()
      }
    )

    actions.presentPendingMessagesIfActive()

    XCTAssertTrue(notices.isEmpty)
    XCTAssertTrue(environment.store.shouldShowLaunchAtLoginApproval)
    XCTAssertEqual(environment.store.pendingErrorMessages, messages)
    XCTAssertEqual(environment.loginManager.openSettingsCallCount, 0)

    isActive = true
    actions.presentPendingMessagesIfActive()
    actions.presentPendingMessagesIfActive()

    XCTAssertEqual(notices, ["approval"] + messages)
    XCTAssertFalse(environment.store.shouldShowLaunchAtLoginApproval)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
    XCTAssertEqual(environment.loginManager.openSettingsCallCount, 1)
  }

  func testAutomaticErrorDrainStopsWhenApplicationLosesFocus() async {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.renameProfile(id: UUID(), to: "")
    await environment.store.connectProfile(id: UUID())
    let messages = environment.store.pendingErrorMessages
    var isActive = true
    var shown: [String] = []
    let actions = DisplayActions(
      store: environment.store,
      isApplicationActive: { isActive },
      showError: {
        shown.append($0)
        isActive = false
      }
    )

    actions.presentPendingMessagesIfActive()
    actions.presentPendingMessagesIfActive()

    XCTAssertEqual(shown, Array(messages.prefix(1)))
    XCTAssertEqual(environment.store.pendingErrorMessages, Array(messages.dropFirst()))

    isActive = true
    actions.presentPendingMessagesIfActive()

    XCTAssertEqual(shown, messages)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testErrorWaitsWhenApplicationLosesFocusDuringApproval() async {
    let environment = VirtualDisplayTestEnvironment()
    environment.loginManager.status = .requiresApproval
    environment.store.setLaunchAtLoginEnabled(true)
    await environment.store.renameProfile(id: UUID(), to: "")
    let messages = environment.store.pendingErrorMessages
    var isActive = true
    var shown: [String] = []
    let actions = DisplayActions(
      store: environment.store,
      isApplicationActive: { isActive },
      showError: { shown.append($0) },
      showLaunchAtLoginApproval: { _ in
        shown.append("approval")
        isActive = false
      }
    )

    actions.presentPendingMessagesIfActive()
    actions.presentPendingMessagesIfActive()

    XCTAssertEqual(shown, ["approval"])
    XCTAssertFalse(environment.store.shouldShowLaunchAtLoginApproval)
    XCTAssertEqual(environment.store.pendingErrorMessages, messages)

    isActive = true
    actions.presentPendingMessagesIfActive()

    XCTAssertEqual(shown, ["approval"] + messages)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testNoticePresentationDoesNotReenterAcrossActionHandlers() async {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.renameProfile(id: UUID(), to: "")
    await environment.store.connectProfile(id: UUID())
    let messages = environment.store.pendingErrorMessages
    var events: [String] = []
    let menuActions = DisplayActions(
      store: environment.store,
      showError: { _ in XCTFail("A second action handler must not open a nested alert") }
    )
    let windowActions = DisplayActions(
      store: environment.store,
      isApplicationActive: { true },
      showError: { message in
        events.append("begin: \(message)")
        menuActions.presentPendingMessages()
        events.append("end: \(message)")
      }
    )

    windowActions.presentPendingMessagesIfActive()

    XCTAssertEqual(events, messages.flatMap { ["begin: \($0)", "end: \($0)"] })
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testErrorsQueuedDuringPresentationAreShownOnce() async {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.renameProfile(id: UUID(), to: "")
    let firstMessage = environment.store.pendingErrorMessages.first
    var shown: [String] = []
    var nextMessage: String?
    let menuActions = DisplayActions(
      store: environment.store,
      showError: { _ in XCTFail("A new failure must wait for the current alert") }
    )
    let actions = DisplayActions(
      store: environment.store,
      isApplicationActive: { true },
      showError: { message in
        shown.append(message)
        if shown.count == 1 {
          environment.loginManager.registerError = NSError(domain: "NoticeTests", code: 1)
          environment.store.setLaunchAtLoginEnabled(true)
          nextMessage = environment.store.pendingErrorMessages.first
          menuActions.presentPendingMessages()
        }
      }
    )

    actions.presentPendingMessagesIfActive()

    XCTAssertEqual(shown.count, 2)
    XCTAssertEqual(shown.first, firstMessage)
    XCTAssertEqual(shown.last, nextMessage)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testApprovalQueuedDuringErrorPresentationWaitsForCurrentAlert() async {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.renameProfile(id: UUID(), to: "")
    var events: [String] = []
    let menuActions = DisplayActions(
      store: environment.store,
      showLaunchAtLoginApproval: { _ in XCTFail("Approval must wait for the error alert") }
    )
    let actions = DisplayActions(
      store: environment.store,
      isApplicationActive: { true },
      showError: { _ in
        events.append("begin error")
        environment.loginManager.status = .requiresApproval
        environment.store.setLaunchAtLoginEnabled(true)
        menuActions.presentPendingMessages()
        XCTAssertTrue(environment.store.shouldShowLaunchAtLoginApproval)
        events.append("end error")
      },
      showLaunchAtLoginApproval: { _ in
        XCTAssertFalse(environment.store.shouldShowLaunchAtLoginApproval)
        events.append("approval")
      }
    )

    actions.presentPendingMessagesIfActive()

    XCTAssertEqual(events, ["begin error", "end error", "approval"])
    XCTAssertFalse(environment.store.shouldShowLaunchAtLoginApproval)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testConcurrentAddRequestsCreateOneDistinctProfileEach() async {
    let environment = VirtualDisplayTestEnvironment()
    let actions = DisplayActions(
      store: environment.store,
      showError: { _ in XCTFail("A fake display connection must succeed") }
    )
    let started = expectation(description: "Both requested displays start connecting")
    started.expectedFulfillmentCount = 2
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    environment.backend.beforeConnect = { _ in
      started.fulfill()
      if !released {
        await withCheckedContinuation { waiters.append($0) }
      }
    }
    let first = Task { await actions.addDisplay(DisplayActions.recommendedResolution) }
    let second = Task { await actions.addDisplay(DisplayActions.recommendedResolution) }

    await fulfillment(of: [started], timeout: 2)

    XCTAssertEqual(environment.store.profiles.count, 2)
    XCTAssertEqual(Set(environment.store.profiles.map(\.id)).count, 2)
    XCTAssertEqual(Set(environment.store.profiles.map(\.name)).count, 2)
    XCTAssertEqual(environment.backend.connectRequests.count, 2)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)

    released = true
    for waiter in waiters { waiter.resume() }
    await first.value
    await second.value
    environment.backend.beforeConnect = nil

    XCTAssertTrue(
      environment.store.profiles.allSatisfy { environment.store.state(for: $0.id).isConnected }
    )
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testCancelled8KChoiceRestoresNativeResolutionControl() async throws {
    let profile = VirtualDisplayProfile(
      name: "Studio",
      resolutionID: "1920x1080",
      desiredConnected: false
    )
    let environment = VirtualDisplayTestEnvironment(state: PersistedState(profiles: [profile]))
    let cancelled = expectation(description: "The 8K warning is cancelled")
    let actions = DisplayActions(
      store: environment.store,
      confirm8K: {
        cancelled.fulfill()
        return false
      },
      showError: { _ in XCTFail("No native error dialog is allowed") }
    )
    let (host, control) = try makeNativeResolutionControl(
      store: environment.store,
      actions: actions
    )
    let eightK = ResolutionPreset.preset(withID: "7680x4320")!
    XCTAssertEqual(control.selectedItem?.title, profile.resolution!.displayName)
    XCTAssertEqual(control.title, profile.resolution!.displayName)

    try selectNativeResolution(eightK, in: control)
    await fulfillment(of: [cancelled], timeout: 2)

    try await assertNativeResolution(profile.resolution!, in: control, hostedBy: host)
    XCTAssertEqual(environment.store.profile(id: profile.id), profile)
    XCTAssertTrue(environment.repository.savedStates.isEmpty)
    XCTAssertTrue(environment.backend.connectRequests.isEmpty)
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
    XCTAssertTrue(environment.store.needs8KWarning(for: eightK))
  }

  func testRejectedConnectedChoiceRestoresNativeResolutionControl() async throws {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    let connection = try XCTUnwrap(environment.backend.connections[profile.id])
    let savedStateCount = environment.repository.savedStates.count
    let resolution = ResolutionPreset.preset(withID: "2560x1440")!
    environment.backend.setResolutionError = .modeSwitchFailed
    let rejected = expectation(description: "The failed resolution reports an error")
    var errors: [String] = []
    let actions = DisplayActions(
      store: environment.store,
      confirm8K: {
        XCTFail("A non-8K choice must not request confirmation")
        return false
      },
      showError: {
        errors.append($0)
        rejected.fulfill()
      }
    )
    let (host, control) = try makeNativeResolutionControl(
      store: environment.store,
      actions: actions
    )

    try selectNativeResolution(resolution, in: control)
    await fulfillment(of: [rejected], timeout: 2)

    try await assertNativeResolution(profile.resolution!, in: control, hostedBy: host)
    XCTAssertEqual(errors, [VirtualDisplayBackendError.modeSwitchFailed.localizedDescription])
    XCTAssertEqual(environment.store.profile(id: profile.id), profile)
    XCTAssertEqual(environment.repository.savedStates.count, savedStateCount)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    XCTAssertEqual(
      environment.backend.appliedResolutionIDs[connection.displayID],
      profile.resolutionID
    )
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
    XCTAssertEqual(environment.backend.connectRequests.count, 1)
    XCTAssertTrue(environment.store.state(for: profile.id).isConnected)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testSuccessfulChoiceUpdatesNativeResolutionAndSavedProfile() async throws {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    let connection = try XCTUnwrap(environment.backend.connections[profile.id])
    let resolution = ResolutionPreset.preset(withID: "2560x1440")!
    let applied = expectation(description: "The native choice reaches the fake backend")
    environment.backend.beforeResolution = { applied.fulfill() }
    let actions = DisplayActions(
      store: environment.store,
      confirm8K: {
        XCTFail("A non-8K choice must not request confirmation")
        return false
      },
      showError: { _ in XCTFail("The fake resolution change must succeed") }
    )
    let (host, control) = try makeNativeResolutionControl(
      store: environment.store,
      actions: actions
    )

    try selectNativeResolution(resolution, in: control)
    await fulfillment(of: [applied], timeout: 2)

    try await assertNativeResolution(resolution, in: control, hostedBy: host)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.resolutionID, resolution.id)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    XCTAssertEqual(environment.backend.resolutionRequests.map(\.0), [resolution.id])
    XCTAssertEqual(environment.backend.resolutionRequests.map(\.1), [connection.displayID])
    XCTAssertEqual(environment.backend.appliedResolutionIDs[connection.displayID], resolution.id)
    XCTAssertEqual(environment.backend.connectRequests.count, 1)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testLaterStoreChangeUpdatesNativeResolutionControl() async throws {
    let profile = VirtualDisplayProfile(
      name: "Studio",
      resolutionID: "1920x1080",
      desiredConnected: false
    )
    let environment = VirtualDisplayTestEnvironment(state: PersistedState(profiles: [profile]))
    let actions = DisplayActions(
      store: environment.store,
      confirm8K: {
        XCTFail("A non-8K choice must not request confirmation")
        return false
      },
      showError: { _ in XCTFail("The saved resolution change must succeed") }
    )
    let (host, control) = try makeNativeResolutionControl(
      store: environment.store,
      actions: actions
    )
    let nativeChoice = ResolutionPreset.preset(withID: "2560x1440")!
    let laterChoice = ResolutionPreset.preset(withID: "3840x2160")!

    try selectNativeResolution(nativeChoice, in: control)
    try await assertNativeResolution(nativeChoice, in: control, hostedBy: host)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.resolutionID, nativeChoice.id)

    await environment.store.setResolution(laterChoice, for: profile.id)

    try await assertNativeResolution(laterChoice, in: control, hostedBy: host)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.resolutionID, laterChoice.id)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    XCTAssertTrue(environment.backend.connectRequests.isEmpty)
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testAccepted8KChoiceCommitsNativeResolutionAndWarningAcknowledgement() async throws {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    let connection = try XCTUnwrap(environment.backend.connections[profile.id])
    let eightK = ResolutionPreset.preset(withID: "7680x4320")!
    let confirmed = expectation(description: "The fake 8K confirmation accepts the choice")
    var confirmationCount = 0
    let actions = DisplayActions(
      store: environment.store,
      confirm8K: {
        confirmationCount += 1
        confirmed.fulfill()
        return true
      },
      showError: { _ in XCTFail("The accepted fake 8K change must succeed") }
    )
    let (host, control) = try makeNativeResolutionControl(
      store: environment.store,
      actions: actions
    )
    XCTAssertTrue(environment.store.needs8KWarning(for: eightK))

    try selectNativeResolution(eightK, in: control)
    await fulfillment(of: [confirmed], timeout: 2)

    try await assertNativeResolution(eightK, in: control, hostedBy: host)
    XCTAssertEqual(confirmationCount, 1)
    XCTAssertFalse(environment.store.needs8KWarning(for: eightK))
    XCTAssertTrue(environment.repository.state.hasAcknowledged8KWarning)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.resolutionID, eightK.id)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    XCTAssertEqual(environment.backend.resolutionRequests.map(\.0), [eightK.id])
    XCTAssertEqual(environment.backend.resolutionRequests.map(\.1), [connection.displayID])
    XCTAssertEqual(environment.backend.appliedResolutionIDs[connection.displayID], eightK.id)
    XCTAssertEqual(environment.backend.connectRequests.count, 1)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testOverlappingNativeChoicesKeepNewestProposalWhenFirstRequestFinishes() async throws {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    let connection = try XCTUnwrap(environment.backend.connections[profile.id])
    let firstChoice = ResolutionPreset.preset(withID: "2560x1440")!
    let newestChoice = ResolutionPreset.preset(withID: "3840x2160")!
    let firstStarted = expectation(description: "The first native choice is in flight")
    let secondStarted = expectation(description: "The newer native choice is in flight")
    var firstWaiter: CheckedContinuation<Void, Never>?
    var secondWaiter: CheckedContinuation<Void, Never>?
    var released = false
    var requestCount = 0
    environment.backend.beforeResolution = {
      requestCount += 1
      guard !released else { return }
      if requestCount == 1 {
        await withCheckedContinuation {
          firstWaiter = $0
          firstStarted.fulfill()
        }
      } else {
        await withCheckedContinuation {
          secondWaiter = $0
          secondStarted.fulfill()
        }
      }
    }
    defer {
      released = true
      firstWaiter?.resume()
      secondWaiter?.resume()
      environment.backend.beforeResolution = nil
    }
    let actions = DisplayActions(
      store: environment.store,
      confirm8K: {
        XCTFail("A non-8K choice must not request confirmation")
        return false
      },
      showError: { _ in XCTFail("Both fake resolution changes must succeed") }
    )
    let (host, control) = try makeNativeResolutionControl(
      store: environment.store,
      actions: actions
    )

    try selectNativeResolution(firstChoice, in: control)
    await fulfillment(of: [firstStarted], timeout: 2)
    try selectNativeResolution(newestChoice, in: control)
    try await assertNativeResolution(newestChoice, in: control, hostedBy: host)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.resolutionID, profile.resolutionID)

    try XCTUnwrap(firstWaiter).resume()
    firstWaiter = nil
    await fulfillment(of: [secondStarted], timeout: 2)

    try await assertNativeResolution(newestChoice, in: control, hostedBy: host)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.resolutionID, firstChoice.id)
    XCTAssertEqual(environment.backend.resolutionRequests.map(\.0), [firstChoice.id])

    try XCTUnwrap(secondWaiter).resume()
    secondWaiter = nil

    try await assertNativeResolution(newestChoice, in: control, hostedBy: host)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.resolutionID, newestChoice.id)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    XCTAssertEqual(
      environment.backend.resolutionRequests.map(\.0),
      [firstChoice.id, newestChoice.id]
    )
    XCTAssertEqual(environment.backend.appliedResolutionIDs[connection.displayID], newestChoice.id)
    XCTAssertEqual(requestCount, 2)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  private func makeNativeResolutionControl(
    store: VirtualDisplayStore,
    actions: DisplayActions
  ) throws -> (NSHostingView<DisplayManagerView>, NSPopUpButton) {
    let host = NSHostingView(rootView: DisplayManagerView(store: store, actions: actions))
    host.frame = NSRect(x: 0, y: 0, width: 760, height: 640)
    host.layoutSubtreeIfNeeded()
    let control = try XCTUnwrap(
      nativePopUpButtons(in: host).first {
        $0.itemTitles.contains(DisplayActions.recommendedResolution.displayName)
      }
    )
    return (host, control)
  }

  private func selectNativeResolution(
    _ resolution: ResolutionPreset,
    in control: NSPopUpButton
  ) throws {
    let menu = try XCTUnwrap(control.menu)
    let item = try XCTUnwrap(control.item(withTitle: resolution.displayName))
    let cell = try XCTUnwrap(control.cell as? NSPopUpButtonCell)
    cell.select(item)
    menu.performActionForItem(at: menu.index(of: item))
  }

  private func assertNativeResolution(
    _ resolution: ResolutionPreset,
    in control: NSPopUpButton,
    hostedBy host: NSHostingView<DisplayManagerView>,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    repeat {
      // Let pending action tasks and SwiftUI updates reach the native control.
      try await Task.sleep(for: .milliseconds(10))
      host.layoutSubtreeIfNeeded()
      if control.selectedItem?.title == resolution.displayName,
        control.title == resolution.displayName
      {
        return
      }
    } while ContinuousClock.now < deadline
    XCTAssertEqual(control.selectedItem?.title, resolution.displayName, file: file, line: line)
    XCTAssertEqual(control.title, resolution.displayName, file: file, line: line)
  }

  private func nativePopUpButtons(in view: NSView) -> [NSPopUpButton] {
    let buttons = (view as? NSPopUpButton).map { [$0] } ?? []
    return buttons + view.subviews.flatMap { nativePopUpButtons(in: $0) }
  }

  private func assertManagementViewLaysOut(
    store: VirtualDisplayStore,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let host = NSHostingView(rootView: DisplayManagerView(store: store))
    host.frame = NSRect(x: 0, y: 0, width: 760, height: 640)
    host.layoutSubtreeIfNeeded()

    let size = host.fittingSize
    XCTAssertTrue(size.width.isFinite, file: file, line: line)
    XCTAssertTrue(size.height.isFinite, file: file, line: line)
    XCTAssertGreaterThanOrEqual(size.width, 620, file: file, line: line)
    XCTAssertGreaterThanOrEqual(size.height, 420, file: file, line: line)
  }

  private func makeMirrorSource() -> DisplayMirrorSource {
    DisplayMirrorSource(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Studio Display"
    )
  }
}
