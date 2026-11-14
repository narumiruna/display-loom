import Foundation

enum DisplayRefreshRate: Int, Codable, CaseIterable, Identifiable, Sendable {
  case standard = 60
  case low = 30

  var id: Int { rawValue }

  var localizedName: String {
    switch self {
    case .standard:
      return String(localized: "refreshRate.standard", defaultValue: "60 Hz (Default)")
    case .low:
      return String(localized: "refreshRate.low", defaultValue: "30 Hz (Low Refresh Rate)")
    }
  }
}
