import AppKit
import Foundation
import SwiftUI

struct DisplayManagerView: View {
  static let windowID = "displays"

  @ObservedObject var store: VirtualDisplayStore
  @State private var resolutionSelections: [UUID: ResolutionSelection] = [:]
  @State private var refreshRateSelections: [UUID: RefreshRateSelection] = [:]

  private struct ResolutionSelection {
    let requestID = UUID()
    let resolutionID: String
  }

  private struct RefreshRateSelection {
    let requestID = UUID()
    let refreshRate: DisplayRefreshRate
  }

  private let actions: DisplayActions

  init(store: VirtualDisplayStore, actions: DisplayActions? = nil) {
    self.store = store
    self.actions = actions ?? DisplayActions(store: store)
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 6) {
            Text("window.displays")
              .font(.largeTitle.bold())
            Text("window.description")
              .foregroundStyle(.secondary)
          }

          if case .unavailable(let reason) = store.backendAvailability {
            Label(reason, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
          }

          if store.profiles.isEmpty {
            ContentUnavailableView(
              "menu.noDisplays",
              systemImage: "display.2",
              description: Text("window.emptyDescription")
            )
            .frame(maxWidth: .infinity)
          } else {
            ForEach(store.profiles) { profile in
              displayCard(profile)
            }
          }
        }
        .padding(24)
      }

      Divider()

      Toggle(
        "menu.launchAtLogin",
        isOn: Binding(
          get: { store.launchAtLoginStatus == .enabled },
          set: actions.updateLaunchAtLogin
        )
      )
      .disabled(store.launchAtLoginStatus == .unavailable)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
    }
    .frame(minWidth: 620, minHeight: 420)
    .toolbar {
      ToolbarItemGroup {
        Button(
          action: {
            Task { await actions.addDisplay(DisplayActions.recommendedResolution) }
          },
          label: {
            Label("menu.addDisplay", systemImage: "plus")
          }
        )
        .keyboardShortcut("n")
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
    }
    .onAppear {
      actions.presentPendingMessagesIfActive()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      actions.presentPendingMessagesIfActive()
    }
    .onChange(of: store.shouldShowLaunchAtLoginApproval) { _, requiresApproval in
      if requiresApproval { actions.presentPendingMessagesIfActive() }
    }
    .onChange(of: store.pendingErrorMessages) { _, messages in
      if !messages.isEmpty { actions.presentPendingMessagesIfActive() }
    }
  }

  private func displayCard(_ profile: VirtualDisplayProfile) -> some View {
    let state = store.state(for: profile.id)

    return GroupBox {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          Image(systemName: state.isConnected ? "display" : "display.slash")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 4) {
            Text(profile.name)
              .font(.headline)
            statusLabel(for: state)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

          Button(state.isConnected ? "menu.disconnect" : "menu.connect") {
            Task {
              if state.isConnected {
                await actions.disconnect(profile)
              } else {
                await actions.connect(profile)
              }
            }
          }
          .disabled(state.isBusy)
        }

        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
          GridRow {
            Text("window.resolution")
            if store.isMirroring(profileID: profile.id) {
              Text("window.resolutionControlledByMirror")
                .foregroundStyle(.secondary)
            } else {
              resolutionPicker(for: profile, state: state)
            }
          }

          GridRow {
            Text("window.refreshRate")
            if store.isMirroring(profileID: profile.id) {
              Text("window.resolutionControlledByMirror")
                .foregroundStyle(.secondary)
            } else {
              refreshRatePicker(for: profile, state: state)
            }
          }

          GridRow {
            Text("menu.mirrorDisplay")
            mirrorPicker(for: profile, state: state)
          }
        }

        if store.hasMirrorRestoreFailure(profileID: profile.id) {
          Label("menu.mirrorRestoreFailed", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let sourceID = profile.mirrorSourceID,
          !store.mirrorSources.contains(where: { $0.id == sourceID })
        {
          Label("menu.mirrorSourceUnavailable", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack {
          Button("menu.rename") {
            Task { await actions.rename(profile) }
          }
          Button("menu.remove", role: .destructive) {
            Task { await actions.remove(profile) }
          }
        }
        .disabled(state.isBusy)
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func resolutionPicker(
    for profile: VirtualDisplayProfile,
    state: DisplayConnectionState
  ) -> some View {
    Picker(
      "window.resolution",
      selection: Binding(
        get: { resolutionSelections[profile.id]?.resolutionID ?? profile.resolutionID },
        set: { resolutionID in
          guard let resolution = ResolutionPreset.preset(withID: resolutionID) else { return }
          let selection = ResolutionSelection(resolutionID: resolutionID)
          resolutionSelections[profile.id] = selection
          Task {
            await actions.selectResolution(resolution, for: profile.id)
            if resolutionSelections[profile.id]?.requestID == selection.requestID {
              resolutionSelections[profile.id] = nil
            }
          }
        }
      )
    ) {
      ForEach(DisplayAspectRatio.allCases) { aspectRatio in
        Section(aspectRatio.localizedName) {
          ForEach(ResolutionPreset.presets(for: aspectRatio)) { preset in
            Text(preset.displayName).tag(preset.id)
          }
        }
      }
    }
    .labelsHidden()
    .disabled(state.isBusy)
  }

  private func refreshRatePicker(
    for profile: VirtualDisplayProfile,
    state: DisplayConnectionState
  ) -> some View {
    Picker(
      "window.refreshRate",
      selection: Binding(
        get: { refreshRateSelections[profile.id]?.refreshRate ?? profile.refreshRate },
        set: { rate in
          let selection = RefreshRateSelection(refreshRate: rate)
          refreshRateSelections[profile.id] = selection
          Task {
            await actions.selectRefreshRate(rate, for: profile.id)
            if refreshRateSelections[profile.id]?.requestID == selection.requestID {
              refreshRateSelections[profile.id] = nil
            }
          }
        }
      )
    ) {
      ForEach(DisplayRefreshRate.allCases) { rate in
        Text(rate.localizedName).tag(rate)
      }
    }
    .labelsHidden()
    .disabled(state.isBusy)
  }

  private func mirrorPicker(
    for profile: VirtualDisplayProfile,
    state: DisplayConnectionState
  ) -> some View {
    Picker(
      "menu.mirrorDisplay",
      selection: Binding(
        get: { store.activeMirrorSourceIDs[profile.id] },
        set: { sourceID in
          Task { await actions.setMirrorSource(sourceID, for: profile.id) }
        }
      )
    ) {
      Text("menu.mirrorNone").tag(UUID?.none)
      ForEach(store.mirrorSources) { source in
        Text(source.name).tag(Optional(source.id))
      }
    }
    .labelsHidden()
    .disabled(!state.isConnected || state.isBusy)
  }

  @ViewBuilder
  private func statusLabel(for state: DisplayConnectionState) -> some View {
    switch state {
    case .connected:
      Text("status.connected")
    case .disconnected:
      Text("status.disconnected")
    case .connecting:
      Text("status.connecting")
    case .failed(let message):
      Text(
        String(
          format: String(localized: "status.failed", defaultValue: "Disconnected: %@"),
          message
        )
      )
    }
  }
}
