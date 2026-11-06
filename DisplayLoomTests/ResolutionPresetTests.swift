import XCTest

@testable import DisplayLoom

final class ResolutionPresetTests: XCTestCase {
  func testCatalogContainsUniqueNativeResolutionIDs() {
    let ids = ResolutionPreset.catalog.map(\.id)

    XCTAssertEqual(ids.count, 18)
    XCTAssertEqual(Set(ids).count, ids.count)
    XCTAssertEqual(ResolutionPreset.maximumWidth, 7_680)
    XCTAssertEqual(ResolutionPreset.maximumHeight, 4_800)
  }

  func testCatalogIsGroupedIntoExpectedAspectRatios() {
    XCTAssertEqual(ResolutionPreset.presets(for: .sixteenByNine).count, 9)
    XCTAssertEqual(ResolutionPreset.presets(for: .sixteenByTen).count, 9)
    XCTAssertEqual(ResolutionPreset.presets(for: .sixteenByNine).last?.id, "7680x4320")
    XCTAssertEqual(ResolutionPreset.presets(for: .sixteenByTen).last?.id, "7680x4800")
  }

  func testCatalogContainsRequired4KAnd8KModes() {
    let ids = Set(ResolutionPreset.catalog.map(\.id))

    XCTAssertTrue(
      ids.isSuperset(of: [
        "3840x2160",
        "3840x2400",
        "7680x4320",
        "7680x4800",
      ])
    )
    XCTAssertFalse(ResolutionPreset.preset(withID: "3840x2160")!.is8K)
    XCTAssertTrue(ResolutionPreset.preset(withID: "7680x4320")!.is8K)
  }
}
