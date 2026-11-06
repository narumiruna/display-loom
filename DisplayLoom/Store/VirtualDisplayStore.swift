import AppKit
import Combine
import CoreGraphics
import Foundation
import os

@MainActor
enum DisplayConnectionState: Equatable {
  case disconnected
  case connecting
  case connected(displayID: CGDirectDisplayID)
  case failed(message: String)

  var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }

  var isBusy: Bool {
    if case .connecting = self { return true }
    return false
  }
}

@MainActor
final class VirtualDisplayStore: ObservableObject {
  @Published private(set) var profiles: [VirtualDisplayProfile]
  @Published private(set) var connectionStates: [UUID: DisplayConnectionState]
  @Published private(set) var backendAvailability: VirtualDisplayBackendAvailability
  @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
  @Published private(set) var shouldShowLaunchAtLoginApproval = false
  @Published private(set) var lastErrorMessage: String?
  @Published private(set) var mirrorSources: [DisplayMirrorSource] = []
  @Published private(set) var activeMirrorSourceIDs: [UUID: UUID] = [:]
  @Published private(set) var mirrorRestoreFailures: Set<UUID> = []

  private let backend: VirtualDisplayBackend
  private let repository: StatePersisting
  private let launchAtLoginManager: LaunchAtLoginManaging
  private let mirroringManager: any DisplayMirroringManaging
  private let wakeRetryDelayNanoseconds: UInt64
  private let logger = Logger(subsystem: "dev.narumi.DisplayLoom", category: "Store")

  private var hasAcknowledged8KWarning: Bool
  private var hasAttemptedLoginItemRegistration: Bool
  private var connections: [UUID: any VirtualDisplayConnection] = [:]
  private var connectionTokens: [UUID: UUID] = [:]
  private var workspaceWakeObserver: NSObjectProtocol?
  private var screenParametersObserver: NSObjectProtocol?
  private var hasStarted = false
  private var wakeRetryInProgress = false
  private struct RestoreSnapshot: Equatable {
    let connectionToken: UUID
    let targetDisplayID: CGDirectDisplayID
    let sourceID: UUID
    let onlineDisplays: [CGDirectDisplayID: UUID]
    let actualSources: [UUID: UUID]
  }

  private struct RestoreRequest {
    let profileID: UUID
    let connectionToken: UUID
    let sourceID: UUID
  }

  private struct MirrorOperation {
    let profileID: UUID
    let connectionToken: UUID
    let requestToken: UUID
    let connection: any VirtualDisplayConnection
    let sourceID: UUID?
    let snapshot: RestoreSnapshot?
    let recoveryGeneration: UUID?
    let task: Task<Result<Void, Error>, Never>
  }

  private var mirrorOperations: [UUID: MirrorOperation] = [:]
  private var pendingConnections: [UUID: Task<any VirtualDisplayConnection, Error>] = [:]
  private var connectionCleanups: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
  private var recoveryGenerations: [UUID: UUID] = [:]
  private var failedRestores: [UUID: RestoreSnapshot] = [:]
  private var resolutionTokens: [UUID: UUID] = [:]
  private var resolutionTasks: [UUID: Task<Void, Never>] = [:]
  private var onlineDisplays: [CGDirectDisplayID: UUID] = [:]
  private var screenUpdateTask: Task<Void, Never>?
  private var screenUpdatePending = false

  init(
    backend: VirtualDisplayBackend,
    repository: StatePersisting,
    launchAtLoginManager: LaunchAtLoginManaging,
    mirroringManager: any DisplayMirroringManaging,
    wakeRetryDelayNanoseconds: UInt64 = 1_000_000_000
  ) {
    self.backend = backend
    self.repository = repository
    self.launchAtLoginManager = launchAtLoginManager
    self.mirroringManager = mirroringManager
    self.wakeRetryDelayNanoseconds = wakeRetryDelayNanoseconds

    let state = repository.load()
    hasAcknowledged8KWarning = state.hasAcknowledged8KWarning
    hasAttemptedLoginItemRegistration = state.hasAttemptedLoginItemRegistration
    profiles = state.profiles
    connectionStates = Dictionary(
      uniqueKeysWithValues: state.profiles.map { ($0.id, .disconnected) }
    )
    backendAvailability = backend.availability
    launchAtLoginStatus = launchAtLoginManager.status
  }

  convenience init() {
    self.init(
      backend: CoreGraphicsVirtualDisplayBackend(),
      repository: StateRepository(),
      launchAtLoginManager: LaunchAtLoginManager(),
      mirroringManager: DisplayMirroringManager()
    )
  }

  deinit {
    screenUpdateTask?.cancel()
    for operation in mirrorOperations.values { operation.task.cancel() }
    for operation in resolutionTasks.values { operation.cancel() }
    let creations = Array(pendingConnections.values)
    for creation in creations { creation.cancel() }
    let manager = mirroringManager
    let logger = logger
    let operations = mirrorOperations
    let cleanup = connections.map { id, connection in
      (connection, operations[id]?.task)
    }
    if !cleanup.isEmpty || !creations.isEmpty {
      Task { @MainActor in
        for creation in creations {
          if let connection = try? await creation.value { connection.invalidate() }
        }
        for (connection, operation) in cleanup {
          await Self.cleanupConnection(connection, after: operation, using: manager, logger: logger)
        }
      }
    }
    if let workspaceWakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
    }
    if let screenParametersObserver {
      NotificationCenter.default.removeObserver(screenParametersObserver)
    }
  }

  func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    installWakeObserver()
    installScreenParametersObserver()
    configureDefaultLaunchAtLoginIfNeeded()

    guard backendAvailability.isAvailable else {
      if case .unavailable(let reason) = backendAvailability {
        for profile in profiles where profile.desiredConnected {
          connectionStates[profile.id] = .failed(message: reason)
        }
      }
      return
    }

    for profile in profiles where profile.desiredConnected {
      await connectProfile(id: profile.id, updateDesiredState: false)
    }
  }

  func state(for profileID: UUID) -> DisplayConnectionState {
    connectionStates[profileID] ?? .disconnected
  }

  func profile(id: UUID) -> VirtualDisplayProfile? {
    profiles.first { $0.id == id }
  }

  func isMirroring(profileID: UUID) -> Bool {
    activeMirrorSourceIDs[profileID] != nil
  }

  func hasMirrorRestoreFailure(profileID: UUID) -> Bool {
    mirrorRestoreFailures.contains(profileID)
  }

  func setMirrorSource(_ sourceID: UUID?, for profileID: UUID) async {
    recoveryGenerations[profileID] = UUID()
    guard let operation = beginMirror(sourceID, for: profileID) else {
      reportError(DisplayMirroringError.targetUnavailable.localizedDescription)
      return
    }
    failedRestores[profileID] = nil
    let result = await operation.task.value
    finishMirror(operation, result: result, explicit: true)
    await handleDisplayReconfiguration()
  }

  func handleDisplayReconfiguration() async {
    scheduleDisplayReconfiguration()
    await waitForDisplayUpdates()
  }

  func waitForDisplayUpdates() async {
    while let task = screenUpdateTask { await task.value }
  }

  func scheduleDisplayReconfiguration() {
    screenUpdatePending = true
    guard screenUpdateTask == nil else { return }
    screenUpdateTask = Task { @MainActor [weak self] in
      await Task.yield()
      while !Task.isCancelled {
        guard let requests = self?.prepareScreenUpdate() else { return }
        for request in requests {
          guard let operation = self?.beginRestore(request) else { continue }
          let result = await operation.task.value
          guard !Task.isCancelled else { return }
          self?.finishMirror(operation, result: result, explicit: false)
        }
        guard self?.screenUpdatePending == true else {
          self?.screenUpdateTask = nil
          return
        }
      }
    }
  }

  func needs8KWarning(for resolution: ResolutionPreset) -> Bool {
    resolution.is8K && !hasAcknowledged8KWarning
  }

  func acknowledge8KWarning() {
    hasAcknowledged8KWarning = true
    save()
  }

  func addDisplay(resolution: ResolutionPreset) async {
    guard backendAvailability.isAvailable else {
      reportError(backendUnavailableMessage())
      return
    }

    let profile = VirtualDisplayProfile(
      name: nextAvailableDisplayName(),
      resolutionID: resolution.id,
      desiredConnected: true
    )
    profiles.append(profile)
    connectionStates[profile.id] = .disconnected
    save()
    await connectProfile(id: profile.id, updateDesiredState: false)
  }

  func connectProfile(id: UUID) async {
    await connectProfile(id: id, updateDesiredState: true)
  }

  func disconnectProfile(id: UUID) async {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
    profiles[index].desiredConnected = false
    let cleanup = detachConnection(for: id)
    connectionStates[id] = .disconnected
    save()
    await cleanup?.value
    logger.info("Disconnected virtual display \(id.uuidString, privacy: .public)")
  }

  func setResolution(_ resolution: ResolutionPreset, for profileID: UUID) async {
    guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
    guard profiles[index].resolutionID != resolution.id || resolutionTasks[profileID] != nil
    else { return }

    if mirrorOperations[profileID] != nil
      || connections[profileID].map({
        mirroringManager.mirrorSourceID(for: $0.displayID) != nil
      }) == true
    {
      refreshActiveMirrorStates()
      reportError(
        String(
          localized: "error.resolutionMirrored",
          defaultValue: "Disconnect display mirroring before changing the resolution."
        )
      )
      return
    }

    if let connection = connections[profileID], let token = connectionTokens[profileID] {
      let requestToken = UUID()
      let previous = resolutionTasks[profileID]
      let backend = backend
      resolutionTokens[profileID] = requestToken
      let operation = Task { @MainActor [weak self] () in
        defer { self?.finishResolutionRequest(for: profileID, token: requestToken) }
        await previous?.value
        guard !Task.isCancelled, self?.connectionTokens[profileID] == token,
          self?.resolutionTokens[profileID] == requestToken
        else { return }
        do {
          try await backend.setResolution(resolution, for: connection)
          // Commit this actual mode before the next write. A later failed write
          // must not leave persistence pointing at a mode older than this one.
          self?.applyResolution(resolution, for: profileID, connectionToken: token)
        } catch {
          guard self?.connectionTokens[profileID] == token,
            self?.resolutionTokens[profileID] == requestToken
          else { return }
          self?.reportError(error.localizedDescription)
        }
      }
      resolutionTasks[profileID] = operation
      await withTaskCancellationHandler(
        operation: {
          await operation.value
        },
        onCancel: {
          operation.cancel()
        }
      )
      return
    }

    profiles[index].resolutionID = resolution.id
    save()

    if case .connecting = state(for: profileID), profiles[index].desiredConnected {
      await connectProfile(id: profileID, updateDesiredState: false)
    }
  }

  private func finishResolutionRequest(for profileID: UUID, token: UUID) {
    guard resolutionTokens[profileID] == token else { return }
    resolutionTokens[profileID] = nil
    resolutionTasks[profileID] = nil
  }

  private func applyResolution(
    _ resolution: ResolutionPreset,
    for profileID: UUID,
    connectionToken: UUID
  ) {
    guard connectionTokens[profileID] == connectionToken,
      let index = profiles.firstIndex(where: { $0.id == profileID }),
      let connection = connections[profileID]
    else { return }
    profiles[index].resolutionID = resolution.id
    connectionStates[profileID] = .connected(displayID: connection.displayID)
    save()
  }

  func renameProfile(id: UUID, to proposedName: String) async {
    let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      reportError(
        String(localized: "error.emptyName", defaultValue: "The display name cannot be empty.")
      )
      return
    }
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
    guard profiles[index].name != name else { return }

    profiles[index].name = String(name.prefix(64))
    let shouldReconnect = profiles[index].desiredConnected && connections[id] != nil
    save()

    if shouldReconnect {
      let cleanup = detachConnection(for: id)
      connectionStates[id] = .disconnected
      await cleanup?.value
      guard connectionTokens[id] == nil, profile(id: id)?.desiredConnected == true else { return }
      await connectProfile(id: id, updateDesiredState: false)
    }
  }

  func removeProfile(id: UUID) async {
    let cleanup = detachConnection(for: id)
    connectionStates[id] = nil
    profiles.removeAll { $0.id == id }
    save()
    await cleanup?.value
    logger.info("Removed virtual display \(id.uuidString, privacy: .public)")
  }

  func retryDesiredConnectionsAfterWake() async {
    guard !wakeRetryInProgress else { return }
    wakeRetryInProgress = true
    defer { wakeRetryInProgress = false }

    if wakeRetryDelayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: wakeRetryDelayNanoseconds)
    }

    for profile in profiles where profile.desiredConnected {
      if let connection = connections[profile.id], !connection.isValid {
        let cleanup = detachConnection(for: profile.id)
        connectionStates[profile.id] = .disconnected
        await cleanup?.value
      }
      if connections[profile.id] == nil {
        await connectProfile(id: profile.id, updateDesiredState: false)
      }
    }

    for id in connectionTokens.keys { recoveryGenerations[id] = UUID() }
    failedRestores.removeAll()
    await handleDisplayReconfiguration()
  }

  func setLaunchAtLoginEnabled(_ enabled: Bool) {
    launchAtLoginStatus = launchAtLoginManager.status
    if enabled && launchAtLoginStatus == .requiresApproval {
      shouldShowLaunchAtLoginApproval = true
      return
    }
    if enabled && launchAtLoginStatus == .enabled { return }
    if !enabled && launchAtLoginStatus == .disabled { return }

    do {
      if enabled {
        try launchAtLoginManager.register()
      } else {
        try launchAtLoginManager.unregister()
      }
      launchAtLoginStatus = launchAtLoginManager.status
      if launchAtLoginStatus == .requiresApproval {
        shouldShowLaunchAtLoginApproval = true
      }
    } catch {
      launchAtLoginStatus = launchAtLoginManager.status
      reportError(
        String(
          format: String(
            localized: "error.loginItem",
            defaultValue: "Could not update Launch at Login: %@"
          ),
          error.localizedDescription
        )
      )
    }
  }

  func openLoginItemSettings() {
    launchAtLoginManager.openSystemSettings()
  }

  func clearLaunchAtLoginApprovalNotice() {
    shouldShowLaunchAtLoginApproval = false
  }

  func takeLastErrorMessage() -> String? {
    defer { lastErrorMessage = nil }
    return lastErrorMessage
  }

  private func detachConnection(for profileID: UUID) -> Task<Void, Never>? {
    connectionTokens[profileID] = nil
    resolutionTokens[profileID] = nil
    resolutionTasks.removeValue(forKey: profileID)?.cancel()
    failedRestores[profileID] = nil
    recoveryGenerations[profileID] = nil
    let operation = mirrorOperations.removeValue(forKey: profileID)
    operation?.task.cancel()
    let creation = pendingConnections.removeValue(forKey: profileID)
    creation?.cancel()
    let previousCleanup = connectionCleanups[profileID]?.task
    let connection = connections.removeValue(forKey: profileID)
    if activeMirrorSourceIDs[profileID] != nil { activeMirrorSourceIDs[profileID] = nil }
    setRestoreFailure(false, for: profileID)
    guard connection != nil || creation != nil else { return previousCleanup }
    let manager = mirroringManager
    let logger = logger
    let cleanupToken = UUID()
    let task = Task { @MainActor [weak self] in
      await previousCleanup?.value
      if let creation, let lateConnection = try? await creation.value {
        lateConnection.invalidate()
      }
      if let connection {
        await Self.cleanupConnection(
          connection,
          after: operation?.task,
          using: manager,
          logger: logger
        )
      }
      self?.finishCleanup(for: profileID, token: cleanupToken)
    }
    connectionCleanups[profileID] = (cleanupToken, task)
    return task
  }

  private func finishCleanup(for profileID: UUID, token: UUID) {
    if connectionCleanups[profileID]?.token == token { connectionCleanups[profileID] = nil }
  }

  private static func cleanupConnection(
    _ connection: any VirtualDisplayConnection,
    after operation: Task<Result<Void, Error>, Never>?,
    using manager: any DisplayMirroringManaging,
    logger: Logger
  ) async {
    if let operation { _ = await operation.value }
    do {
      if manager.mirrorSourceID(for: connection.displayID) != nil {
        try await manager.setMirror(targetDisplayID: connection.displayID, sourceID: nil)
      }
    } catch {
      logger.error("Could not clear mirroring: \(error.localizedDescription, privacy: .public)")
    }
    connection.invalidate()
  }

  private func connectProfile(id: UUID, updateDesiredState: Bool) async {
    guard backendAvailability.isAvailable else {
      reportError(backendUnavailableMessage())
      return
    }
    guard let index = profiles.firstIndex(where: { $0.id == id }),
      let resolution = profiles[index].resolution
    else {
      reportError(
        String(
          localized: "error.invalidConfiguration",
          defaultValue: "The virtual display configuration is invalid."
        )
      )
      return
    }

    if updateDesiredState {
      profiles[index].desiredConnected = true
      save()
    } else if !profiles[index].desiredConnected {
      return
    }

    let cleanup = detachConnection(for: id)
    let token = UUID()
    connectionTokens[id] = token
    connectionStates[id] = .connecting
    let profile = profiles[index]
    await cleanup?.value
    guard connectionTokens[id] == token else { return }

    let backend = backend
    let creation = Task { [weak self] in
      try await backend.connect(
        profile: profile,
        resolution: resolution,
        terminationHandler: { [weak self] in
          Task { @MainActor [weak self] in
            await self?.handleTermination(profileID: id, token: token)
          }
        }
      )
    }
    pendingConnections[id] = creation
    do {
      let connection = try await withTaskCancellationHandler(
        operation: {
          try await creation.value
        },
        onCancel: {
          creation.cancel()
        }
      )

      guard connectionTokens[id] == token,
        let currentProfile = profiles.first(where: { $0.id == id }),
        currentProfile.desiredConnected
      else {
        connection.invalidate()
        return
      }

      pendingConnections[id] = nil
      connections[id] = connection
      connectionStates[id] = .connected(displayID: connection.displayID)
      await handleDisplayReconfiguration()
      logger.info("Virtual display \(id.uuidString, privacy: .public) is connected")
    } catch {
      guard connectionTokens[id] == token else { return }
      pendingConnections[id] = nil
      connections[id] = nil
      connectionStates[id] = .failed(message: error.localizedDescription)
      reportError(error.localizedDescription)
    }
  }

  private func handleTermination(profileID: UUID, token: UUID) async {
    guard connectionTokens[profileID] == token else { return }
    let cleanup = detachConnection(for: profileID)
    let message = String(
      localized: "error.unexpectedTermination",
      defaultValue: "The virtual display was disconnected by macOS."
    )
    connectionStates[profileID] = .failed(message: message)
    reportError(message)
    await cleanup?.value
    logger.error(
      "Virtual display \(profileID.uuidString, privacy: .public) terminated unexpectedly"
    )
  }

  private func configureDefaultLaunchAtLoginIfNeeded() {
    guard !hasAttemptedLoginItemRegistration else {
      launchAtLoginStatus = launchAtLoginManager.status
      return
    }

    hasAttemptedLoginItemRegistration = true
    save()
    setLaunchAtLoginEnabled(true)
  }

  private func installWakeObserver() {
    workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.retryDesiredConnectionsAfterWake()
      }
    }
  }

  private func installScreenParametersObserver() {
    screenParametersObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.scheduleDisplayReconfiguration()
      }
    }
  }

  private func prepareScreenUpdate() -> [RestoreRequest] {
    screenUpdatePending = false
    refreshMirrorSources()
    refreshActiveMirrorStates()
    var requests: [RestoreRequest] = []
    for profile in profiles {
      guard let sourceID = profile.mirrorSourceID,
        connections[profile.id] != nil,
        mirrorSources.contains(where: { $0.id == sourceID })
      else {
        failedRestores[profile.id] = nil
        setRestoreFailure(false, for: profile.id)
        continue
      }
      if activeMirrorSourceIDs[profile.id] == sourceID {
        failedRestores[profile.id] = nil
        setRestoreFailure(false, for: profile.id)
        continue
      }
      guard mirrorOperations[profile.id] == nil,
        let snapshot = restoreSnapshot(for: profile.id),
        failedRestores[profile.id] != snapshot
      else { continue }
      requests.append(
        RestoreRequest(
          profileID: profile.id,
          connectionToken: snapshot.connectionToken,
          sourceID: sourceID
        )
      )
    }
    return requests
  }

  private func beginRestore(_ request: RestoreRequest) -> MirrorOperation? {
    refreshActiveMirrorStates()
    guard connectionTokens[request.profileID] == request.connectionToken,
      profile(id: request.profileID)?.mirrorSourceID == request.sourceID,
      activeMirrorSourceIDs[request.profileID] != request.sourceID,
      mirrorOperations[request.profileID] == nil,
      let snapshot = restoreSnapshot(for: request.profileID),
      failedRestores[request.profileID] != snapshot
    else { return nil }
    return beginMirror(request.sourceID, for: request.profileID, snapshot: snapshot)
  }

  private func refreshMirrorSources() {
    do {
      let virtualDisplayIDs = Set(connections.values.map(\.displayID))
      let sources = try mirroringManager.availableSources(excluding: virtualDisplayIDs)
      onlineDisplays = try mirroringManager.onlineDisplayIdentities()
      if mirrorSources != sources { mirrorSources = sources }
    } catch {
      onlineDisplays = [:]
      if !mirrorSources.isEmpty { mirrorSources = [] }
      logger.error(
        "Could not refresh mirror sources: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func refreshActiveMirrorStates() {
    let sources = connections.reduce(into: [UUID: UUID]()) { result, entry in
      if let sourceID = mirroringManager.mirrorSourceID(for: entry.value.displayID) {
        result[entry.key] = sourceID
      }
    }
    if activeMirrorSourceIDs != sources { activeMirrorSourceIDs = sources }
  }

  private func restoreSnapshot(for profileID: UUID) -> RestoreSnapshot? {
    guard let token = connectionTokens[profileID],
      let connection = connections[profileID],
      let sourceID = profile(id: profileID)?.mirrorSourceID
    else { return nil }
    return RestoreSnapshot(
      connectionToken: token,
      targetDisplayID: connection.displayID,
      sourceID: sourceID,
      onlineDisplays: onlineDisplays,
      actualSources: activeMirrorSourceIDs
    )
  }

  private func beginMirror(
    _ sourceID: UUID?,
    for profileID: UUID,
    snapshot: RestoreSnapshot? = nil
  ) -> MirrorOperation? {
    guard let connection = connections[profileID], let token = connectionTokens[profileID]
    else { return nil }
    let requestToken = UUID()
    let previous = mirrorOperations[profileID]?.task
    let manager = mirroringManager
    let task = Task { @MainActor [weak self] () -> Result<Void, Error> in
      if let previous { _ = await previous.value }
      guard !Task.isCancelled,
        self?.connectionTokens[profileID] == token,
        self?.mirrorOperations[profileID]?.requestToken == requestToken
      else { return .failure(CancellationError()) }
      do {
        try await manager.setMirror(targetDisplayID: connection.displayID, sourceID: sourceID)
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    let operation = MirrorOperation(
      profileID: profileID,
      connectionToken: token,
      requestToken: requestToken,
      connection: connection,
      sourceID: sourceID,
      snapshot: snapshot,
      recoveryGeneration: recoveryGenerations[profileID],
      task: task
    )
    mirrorOperations[profileID] = operation
    return operation
  }

  private func finishMirror(
    _ operation: MirrorOperation,
    result: Result<Void, Error>,
    explicit: Bool
  ) {
    let id = operation.profileID
    guard connectionTokens[id] == operation.connectionToken,
      mirrorOperations[id]?.requestToken == operation.requestToken,
      let index = profiles.firstIndex(where: { $0.id == id })
    else { return }
    mirrorOperations[id] = nil
    refreshActiveMirrorStates()
    switch result {
    case .success:
      if explicit {
        profiles[index].mirrorSourceID = operation.sourceID
        save()
      }
      failedRestores[id] = nil
      setRestoreFailure(false, for: id)
    case .failure(let error):
      if explicit {
        reportError(error.localizedDescription)
      } else if activeMirrorSourceIDs[id] == operation.sourceID {
        failedRestores[id] = nil
        setRestoreFailure(false, for: id)
      } else {
        if recoveryGenerations[id] == operation.recoveryGeneration {
          failedRestores[id] = operation.snapshot
        }
        setRestoreFailure(true, for: id)
        logger.error(
          """
          Could not restore mirroring for \(id.uuidString, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """
        )
      }
    }
  }

  private func setRestoreFailure(_ failed: Bool, for profileID: UUID) {
    guard mirrorRestoreFailures.contains(profileID) != failed else { return }
    if failed {
      mirrorRestoreFailures.insert(profileID)
    } else {
      mirrorRestoreFailures.remove(profileID)
    }
  }

  private func nextAvailableDisplayName() -> String {
    let baseName = String(localized: "display.defaultName", defaultValue: "Display Loom")
    let existingNames = Set(profiles.map(\.name))
    var number = 1
    while existingNames.contains("\(baseName) \(number)") {
      number += 1
    }
    return "\(baseName) \(number)"
  }

  private func backendUnavailableMessage() -> String {
    if case .unavailable(let reason) = backendAvailability { return reason }
    return String(
      localized: "error.apiUnavailable",
      defaultValue: "This version of macOS does not provide the required virtual display API."
    )
  }

  private func reportError(_ message: String) {
    lastErrorMessage = message
    logger.error("\(message, privacy: .public)")
  }

  private func save() {
    repository.save(
      PersistedState(
        profiles: profiles,
        hasAcknowledged8KWarning: hasAcknowledged8KWarning,
        hasAttemptedLoginItemRegistration: hasAttemptedLoginItemRegistration
      )
    )
  }
}
