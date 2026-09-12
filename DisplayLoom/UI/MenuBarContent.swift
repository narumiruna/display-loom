import AppKit
import SwiftUI

struct MenuBarContent: View {
  @ObservedObject var store: VirtualDisplayStore

  var body: some View {
    Group {
      if case .unavailable(let reason) = store.backendAvailability {
        Text(reason)
      }

      if store.profiles.isEmpty {
        Text("menu.noDisplays")
      } else {
        ForEach(store.profiles) { profile in
          profileMenu(profile)
        }
      }

      Divider()
      addDisplayControls
      Divider()

      Toggle(
        "menu.launchAtLogin",
        isOn: Binding(
          get: { store.launchAtLoginStatus == .enabled },
          set: updateLaunchAtLogin
        )
      )
      .disabled(store.launchAtLoginStatus == .unavailable)

      Button("menu.about") {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
      }

      Divider()

      Button("menu.quit") {
        NSApp.terminate(nil)
      }
      .keyboardShortcut("q")
    }
    .onAppear {
      presentPendingMessages()
    }
  }

  @ViewBuilder
  private func profileMenu(_ profile: VirtualDisplayProfile) -> some View {
    let state = store.state(for: profile.id)
    Menu {
      statusMessage(for: state)

      if state.isConnected || state.isBusy {
        Button {
          store.disconnectProfile(id: profile.id)
        } label: {
          Label("menu.disconnect", systemImage: "stop.circle")
        }
        .disabled(state.isBusy)
      } else {
        Button {
          Task {
            await store.connectProfile(id: profile.id)
            presentStoreErrorIfNeeded()
          }
        } label: {
          Label("menu.connect", systemImage: "play.circle")
        }
      }

      mirrorMenu(for: profile, state: state)
      resolutionMenu(for: profile, state: state)

      Divider()

      Button {
        guard let name = DialogPresenter.requestName(currentName: profile.name) else { return }
        Task {
          await store.renameProfile(id: profile.id, to: name)
          presentStoreErrorIfNeeded()
        }
      } label: {
        Label("menu.rename", systemImage: "pencil")
      }
      .disabled(state.isBusy)

      Button(role: .destructive) {
        guard DialogPresenter.confirmRemoval(name: profile.name) else { return }
        store.removeProfile(id: profile.id)
      } label: {
        Label("menu.remove", systemImage: "trash")
      }
      .disabled(state.isBusy)
    } label: {
      Label(profile.name, systemImage: statusSymbol(for: state))
    }
  }

  private func mirrorMenu(
    for profile: VirtualDisplayProfile,
    state: DisplayConnectionState
  ) -> some View {
    let activeSourceID = store.activeMirrorSourceIDs[profile.id]
    let restoreFailed = store.hasMirrorRestoreFailure(profileID: profile.id)
    let selectedSourceUnavailable =
      profile.mirrorSourceID.map { selectedSourceID in
        !store.mirrorSources.contains(where: { $0.id == selectedSourceID })
      } ?? false

    return Menu {
      Button {
        store.setMirrorSource(nil, for: profile.id)
        presentStoreErrorIfNeeded()
      } label: {
        if activeSourceID == nil {
          Label("menu.mirrorNone", systemImage: "checkmark")
        } else {
          Text("menu.mirrorNone")
        }
      }

      if restoreFailed || selectedSourceUnavailable {
        Divider()
        if restoreFailed {
          Label("menu.mirrorRestoreFailed", systemImage: "exclamationmark.triangle")
            .disabled(true)
        }
        if selectedSourceUnavailable {
          Label("menu.mirrorSourceUnavailable", systemImage: "exclamationmark.triangle")
            .disabled(true)
        }
      }

      if !store.mirrorSources.isEmpty {
        Divider()
        ForEach(store.mirrorSources) { source in
          Button {
            store.setMirrorSource(source.id, for: profile.id)
            presentStoreErrorIfNeeded()
          } label: {
            if activeSourceID == source.id {
              Label(source.name, systemImage: "checkmark")
            } else {
              Text(source.name)
            }
          }
        }
      }
    } label: {
      Text("menu.mirrorDisplay")
    }
    .disabled(!state.isConnected || state.isBusy)
  }

  private func resolutionMenu(
    for profile: VirtualDisplayProfile,
    state: DisplayConnectionState
  ) -> some View {
    Menu {
      ForEach(DisplayAspectRatio.allCases) { aspectRatio in
        Menu(aspectRatio.localizedName) {
          ForEach(ResolutionPreset.presets(for: aspectRatio)) { preset in
            Button {
              selectResolution(preset, for: profile.id)
            } label: {
              if profile.resolutionID == preset.id {
                Label(preset.displayName, systemImage: "checkmark")
              } else {
                Text(preset.displayName)
              }
            }
          }
        }
      }
    } label: {
      if store.isMirroring(profileID: profile.id) {
        Text("menu.resolutionControlledByMirror")
      } else {
        Text(
          String(
            format: String(localized: "menu.resolutionCurrent", defaultValue: "Resolution: %@"),
            profile.resolution?.displayName ?? profile.resolutionID
          )
        )
      }
    }
    .disabled(state.isBusy || store.isMirroring(profileID: profile.id))
  }

  @ViewBuilder
  private var addDisplayControls: some View {
    Button {
      addDisplay(Self.recommendedResolution)
    } label: {
      Label("menu.addDisplay", systemImage: "plus")
    }
    .disabled(!store.backendAvailability.isAvailable)

    Menu {
      ForEach(DisplayAspectRatio.allCases) { aspectRatio in
        Menu(aspectRatio.localizedName) {
          ForEach(ResolutionPreset.presets(for: aspectRatio)) { preset in
            Button(preset.displayName) {
              addDisplay(preset)
            }
          }
        }
      }
    } label: {
      Label("menu.addDisplayWithResolution", systemImage: "slider.horizontal.3")
    }
    .disabled(!store.backendAvailability.isAvailable)
  }

  private func addDisplay(_ resolution: ResolutionPreset) {
    guard approve8KIfNeeded(resolution) else { return }
    Task {
      await store.addDisplay(resolution: resolution)
      presentStoreErrorIfNeeded()
    }
  }

  private func selectResolution(_ resolution: ResolutionPreset, for profileID: UUID) {
    guard approve8KIfNeeded(resolution) else { return }
    Task {
      await store.setResolution(resolution, for: profileID)
      presentStoreErrorIfNeeded()
    }
  }

  private func approve8KIfNeeded(_ resolution: ResolutionPreset) -> Bool {
    guard store.needs8KWarning(for: resolution) else { return true }
    guard DialogPresenter.confirm8K() else { return false }
    store.acknowledge8KWarning()
    return true
  }

  private func updateLaunchAtLogin(_ enabled: Bool) {
    store.setLaunchAtLoginEnabled(enabled)
    presentPendingMessages()
  }

  private func presentPendingMessages() {
    if store.shouldShowLaunchAtLoginApproval {
      DialogPresenter.showLaunchAtLoginApproval {
        store.openLoginItemSettings()
      }
      store.clearLaunchAtLoginApprovalNotice()
    }
    presentStoreErrorIfNeeded()
  }

  private func presentStoreErrorIfNeeded() {
    guard let message = store.takeLastErrorMessage() else { return }
    DialogPresenter.showError(message)
  }

  @ViewBuilder
  private func statusMessage(for state: DisplayConnectionState) -> some View {
    switch state {
    case .connecting:
      Text("status.connecting")
    case .failed(let message):
      Text(
        String(
          format: String(localized: "status.failed", defaultValue: "Disconnected: %@"),
          message
        )
      )
    case .connected, .disconnected:
      EmptyView()
    }
  }

  private static let recommendedResolution = ResolutionPreset(
    width: 1_920,
    height: 1_080,
    aspectRatio: .sixteenByNine
  )

  private func statusSymbol(for state: DisplayConnectionState) -> String {
    switch state {
    case .connected: return "display"
    case .connecting: return "ellipsis.circle"
    case .failed: return "exclamationmark.triangle"
    case .disconnected: return "display.slash"
    }
  }
}
