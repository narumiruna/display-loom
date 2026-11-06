import Foundation

enum DisplayAspectRatio: String, Codable, CaseIterable, Identifiable, Sendable {
  case sixteenByNine
  case sixteenByTen

  var id: String { rawValue }

  var localizedName: String {
    switch self {
    case .sixteenByNine:
      return String(localized: "aspectRatio.16by9", defaultValue: "16:9")
    case .sixteenByTen:
      return String(localized: "aspectRatio.16by10", defaultValue: "16:10")
    }
  }
}

struct ResolutionPreset: Codable, Hashable, Identifiable, Sendable {
  let width: Int
  let height: Int
  let aspectRatio: DisplayAspectRatio

  var id: String { "\(width)x\(height)" }

  var is8K: Bool { width >= 7_680 }

  var displayName: String {
    let dimensions = "\(width) × \(height)"
    guard let marketingName else { return dimensions }
    return "\(dimensions) (\(marketingName))"
  }

  private var marketingName: String? {
    switch id {
    case "1280x720": return "HD"
    case "1920x1080": return "Full HD"
    case "2560x1440": return "QHD"
    case "3840x2160": return "4K UHD"
    case "5120x2880": return "5K"
    case "7680x4320": return "8K UHD"
    case "1920x1200": return "WUXGA"
    case "3840x2400": return "4K 16:10"
    case "5120x3200": return "5K 16:10"
    case "7680x4800": return "8K 16:10"
    default: return nil
    }
  }

  static let catalog: [ResolutionPreset] = [
    ResolutionPreset(width: 1_280, height: 720, aspectRatio: .sixteenByNine),
    ResolutionPreset(width: 1_366, height: 768, aspectRatio: .sixteenByNine),
    ResolutionPreset(width: 1_600, height: 900, aspectRatio: .sixteenByNine),
    ResolutionPreset(width: 1_920, height: 1_080, aspectRatio: .sixteenByNine),
    ResolutionPreset(width: 2_560, height: 1_440, aspectRatio: .sixteenByNine),
    ResolutionPreset(width: 3_200, height: 1_800, aspectRatio: .sixteenByNine),
    ResolutionPreset(width: 3_840, height: 2_160, aspectRatio: .sixteenByNine),
    ResolutionPreset(width: 5_120, height: 2_880, aspectRatio: .sixteenByNine),
    ResolutionPreset(width: 7_680, height: 4_320, aspectRatio: .sixteenByNine),
    ResolutionPreset(width: 1_280, height: 800, aspectRatio: .sixteenByTen),
    ResolutionPreset(width: 1_440, height: 900, aspectRatio: .sixteenByTen),
    ResolutionPreset(width: 1_680, height: 1_050, aspectRatio: .sixteenByTen),
    ResolutionPreset(width: 1_920, height: 1_200, aspectRatio: .sixteenByTen),
    ResolutionPreset(width: 2_560, height: 1_600, aspectRatio: .sixteenByTen),
    ResolutionPreset(width: 2_880, height: 1_800, aspectRatio: .sixteenByTen),
    ResolutionPreset(width: 3_840, height: 2_400, aspectRatio: .sixteenByTen),
    ResolutionPreset(width: 5_120, height: 3_200, aspectRatio: .sixteenByTen),
    ResolutionPreset(width: 7_680, height: 4_800, aspectRatio: .sixteenByTen),
  ]

  static var maximumWidth: Int { catalog.map(\.width).max() ?? 0 }

  static var maximumHeight: Int { catalog.map(\.height).max() ?? 0 }

  static func presets(for aspectRatio: DisplayAspectRatio) -> [ResolutionPreset] {
    catalog.filter { $0.aspectRatio == aspectRatio }
  }

  static func preset(withID id: String) -> ResolutionPreset? {
    catalog.first { $0.id == id }
  }
}
