import Foundation

struct VirtualDisplayProfile: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var name: String
  var resolutionID: String
  var desiredConnected: Bool
  var mirrorSourceID: UUID?
  var refreshRate: DisplayRefreshRate

  init(
    id: UUID = UUID(),
    name: String,
    resolutionID: String,
    desiredConnected: Bool = true,
    mirrorSourceID: UUID? = nil,
    refreshRate: DisplayRefreshRate = .standard
  ) {
    self.id = id
    self.name = name
    self.resolutionID = resolutionID
    self.desiredConnected = desiredConnected
    self.mirrorSourceID = mirrorSourceID
    self.refreshRate = refreshRate
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, resolutionID, desiredConnected, mirrorSourceID, refreshRate
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    resolutionID = try values.decode(String.self, forKey: .resolutionID)
    desiredConnected = try values.decode(Bool.self, forKey: .desiredConnected)
    mirrorSourceID = try values.decodeIfPresent(UUID.self, forKey: .mirrorSourceID)
    refreshRate =
      try values.decodeIfPresent(DisplayRefreshRate.self, forKey: .refreshRate) ?? .standard
  }

  var resolution: ResolutionPreset? {
    ResolutionPreset.preset(withID: resolutionID)
  }
}
