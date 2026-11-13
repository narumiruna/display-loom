import CoreGraphics
import Foundation
import os

/// Handle writes use the worker. Status reads must be safe from any thread.
protocol CoreGraphicsVirtualDisplayHandling: AnyObject {
  var displayID: CGDirectDisplayID { get }
  var isValid: Bool { get }
  var isInvalidated: Bool { get }
  func setMode(width: UInt32, height: UInt32, refreshRate: Double) throws
  func invalidate()
}

extension VSCGVirtualDisplayHandle: CoreGraphicsVirtualDisplayHandling {}

/// Monotonic seconds and a suspending delay, injected for registration tests.
struct DisplayRegistrationClock {
  var now: () -> TimeInterval
  var sleep: (TimeInterval) async throws -> Void

  static let continuous = DisplayRegistrationClock(
    now: { ProcessInfo.processInfo.systemUptime },
    sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
  )
}

private final class CoreGraphicsVirtualDisplayConnection: VirtualDisplayConnection,
  @unchecked Sendable
{
  let displayID: CGDirectDisplayID
  private let handle: any CoreGraphicsVirtualDisplayHandling
  private let worker: DisplayOperationWorker
  private let stateLock = NSLock()
  private var invalidationRequested = false

  init(handle: any CoreGraphicsVirtualDisplayHandling, worker: DisplayOperationWorker) {
    self.handle = handle
    self.worker = worker
    displayID = handle.displayID
  }

  private var isInvalidationRequested: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return invalidationRequested
  }

  var isValid: Bool { !isInvalidationRequested && handle.isValid }

  func invalidate() {
    stateLock.lock()
    let needsInvalidation = !invalidationRequested
    invalidationRequested = true
    stateLock.unlock()
    if needsInvalidation {
      worker.enqueue { [handle] in handle.invalidate() }
    }
  }

  /// Only call on the worker, including while this connection is pending.
  func checkRegistration() throws -> Bool {
    guard !isInvalidationRequested && !handle.isInvalidated else {
      throw VirtualDisplayBackendError.invalidated
    }
    return handle.isValid
  }

  /// The mirror read and mode write run in the same worker operation.
  func setResolution(
    _ resolution: ResolutionPreset,
    isInMirrorSet: (CGDirectDisplayID) -> Bool
  ) throws {
    guard isValid else { throw VirtualDisplayBackendError.invalidated }
    guard !isInMirrorSet(displayID) else {
      throw VirtualDisplayBackendError.invalidConfiguration
    }
    try handle.setMode(
      width: UInt32(resolution.width),
      height: UInt32(resolution.height),
      refreshRate: 60
    )
  }

  deinit {
    invalidate()
  }
}

final class CoreGraphicsVirtualDisplayBackend: VirtualDisplayBackend {
  typealias HandleFactory = (
    VirtualDisplayProfile, ResolutionPreset, @escaping () -> Void
  ) throws -> any CoreGraphicsVirtualDisplayHandling

  private let worker: DisplayOperationWorker
  private let isAPIAvailable: () -> Bool
  private let makeHandle: HandleFactory
  private let registrationClock: DisplayRegistrationClock
  private let isInMirrorSet: (CGDirectDisplayID) -> Bool
  private let logger = Logger(subsystem: "dev.narumi.DisplayLoom", category: "Backend")

  init(
    worker: DisplayOperationWorker = .shared,
    isAPIAvailable: @escaping () -> Bool = { VSCGVirtualDisplayHandle.isAPIAvailable },
    makeHandle: @escaping HandleFactory = CoreGraphicsVirtualDisplayBackend.createHandle,
    registrationClock: DisplayRegistrationClock = .continuous,
    isInMirrorSet: @escaping (CGDirectDisplayID) -> Bool = { CGDisplayIsInMirrorSet($0) != 0 }
  ) {
    self.worker = worker
    self.isAPIAvailable = isAPIAvailable
    self.makeHandle = makeHandle
    self.registrationClock = registrationClock
    self.isInMirrorSet = isInMirrorSet
  }

  var availability: VirtualDisplayBackendAvailability {
    if isAPIAvailable() {
      return .available
    }
    return .unavailable(
      reason: String(
        localized: "error.apiUnavailable",
        defaultValue: "This version of macOS does not provide the required virtual display API."
      )
    )
  }

  static func mapError(_ error: Error) -> VirtualDisplayBackendError {
    guard let bridgeError = error as? VSCGVirtualDisplayError else {
      return error as? VirtualDisplayBackendError ?? .unexpected(error.localizedDescription)
    }

    switch bridgeError.code {
    case .apiUnavailable: return .apiUnavailable
    case .invalidConfiguration: return .invalidConfiguration
    case .creationFailed: return .creationFailed
    case .settingsRejected: return .settingsRejected
    case .registrationTimedOut: return .registrationTimedOut
    case .modeUnavailable: return .modeUnavailable
    case .modeSwitchFailed: return .modeSwitchFailed
    case .invalidated: return .invalidated
    default: return .unexpected(error.localizedDescription)
    }
  }

  func connect(
    profile: VirtualDisplayProfile,
    resolution: ResolutionPreset,
    terminationHandler: @escaping () -> Void
  ) async throws -> any VirtualDisplayConnection {
    guard availability.isAvailable else {
      throw VirtualDisplayBackendError.apiUnavailable
    }

    // Creation can complete after cancellation. Always receive its owner before
    // checking cancellation so that a late handle cannot escape cleanup.
    let pending: (connection: CoreGraphicsVirtualDisplayConnection, deadline: TimeInterval)
    do {
      pending = try await worker.perform { [makeHandle, worker, registrationClock] in
        let handle = try makeHandle(profile, resolution, terminationHandler)
        return (
          CoreGraphicsVirtualDisplayConnection(handle: handle, worker: worker),
          registrationClock.now() + 2
        )
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.mapError(error)
    }

    do {
      while true {
        try Task.checkCancellation()
        let registered = try await worker.perform { [registrationClock, isInMirrorSet] in
          guard registrationClock.now() < pending.deadline else {
            throw VirtualDisplayBackendError.registrationTimedOut
          }
          guard try pending.connection.checkRegistration() else { return false }
          try Self.setInitialResolution(
            resolution,
            for: pending.connection,
            isInMirrorSet: isInMirrorSet
          )
          return true
        }
        try Task.checkCancellation()
        if registered {
          logger.info(
            """
            Connected virtual display \(profile.id.uuidString, privacy: .public) \
            as \(pending.connection.displayID)
            """
          )
          return pending.connection
        }

        let remaining = pending.deadline - registrationClock.now()
        guard remaining > 0 else { throw VirtualDisplayBackendError.registrationTimedOut }
        // Yield outside the worker. Use the original deadline even when a probe
        // is delayed by scheduling or another display operation.
        try await registrationClock.sleep(min(0.05, remaining))
      }
    } catch {
      pending.connection.invalidate()
      if error is CancellationError { throw CancellationError() }
      let mappedError = Self.mapError(error)
      logger.error(
        "Could not connect virtual display: \(mappedError.localizedDescription, privacy: .public)"
      )
      throw mappedError
    }
  }

  func setResolution(
    _ resolution: ResolutionPreset,
    for connection: any VirtualDisplayConnection
  ) async throws {
    guard let connection = connection as? CoreGraphicsVirtualDisplayConnection else {
      throw VirtualDisplayBackendError.invalidConfiguration
    }

    do {
      try await worker.perform { [isInMirrorSet, logger] in
        try connection.setResolution(resolution, isInMirrorSet: isInMirrorSet)
        logger.info("Set display \(connection.displayID) to \(resolution.id, privacy: .public)")
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let mappedError = Self.mapError(error)
      logger.error(
        "Could not switch display mode: \(mappedError.localizedDescription, privacy: .public)"
      )
      throw mappedError
    }
  }

  private static func setInitialResolution(
    _ resolution: ResolutionPreset,
    for connection: CoreGraphicsVirtualDisplayConnection,
    isInMirrorSet: (CGDirectDisplayID) -> Bool
  ) throws {
    // macOS can restore mirroring as the display registers. Keep the
    // connection and let macOS choose the mirror set's compatible mode.
    guard !isInMirrorSet(connection.displayID) else { return }
    do {
      try connection.setResolution(resolution, isInMirrorSet: isInMirrorSet)
    } catch {
      // Mirroring can start before the bridge's final pre-write check.
      guard mapError(error) == .invalidConfiguration,
        isInMirrorSet(connection.displayID)
      else { throw error }
    }
  }

  private static func createHandle(
    profile: VirtualDisplayProfile,
    resolution: ResolutionPreset,
    terminationHandler: @escaping () -> Void
  ) throws -> any CoreGraphicsVirtualDisplayHandling {
    let identity = StableDisplayIdentity(profileID: profile.id)
    let orderedPresets = [resolution] + ResolutionPreset.catalog.filter { $0.id != resolution.id }
    let modeSpecs = orderedPresets.map {
      VSCGVirtualDisplayModeSpec(
        width: UInt32($0.width),
        height: UInt32($0.height),
        refreshRate: 60
      )
    }
    return try VSCGVirtualDisplayHandle.create(
      withName: profile.name,
      vendorID: identity.vendorID,
      productID: identity.productID,
      serialNumber: identity.serialNumber,
      maxWidth: UInt32(ResolutionPreset.maximumWidth),
      maxHeight: UInt32(ResolutionPreset.maximumHeight),
      modes: modeSpecs,
      terminationHandler: terminationHandler
    )
  }
}
