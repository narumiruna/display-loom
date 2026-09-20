import CoreGraphics
import Foundation
import os

extension VSCGVirtualDisplayModeSpec: @unchecked Sendable {}

private final class CoreGraphicsVirtualDisplayConnection: VirtualDisplayConnection,
  @unchecked Sendable
{
  private let handle: VSCGVirtualDisplayHandle

  init(handle: VSCGVirtualDisplayHandle) {
    self.handle = handle
  }

  var displayID: CGDirectDisplayID { handle.displayID }
  var isValid: Bool { handle.isValid }

  func invalidate() {
    handle.invalidate()
  }

  func setResolution(_ resolution: ResolutionPreset) throws {
    try handle.setMode(
      width: UInt32(resolution.width),
      height: UInt32(resolution.height),
      refreshRate: 60
    )
  }
}

final class CoreGraphicsVirtualDisplayBackend: VirtualDisplayBackend {
  private let workQueue = DispatchQueue(
    label: "dev.narumi.DisplayLoom.backend", qos: .userInitiated)
  private let logger = Logger(subsystem: "dev.narumi.DisplayLoom", category: "Backend")

  var availability: VirtualDisplayBackendAvailability {
    if VSCGVirtualDisplayHandle.isAPIAvailable {
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

    let identity = StableDisplayIdentity(profileID: profile.id)
    let orderedPresets = [resolution] + ResolutionPreset.catalog.filter { $0.id != resolution.id }
    let modeSpecs = orderedPresets.map {
      VSCGVirtualDisplayModeSpec(
        width: UInt32($0.width),
        height: UInt32($0.height),
        refreshRate: 60
      )
    }

    return try await withCheckedThrowingContinuation { continuation in
      workQueue.async { [logger] in
        do {
          let handle = try VSCGVirtualDisplayHandle.create(
            withName: profile.name,
            vendorID: identity.vendorID,
            productID: identity.productID,
            serialNumber: identity.serialNumber,
            maxWidth: UInt32(ResolutionPreset.maximumWidth),
            maxHeight: UInt32(ResolutionPreset.maximumHeight),
            modes: modeSpecs,
            terminationHandler: terminationHandler
          )
          logger.info(
            "Connected virtual display \(profile.id.uuidString, privacy: .public) as \(handle.displayID)"
          )
          continuation.resume(returning: CoreGraphicsVirtualDisplayConnection(handle: handle))
        } catch {
          let mappedError = Self.mapError(error)
          logger.error(
            "Could not connect virtual display: \(mappedError.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: mappedError)
        }
      }
    }
  }

  func setResolution(
    _ resolution: ResolutionPreset,
    for connection: any VirtualDisplayConnection
  ) async throws {
    guard let connection = connection as? CoreGraphicsVirtualDisplayConnection else {
      throw VirtualDisplayBackendError.invalidConfiguration
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      workQueue.async { [logger] in
        do {
          try connection.setResolution(resolution)
          logger.info("Set display \(connection.displayID) to \(resolution.id, privacy: .public)")
          continuation.resume()
        } catch {
          let mappedError = Self.mapError(error)
          logger.error(
            "Could not switch display mode: \(mappedError.localizedDescription, privacy: .public)")
          continuation.resume(throwing: mappedError)
        }
      }
    }
  }
}
