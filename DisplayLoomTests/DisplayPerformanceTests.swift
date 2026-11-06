import XCTest

@MainActor
final class DisplayPerformanceTests: XCTestCase {
  func testNotificationBurst() async throws {
    try await PerformanceChecks.notificationBurst()
  }

  func testFailureFeedbackAndRecovery() async throws {
    try await PerformanceChecks.failureFeedback()
  }

  func testPendingUpdatesAndResolutionRejection() async throws {
    try await PerformanceChecks.pendingUpdatesAndResolution()
  }

  func testStaleSelectionAndProfileIndex() async throws {
    try await PerformanceChecks.staleSelectionAndProfileIndex()
  }

  func testDisconnectDuringMirror() async throws {
    try await PerformanceChecks.disconnectDuringMirror()
  }

  func testReconnectWaitsForCleanup() async throws {
    try await PerformanceChecks.reconnectWaitsForCleanup()
  }

  func testSupersededCreation() async throws {
    try await PerformanceChecks.supersededCreation()
  }

  func testRecoveryDuringFailure() async throws {
    try await PerformanceChecks.recoveryDuringFailure()
  }

  func testResolutionLifecycleAndFailures() async throws {
    try await PerformanceChecks.resolutionLifecycleAndFailures()
  }

  func testScheduledStoreLifetime() async throws {
    try await PerformanceChecks.storeLifetime()
  }

  func testMainActorResponsiveness() async throws {
    try await PerformanceChecks.mainActorResponsiveness()
  }

  func testCoordinationAcrossTargets() async throws {
    try await PerformanceChecks.coordinationAcrossTargets()
  }

  func testPersistenceAndRecovery() async throws {
    try await PerformanceChecks.persistenceAndRecovery()
  }
}
