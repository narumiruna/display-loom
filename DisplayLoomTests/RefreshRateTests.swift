import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import DisplayLoom

@MainActor
final class RefreshRateTests: XCTestCase {
  func testNewDisplaysDefaultTo60HzAndChangesStayProfileSpecific() async throws {
    let environment = VirtualDisplayTestEnvironment()
    let actions = DisplayActions(store: environment.store)
    await actions.addDisplay(DisplayActions.recommendedResolution)
    await actions.addDisplay(DisplayActions.recommendedResolution)
    let untouched = try XCTUnwrap(environment.store.profiles.first)
    let selected = try XCTUnwrap(environment.store.profiles.last)
    let connection = try XCTUnwrap(environment.backend.connections[selected.id])
    XCTAssertEqual(selected.refreshRate, .standard)
    XCTAssertEqual(environment.backend.appliedRefreshRates[connection.displayID], .standard)

    await actions.selectRefreshRate(.low, for: selected.id)

    XCTAssertEqual(environment.store.profile(id: untouched.id), untouched)
    XCTAssertEqual(environment.store.profile(id: selected.id)?.refreshRate, .low)
    XCTAssertEqual(environment.backend.appliedRefreshRates[connection.displayID], .low)
    XCTAssertEqual(
      environment.backend.appliedResolutionIDs[connection.displayID],
      selected.resolutionID
    )
    XCTAssertEqual(environment.backend.refreshRateRequests.map(\.0), [.low])
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    XCTAssertEqual(environment.backend.connectRequests.count, 2)

    await actions.selectRefreshRate(.standard, for: selected.id)

    XCTAssertEqual(environment.store.profile(id: selected.id)?.refreshRate, .standard)
    XCTAssertEqual(environment.backend.appliedRefreshRates[connection.displayID], .standard)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testDisconnectedChoiceSurvivesReloadConnectAndWake() async throws {
    let profile = VirtualDisplayProfile(
      name: "Offline",
      resolutionID: "1920x1080",
      desiredConnected: false
    )
    let environment = VirtualDisplayTestEnvironment(state: PersistedState(profiles: [profile]))

    await environment.store.setRefreshRate(.low, for: profile.id)

    XCTAssertEqual(environment.store.state(for: profile.id), .disconnected)
    XCTAssertFalse(try XCTUnwrap(environment.store.profile(id: profile.id)).desiredConnected)
    XCTAssertTrue(environment.backend.connectRequests.isEmpty)
    XCTAssertTrue(environment.backend.resolutionRequests.isEmpty)
    let restored = VirtualDisplayTestEnvironment(state: environment.repository.state)
    await restored.store.connectProfile(id: profile.id)
    let first = try XCTUnwrap(restored.backend.connections[profile.id])
    XCTAssertEqual(restored.backend.connectRequests.last?.0.refreshRate, .low)
    XCTAssertEqual(restored.backend.appliedRefreshRates[first.displayID], .low)

    first.invalidate()
    await restored.store.retryDesiredConnectionsAfterWake()

    let replacement = try XCTUnwrap(restored.backend.connections[profile.id])
    XCTAssertNotEqual(replacement.displayID, first.displayID)
    XCTAssertEqual(restored.backend.appliedRefreshRates[replacement.displayID], .low)
    XCTAssertEqual(restored.repository.state.profiles, restored.store.profiles)
  }

  func testFailedRateChangeKeepsLastSuccessfulModeAndPersistence() async throws {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    let connection = try XCTUnwrap(environment.backend.connections[profile.id])
    await environment.store.setRefreshRate(.low, for: profile.id)
    let savedState = environment.repository.state
    environment.backend.setResolutionError = .modeSwitchFailed

    await environment.store.setRefreshRate(.standard, for: profile.id)

    XCTAssertEqual(environment.store.profile(id: profile.id)?.refreshRate, .low)
    XCTAssertEqual(environment.backend.appliedRefreshRates[connection.displayID], .low)
    XCTAssertEqual(environment.repository.state, savedState)
    XCTAssertTrue(environment.store.state(for: profile.id).isConnected)
    XCTAssertEqual(
      environment.store.takeNextErrorMessage(),
      VirtualDisplayBackendError.modeSwitchFailed.localizedDescription
    )
  }

  func testSelectingSavedRateDoesNotWriteAMode() async throws {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    let savedCount = environment.repository.savedStates.count

    await environment.store.setRefreshRate(.standard, for: profile.id)

    XCTAssertTrue(environment.backend.refreshRateRequests.isEmpty)
    XCTAssertEqual(environment.repository.savedStates.count, savedCount)
  }

  func testMirroringRejectsRefreshRateChangeWithoutSavingOrWriting() async throws {
    let environment = VirtualDisplayTestEnvironment()
    let source = DisplayMirrorSource(id: UUID(), name: "Source")
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    await environment.store.setMirrorSource(source.id, for: profile.id)
    let savedState = environment.repository.state

    await environment.store.setRefreshRate(.low, for: profile.id)

    XCTAssertTrue(environment.store.isMirroring(profileID: profile.id))
    XCTAssertTrue(environment.backend.refreshRateRequests.isEmpty)
    XCTAssertEqual(environment.store.profile(id: profile.id)?.refreshRate, .standard)
    XCTAssertEqual(environment.repository.state, savedState)
    XCTAssertEqual(
      environment.store.takeNextErrorMessage(),
      String(
        localized: "error.refreshRateMirrored",
        defaultValue: "Disconnect display mirroring before changing the refresh rate."
      )
    )
  }

  func testOverlappingResolutionAndRateChangesPreserveBothSettings() async throws {
    for rateFirst in [true, false] {
      let environment = VirtualDisplayTestEnvironment()
      await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
      let profile = try XCTUnwrap(environment.store.profiles.first)
      let connection = try XCTUnwrap(environment.backend.connections[profile.id])
      let resolution = ResolutionPreset.preset(withID: "2560x1440")!
      let started = expectation(description: "First mode write started")
      let submitted = expectation(description: "Second mode change submitted")
      var waiter: CheckedContinuation<Void, Never>?
      environment.backend.beforeResolution = {
        await withCheckedContinuation {
          waiter = $0
          started.fulfill()
        }
      }
      let first = Task {
        if rateFirst {
          await environment.store.setRefreshRate(.low, for: profile.id)
        } else {
          await environment.store.setResolution(resolution, for: profile.id)
        }
      }
      await fulfillment(of: [started], timeout: 2)
      environment.backend.beforeResolution = nil
      let second = Task {
        submitted.fulfill()
        if rateFirst {
          await environment.store.setResolution(resolution, for: profile.id)
        } else {
          await environment.store.setRefreshRate(.low, for: profile.id)
        }
      }
      await fulfillment(of: [submitted], timeout: 2)
      waiter?.resume()
      await first.value
      await second.value

      XCTAssertEqual(environment.store.profile(id: profile.id)?.refreshRate, .low)
      XCTAssertEqual(environment.store.profile(id: profile.id)?.resolutionID, resolution.id)
      XCTAssertEqual(environment.backend.appliedRefreshRates[connection.displayID], .low)
      XCTAssertEqual(environment.backend.appliedResolutionIDs[connection.displayID], resolution.id)
      XCTAssertEqual(environment.backend.refreshRateRequests.count, 2)
      XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
      XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
    }
  }

  func testOverlappingModeFailurePreservesOtherSettingAndReportsError() async throws {
    for rateFirst in [true, false] {
      for failRate in [true, false] {
        let environment = VirtualDisplayTestEnvironment()
        await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
        let profile = try XCTUnwrap(environment.store.profiles.first)
        let connection = try XCTUnwrap(environment.backend.connections[profile.id])
        let resolution = ResolutionPreset.preset(withID: "2560x1440")!
        if failRate {
          environment.backend.refreshRateErrors[.low] = .modeSwitchFailed
        } else {
          environment.backend.resolutionErrors[resolution.id] = .modeSwitchFailed
        }
        let started = expectation(description: "First mode write started")
        let submitted = expectation(description: "Second mode change submitted")
        var waiter: CheckedContinuation<Void, Never>?
        environment.backend.beforeResolution = {
          await withCheckedContinuation {
            waiter = $0
            started.fulfill()
          }
        }
        let first = Task {
          if rateFirst {
            await environment.store.setRefreshRate(.low, for: profile.id)
          } else {
            await environment.store.setResolution(resolution, for: profile.id)
          }
        }
        await fulfillment(of: [started], timeout: 2)
        environment.backend.beforeResolution = nil
        let second = Task {
          submitted.fulfill()
          if rateFirst {
            await environment.store.setResolution(resolution, for: profile.id)
          } else {
            await environment.store.setRefreshRate(.low, for: profile.id)
          }
        }
        await fulfillment(of: [submitted], timeout: 2)
        waiter?.resume()
        await first.value
        await second.value

        let expectedRate: DisplayRefreshRate = failRate ? .standard : .low
        let expectedResolution = failRate ? resolution.id : profile.resolutionID
        XCTAssertEqual(environment.store.profile(id: profile.id)?.refreshRate, expectedRate)
        XCTAssertEqual(
          environment.store.profile(id: profile.id)?.resolutionID,
          expectedResolution
        )
        XCTAssertEqual(environment.backend.appliedRefreshRates[connection.displayID], expectedRate)
        XCTAssertEqual(
          environment.backend.appliedResolutionIDs[connection.displayID],
          expectedResolution
        )
        XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
        XCTAssertEqual(
          environment.store.pendingErrorMessages,
          [VirtualDisplayBackendError.modeSwitchFailed.localizedDescription]
        )
      }
    }
  }

  func testRateChangeDuringConnectionReplacesStaleCreation() async throws {
    let profile = VirtualDisplayProfile(
      name: "Pending",
      resolutionID: "1920x1080",
      desiredConnected: false
    )
    let environment = VirtualDisplayTestEnvironment(state: PersistedState(profiles: [profile]))
    let started = expectation(description: "Connection started")
    let replacing = expectation(description: "Rate change submitted")
    var waiter: CheckedContinuation<Void, Never>?
    environment.backend.beforeConnect = { _ in
      await withCheckedContinuation {
        waiter = $0
        started.fulfill()
      }
    }
    let original = Task { await environment.store.connectProfile(id: profile.id) }
    await fulfillment(of: [started], timeout: 2)
    environment.backend.beforeConnect = nil
    let replacement = Task {
      replacing.fulfill()
      await environment.store.setRefreshRate(.low, for: profile.id)
    }
    await fulfillment(of: [replacing], timeout: 2)
    waiter?.resume()
    await original.value
    await replacement.value

    let connection = try XCTUnwrap(environment.backend.connections[profile.id])
    XCTAssertEqual(environment.backend.connectRequests.map(\.0.refreshRate), [.standard, .low])
    XCTAssertTrue(try XCTUnwrap(environment.backend.createdConnections.first).invalidated)
    XCTAssertEqual(environment.backend.appliedRefreshRates[connection.displayID], .low)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
  }

  func testRemovedProfileIgnoresLateRefreshRateWrite() async throws {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    let started = expectation(description: "Rate write started")
    var waiter: CheckedContinuation<Void, Never>?
    environment.backend.beforeResolution = {
      await withCheckedContinuation {
        waiter = $0
        started.fulfill()
      }
    }
    let pending = Task { await environment.store.setRefreshRate(.low, for: profile.id) }
    await fulfillment(of: [started], timeout: 2)
    await environment.store.removeProfile(id: profile.id)
    waiter?.resume()
    await pending.value

    XCTAssertTrue(environment.store.profiles.isEmpty)
    XCTAssertTrue(environment.repository.state.profiles.isEmpty)
    XCTAssertTrue(environment.store.connectionStates.isEmpty)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testNativeRefreshRateControlSavesBothChoices() async throws {
    let profile = VirtualDisplayProfile(
      name: "Offline",
      resolutionID: "1920x1080",
      desiredConnected: false
    )
    let environment = VirtualDisplayTestEnvironment(state: PersistedState(profiles: [profile]))
    let (host, control) = try makeNativeRateControl(environment: environment)
    XCTAssertEqual(control.itemTitles, DisplayRefreshRate.allCases.map(\.localizedName))
    XCTAssertEqual(control.title, DisplayRefreshRate.standard.localizedName)

    for rate in [DisplayRefreshRate.low, .standard] {
      try selectNativeRate(rate, in: control)
      try await waitForNativeRate(rate, in: control, host: host) {
        environment.store.profile(id: profile.id)?.refreshRate == rate
      }
      XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
    }
    XCTAssertTrue(environment.backend.connectRequests.isEmpty)
  }

  func testFailedNativeRefreshRateChoiceRestoresCommittedSelection() async throws {
    let environment = VirtualDisplayTestEnvironment()
    await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    environment.backend.setResolutionError = .modeSwitchFailed
    var errors: [String] = []
    let actions = DisplayActions(store: environment.store, showError: { errors.append($0) })
    let (host, control) = try makeNativeRateControl(environment: environment, actions: actions)

    try selectNativeRate(.low, in: control)
    try await waitForNativeRate(.standard, in: control, host: host) { !errors.isEmpty }

    XCTAssertEqual(errors, [VirtualDisplayBackendError.modeSwitchFailed.localizedDescription])
    XCTAssertEqual(environment.store.profile(id: profile.id)?.refreshRate, .standard)
    XCTAssertEqual(environment.repository.state.profiles, environment.store.profiles)
  }

  func testMirroredManagementViewHasNoRefreshRateControl() async throws {
    let environment = VirtualDisplayTestEnvironment()
    let source = DisplayMirrorSource(id: UUID(), name: "Source")
    environment.mirroringManager.sources = [source]
    await environment.store.addDisplay(resolution: DisplayActions.recommendedResolution)
    let profile = try XCTUnwrap(environment.store.profiles.first)
    await environment.store.setRefreshRate(.low, for: profile.id)
    await environment.store.setMirrorSource(source.id, for: profile.id)
    let host = NSHostingView(rootView: DisplayManagerView(store: environment.store))
    host.frame = NSRect(x: 0, y: 0, width: 760, height: 640)
    host.layoutSubtreeIfNeeded()

    XCTAssertFalse(
      nativePopUpButtons(in: host).contains {
        $0.itemTitles.contains(DisplayRefreshRate.standard.localizedName)
      }
    )
    XCTAssertEqual(environment.store.profile(id: profile.id)?.refreshRate, .low)
    XCTAssertTrue(environment.store.pendingErrorMessages.isEmpty)
  }

  func testLaterStoreRateChangeUpdatesNativeControl() async throws {
    let profile = VirtualDisplayProfile(
      name: "Offline",
      resolutionID: "1920x1080",
      desiredConnected: false
    )
    let environment = VirtualDisplayTestEnvironment(state: PersistedState(profiles: [profile]))
    let (host, control) = try makeNativeRateControl(environment: environment)

    await environment.store.setRefreshRate(.low, for: profile.id)
    try await waitForNativeRate(.low, in: control, host: host) { true }
  }

  private func makeNativeRateControl(
    environment: VirtualDisplayTestEnvironment,
    actions: DisplayActions? = nil
  ) throws -> (NSHostingView<DisplayManagerView>, NSPopUpButton) {
    let host = NSHostingView(
      rootView: DisplayManagerView(store: environment.store, actions: actions)
    )
    host.frame = NSRect(x: 0, y: 0, width: 760, height: 640)
    host.layoutSubtreeIfNeeded()
    let control = try XCTUnwrap(
      nativePopUpButtons(in: host).first {
        $0.itemTitles.contains(DisplayRefreshRate.standard.localizedName)
      }
    )
    return (host, control)
  }

  private func nativePopUpButtons(in view: NSView) -> [NSPopUpButton] {
    let buttons = (view as? NSPopUpButton).map { [$0] } ?? []
    return buttons + view.subviews.flatMap { nativePopUpButtons(in: $0) }
  }

  private func selectNativeRate(_ rate: DisplayRefreshRate, in control: NSPopUpButton) throws {
    let menu = try XCTUnwrap(control.menu)
    let item = try XCTUnwrap(control.item(withTitle: rate.localizedName))
    let cell = try XCTUnwrap(control.cell as? NSPopUpButtonCell)
    cell.select(item)
    menu.performActionForItem(at: menu.index(of: item))
  }

  private func waitForNativeRate(
    _ rate: DisplayRefreshRate,
    in control: NSPopUpButton,
    host: NSHostingView<DisplayManagerView>,
    until committed: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    repeat {
      try await Task.sleep(for: .milliseconds(10))
      host.layoutSubtreeIfNeeded()
      if committed(), control.title == rate.localizedName,
        control.selectedItem?.title == rate.localizedName
      {
        return
      }
    } while ContinuousClock.now < deadline
    XCTAssertTrue(committed())
    XCTAssertEqual(control.title, rate.localizedName)
    XCTAssertEqual(control.selectedItem?.title, rate.localizedName)
  }
}
