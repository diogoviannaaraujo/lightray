import LightrayCore
import SwiftUI
import XCTest
@testable import Lightray

@MainActor
final class ClientTests: XCTestCase {
    func testSoftwareKeyboardTypingDismissalAndInputDisable() async throws {
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow)
        let previous = window.rootViewController
        let controller = UIViewController()
        let surface = StreamSurfaceView(frame: window.bounds)
        let renderer = VideoRenderer()
        var inputs: [InputMessage] = []
        var dismissals = 0
        let onInput: (InputMessage) -> Void = { inputs.append($0) }
        let onDismiss: () -> Void = { dismissals += 1 }
        surface.configure(renderer: renderer, videoSize: CGSize(width: 1280, height: 720),
                          displayID: 1, inputEnabled: true, inputResetGeneration: 0,
                          onInput: onInput, onFocusLost: {}, onKeyboardDismissed: onDismiss)
        controller.view = surface
        window.rootViewController = controller
        defer {
            surface.detach()
            window.rootViewController = previous
        }
        try await waitUntil { surface.isFirstResponder }
        surface.insertText("hidden")
        surface.deleteBackward()
        XCTAssertTrue(inputs.isEmpty)

        let shown = expectation(forNotification: UIResponder.keyboardDidShowNotification, object: nil) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return false }
            return frame.height > 100
        }
        surface.setSoftwareKeyboardVisible(true)
        await fulfillment(of: [shown], timeout: 10)
        XCTAssertTrue(surface.softwareKeyboardVisible)
        XCTAssertNil(surface.inputView)
        surface.insertText("Olá 👩🏽‍💻\r\n\t")
        surface.deleteBackward()
        let text = "Olá 👩🏽‍💻".unicodeScalars.map { InputMessage.text(String($0)) }
        let keys: [InputMessage] = [0x28, 0x2B, 0x2A].flatMap { usage in
            [.key(usage: usage, down: true, isRepeat: false), .key(usage: usage, down: false, isRepeat: false)]
        }
        XCTAssertEqual(inputs, text + keys)

        surface.setSoftwareKeyboardVisible(false)
        XCTAssertTrue(surface.isFirstResponder) // Hardware keyboard capture remains active.
        XCTAssertNotNil(surface.inputView)
        surface.insertText("hidden")
        XCTAssertEqual(inputs, text + keys)

        surface.setSoftwareKeyboardVisible(true)
        _ = surface.resignFirstResponder()
        XCTAssertFalse(surface.softwareKeyboardVisible)
        XCTAssertEqual(dismissals, 1)

        surface.configure(renderer: renderer, videoSize: CGSize(width: 1280, height: 720),
                          displayID: 1, inputEnabled: false, inputResetGeneration: 1,
                          softwareKeyboardVisible: true, onInput: onInput, onFocusLost: {},
                          onKeyboardDismissed: onDismiss)
        XCTAssertFalse(surface.softwareKeyboardVisible)
        surface.insertText("disabled")
        surface.deleteBackward()
        XCTAssertEqual(inputs, text + keys)
    }

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

    func testEstablishedSessionRetriesPastDeadlineAndRecovers() async throws {
        let host = try RecoveryHost()
        defer { host.stop() }
        let session = ClientSession()
        defer { session.disconnect() }
        session.connect(address: "127.0.0.1:\(host.socket.localPort)", name: "Recovery host",
                        token: host.pairing.token, remember: false)
        try await waitUntil { session.phase == .connected }
        let oldRenderer = session.renderer

        host.online = false
        try await waitUntil { session.phase == .connecting }
        // The former 12-second deadline discarded the active computer here.
        try await Task.sleep(for: .seconds(14))
        XCTAssertEqual(session.phase, .connecting)
        XCTAssertTrue(session.isPresentingSession)
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.canSendInput)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)

        host.restart()
        try await waitUntil { session.phase == .connected }
        XCTAssertFalse(session.renderer === oldRenderer)

        // Returning from the background while the host is still offline must also recover.
        session.suspend()
        host.online = false
        session.foreground()
        try await Task.sleep(for: .seconds(14))
        XCTAssertEqual(session.phase, .connecting)
        XCTAssertNil(session.errorMessage)
        host.restart()
        try await waitUntil { session.phase == .connected }

        session.disconnect()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.isPresentingSession)
    }

    /// The smoke-test script installs this private, temporary file in the app container.
    /// A normal test run skips this test without needing a running Mac host.
    func testSyntheticHostStreamingSwitchingInputAndReconnect() async throws {
        struct Configuration: Decodable { let address: String; let token: String }
        let file = URL.documentsDirectory.appendingPathComponent("lightray-smoke.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("Run apple/ios-client/scripts/smoke-test.py for the local synthetic-host integration test.")
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
        session.send(.text("Lightray café 👋"))
        session.sendKey(0x2A)
        session.sendKey(0x28)
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

    /// Opt in with a real desktop host. Keep it idle between connections to exercise the
    /// prepared pipeline instead of hiding first-picture failures behind a moving test pattern.
    func testPreparedDesktopStartupAndReconnect() async throws {
        struct Configuration: Decodable { let address: String; let token: String }
        let file = URL.documentsDirectory.appending(path: "lightray-startup.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("Install lightray-startup.json to run the prepared desktop test.")
        }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
        let session = ClientSession()
        defer { session.disconnect() }
        let clock = ContinuousClock()
        for trial in 1...3 {
            let start = clock.now
            session.connect(address: configuration.address, name: "Prepared Mac",
                            token: configuration.token, remember: false)
            try await waitUntil(timeout: .seconds(3)) { session.hasPicture }
            print("LIGHTRAY_DESKTOP_STARTUP trial=\(trial) time_to_live=\(start.duration(to: clock.now))")
            XCTAssertTrue(session.canSendInput)
            // A stationary display must not become "interrupted" or disable input.
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertTrue(session.hasPicture)
                XCTAssertTrue(session.canSendInput)
            }
            session.disconnect()
            try await Task.sleep(for: .seconds(1))
        }
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

/// A real UDP/authentication peer with controllable outages; no screen-capture permission needed.
@MainActor
private final class RecoveryHost {
    let pairing = Pairing.generate()
    let socket: UDPSocket
    var online = true
    private var endpoint: HostEndpoint!
    private let timer: DispatchSourceTimer

    init() throws {
        socket = try UDPSocket(queue: .main)
        timer = DispatchSource.makeTimerSource(queue: .main)
        restart()
        socket.start { [weak self] bytes, peer in
            MainActor.assumeIsolated {
                guard let self, self.online else { return }
                self.endpoint.receive(bytes, from: peer, now: monotonicMicros(), unixTime: unixSeconds())
                self.pump()
            }
        }
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.pump() }
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.resume()
    }

    func restart() {
        let pairing = pairing
        endpoint = HostEndpoint(config: HostConfig(), hostSecret: Pairing.generate().psk) {
            $0 == pairing.id ? pairing.psk : nil
        }
        online = true
    }

    private func pump() {
        guard online else { return }
        endpoint.tick(now: monotonicMicros())
        for (bytes, peer) in endpoint.takeOutbox() { socket.send(bytes, to: peer) }
        _ = endpoint.takeEvents()
    }

    func stop() {
        timer.cancel()
        socket.close()
    }
}
