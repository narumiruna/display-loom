import CoreGraphics
import Foundation

enum VirtualDisplayBackendAvailability: Equatable, Sendable {
  case available
  case unavailable(reason: String)

  var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }
}

protocol VirtualDisplayConnection: AnyObject {
  var displayID: CGDirectDisplayID { get }
  var isValid: Bool { get }
  func invalidate()
}

/// Operations throw normalized `VirtualDisplayBackendError` values for presentation by callers.
protocol VirtualDisplayBackend: AnyObject {
  var availability: VirtualDisplayBackendAvailability { get }

  func connect(
    profile: VirtualDisplayProfile,
    resolution: ResolutionPreset,
    terminationHandler: @escaping () -> Void
  ) async throws -> any VirtualDisplayConnection

  func setResolution(
    _ resolution: ResolutionPreset,
    for connection: any VirtualDisplayConnection
  ) async throws
}

enum VirtualDisplayBackendError: LocalizedError, Equatable {
  case apiUnavailable
  case invalidConfiguration
  case creationFailed
  case settingsRejected
  case registrationTimedOut
  case modeUnavailable
  case modeSwitchFailed
  case invalidated
  case unexpected(String)

  var errorDescription: String? {
    switch self {
    case .apiUnavailable:
      return String(
        localized: "error.apiUnavailable",
        defaultValue: "This version of macOS does not provide the required virtual display API.")
    case .invalidConfiguration:
      return String(
        localized: "error.invalidConfiguration",
        defaultValue: "The virtual display configuration is invalid.")
    case .creationFailed:
      return String(
        localized: "error.creationFailed",
        defaultValue:
          "macOS could not create the virtual display. The system display limit may have been reached."
      )
    case .settingsRejected:
      return String(
        localized: "error.settingsRejected",
        defaultValue: "macOS rejected the requested virtual display settings.")
    case .registrationTimedOut:
      return String(
        localized: "error.registrationTimedOut",
        defaultValue: "The virtual display did not appear within two seconds.")
    case .modeUnavailable:
      return String(
        localized: "error.modeUnavailable",
        defaultValue: "The selected resolution is not available on this Mac.")
    case .modeSwitchFailed:
      return String(
        localized: "error.modeSwitchFailed",
        defaultValue: "macOS could not switch to the selected resolution.")
    case .invalidated:
      return String(
        localized: "error.invalidated", defaultValue: "The virtual display is no longer connected.")
    case .unexpected(let detail):
      return String(
        format: String(
          localized: "error.unexpected", defaultValue: "An unexpected error occurred: %@"),
        detail
      )
    }
  }
}
