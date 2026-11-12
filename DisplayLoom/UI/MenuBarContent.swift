import AppKit
import Foundation
import SwiftUI

struct MenuBarContent: View {
  @ObservedObject var store: VirtualDisplayStore
  @Environment(\.openWindow) private var openWindow

  private var actions: DisplayActions { DisplayActions(store: store) }

  var body: some View {
    Group {
      Button("menu.openWindow") {
        openWindow(id: DisplayManagerView.windowID)
        NSApp.activate(ignoringOtherApps: true)
      }
      .keyboardShortcut("0")

      Divider()

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
          set: actions.updateLaunchAtLogin
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
      actions.presentPendingMessages()
    }
  }

  @ViewBuilder
  private func profileMenu(_ profile: VirtualDisplayProfile) -> some View {
    let state = store.state(for: profile.id)
    Menu(
      content: {
        statusMessage(for: state)

        if state.isConnected || state.isBusy {
          Button(
            action: {
              Task { await actions.disconnect(profile) }
            },
            label: {
              Label("menu.disconnect", systemImage: "stop.circle")
            }
          )
          .disabled(state.isBusy)
        } else {
          Button(
            action: {
              Task { await actions.connect(profile) }
            },
            label: {
              Label("menu.connect", systemImage: "play.circle")
            }
          )
        }

        mirrorMenu(for: profile, state: state)
        resolutionMenu(for: profile, state: state)

        Divider()

        Button(
          action: {
            Task { await actions.rename(profile) }
          },
          label: {
            Label("menu.rename", systemImage: "pencil")
          }
        )
        .disabled(state.isBusy)

        Button(
          role: .destructive,
          action: {
            Task { await actions.remove(profile) }
          },
          label: {
            Label("menu.remove", systemImage: "trash")
          }
        )
        .disabled(state.isBusy)
      },
      label: {
        Label(profile.name, systemImage: statusSymbol(for: state))
      }
    )
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

    return Menu(
      content: {
        Button(
          action: {
            Task { await actions.setMirrorSource(nil, for: profile.id) }
          },
          label: {
            if activeSourceID == nil {
              Label("menu.mirrorNone", systemImage: "checkmark")
            } else {
              Text("menu.mirrorNone")
            }
          }
        )

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
            Button(
              action: {
                Task { await actions.setMirrorSource(source.id, for: profile.id) }
              },
              label: {
                if activeSourceID == source.id {
                  Label(source.name, systemImage: "checkmark")
                } else {
                  Text(source.name)
                }
              }
            )
          }
        }
      },
      label: {
        Text("menu.mirrorDisplay")
      }
    )
    .disabled(!state.isConnected || state.isBusy)
  }

  private func resolutionMenu(
    for profile: VirtualDisplayProfile,
    state: DisplayConnectionState
  ) -> some View {
    Menu(
      content: {
        ForEach(DisplayAspectRatio.allCases) { aspectRatio in
          Menu(aspectRatio.localizedName) {
            ForEach(ResolutionPreset.presets(for: aspectRatio)) { preset in
              Button(
                action: {
                  Task { await actions.selectResolution(preset, for: profile.id) }
                },
                label: {
                  if profile.resolutionID == preset.id {
                    Label(preset.displayName, systemImage: "checkmark")
                  } else {
                    Text(preset.displayName)
                  }
                }
              )
            }
          }
        }
      },
      label: {
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
    )
    .disabled(state.isBusy || store.isMirroring(profileID: profile.id))
  }

  @ViewBuilder
  private var addDisplayControls: some View {
    Button(
      action: {
        Task { await actions.addDisplay(DisplayActions.recommendedResolution) }
      },
      label: {
        Label("menu.addDisplay", systemImage: "plus")
      }
    )
    .disabled(!store.backendAvailability.isAvailable)

    Menu(
      content: {
        ForEach(DisplayAspectRatio.allCases) { aspectRatio in
          Menu(aspectRatio.localizedName) {
            ForEach(ResolutionPreset.presets(for: aspectRatio)) { preset in
              Button(preset.displayName) {
                Task { await actions.addDisplay(preset) }
              }
            }
          }
        }
      },
      label: {
        Label("menu.addDisplayWithResolution", systemImage: "slider.horizontal.3")
      }
    )
    .disabled(!store.backendAvailability.isAvailable)
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

  private func statusSymbol(for state: DisplayConnectionState) -> String {
    switch state {
    case .connected: return "display"
    case .connecting: return "ellipsis.circle"
    case .failed: return "exclamationmark.triangle"
    case .disconnected: return "display.slash"
    }
  }
}
