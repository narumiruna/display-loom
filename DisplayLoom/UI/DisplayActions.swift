import AppKit
import Foundation

@MainActor
struct DisplayActions {
  let store: VirtualDisplayStore

  private let isApplicationActive: @MainActor () -> Bool
  private let confirm8K: @MainActor () -> Bool
  private let showError: @MainActor (String) -> Void
  private let showLaunchAtLoginApproval: @MainActor (@escaping () -> Void) -> Void
  private static var isPresentingNotice = false

  init(
    store: VirtualDisplayStore,
    isApplicationActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
    confirm8K: @escaping @MainActor () -> Bool = { DialogPresenter.confirm8K() },
    showError: @escaping @MainActor (String) -> Void = { DialogPresenter.showError($0) },
    showLaunchAtLoginApproval: @escaping @MainActor (@escaping () -> Void) -> Void = {
      DialogPresenter.showLaunchAtLoginApproval(openSettings: $0)
    }
  ) {
    self.store = store
    self.isApplicationActive = isApplicationActive
    self.confirm8K = confirm8K
    self.showError = showError
    self.showLaunchAtLoginApproval = showLaunchAtLoginApproval
  }

  static let recommendedResolution = ResolutionPreset(
    width: 1_920,
    height: 1_080,
    aspectRatio: .sixteenByNine
  )

  func addDisplay(_ resolution: ResolutionPreset) async {
    guard approve8KIfNeeded(resolution) else { return }
    await store.addDisplay(resolution: resolution)
    presentPendingMessages()
  }

  func connect(_ profile: VirtualDisplayProfile) async {
    await store.connectProfile(id: profile.id)
    presentPendingMessages()
  }

  func disconnect(_ profile: VirtualDisplayProfile) async {
    await store.disconnectProfile(id: profile.id)
    presentPendingMessages()
  }

  func selectResolution(_ resolution: ResolutionPreset, for profileID: UUID) async {
    guard approve8KIfNeeded(resolution) else { return }
    await store.setResolution(resolution, for: profileID)
    presentPendingMessages()
  }

  func setMirrorSource(_ sourceID: UUID?, for profileID: UUID) async {
    await store.setMirrorSource(sourceID, for: profileID)
    presentPendingMessages()
  }

  func rename(_ profile: VirtualDisplayProfile) async {
    guard let name = DialogPresenter.requestName(currentName: profile.name) else { return }
    await store.renameProfile(id: profile.id, to: name)
    presentPendingMessages()
  }

  func remove(_ profile: VirtualDisplayProfile) async {
    guard DialogPresenter.confirmRemoval(name: profile.name) else { return }
    await store.removeProfile(id: profile.id)
    presentPendingMessages()
  }

  func updateLaunchAtLogin(_ enabled: Bool) {
    store.setLaunchAtLoginEnabled(enabled)
    presentPendingMessages()
  }

  func presentPendingMessages() {
    presentPendingMessages(while: { true })
  }

  func presentPendingMessagesIfActive() {
    presentPendingMessages(while: isApplicationActive)
  }

  private func presentPendingMessages(while canPresent: @MainActor () -> Bool) {
    guard !Self.isPresentingNotice, canPresent() else { return }
    Self.isPresentingNotice = true
    defer { Self.isPresentingNotice = false }

    while canPresent() {
      if store.shouldShowLaunchAtLoginApproval {
        store.clearLaunchAtLoginApprovalNotice()
        showLaunchAtLoginApproval {
          store.openLoginItemSettings()
        }
      } else if let message = store.takeNextErrorMessage() {
        showError(message)
      } else {
        break
      }
    }
  }

  private func approve8KIfNeeded(_ resolution: ResolutionPreset) -> Bool {
    guard store.needs8KWarning(for: resolution) else { return true }
    guard confirm8K() else { return false }
    store.acknowledge8KWarning()
    return true
  }
}
