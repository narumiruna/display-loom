import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
  case enabled
  case disabled
  case requiresApproval
  case unavailable
}

protocol LaunchAtLoginManaging: AnyObject {
  var status: LaunchAtLoginStatus { get }
  func register() throws
  func unregister() throws
  func openSystemSettings()
}

final class LaunchAtLoginManager: LaunchAtLoginManaging {
  private let service = SMAppService.mainApp

  var status: LaunchAtLoginStatus {
    switch service.status {
    case .enabled:
      return .enabled
    case .requiresApproval:
      return .requiresApproval
    case .notRegistered:
      return .disabled
    case .notFound:
      return .unavailable
    @unknown default:
      return .unavailable
    }
  }

  func register() throws {
    try service.register()
  }

  func unregister() throws {
    try service.unregister()
  }

  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
