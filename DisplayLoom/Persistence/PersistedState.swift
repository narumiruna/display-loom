struct PersistedState: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int
  var profiles: [VirtualDisplayProfile]
  var hasAcknowledged8KWarning: Bool
  var hasAttemptedLoginItemRegistration: Bool

  init(
    version: Int = PersistedState.currentVersion,
    profiles: [VirtualDisplayProfile] = [],
    hasAcknowledged8KWarning: Bool = false,
    hasAttemptedLoginItemRegistration: Bool = false
  ) {
    self.version = version
    self.profiles = profiles
    self.hasAcknowledged8KWarning = hasAcknowledged8KWarning
    self.hasAttemptedLoginItemRegistration = hasAttemptedLoginItemRegistration
  }
}
