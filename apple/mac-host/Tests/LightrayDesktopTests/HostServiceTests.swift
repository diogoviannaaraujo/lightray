import Foundation
import XCTest
import LightrayHostSupport
@testable import lightray_host_app

@MainActor private final class Registration: ServiceRegistration {
    var state: RegistrationState = .notRegistered
    var events: [String] = []
    var registerError = false
    var unregisterError = false
    func register() throws {
        events.append("register")
        if registerError { throw HostFailure.message("registration failed") }
        state = .enabled
    }
    func unregister() async throws {
        events.append("unregister")
        if unregisterError { throw HostFailure.message("unregistration failed") }
        state = .notRegistered
    }
    func openSettings() {}
}

@MainActor private final class Control: HostControlClient {
    var snapshot = HostSnapshot(state: .running, message: "Sharing is on.", screenAllowed: true, inputAllowed: true)
    var unavailable = false
    var stops = 0
    var permissions: [String] = []
    var statusReply: (() async throws -> HostSnapshot)?
    var permissionReply: (() async throws -> HostSnapshot)?
    func status() async throws -> HostSnapshot {
        if let statusReply { return try await statusReply() }
        if unavailable { throw HostFailure.message("unavailable") }
        return snapshot
    }
    func requestPermission(_ permission: String) async throws -> HostSnapshot {
        permissions.append(permission)
        if let permissionReply { return try await permissionReply() }
        if unavailable { throw HostFailure.message("unavailable") }
        return snapshot
    }
    func stopSharing() async throws {
        stops += 1
        if unavailable { throw HostFailure.message("unavailable") }
    }
}

@MainActor final class HostServiceTests: XCTestCase {
    private var directory: URL!
    private var store: HostSettingsStore!
    private var registration: Registration!
    private var control: Control!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = HostSettingsStore(directory: directory)
        try store.save(HostSettings())
        registration = Registration(); control = Control()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private func makeService(build: String = "1") -> HostService {
        HostService(store: store, registration: registration, control: control, build: build)
    }
    func testOpeningAppDoesNotEnableSharing() async {
        let service = makeService()
        await service.refreshAfterUpgrade()
        XCTAssertTrue(registration.events.isEmpty)
        XCTAssertFalse(service.settings.enabled)
    }
    func testStartAndPersistentStopAcrossAppReopen() async throws {
        let service = makeService()
        await service.start(port: 17373, quality: .smooth, allowInput: false)
        XCTAssertEqual(registration.events, ["register"])
        XCTAssertTrue(try store.load().enabled)
        XCTAssertEqual(try store.load().port, 17373)
        await service.refresh()
        XCTAssertEqual(service.snapshot.state, .running)
        // Merely recreating the controller must neither restart nor stop a service.
        let reopened = makeService()
        await reopened.refreshAfterUpgrade()
        XCTAssertEqual(registration.events, ["register"])
        await reopened.stop()
        XCTAssertFalse(try store.load().enabled)
        XCTAssertEqual(registration.events, ["register", "unregister"])
        let afterLogin = makeService()
        await afterLogin.refreshAfterUpgrade()
        XCTAssertEqual(afterLogin.snapshot.state, .stopped)
        XCTAssertEqual(registration.events.count, 2)
    }
    func testSystemApprovalIsNotOverridden() async throws {
        registration.state = .requiresApproval
        let service = makeService()
        await service.start(port: 7373, quality: .balanced, allowInput: true)
        await service.refreshAfterUpgrade()
        XCTAssertTrue(registration.events.isEmpty)
        XCTAssertEqual(service.snapshot.state, .blocked)
        XCTAssertTrue(try store.load().enabled)
    }
    func testRegistrationFailureIsVisibleAndCanRetry() async {
        registration.registerError = true
        let service = makeService()
        await service.start(port: 7373, quality: .balanced, allowInput: true)
        XCTAssertEqual(service.snapshot.state, .failed)
        registration.registerError = false
        await service.start(port: 7373, quality: .balanced, allowInput: true)
        await service.refresh()
        XCTAssertEqual(service.snapshot.state, .running)
    }
    func testStopUnregistersEvenWhenServiceUnavailable() async throws {
        let service = makeService()
        await service.start(port: 7373, quality: .balanced, allowInput: true)
        control.unavailable = true
        await service.stop()
        XCTAssertEqual(registration.state, .notRegistered)
        XCTAssertFalse(try store.load().enabled)
        XCTAssertEqual(service.snapshot.state, .stopped)
    }
    func testUnregisterFailureKeepsStopAvailableAndDisabledOnDisk() async throws {
        let service = makeService()
        await service.start(port: 7373, quality: .balanced, allowInput: true)
        registration.unregisterError = true
        await service.stop()
        XCTAssertEqual(service.snapshot.state, .failed)
        XCTAssertTrue(service.isActive)
        XCTAssertFalse(try store.load().enabled)
        registration.unregisterError = false
        await service.stop()
        XCTAssertEqual(service.snapshot.state, .stopped)
    }
    func testUpgradeReregistersOnlyApprovedEnabledService() async throws {
        let service = makeService()
        await service.start(port: 7373, quality: .balanced, allowInput: true)
        let update = makeService(build: "2")
        await update.refreshAfterUpgrade()
        XCTAssertEqual(registration.events, ["register", "unregister", "register"])
        XCTAssertEqual(try store.load().registeredBuild, "2")
        registration.state = .requiresApproval
        await makeService(build: "3").refreshAfterUpgrade()
        XCTAssertEqual(registration.events.count, 3)
    }
    func testPermissionsAndRuntimeReadinessAreReportedByAgent() async {
        let service = makeService()
        XCTAssertFalse(service.hasServiceSnapshot)
        await service.start(port: 7373, quality: .balanced, allowInput: true)
        XCTAssertFalse(service.hasServiceSnapshot)
        control.snapshot = HostSnapshot(state: .blocked, message: "Screen permission required")
        await service.refresh()
        XCTAssertEqual(service.snapshot.state, .blocked)
        XCTAssertTrue(service.hasServiceSnapshot)
        XCTAssertFalse(service.snapshot.screenAllowed)
        await service.requestPermission("screen")
        XCTAssertEqual(control.permissions, ["screen"])
        control.snapshot = HostSnapshot(state: .failed, message: "bind: Address already in use")
        await service.refresh()
        XCTAssertEqual(service.snapshot.message, "bind: Address already in use")
    }
    func testServiceDisconnectionClearsPermissionKnowledgeUntilAgentReplies() async {
        registration.state = .enabled
        let service = makeService()
        await service.refresh()
        XCTAssertTrue(service.hasServiceSnapshot)
        control.unavailable = true
        await service.refresh()
        XCTAssertFalse(service.hasServiceSnapshot)
        control.unavailable = false
        await service.refresh()
        XCTAssertTrue(service.hasServiceSnapshot)
        await service.stop()
        XCTAssertFalse(service.hasServiceSnapshot)
    }
    func testBackgroundApprovalClearsPermissionKnowledge() async {
        registration.state = .enabled
        let service = makeService()
        await service.refresh()
        XCTAssertTrue(service.hasServiceSnapshot)
        registration.state = .requiresApproval
        await service.refresh()
        XCTAssertFalse(service.hasServiceSnapshot)
        XCTAssertEqual(service.snapshot.state, .blocked)
    }
    func testStaleStatusDoesNotRestorePermissionKnowledgeAfterStop() async {
        registration.state = .enabled
        let service = makeService()
        let requested = expectation(description: "Status requested")
        var reply: CheckedContinuation<HostSnapshot, Error>?
        control.statusReply = {
            try await withCheckedThrowingContinuation {
                reply = $0
                requested.fulfill()
            }
        }
        let refresh = Task { await service.refresh() }
        await fulfillment(of: [requested], timeout: 1)
        await service.stop()
        reply?.resume(returning: control.snapshot)
        await refresh.value
        XCTAssertEqual(service.snapshot.state, .stopped)
        XCTAssertFalse(service.hasServiceSnapshot)
    }
    func testStalePermissionReplyDoesNotRestoreStoppedServiceState() async {
        registration.state = .enabled
        let service = makeService()
        let requested = expectation(description: "Permission requested")
        var reply: CheckedContinuation<HostSnapshot, Error>?
        control.permissionReply = {
            try await withCheckedThrowingContinuation {
                reply = $0
                requested.fulfill()
            }
        }
        let request = Task { await service.requestPermission("screen") }
        await fulfillment(of: [requested], timeout: 1)
        await service.stop()
        reply?.resume(returning: control.snapshot)
        await request.value
        XCTAssertEqual(service.snapshot.state, .stopped)
        XCTAssertFalse(service.hasServiceSnapshot)
    }
    func testPermissionRequestInvalidatesOlderStatusReply() async {
        registration.state = .enabled
        let service = makeService()
        let requested = expectation(description: "Status requested")
        var reply: CheckedContinuation<HostSnapshot, Error>?
        control.statusReply = {
            try await withCheckedThrowingContinuation {
                reply = $0
                requested.fulfill()
            }
        }
        let refresh = Task { await service.refresh() }
        await fulfillment(of: [requested], timeout: 1)
        await service.requestPermission("screen")
        reply?.resume(returning: HostSnapshot(state: .blocked, message: "Old permission state"))
        await refresh.value
        XCTAssertEqual(service.snapshot, control.snapshot)
        XCTAssertTrue(service.hasServiceSnapshot)
    }
    func testInvalidPortDoesNotRegisterOrOverwriteSettings() async throws {
        let service = makeService()
        await service.start(port: 0, quality: .balanced, allowInput: true)
        XCTAssertEqual(service.snapshot.state, .failed)
        XCTAssertTrue(registration.events.isEmpty)
        XCTAssertFalse(try store.load().enabled)
    }
    func testCorruptSettingsStillAllowUnregisterWithoutOverwritingTheFile() async throws {
        let corrupt = Data("invalid-settings".utf8)
        try corrupt.write(to: store.url)
        registration.state = .enabled
        let service = makeService()
        XCTAssertNotNil(service.configurationError)
        await service.stop()
        XCTAssertEqual(registration.state, .notRegistered)
        XCTAssertEqual(service.snapshot.state, .stopped)
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
    }

    func testUnwritableSettingsStillAllowUnregister() async throws {
        let service = makeService()
        await service.start(port: 7373, quality: .balanced, allowInput: true)
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        await service.stop()
        XCTAssertEqual(registration.state, .notRegistered)
        XCTAssertEqual(service.snapshot.state, .stopped)
        XCTAssertTrue(service.snapshot.message.contains("Settings need attention"))
    }

}
