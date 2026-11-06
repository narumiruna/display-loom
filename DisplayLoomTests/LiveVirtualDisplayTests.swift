import CoreGraphics
import XCTest

@testable import DisplayLoom

@MainActor
final class LiveVirtualDisplayTests: XCTestCase {
  func testCreatesAndSwitchesARealVirtualDisplayWhenExplicitlyEnabled() async throws {
    guard ProcessInfo.processInfo.environment["RUN_VIRTUAL_DISPLAY_TESTS"] == "1" else {
      throw XCTSkip("Set RUN_VIRTUAL_DISPLAY_TESTS=1 to create a real virtual display.")
    }

    let backend = CoreGraphicsVirtualDisplayBackend()
    guard backend.availability.isAvailable else {
      throw XCTSkip("CGVirtualDisplay is unavailable on this macOS version.")
    }

    let profile = VirtualDisplayProfile(
      name: "Display Loom Integration Test",
      resolutionID: "1920x1080"
    )
    let connection = try await backend.connect(
      profile: profile,
      resolution: ResolutionPreset.preset(withID: "1920x1080")!,
      terminationHandler: {}
    )
    defer { connection.invalidate() }

    XCTAssertTrue(CGDisplayIsOnline(connection.displayID) != 0)
    let initialMode = try XCTUnwrap(CGDisplayCopyDisplayMode(connection.displayID))
    XCTAssertEqual(initialMode.pixelWidth, 1_920)
    XCTAssertEqual(initialMode.pixelHeight, 1_080)

    try await backend.setResolution(
      ResolutionPreset.preset(withID: "1920x1200")!,
      for: connection
    )
    let switchedMode = try XCTUnwrap(CGDisplayCopyDisplayMode(connection.displayID))
    XCTAssertEqual(switchedMode.pixelWidth, 1_920)
    XCTAssertEqual(switchedMode.pixelHeight, 1_200)

    let mirroringManager = DisplayMirroringManager()
    guard
      let source = try mirroringManager.availableSources(
        excluding: [connection.displayID]
      ).first,
      let sourceDisplayID = DisplayUUID.displayID(for: source.id)
    else {
      throw XCTSkip("Connect a physical display to run the mirroring portion of this test.")
    }

    try await mirroringManager.setMirror(
      targetDisplayID: connection.displayID,
      sourceID: source.id
    )

    XCTAssertEqual(CGDisplayMirrorsDisplay(connection.displayID), sourceDisplayID)
    XCTAssertEqual(mirroringManager.mirrorSourceID(for: connection.displayID), source.id)

    try await mirroringManager.setMirror(
      targetDisplayID: connection.displayID,
      sourceID: nil
    )
  }
}
