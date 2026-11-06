import AppKit
import Combine
import Foundation

@testable import DisplayLoom

// These checks run both in XCTest and in scripts/check-performance.sh.
@MainActor
enum PerformanceChecks {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
  }

  static func run() async throws {
    try await notificationBurst()
    try await failureFeedback()
    try await pendingUpdatesAndResolution()
    try await staleSelectionAndProfileIndex()
    try await disconnectDuringMirror()
    try await reconnectWaitsForCleanup()
    try await supersededCreation()
    try await recoveryDuringFailure()
    try await resolutionLifecycleAndFailures()
    try await storeLifetime()
    try await mainActorResponsiveness()
    try await persistenceAndRecovery()
    try await coordinationAcrossTargets()
  }

  static func environment(count: Int = 1) async -> VirtualDisplayTestEnvironment {
    let environment = VirtualDisplayTestEnvironment(
      state: PersistedState(
        profiles: (0..<count).map {
          VirtualDisplayProfile(name: "Display \($0)", resolutionID: "1920x1080")
        }, hasAttemptedLoginItemRegistration: true
      )
    )
    await environment.store.start()
    return environment
  }

  static func postScreenChange() {
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
  }

  static func notificationBurst() async throws {
    let environment = await environment(count: 4)
    let source = DisplayMirrorSource(id: UUID(), name: "Source")
    environment.mirroringManager.sources = [source]
    for profile in environment.store.profiles {
      await environment.store.setMirrorSource(source.id, for: profile.id)
    }
    let scans = environment.mirroringManager.excludedDisplayIDSets.count
    let attempts = environment.mirroringManager.mirrorAttempts.count
    var publications = 0
    let subscription = environment.store.objectWillChange.sink { publications += 1 }
    for _ in 0..<100 { postScreenChange() }
    await environment.store.waitForDisplayUpdates()
    let newScans = environment.mirroringManager.excludedDisplayIDSets.count - scans
    let newAttempts = environment.mirroringManager.mirrorAttempts.count - attempts
    try require(newScans == 1, "Burst must use one source scan, got \(newScans)")
    try require(newAttempts == 0, "Unchanged mirrors must not call setMirror")
    try require(publications == 0, "Unchanged state must not publish, got \(publications)")
    subscription.cancel()
    print("PASS F1: 100 events, 4 profiles: scans=1 restoreCalls=0 objectWillChange=0")
  }

  static func failureFeedback() async throws {
    let environment = await environment()
    let store = environment.store
    let manager = environment.mirroringManager
    let profile = store.profiles[0]
    let target = environment.backend.connections[profile.id]!.displayID
    let source = DisplayMirrorSource(id: UUID(), name: "Source")
    manager.sources = [source]
    await store.setMirrorSource(source.id, for: profile.id)
    manager.simulateActualMirror(targetDisplayID: target, sourceID: nil)
    manager.setMirrorError = DisplayMirroringError.verificationFailed
    manager.onMirrorAttempt = { postScreenChange() }
    defer { manager.onMirrorAttempt = nil }
    let initial = manager.mirrorAttempts.count
    await store.handleDisplayReconfiguration()
    for _ in 0..<100 { postScreenChange() }
    await store.waitForDisplayUpdates()
    try require(
      manager.mirrorAttempts.count == initial + 1, "Failure feedback must stop after one attempt")
    try require(store.hasMirrorRestoreFailure(profileID: profile.id), "Failure must be visible")
    try require(
      store.profile(id: profile.id)?.mirrorSourceID == source.id, "Failure must preserve intent")
    try require(
      store.takeLastErrorMessage() == nil, "Automatic failure must not produce a modal error")

    await store.retryDesiredConnectionsAfterWake()
    try require(manager.mirrorAttempts.count == initial + 2, "Wake must grant one retry")
    manager.sources = []
    await store.handleDisplayReconfiguration()
    manager.sources = [source]
    await store.handleDisplayReconfiguration()
    try require(
      manager.mirrorAttempts.count == initial + 3, "Source reconnection must grant one retry")
    manager.setMirrorError = nil
    await store.setMirrorSource(source.id, for: profile.id)
    try require(
      manager.mirrorAttempts.count == initial + 4, "Explicit selection must grant one retry")
    try require(store.isMirroring(profileID: profile.id), "Explicit retry must restore mirror")
    try require(
      !store.hasMirrorRestoreFailure(profileID: profile.id), "Successful retry must clear failure")
    print("PASS F1: failure feedback bounded; explicit, wake, and reconnect retries preserved")
  }

  static func pendingUpdatesAndResolution() async throws {
    let environment = await environment()
    let store = environment.store
    let manager = environment.mirroringManager
    let profile = store.profiles[0]
    let source = DisplayMirrorSource(id: UUID(), name: "Source")
    manager.sources = [source]
    await store.setMirrorSource(source.id, for: profile.id)
    manager.simulateActualMirror(
      targetDisplayID: environment.backend.connections[profile.id]!.displayID, sourceID: nil)
    let gate = MirrorCheckGate()
    manager.beforeMirror = { await gate.wait() }
    let scans = manager.excludedDisplayIDSets.count
    postScreenChange()
    await gate.entered()
    for _ in 0..<100 { postScreenChange() }
    let newSource = DisplayMirrorSource(id: UUID(), name: "New source")
    manager.sources = [source, newSource]
    await store.setResolution(ResolutionPreset.preset(withID: "2560x1440")!, for: profile.id)
    try require(
      environment.backend.resolutionRequests.isEmpty,
      "Pending mirror must reject resolution changes")
    try require(store.takeLastErrorMessage() != nil, "Rejected resolution must report an error")
    manager.beforeMirror = nil
    gate.open()
    await store.waitForDisplayUpdates()
    try require(
      manager.excludedDisplayIDSets.count == scans + 2,
      "Events during a pass must merge into one pending scan")
    try require(
      store.mirrorSources == [source, newSource], "Pending pass must preserve the latest inventory")
    try require(
      store.profile(id: profile.id)?.resolutionID == "1920x1080", "Rejected mode must not be saved")
    print(
      "PASS F1/F3: in-flight events merge; latest inventory retained; pending mode change rejected")
  }

  static func staleSelectionAndProfileIndex() async throws {
    let environment = await environment(count: 2)
    let store = environment.store
    let manager = environment.mirroringManager
    let removedID = store.profiles[0].id
    let id = store.profiles[1].id
    let first = DisplayMirrorSource(id: UUID(), name: "First")
    let second = DisplayMirrorSource(id: UUID(), name: "Second")
    manager.sources = [first, second]
    let gate = MirrorCheckGate()
    manager.beforeMirror = { await gate.wait() }
    let oldSelection = Task { await store.setMirrorSource(first.id, for: id) }
    await gate.entered()
    await store.removeProfile(id: removedID)
    let submitted = MirrorCheckGate()
    let newSelection = Task {
      submitted.open()
      await store.setMirrorSource(second.id, for: id)
    }
    await submitted.entered()
    manager.beforeMirror = nil
    gate.open()
    await oldSelection.value
    await newSelection.value
    try require(store.profiles.count == 1, "Unrelated removal must remain removed")
    try require(
      store.profile(id: id)?.mirrorSourceID == second.id, "Only the newest selection may persist")
    try require(
      store.activeMirrorSourceIDs[id] == second.id,
      "Newest selection must be the final actual mirror")
    try require(
      environment.repository.state.profiles[0].mirrorSourceID == second.id,
      "Saved index must be revalidated after suspension")
    print("PASS F3: stale selection ignored and changed profile index handled safely")
  }

  static func disconnectDuringMirror() async throws {
    for remove in [false, true] {
      let environment = await environment()
      let store = environment.store
      let manager = environment.mirroringManager
      let profile = store.profiles[0]
      let connection = environment.backend.connections[profile.id]!
      let source = DisplayMirrorSource(id: UUID(), name: "Source")
      manager.sources = [source]
      let gate = MirrorCheckGate()
      manager.beforeMirror = { await gate.wait() }
      let selection = Task { await store.setMirrorSource(source.id, for: profile.id) }
      await gate.entered()
      let submitted = MirrorCheckGate()
      let cleanup = Task {
        submitted.open()
        if remove {
          await store.removeProfile(id: profile.id)
        } else {
          await store.disconnectProfile(id: profile.id)
        }
      }
      await submitted.entered()
      manager.beforeMirror = nil
      gate.open()
      await selection.value
      await cleanup.value
      try require(connection.invalidated, "Cleanup must invalidate the old connection")
      try require(
        manager.mirrorSourceID(for: connection.displayID) == nil,
        "Late mirror write must be cleared before invalidation")
      try require(
        store.activeMirrorSourceIDs[profile.id] == nil, "Late result must not restore store state")
      try require(
        store.profile(id: profile.id)?.desiredConnected != true,
        "Late result must not restore saved intent")
      if remove {
        try require(store.profile(id: profile.id) == nil, "Removed profile must not return")
      }
    }
    print("PASS F3: disconnect/removal during a mirror write clean up late results")
  }

  static func reconnectWaitsForCleanup() async throws {
    let environment = await environment()
    let store = environment.store
    let manager = environment.mirroringManager
    let id = store.profiles[0].id
    let oldConnection = environment.backend.connections[id]!
    let source = DisplayMirrorSource(id: UUID(), name: "Source")
    manager.sources = [source]
    await store.setMirrorSource(source.id, for: id)
    let gate = MirrorCheckGate()
    manager.beforeMirror = { await gate.wait() }
    let disconnect = Task { await store.disconnectProfile(id: id) }
    await gate.entered()
    let initialRequests = environment.backend.connectRequests.count
    let submitted = MirrorCheckGate()
    let reconnect = Task {
      submitted.open()
      await store.connectProfile(id: id)
    }
    await submitted.entered()
    try require(
      environment.backend.connectRequests.count == initialRequests,
      "Reconnect must wait for the old mirror cleanup")
    manager.beforeMirror = nil
    gate.open()
    await disconnect.value
    await reconnect.value
    try require(oldConnection.invalidated, "Old connection must be invalidated before replacement")
    try require(
      environment.backend.connections[id]!.displayID != oldConnection.displayID,
      "Reconnect must create a new handle")
    try require(
      store.activeMirrorSourceIDs[id] == source.id, "Reconnect must restore saved mirror intent")
    print("PASS lifecycle: reconnect waits for detached connection cleanup")
  }

  static func supersededCreation() async throws {
    let environment = await environment()
    let store = environment.store
    let backend = environment.backend
    let id = store.profiles[0].id
    await store.disconnectProfile(id: id)
    let gate = MirrorCheckGate()
    backend.beforeConnect = { _ in await gate.wait() }
    let first = Task { await store.connectProfile(id: id) }
    await gate.entered()
    let initialRequests = backend.connectRequests.count
    let submitted = MirrorCheckGate()
    let replacement = Task {
      submitted.open()
      await store.connectProfile(id: id)
    }
    await submitted.entered()
    try require(
      backend.connectRequests.count == initialRequests,
      "Replacement must await the superseded creation")
    backend.beforeConnect = nil
    gate.open()
    await first.value
    await replacement.value
    try require(
      backend.createdConnections.dropLast().allSatisfy(\.invalidated),
      "All superseded handles must be invalidated")
    try require(backend.createdConnections.last?.isValid == true, "Replacement must remain valid")
    try require(store.state(for: id).isConnected, "Late creation must not replace current state")
    print("PASS lifecycle: superseded creation is awaited and its late handle is invalidated")
  }

  static func recoveryDuringFailure() async throws {
    for wake in [false, true] {
      let environment = await environment(count: 2)
      let store = environment.store
      let manager = environment.mirroringManager
      let source = DisplayMirrorSource(id: UUID(), name: "Source")
      manager.sources = [source]
      for profile in store.profiles { await store.setMirrorSource(source.id, for: profile.id) }
      let id = store.profiles[0].id
      let target = environment.backend.connections[id]!.displayID
      let otherTarget = environment.backend.connections[store.profiles[1].id]!.displayID
      manager.simulateActualMirror(targetDisplayID: target, sourceID: nil)
      manager.setMirrorError = DisplayMirroringError.verificationFailed
      let gate = MirrorCheckGate()
      manager.beforeMirror = { await gate.wait() }
      manager.onMirrorAttempt = { postScreenChange() }
      let attempts = manager.mirrorAttempts.filter { $0.targetDisplayID == target }.count
      postScreenChange()
      await gate.entered()
      var recovery: Task<Void, Never>?
      if wake {
        let submitted = MirrorCheckGate()
        recovery = Task {
          submitted.open()
          await store.retryDesiredConnectionsAfterWake()
        }
        await submitted.entered()
      } else {
        manager.simulateActualMirror(targetDisplayID: otherTarget, sourceID: nil)
        postScreenChange()
      }
      manager.beforeMirror = nil
      gate.open()
      await recovery?.value
      await store.waitForDisplayUpdates()
      try require(
        manager.mirrorAttempts.filter { $0.targetDisplayID == target }.count == attempts + 2,
        "A failed old operation must not consume a newer wake or mirror-state retry")

      manager.onMirrorAttempt = nil
      manager.setMirrorError = nil
      manager.afterMirrorError = DisplayMirroringError.configurationFailed(9)
      await store.retryDesiredConnectionsAfterWake()
      try require(
        !store.hasMirrorRestoreFailure(profileID: id),
        "A reported error with the desired actual state must clear old restore failure")
    }
    print(
      "PASS F1: in-flight failure preserves newer wake/topology retries and actual-state reporting")
  }

  static func resolutionLifecycleAndFailures() async throws {
    let environment = await environment(count: 2)
    let store = environment.store
    let backend = environment.backend
    let removedID = store.profiles[0].id
    let id = store.profiles[1].id
    let mode = ResolutionPreset.preset(withID: "2560x1440")!
    let newerMode = ResolutionPreset.preset(withID: "3840x2160")!
    let gate = MirrorCheckGate()
    backend.beforeResolution = { await gate.wait() }
    let first = Task { await store.setResolution(mode, for: id) }
    await gate.entered()
    await store.removeProfile(id: removedID)
    backend.beforeResolution = nil
    let submitted = MirrorCheckGate()
    let second = Task {
      submitted.open()
      await store.setResolution(newerMode, for: id)
    }
    await submitted.entered()
    gate.open()
    await first.value
    await second.value
    let target = backend.connections[id]!.displayID
    try require(
      store.profile(id: id)?.resolutionID == newerMode.id
        && backend.appliedResolutionIDs[target] == newerMode.id,
      "Mode metadata and actual mode must follow the newest request despite a changed array index")

    backend.setResolutionError = .modeSwitchFailed
    await store.setResolution(mode, for: id)
    try require(
      store.profile(id: id)?.resolutionID == newerMode.id, "A failed mode must not be saved")
    try require(
      store.takeLastErrorMessage()
        == VirtualDisplayBackendError.modeSwitchFailed.localizedDescription,
      "Mode error must be reported without double wrapping")
    backend.setResolutionError = nil

    let fallbackGate = MirrorCheckGate()
    backend.beforeResolution = { await fallbackGate.wait() }
    let olderSuccess = Task { await store.setResolution(mode, for: id) }
    await fallbackGate.entered()
    backend.beforeResolution = nil
    backend.resolutionErrors[newerMode.id] = .modeSwitchFailed
    let retrySubmitted = MirrorCheckGate()
    let newerFailure = Task {
      retrySubmitted.open()
      // This matches the saved mode while the older write is still pending.
      await store.setResolution(newerMode, for: id)
    }
    await retrySubmitted.entered()
    fallbackGate.open()
    await olderSuccess.value
    await newerFailure.value
    try require(
      store.profile(id: id)?.resolutionID == mode.id
        && backend.appliedResolutionIDs[target] == mode.id,
      "A failed newer write must retain the preceding successful actual mode")
    try require(
      store.takeLastErrorMessage() != nil, "The failed newest request must report an error")
    backend.resolutionErrors.removeAll()
    await store.setResolution(newerMode, for: id)
    try require(
      store.profile(id: id)?.resolutionID == newerMode.id
        && backend.appliedResolutionIDs[target] == newerMode.id,
      "Selecting the original saved mode must perform a write after the newer failure")

    let removalGate = MirrorCheckGate()
    backend.beforeResolution = { await removalGate.wait() }
    let pending = Task { await store.setResolution(mode, for: id) }
    await removalGate.entered()
    await store.removeProfile(id: id)
    removalGate.open()
    await pending.value
    try require(
      store.profiles.isEmpty && store.connectionStates.isEmpty,
      "A late mode completion must not restore a removed profile")
    print("PASS regression: resolution ordering, changed indexes, errors, and removal")
  }

  static func storeLifetime() async throws {
    for suspended in [false, true] {
      let backend = FakeVirtualDisplayBackend()
      let manager = FakeDisplayMirroringManager()
      let source = DisplayMirrorSource(id: UUID(), name: "Source")
      let profile = VirtualDisplayProfile(
        name: "Lifetime", resolutionID: "1920x1080", mirrorSourceID: source.id)
      var store: VirtualDisplayStore? = VirtualDisplayStore(
        backend: backend,
        repository: MemoryStateRepository(
          state: PersistedState(
            profiles: [profile], hasAttemptedLoginItemRegistration: true)),
        launchAtLoginManager: FakeLaunchAtLoginManager(), mirroringManager: manager,
        wakeRetryDelayNanoseconds: 0
      )
      await store!.start()
      let connection = backend.connections[profile.id]!
      let gate = MirrorCheckGate()
      let invalidated = MirrorCheckGate()
      connection.onInvalidate = { invalidated.open() }
      if suspended { manager.beforeMirror = { await gate.wait() } }
      manager.sources = [source]
      let scans = manager.excludedDisplayIDSets.count
      postScreenChange()
      if suspended { await gate.entered() }
      var publications = 0
      let subscription = store!.objectWillChange.sink { publications += 1 }
      let weakStore = WeakStoreReference(store!)
      store = nil
      try require(
        weakStore.value == nil, "Scheduled work must not retain the store across suspension")
      manager.beforeMirror = nil
      gate.open()
      await invalidated.entered()
      try require(publications == 0, "Released store must not receive late publications")
      try require(
        manager.excludedDisplayIDSets.count == scans + (suspended ? 1 : 0),
        "Released store must not schedule another pass")
      try require(
        manager.mirrorSourceID(for: connection.displayID) == nil,
        "Teardown must clear any late mirror")
      subscription.cancel()
    }
    print(
      "PASS lifecycle: store release before and during a pass; no late publication or follow-up")
  }

  static func mainActorResponsiveness() async throws {
    let gate = MirrorWorkerCheckGate()
    defer { gate.open() }
    let manager = DisplayMirroringManager(worker: DisplayOperationWorker()) { _, _ in
      if Thread.isMainThread { throw Failure(description: "Configuration ran on main thread") }
      gate.block()
    }
    let operation = Task { try await manager.setMirror(targetDisplayID: 1, sourceID: nil) }
    await gate.entered()
    // Reaching this line on MainActor while the worker is gated proves it yielded.
    gate.open()
    try await operation.value
    print("PASS F3: real mirroring service yields MainActor during a gated worker transaction")
  }

  static func coordinationAcrossTargets() async throws {
    for sourceAppearsLater in [false, true] {
      let environment = await environment(count: 2)
      let store = environment.store
      let manager = environment.mirroringManager
      let first = store.profiles[0].id
      let second = store.profiles[1].id
      let firstTarget = environment.backend.connections[first]!.displayID
      let secondTarget = environment.backend.connections[second]!.displayID
      let source = DisplayMirrorSource(id: UUID(), name: "Source")
      let other = DisplayMirrorSource(id: UUID(), name: "Other")
      manager.sources = [source, other]
      await store.setMirrorSource(source.id, for: first)
      await store.setMirrorSource(sourceAppearsLater ? other.id : source.id, for: second)
      let saved = environment.repository.state
      manager.simulateActualMirror(targetDisplayID: firstTarget, sourceID: nil)
      manager.simulateActualMirror(targetDisplayID: secondTarget, sourceID: nil)
      if sourceAppearsLater { manager.sources = [other] }
      manager.onMirrorChange = { [weak store, weak manager] in
        guard let manager else { return }
        if manager.mirrorSourceID(for: secondTarget) != nil {
          manager.onMirrorChange = nil
          if sourceAppearsLater {
            manager.sources = [source, other]
          } else {
            manager.simulateActualMirror(targetDisplayID: firstTarget, sourceID: nil)
          }
        }
        store?.scheduleDisplayReconfiguration()
      }
      let initial = manager.mirrorAttempts.count
      await store.handleDisplayReconfiguration()
      manager.onMirrorChange = nil
      try require(
        store.activeMirrorSourceIDs[first] == source.id,
        "An earlier target must be revisited after a later target changes its state or source availability"
      )
      try require(
        store.activeMirrorSourceIDs[second] == (sourceAppearsLater ? other.id : source.id),
        "The later target must retain its requested source")
      try require(
        manager.mirrorAttempts.count == initial + (sourceAppearsLater ? 2 : 3),
        "Coordination must not issue redundant writes to unchanged targets")
      try require(
        environment.repository.state == saved, "Automatic coordination must not change saved intent"
      )
      await store.setMirrorSource(nil, for: first)
      try require(
        store.profile(id: first)?.mirrorSourceID == nil
          && store.activeMirrorSourceIDs[first] == nil,
        "Explicit clearing must not restore old intent")
    }
    print(
      "PASS regression: cross-target restoration, source return during a pass, and explicit clearing"
    )
  }

  static func persistenceAndRecovery() async throws {
    let environment = await environment()
    let store = environment.store
    let id = store.profiles[0].id
    let source = DisplayMirrorSource(id: UUID(), name: "Source")
    environment.mirroringManager.sources = [source]
    await store.setMirrorSource(source.id, for: id)
    let oldConnection = environment.backend.connections[id]!
    await store.renameProfile(id: id, to: "Renamed")
    try require(oldConnection.invalidated, "Rename must invalidate old handle")
    try require(store.profile(id: id)?.name == "Renamed", "Rename must persist")
    try require(
      store.activeMirrorSourceIDs[id] == source.id, "Rename must restore saved mirror intent")
    let target = environment.backend.connections[id]!
    target.invalidate()
    await store.retryDesiredConnectionsAfterWake()
    try require(
      environment.backend.connections[id]!.displayID != target.displayID,
      "Wake must reconnect an invalid handle")
    try require(
      store.activeMirrorSourceIDs[id] == source.id, "Wake must restore saved mirror intent")
    let reloaded = VirtualDisplayTestEnvironment(state: environment.repository.state)
    reloaded.mirroringManager.sources = [source]
    await reloaded.store.start()
    try require(
      reloaded.store.profile(id: id)?.name == "Renamed", "Reload must preserve saved name")
    try require(
      reloaded.store.activeMirrorSourceIDs[id] == source.id,
      "Reload must restore saved mirror intent")
    print("PASS regression: saved intent, rename, wake reconnection, and reload")
  }
}

@MainActor
private final class WeakStoreReference {
  weak var value: VirtualDisplayStore?

  init(_ value: VirtualDisplayStore) { self.value = value }
}

@MainActor
private final class MirrorCheckGate {
  private var released = false
  private var didEnter = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var observers: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    didEnter = true
    let pending = observers
    observers.removeAll()
    for observer in pending { observer.resume() }
    if !released { await withCheckedContinuation { waiters.append($0) } }
  }

  func entered() async {
    if didEnter || released { return }
    await withCheckedContinuation { observers.append($0) }
  }

  func open() {
    released = true
    let pending = waiters + observers
    waiters.removeAll()
    observers.removeAll()
    for continuation in pending { continuation.resume() }
  }
}

private final class MirrorWorkerCheckGate: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func block() {
    continuation.yield(())
    semaphore.wait()
  }

  func entered() async {
    for await _ in stream { return }
  }

  func open() { semaphore.signal() }
}
