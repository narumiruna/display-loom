import Foundation
import XCTest

@testable import DisplayLoom

final class PersistenceTests: XCTestCase {
  func testPersistedStateCodableRoundTrip() throws {
    let profile = VirtualDisplayProfile(
      id: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
      name: "Editing",
      resolutionID: "3840x2160",
      desiredConnected: true,
      mirrorSourceID: UUID(uuidString: "11112233-4455-6677-8899-AABBCCDDEEFF")!
    )
    let original = PersistedState(
      profiles: [profile],
      hasAcknowledged8KWarning: true,
      hasAttemptedLoginItemRegistration: true
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PersistedState.self, from: data)

    XCTAssertEqual(decoded, original)
    XCTAssertEqual(decoded.version, PersistedState.currentVersion)
  }

  func testVersionOneProfileWithoutMirrorSourceRemainsCompatible() throws {
    let data = Data(
      """
      {
        "version": 1,
        "profiles": [{
          "id": "00112233-4455-6677-8899-AABBCCDDEEFF",
          "name": "Editing",
          "resolutionID": "3840x2160",
          "desiredConnected": true
        }],
        "hasAcknowledged8KWarning": false,
        "hasAttemptedLoginItemRegistration": true
      }
      """.utf8
    )

    let decoded = try JSONDecoder().decode(PersistedState.self, from: data)

    XCTAssertEqual(decoded.profiles.count, 1)
    XCTAssertNil(decoded.profiles[0].mirrorSourceID)
  }

  func testStateRepositoryReturnsEmptyStateForCorruptData() {
    let suiteName = "PersistenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(Data("not-json".utf8), forKey: StateRepository.storageKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let loaded = StateRepository(defaults: defaults).load()

    XCTAssertEqual(loaded, PersistedState())
  }

  func testStateRepositoryReturnsEmptyStateForUnsupportedVersion() throws {
    let suiteName = "PersistenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let unsupported = PersistedState(version: 999)
    defaults.set(try JSONEncoder().encode(unsupported), forKey: StateRepository.storageKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let loaded = StateRepository(defaults: defaults).load()

    XCTAssertEqual(loaded, PersistedState())
  }

  func testStableDisplayIdentityIsRepeatableAndProfileSpecific() {
    let firstID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    let secondID = UUID(uuidString: "10112233-4455-6677-8899-AABBCCDDEEFF")!

    let first = StableDisplayIdentity(profileID: firstID)
    let repeated = StableDisplayIdentity(profileID: firstID)
    let second = StableDisplayIdentity(profileID: secondID)

    XCTAssertEqual(first, repeated)
    XCTAssertNotEqual(first.productID, second.productID)
    XCTAssertNotEqual(first.serialNumber, second.serialNumber)
    XCTAssertNotEqual(first.serialNumber, 0)
  }
}
