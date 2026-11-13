import Foundation
import XCTest

@testable import DisplayLoom

final class CoreGraphicsVirtualDisplayBackendTests: XCTestCase {
  func testKnownBridgeCodesMapToLocalizedBackendErrors() {
    let cases: [(VSCGVirtualDisplayError.Code, VirtualDisplayBackendError)] = [
      (.apiUnavailable, .apiUnavailable),
      (.invalidConfiguration, .invalidConfiguration),
      (.creationFailed, .creationFailed),
      (.settingsRejected, .settingsRejected),
      (.registrationTimedOut, .registrationTimedOut),
      (.modeUnavailable, .modeUnavailable),
      (.modeSwitchFailed, .modeSwitchFailed),
      (.invalidated, .invalidated),
    ]

    for (code, expected) in cases {
      let error = NSError(
        domain: VSCGVirtualDisplayErrorDomain,
        code: code.rawValue,
        userInfo: [NSLocalizedDescriptionKey: "Unlocalized bridge detail"]
      )
      let mapped = CoreGraphicsVirtualDisplayBackend.mapError(error)

      XCTAssertEqual(mapped, expected)
      XCTAssertEqual(mapped.localizedDescription, expected.localizedDescription)
    }
  }

  func testUnknownBridgeCodeRetainsDetailInLocalizedFallback() {
    let error = NSError(
      domain: VSCGVirtualDisplayErrorDomain,
      code: 999,
      userInfo: [NSLocalizedDescriptionKey: "Unknown bridge failure"]
    )

    let mapped = CoreGraphicsVirtualDisplayBackend.mapError(error)

    XCTAssertEqual(mapped, .unexpected(error.localizedDescription))
    XCTAssertEqual(
      mapped.localizedDescription,
      VirtualDisplayBackendError.unexpected(error.localizedDescription).localizedDescription
    )
  }

  func testOtherErrorDomainDoesNotMatchAKnownBridgeCode() {
    let error = NSError(
      domain: "BackendTests",
      code: VSCGVirtualDisplayError.Code.apiUnavailable.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "Unrelated failure"]
    )

    let mapped = CoreGraphicsVirtualDisplayBackend.mapError(error)

    XCTAssertEqual(mapped, .unexpected(error.localizedDescription))
    XCTAssertEqual(
      mapped.localizedDescription,
      VirtualDisplayBackendError.unexpected(error.localizedDescription).localizedDescription
    )
  }

  func testAlreadyNormalizedErrorsAreNotWrappedAgain() {
    let errors: [VirtualDisplayBackendError] = [.modeSwitchFailed, .unexpected("Original detail")]

    for error in errors {
      let mapped = CoreGraphicsVirtualDisplayBackend.mapError(error)

      XCTAssertEqual(mapped, error)
      XCTAssertEqual(mapped.localizedDescription, error.localizedDescription)
    }
  }

  func testConnectNormalizesBridgeFailureBeforeCreatingADisplay() async {
    let backend = CoreGraphicsVirtualDisplayBackend()
    let expectedError: VirtualDisplayBackendError =
      backend.availability.isAvailable ? .invalidConfiguration : .apiUnavailable

    do {
      // The bridge rejects an empty name before allocating a display descriptor.
      _ = try await backend.connect(
        profile: VirtualDisplayProfile(name: "", resolutionID: "1920x1080"),
        resolution: ResolutionPreset.preset(withID: "1920x1080")!,
        terminationHandler: { XCTFail("Invalid configuration must not create a display") }
      )
      XCTFail("Expected the backend to reject an empty display name")
    } catch {
      XCTAssertEqual(error as? VirtualDisplayBackendError, expectedError)
      XCTAssertEqual(error.localizedDescription, expectedError.localizedDescription)
    }
  }

  func testWorkerSkipsCancelledQueuedOperation() async throws {
    try await BackendPerformanceChecks.workerSkipsCancelledQueuedOperation()
  }

  func testWorkerReturnsResultFromCancelledExecutingOperation() async throws {
    try await BackendPerformanceChecks.workerReturnsResultFromCancelledExecutingOperation()
  }

  func testRegistrationYieldsWorkerToConnectedDisplayResolution() async throws {
    try await BackendPerformanceChecks.registrationYieldsWorkerToConnectedDisplayResolution()
  }

  func testRegistrationTimeoutUsesOriginalMonotonicDeadline() async throws {
    try await BackendPerformanceChecks.registrationTimeoutUsesOriginalMonotonicDeadline()
  }

  func testPendingInvalidationCleansUpOnce() async throws {
    try await BackendPerformanceChecks.pendingInvalidationCleansUpOnce()
  }

  func testCancellationDuringRegistrationCleansUpOnce() async throws {
    try await BackendPerformanceChecks.cancellationDuringRegistrationCleansUpOnce()
  }

  func testCancelledQueuedCreationDoesNotCreateHandle() async throws {
    try await BackendPerformanceChecks.cancelledQueuedCreationDoesNotCreateHandle()
  }

  func testCancelledExecutingCreationOwnsAndCleansUpLateHandle() async throws {
    try await BackendPerformanceChecks.cancelledExecutingCreationOwnsAndCleansUpLateHandle()
  }

  func testCancelledExecutingInitialModeCleansUpLateResult() async throws {
    try await BackendPerformanceChecks.cancelledExecutingInitialModeCleansUpLateResult()
  }

  func testInitialModeFailureIsNormalizedAndCleansUpOnce() async throws {
    try await BackendPerformanceChecks.initialModeFailureIsNormalizedAndCleansUpOnce()
  }

  func testInvalidationIsSerializedWithModeWriteAndKeepsDisplayID() async throws {
    try await BackendPerformanceChecks.invalidationIsSerializedWithModeWriteAndKeepsDisplayID()
  }

  func testUnmirroredModeWritesReachHandle() async throws {
    try await BackendPerformanceChecks.unmirroredModeWritesReachHandle()
  }

  func testModeWriteRechecksMirrorStateOnWorker() async throws {
    try await BackendPerformanceChecks.modeWriteRechecksMirrorStateOnWorker()
  }

  func testReleasedConnectionCleansUpOnce() async throws {
    try await BackendPerformanceChecks.releasedConnectionCleansUpOnce()
  }

  func testMirroredInitialModeIsSkippedAndConnectionRemainsValid() async throws {
    try await BackendPerformanceChecks.mirroredInitialModeIsSkippedAndConnectionRemainsValid()
  }

  func testRegistrationPreservesRestoredMirrorState() async throws {
    try await BackendPerformanceChecks.registrationPreservesRestoredMirrorState()
  }

  func testMirroringDuringInitialModeKeepsConnection() async throws {
    try await BackendPerformanceChecks.mirroringDuringInitialModeKeepsConnection()
  }

  func testResolutionRejectsForeignConnectionWithNormalizedError() async {
    let backend = CoreGraphicsVirtualDisplayBackend()

    do {
      try await backend.setResolution(
        ResolutionPreset.preset(withID: "1920x1080")!,
        for: FakeDisplayConnection(displayID: 123)
      )
      XCTFail("Expected the backend to reject a foreign connection")
    } catch {
      XCTAssertEqual(error as? VirtualDisplayBackendError, .invalidConfiguration)
    }
  }
}
