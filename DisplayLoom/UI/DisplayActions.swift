import Foundation

@MainActor
struct DisplayActions {
  let store: VirtualDisplayStore

  static let recommendedResolution = ResolutionPreset(
    width: 1_920,
    height: 1_080,
    aspectRatio: .sixteenByNine
  )

  func addDisplay(_ resolution: ResolutionPreset) async {
    guard approve8KIfNeeded(resolution) else { return }
    await store.addDisplay(resolution: resolution)
    presentStoreErrorIfNeeded()
  }

  func connect(_ profile: VirtualDisplayProfile) async {
    await store.connectProfile(id: profile.id)
    presentStoreErrorIfNeeded()
  }

  func disconnect(_ profile: VirtualDisplayProfile) async {
    await store.disconnectProfile(id: profile.id)
    presentStoreErrorIfNeeded()
  }

  func selectResolution(_ resolution: ResolutionPreset, for profileID: UUID) async {
    guard approve8KIfNeeded(resolution) else { return }
    await store.setResolution(resolution, for: profileID)
    presentStoreErrorIfNeeded()
  }

  func setMirrorSource(_ sourceID: UUID?, for profileID: UUID) async {
    await store.setMirrorSource(sourceID, for: profileID)
    presentStoreErrorIfNeeded()
  }

  func rename(_ profile: VirtualDisplayProfile) async {
    guard let name = DialogPresenter.requestName(currentName: profile.name) else { return }
    await store.renameProfile(id: profile.id, to: name)
    presentStoreErrorIfNeeded()
  }

  func remove(_ profile: VirtualDisplayProfile) async {
    guard DialogPresenter.confirmRemoval(name: profile.name) else { return }
    await store.removeProfile(id: profile.id)
    presentStoreErrorIfNeeded()
  }

  func updateLaunchAtLogin(_ enabled: Bool) {
    store.setLaunchAtLoginEnabled(enabled)
    presentPendingMessages()
  }

  func presentPendingMessages() {
    if store.shouldShowLaunchAtLoginApproval {
      store.clearLaunchAtLoginApprovalNotice()
      DialogPresenter.showLaunchAtLoginApproval {
        store.openLoginItemSettings()
      }
    }
    presentStoreErrorIfNeeded()
  }

  func presentStoreErrorIfNeeded() {
    guard let message = store.takeLastErrorMessage() else { return }
    DialogPresenter.showError(message)
  }

  private func approve8KIfNeeded(_ resolution: ResolutionPreset) -> Bool {
    guard store.needs8KWarning(for: resolution) else { return true }
    guard DialogPresenter.confirm8K() else { return false }
    store.acknowledge8KWarning()
    return true
  }
}
