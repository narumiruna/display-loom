import XCTest

@testable import DisplayLoom

@MainActor
final class VirtualDisplayStoreLoginTests: XCTestCase {
  func testFirstStartRegistersLoginItemOnlyOnce() async {
    let environment = VirtualDisplayTestEnvironment()

    await environment.store.start()
    await environment.store.start()

    XCTAssertEqual(environment.loginManager.registerCallCount, 1)
    XCTAssertTrue(environment.repository.state.hasAttemptedLoginItemRegistration)
    XCTAssertEqual(environment.store.launchAtLoginStatus, .enabled)
  }

  func testLoginItemApprovalStateIsExposed() async {
    let environment = VirtualDisplayTestEnvironment()
    environment.loginManager.status = .requiresApproval

    await environment.store.start()

    XCTAssertTrue(environment.store.shouldShowLaunchAtLoginApproval)
    XCTAssertEqual(environment.loginManager.registerCallCount, 0)
    environment.store.openLoginItemSettings()
    XCTAssertEqual(environment.loginManager.openSettingsCallCount, 1)
    environment.store.clearLaunchAtLoginApprovalNotice()
    XCTAssertFalse(environment.store.shouldShowLaunchAtLoginApproval)
  }

  func testFirstStartDoesNotRegisterAnEnabledLoginItem() async {
    let environment = VirtualDisplayTestEnvironment()
    environment.loginManager.status = .enabled

    await environment.store.start()

    XCTAssertEqual(environment.loginManager.registerCallCount, 0)
    XCTAssertEqual(environment.store.launchAtLoginStatus, .enabled)
    XCTAssertTrue(environment.repository.state.hasAttemptedLoginItemRegistration)
  }

  func testFirstStartExposesApprovalRequiredAfterRegistration() async {
    let environment = VirtualDisplayTestEnvironment()
    environment.loginManager.statusAfterRegistration = .requiresApproval

    await environment.store.start()

    XCTAssertEqual(environment.loginManager.registerCallCount, 1)
    XCTAssertEqual(environment.store.launchAtLoginStatus, .requiresApproval)
    XCTAssertTrue(environment.store.shouldShowLaunchAtLoginApproval)
  }

  func testFailedInitialRegistrationIsNotRetriedOnRelaunch() async throws {
    let environment = VirtualDisplayTestEnvironment()
    let error = NSError(domain: "LoginTests", code: 1)
    environment.loginManager.registerError = error

    await environment.store.start()

    let message = try XCTUnwrap(environment.store.takeLastErrorMessage())
    XCTAssertTrue(message.contains(error.localizedDescription))
    XCTAssertNil(environment.store.takeLastErrorMessage())
    XCTAssertEqual(environment.store.launchAtLoginStatus, .disabled)
    XCTAssertEqual(environment.loginManager.registerCallCount, 1)
    XCTAssertTrue(environment.repository.state.hasAttemptedLoginItemRegistration)

    let relaunched = VirtualDisplayTestEnvironment(state: environment.repository.state)
    await relaunched.store.start()

    XCTAssertEqual(relaunched.loginManager.registerCallCount, 0)
    XCTAssertEqual(relaunched.store.launchAtLoginStatus, .disabled)
  }

  func testManualLoginToggleSkipsRedundantRequests() {
    let environment = VirtualDisplayTestEnvironment()

    environment.store.setLaunchAtLoginEnabled(false)
    XCTAssertEqual(environment.loginManager.unregisterCallCount, 0)

    environment.store.setLaunchAtLoginEnabled(true)
    environment.store.setLaunchAtLoginEnabled(true)
    XCTAssertEqual(environment.loginManager.registerCallCount, 1)
    XCTAssertEqual(environment.store.launchAtLoginStatus, .enabled)

    environment.store.setLaunchAtLoginEnabled(false)
    environment.store.setLaunchAtLoginEnabled(false)
    XCTAssertEqual(environment.loginManager.unregisterCallCount, 1)
    XCTAssertEqual(environment.store.launchAtLoginStatus, .disabled)
  }

  func testManualEnableRequestsApprovalWithoutRegisteringAgain() {
    let environment = VirtualDisplayTestEnvironment()
    environment.loginManager.status = .requiresApproval

    environment.store.setLaunchAtLoginEnabled(true)

    XCTAssertEqual(environment.loginManager.registerCallCount, 0)
    XCTAssertEqual(environment.store.launchAtLoginStatus, .requiresApproval)
    XCTAssertTrue(environment.store.shouldShowLaunchAtLoginApproval)
  }

  func testFailedManualToggleReportsErrorAndKeepsActualStatus() throws {
    let environment = VirtualDisplayTestEnvironment()
    let error = NSError(domain: "LoginTests", code: 2)
    environment.loginManager.registerError = error

    environment.store.setLaunchAtLoginEnabled(true)

    let registrationMessage = try XCTUnwrap(environment.store.takeLastErrorMessage())
    XCTAssertTrue(registrationMessage.contains(error.localizedDescription))
    XCTAssertEqual(environment.store.launchAtLoginStatus, .disabled)

    environment.loginManager.status = .enabled
    environment.loginManager.unregisterError = error
    environment.store.setLaunchAtLoginEnabled(false)

    let unregistrationMessage = try XCTUnwrap(environment.store.takeLastErrorMessage())
    XCTAssertTrue(unregistrationMessage.contains(error.localizedDescription))
    XCTAssertEqual(environment.store.launchAtLoginStatus, .enabled)
  }
}
