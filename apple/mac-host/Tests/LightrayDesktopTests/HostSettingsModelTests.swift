import Foundation
import XCTest
import LightrayHostSupport
@testable import lightray_host_app

@MainActor private final class SettingsRegistration: ServiceRegistration {
    var state: RegistrationState = .notRegistered
    var actions: [String] = []
    func register() throws { actions.append("register"); state = .enabled }
    func unregister() async throws { actions.append("unregister"); state = .notRegistered }
    func openSettings() { actions.append("openSettings") }
}

@MainActor private final class SettingsControl: HostControlClient {
    var snapshot = HostSnapshot(state: .running, message: "Ready for a paired device.",
                                screenAllowed: true, inputAllowed: true)
    var unavailable = false
    var statusRequests = 0
    func status() async throws -> HostSnapshot {
        statusRequests += 1
        if unavailable { throw HostFailure.message("The service is unavailable.") }
        return snapshot
    }
    func requestPermission(_ permission: String) async throws -> HostSnapshot { snapshot }
    func stopSharing() async throws {}
}

@MainActor final class HostSettingsModelTests: XCTestCase {
    private var directory: URL!
    private var store: HostSettingsStore!
    private var registration: SettingsRegistration!
    private var control: SettingsControl!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = HostSettingsStore(directory: directory)
        try store.save(HostSettings())
        registration = SettingsRegistration()
        control = SettingsControl()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func makeModel() -> HostSettingsModel {
        HostSettingsModel(service: HostService(store: store, registration: registration,
                                              control: control, build: "test"))
    }

    func testUnregisteredServiceOffersInstallationWithoutActivatingOnOpen() {
        let model = makeModel()
        XCTAssertEqual(model.banners.map(\.id), ["service"])
        XCTAssertTrue(model.banners.first?.action == .activate)
        XCTAssertEqual(model.banners.first?.button, "Install & Activate")
        XCTAssertTrue(model.canStart)
        XCTAssertTrue(registration.actions.isEmpty)
        XCTAssertEqual(control.statusRequests, 0)
    }

    func testBackgroundApprovalOffersSystemSettings() async {
        registration.state = .requiresApproval
        let model = makeModel()
        await model.service.refresh()
        XCTAssertEqual(model.banners.map(\.id), ["service"])
        XCTAssertTrue(model.banners.first?.action == .backgroundSettings)
        XCTAssertFalse(model.hasServiceSnapshot)
        XCTAssertTrue(registration.actions.isEmpty)
        XCTAssertEqual(control.statusRequests, 0)
    }

    func testMissingHelperOffersApplicationLocationInsteadOfActivation() async {
        registration.state = .notFound
        let model = makeModel()
        await model.service.refresh()
        XCTAssertEqual(model.banners.map(\.id), ["service"])
        XCTAssertTrue(model.banners.first?.action == .revealApp)
        XCTAssertFalse(model.canStart)
        XCTAssertFalse(model.hasServiceSnapshot)
    }

    func testUnknownServicePermissionsDoNotShowPermissionWarnings() {
        registration.state = .enabled
        let model = makeModel()
        XCTAssertFalse(model.hasServiceSnapshot)
        XCTAssertFalse(model.snapshot.screenAllowed)
        XCTAssertFalse(model.snapshot.inputAllowed)
        XCTAssertTrue(model.banners.isEmpty)
        XCTAssertEqual(model.statusTitle, "Checking service…")
    }

    func testConfirmedMissingPermissionsOfferBothPermissionActions() async {
        registration.state = .enabled
        control.snapshot = HostSnapshot(state: .blocked, message: "Screen Recording is required.")
        let model = makeModel()
        await model.service.refresh()
        XCTAssertTrue(model.hasServiceSnapshot)
        XCTAssertEqual(model.banners.map(\.id), ["screen", "input"])
        XCTAssertTrue(model.banners[0].action == .screenPermission)
        XCTAssertTrue(model.banners[1].action == .inputPermission)
    }

    func testAccessibilityBlockedServiceOffersOnlyAccessibility() async {
        registration.state = .enabled
        control.snapshot = HostSnapshot(state: .blocked, message: "Accessibility is required.", screenAllowed: true)
        let model = makeModel()
        await model.service.refresh()
        XCTAssertEqual(model.banners.map(\.id), ["input"])
        XCTAssertTrue(model.banners.first?.action == .inputPermission)
    }

    func testDisabledRemoteControlDoesNotRequireAccessibility() async throws {
        var settings = HostSettings()
        settings.allowInput = false
        try store.save(settings)
        registration.state = .enabled
        control.snapshot = HostSnapshot(state: .blocked, message: "Screen Recording is required.")
        let model = makeModel()
        // An unsaved draft cannot change the permissions needed by the current service.
        model.allowInput = true
        await model.service.refresh()
        XCTAssertEqual(model.banners.map(\.id), ["screen"])
        control.snapshot = HostSnapshot(state: .running, message: "Sharing is on.", screenAllowed: true)
        await model.service.refresh()
        XCTAssertTrue(model.banners.isEmpty)
    }

    func testHealthyRunningServiceHasNoWarnings() async {
        registration.state = .enabled
        let model = makeModel()
        await model.service.refresh()
        XCTAssertEqual(model.statusTitle, "Ready to connect")
        XCTAssertTrue(model.hasServiceSnapshot)
        XCTAssertTrue(model.banners.isEmpty)
    }

    func testFailedRuntimeOffersActivationWithFailureDetails() async {
        registration.state = .enabled
        control.snapshot = HostSnapshot(state: .failed, message: "The UDP port is already in use.",
                                        screenAllowed: true, inputAllowed: true)
        let model = makeModel()
        await model.service.refresh()
        XCTAssertEqual(model.banners.map(\.id), ["service"])
        XCTAssertTrue(model.banners.first?.action == .activate)
        XCTAssertEqual(model.banners.first?.message, control.snapshot.message)
    }

    func testUnavailableServiceOffersActivationWithoutFalsePermissionWarnings() async {
        registration.state = .enabled
        let model = makeModel()
        await model.service.refresh()
        XCTAssertTrue(model.hasServiceSnapshot)
        control.unavailable = true
        await model.service.refresh()
        XCTAssertFalse(model.hasServiceSnapshot)
        XCTAssertEqual(model.banners.map(\.id), ["service"])
        XCTAssertTrue(model.banners.first?.action == .activate)
        XCTAssertEqual(model.banners.first?.message, "The service is unavailable.")
    }

    func testDraftSettingsAndSelectedPageSurviveServiceRefresh() async throws {
        let model = makeModel()
        model.port = "17373"
        model.quality = .native
        model.allowInput = false
        model.page = .pairing
        registration.state = .enabled
        await model.service.refresh()
        XCTAssertEqual(model.port, "17373")
        XCTAssertEqual(model.quality, .native)
        XCTAssertFalse(model.allowInput)
        XCTAssertEqual(model.page, .pairing)
        XCTAssertEqual(model.snapshot.state, .running)
        XCTAssertEqual(try store.load(), HostSettings())
    }

    func testCorruptSettingsDoNotOfferMisleadingSetupActions() async throws {
        try Data("invalid settings".utf8).write(to: store.url)
        let model = makeModel()
        await model.service.refresh()
        XCTAssertNotNil(model.configurationError)
        XCTAssertTrue(model.banners.isEmpty)
        XCTAssertFalse(model.canEdit)
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(control.statusRequests, 0)
    }
}
