import CoreGraphics
import Foundation

@testable import DisplayLoom

final class MemoryStateRepository: StatePersisting {
  var state: PersistedState
  private(set) var savedStates: [PersistedState] = []

  init(state: PersistedState = PersistedState()) {
    self.state = state
  }

  func load() -> PersistedState { state }

  func save(_ state: PersistedState) {
    self.state = state
    savedStates.append(state)
  }
}

final class FakeLaunchAtLoginManager: LaunchAtLoginManaging {
  var status: LaunchAtLoginStatus = .disabled
  var registerError: Error?
  var unregisterError: Error?
  var statusAfterRegistration: LaunchAtLoginStatus = .enabled
  private(set) var registerCallCount = 0
  private(set) var unregisterCallCount = 0
  private(set) var openSettingsCallCount = 0

  func register() throws {
    registerCallCount += 1
    if let registerError { throw registerError }
    if status != .requiresApproval { status = statusAfterRegistration }
  }

  func unregister() throws {
    unregisterCallCount += 1
    if let unregisterError { throw unregisterError }
    status = .disabled
  }

  func openSystemSettings() {
    openSettingsCallCount += 1
  }
}

final class FakeDisplayConnection: VirtualDisplayConnection {
  let displayID: CGDirectDisplayID
  private(set) var invalidated = false

  init(displayID: CGDirectDisplayID) {
    self.displayID = displayID
  }

  var isValid: Bool { !invalidated }

  func invalidate() {
    invalidated = true
  }
}

struct MirrorRequest: Equatable {
  let targetDisplayID: CGDirectDisplayID
  let sourceID: UUID?
}

@MainActor
final class FakeDisplayMirroringManager: DisplayMirroringManaging {
  var sources: [DisplayMirrorSource] = []
  var availableSourcesError: Error?
  var setMirrorError: Error?
  var onMirrorChange: (() -> Void)?

  private(set) var excludedDisplayIDSets: [Set<CGDirectDisplayID>] = []
  private(set) var mirrorRequests: [MirrorRequest] = []
  private(set) var actualSourceIDs: [CGDirectDisplayID: UUID] = [:]

  func availableSources(excluding displayIDs: Set<CGDirectDisplayID>) throws
    -> [DisplayMirrorSource]
  {
    excludedDisplayIDSets.append(displayIDs)
    if let availableSourcesError { throw availableSourcesError }
    return sources
  }

  func mirrorSourceID(for targetDisplayID: CGDirectDisplayID) -> UUID? {
    actualSourceIDs[targetDisplayID]
  }

  func setMirror(targetDisplayID: CGDirectDisplayID, sourceID: UUID?) throws {
    if let setMirrorError { throw setMirrorError }
    guard actualSourceIDs[targetDisplayID] != sourceID else { return }

    mirrorRequests.append(MirrorRequest(targetDisplayID: targetDisplayID, sourceID: sourceID))
    if let sourceID {
      actualSourceIDs[targetDisplayID] = sourceID
    } else {
      actualSourceIDs[targetDisplayID] = nil
    }
    onMirrorChange?()
  }

  func simulateActualMirror(targetDisplayID: CGDirectDisplayID, sourceID: UUID?) {
    if let sourceID {
      actualSourceIDs[targetDisplayID] = sourceID
    } else {
      actualSourceIDs[targetDisplayID] = nil
    }
  }
}

final class FakeVirtualDisplayBackend: VirtualDisplayBackend {
  var availability: VirtualDisplayBackendAvailability = .available
  var connectError: Error?
  var setResolutionError: Error?

  private(set) var connectRequests: [(VirtualDisplayProfile, ResolutionPreset)] = []
  private(set) var resolutionRequests: [(String, CGDirectDisplayID)] = []
  private(set) var connections: [UUID: FakeDisplayConnection] = [:]
  private var terminationHandlers: [UUID: () -> Void] = [:]
  private var nextDisplayID: CGDirectDisplayID = 100

  func connect(
    profile: VirtualDisplayProfile,
    resolution: ResolutionPreset,
    terminationHandler: @escaping () -> Void
  ) async throws -> any VirtualDisplayConnection {
    connectRequests.append((profile, resolution))
    if let connectError { throw connectError }
    nextDisplayID += 1
    let connection = FakeDisplayConnection(displayID: nextDisplayID)
    connections[profile.id] = connection
    terminationHandlers[profile.id] = terminationHandler
    return connection
  }

  func setResolution(
    _ resolution: ResolutionPreset,
    for connection: any VirtualDisplayConnection
  ) async throws {
    if let setResolutionError { throw setResolutionError }
    resolutionRequests.append((resolution.id, connection.displayID))
  }

  func terminate(profileID: UUID) {
    terminationHandlers[profileID]?()
  }
}

@MainActor
struct VirtualDisplayTestEnvironment {
  let backend = FakeVirtualDisplayBackend()
  let loginManager = FakeLaunchAtLoginManager()
  let mirroringManager = FakeDisplayMirroringManager()
  let repository: MemoryStateRepository
  let store: VirtualDisplayStore

  init(state: PersistedState = PersistedState()) {
    repository = MemoryStateRepository(state: state)
    store = VirtualDisplayStore(
      backend: backend,
      repository: repository,
      launchAtLoginManager: loginManager,
      mirroringManager: mirroringManager,
      wakeRetryDelayNanoseconds: 0
    )
  }
}
