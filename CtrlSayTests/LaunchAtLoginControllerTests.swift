import ServiceManagement
import XCTest

final class LaunchAtLoginControllerTests: XCTestCase {
    @MainActor
    func testMapsEverySystemStatus() {
        let cases: [(SMAppService.Status, LaunchAtLoginState)] = [
            (.notRegistered, .disabled),
            (.enabled, .enabled),
            (.requiresApproval, .requiresApproval),
            (.notFound, .unavailable),
        ]

        for (status, expected) in cases {
            let service = FakeLaunchAtLoginService(status: status)
            let controller = LaunchAtLoginController(
                service: service,
                openSystemSettingsAction: {}
            )
            XCTAssertEqual(controller.state, expected)
            XCTAssertEqual(controller.isEnabled, expected.isSelected)
        }
    }

    @MainActor
    func testEnablingAndDisablingUseMainAppServiceOperations() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(
            service: service,
            openSystemSettingsAction: {}
        )

        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(controller.state, .enabled)

        XCTAssertTrue(controller.setEnabled(false))
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(controller.state, .disabled)
    }

    @MainActor
    func testRequiresApprovalRemainsSelectedAndCanOpenSystemSettings() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        var openedSettings = false
        let controller = LaunchAtLoginController(
            service: service,
            openSystemSettingsAction: { openedSettings = true }
        )

        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertEqual(service.registerCount, 0)
        controller.openSystemSettings()
        XCTAssertTrue(openedSettings)
    }

    @MainActor
    func testRegistrationFailureIsNonfatalAndDoesNotExposeRawError() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registrationError = TestError.registrationFailed
        let controller = LaunchAtLoginController(
            service: service,
            openSystemSettingsAction: {}
        )

        XCTAssertFalse(controller.setEnabled(true))
        XCTAssertEqual(controller.state, .disabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(
            controller.errorMessage,
            "Ctrl-Say couldn’t update Login Items. Open System Settings and try again."
        )
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: SMAppService.Status
    var registrationError: Error?
    var unregistrationError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registrationError { throw registrationError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }
}

private enum TestError: Error {
    case registrationFailed
}
