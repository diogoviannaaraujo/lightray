import LightrayCore
import SwiftUI
import XCTest
@testable import Lightray

@MainActor
final class ClientTests: XCTestCase {
    func testPairingVaultRoundTripReplacementAndRemoval() throws {
        let original = Pairing.generate()
        defer { try? PairingVault.remove(id: original.id) }
        try PairingVault.save(original)
        XCTAssertTrue(try PairingVault.load(id: original.id) == original)
        let replacement = Pairing(id: original.id, psk: Pairing.generate().psk)
        try PairingVault.save(replacement)
        XCTAssertTrue(try PairingVault.load(id: original.id) == replacement)
        try PairingVault.remove(id: original.id)
        XCTAssertThrowsError(try PairingVault.load(id: original.id))
        XCTAssertNoThrow(try PairingVault.remove(id: original.id))
    }

    func testMalformedConnectionDoesNotStartSession() {
        let session = ClientSession()
        session.connect(address: "127.0.0.1:0", name: "Test", token: Pairing.generate().token, remember: false)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNotNil(session.errorMessage)
        session.errorMessage = nil
        session.connect(address: "127.0.0.1", name: "Test", token: "lr1-incomplete", remember: false)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(session.isPresentingSession)
    }

    func testCancelDuringStartupCannotReviveSession() async throws {
        let session = ClientSession()
        for _ in 0..<12 {
            session.connect(address: "127.0.0.1:17374", name: "Cancellation", token: Pairing.generate().token, remember: false)
            session.disconnect()
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.isPresentingSession)
        XCTAssertFalse(session.hasPicture)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    func testHandshakeRetriesDoNotExtendTimeout() async throws {
        let session = ClientSession()
        defer { session.disconnect() }
        session.connect(address: "127.0.0.1:17374", name: "Unreachable", token: Pairing.generate().token, remember: false)
        try await waitUntil(timeout: .seconds(15)) { session.phase == .idle }
        XCTAssertTrue(session.errorMessage?.contains("12 seconds") == true)
        XCTAssertFalse(session.isPresentingSession)
    }

    /// The smoke-test script installs this private, temporary file in the app container.
    /// A normal test run skips this test without needing a running Mac host.
    func testSyntheticHostStreamingSwitchingInputAndReconnect() async throws {
        struct Configuration: Decodable { let address: String; let token: String }
        let file = URL.documentsDirectory.appendingPathComponent("lightray-smoke.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("Run ios/scripts/smoke-test.py for the local synthetic-host integration test.")
        }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
        let session = ClientSession()
        defer { session.disconnect() }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow)
        let previous = window.rootViewController
        window.rootViewController = UIHostingController(rootView: ContentView(session: session))
        defer { window.rootViewController = previous }

        session.connect(address: configuration.address, name: "Synthetic Mac", token: configuration.token, remember: false)
        try await waitUntil { session.hasPicture }
        XCTAssertEqual(session.phase, .connected)
        XCTAssertTrue(session.canSendInput)
        XCTAssertEqual(session.displays.count, 2)
        XCTAssertGreaterThan(session.videoSize.width, 0)
        XCTAssertFalse(session.statistics.isEmpty)

        let second = try XCTUnwrap(session.displays.first { $0.id != session.selectedDisplay })
        session.selectDisplay(second.id)
        try await waitUntil { session.selectedDisplay == second.id && session.hasPicture }
        session.sendKey(0x29)
        session.send(.pointer(x: 32768, y: 32768, display: second.id))
        session.send(.button(.left, down: true))
        session.releaseInput()
        try await Task.sleep(for: .milliseconds(200))

        let oldRenderer = session.renderer
        session.suspend()
        XCTAssertEqual(session.phase, .suspended)
        XCTAssertFalse(session.hasPicture)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        session.foreground()
        try await waitUntil { session.hasPicture && session.selectedDisplay == second.id }
        XCTAssertFalse(session.renderer === oldRenderer)

        session.reconnect()
        try await waitUntil { session.hasPicture }
        session.showStatistics = true
        print("LIGHTRAY_SMOKE_LIVE")
        try await Task.sleep(for: .seconds(3))
        session.disconnect()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.isPresentingSession)
    }

    private func waitUntil(timeout: Duration = .seconds(12), _ predicate: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: timeout)
        while !predicate() {
            if clock.now >= end {
                XCTFail("Timed out waiting for client state")
                throw WaitError.timeout
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private enum WaitError: Error { case timeout }
}
