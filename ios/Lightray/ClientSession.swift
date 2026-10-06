import Foundation
import LightrayCore
import Observation
import UIKit

/// UI state stays on the main actor; ClientRunner owns networking and decoding queues.
@MainActor @Observable
final class ClientSession {
    enum Phase { case idle, connecting, connected, suspended }

    var hosts: [PairedHost] = []
    var phase: Phase = .idle
    var status = "Choose a computer to get started."
    var errorMessage: String?
    var activeHost: PairedHost?
    var displays: [DisplayInfo] = []
    var selectedDisplay: UInt32 = 0
    private var pendingDisplay: UInt32?
    var videoSize = CGSize(width: 1920, height: 1080)
    var renderer = VideoRenderer()
    var hasPicture = false
    var statistics = ""
    var showStatistics = false
    var inputEnabled = true
    var inputResetGeneration: UInt64 = 0

    var isPresentingSession: Bool { activeHost != nil }
    var canSendInput: Bool { phase == .connected && hasPicture && inputEnabled && pendingDisplay == nil }

    @ObservationIgnored private let hostStore = PairedHostsStore()
    @ObservationIgnored private var pairing: Pairing?
    @ObservationIgnored private var attempt: Attempt?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var stream: UInt8 = 1
    @ObservationIgnored private var preferredDisplay: UInt32 = 0
    @ObservationIgnored private var heldKeys = Set<UInt16>()
    @ObservationIgnored private var heldButtons = Set<UInt8>()

    /// Cancellation cannot interrupt DNS. Keep start/stop ordered even if the user leaves
    /// while resolution is still running. A completed, cancelled start is stopped on main.
    private final class Attempt {
        let runner: ClientRunner
        var starting = true
        var cancelled = false
        init(_ runner: ClientRunner) { self.runner = runner }
    }

    init() {
        do { hosts = try hostStore.load() }
        catch { errorMessage = "Saved computers could not be read: \(error.localizedDescription)" }
    }

    func connect(address: String, name: String, token: String, remember: Bool) {
        do {
            let target = try ConnectionTarget(address)
            guard let key = Pairing(token: token) else {
                errorMessage = "Enter the complete pairing token beginning with lr1-."
                return
            }
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = PairedHost(pairingID: key.id, name: trimmedName.isEmpty ? target.host : trimmedName,
                                  address: target.address)
            try hostStore.validate([host])
            if remember {
                var updated = hosts.filter { $0.pairingID != key.id }
                updated.append(host)
                try hostStore.validate(updated)
                try PairingVault.save(key)
                try hostStore.save(updated)
                hosts = updated
            }
            begin(host: host, pairing: key)
        } catch {
            errorMessage = "Could not connect. Check the host address, port, and saved pairing. \(error.localizedDescription)"
        }
    }

    func connect(_ host: PairedHost) {
        do { begin(host: host, pairing: try PairingVault.load(id: host.pairingID)) }
        catch { errorMessage = "The saved pairing is unavailable. Add this computer again with its pairing token. \(error.localizedDescription)" }
    }

    func forget(_ host: PairedHost) {
        do {
            let updated = hosts.filter { $0.pairingID != host.pairingID }
            try PairingVault.remove(id: host.pairingID)
            try hostStore.save(updated)
            hosts = updated
        } catch { errorMessage = "Could not forget this computer: \(error.localizedDescription)" }
    }

    private func begin(host: PairedHost, pairing: Pairing) {
        disconnect()
        activeHost = host
        self.pairing = pairing
        preferredDisplay = 0
        start()
    }

    func reconnect() {
        guard activeHost != nil else { return }
        stopAttempt()
        start()
    }

    func disconnect() {
        stopAttempt()
        activeHost = nil
        pairing = nil
        phase = .idle
        status = "Choose a computer to get started."
        displays = []
        selectedDisplay = 0
        pendingDisplay = nil
    }

    func suspend() {
        guard activeHost != nil else { return }
        stopAttempt()
        phase = .suspended
        status = "Paused while Lightray is in the background."
    }

    func foreground() {
        guard phase == .suspended else { return }
        start()
    }

    private func start() {
        guard let host = activeHost, let pairing else { return }
        do {
            let target = try ConnectionTarget(host.address)
            var settings = ClientRunner.Settings(host: target.host, port: target.port, pairing: pairing)
            settings.streams = 1
            let current = Attempt(ClientRunner(settings: settings))
            attempt = current
            resetPicture()
            phase = .connecting
            status = "Connecting to \(host.name)…"
            current.runner.onEvent = { [weak self, weak current] event in
                guard let self, let current, self.attempt === current, !current.cancelled else { return }
                self.handle(event, runner: current.runner)
            }
            armDeadline(for: current)
            Task { [weak self, current] in
                do {
                    let runner = current.runner
                    try await Task.detached(priority: .userInitiated) { try runner.start() }.value
                    current.starting = false
                    if current.cancelled { current.runner.stop() }
                } catch {
                    current.starting = false
                    current.runner.stop()
                    guard let self, self.attempt === current, !current.cancelled else { return }
                    self.fail("Could not reach this computer. Check its address and your network. \(error.localizedDescription)")
                }
            }
        } catch { fail("The computer address is invalid.") }
    }

    private func stopAttempt() {
        deadline?.cancel()
        deadline = nil
        releaseInput()
        if let current = attempt {
            current.cancelled = true
            if !current.starting { current.runner.stop() }
        }
        attempt = nil
        hasPicture = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func fail(_ message: String) {
        disconnect()
        errorMessage = message
    }

    private func armDeadline(for current: Attempt) {
        deadline?.cancel()
        deadline = Task { [weak self, weak current] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, let current, self.attempt === current, self.phase == .connecting else { return }
            self.fail("The host did not authenticate within 12 seconds. Confirm it is running, the pairing token matches, and Local Network access is enabled for Lightray in Settings.")
        }
    }

    private func resetPicture() {
        releaseInput()
        renderer = VideoRenderer()
        hasPicture = false
        statistics = ""
    }

    private func handle(_ event: ClientRunner.Event, runner: ClientRunner) {
        switch event {
        case .connecting, .disconnected:
            let wasConnected = phase == .connected
            resetPicture()
            phase = .connecting
            status = "Connecting…"
            selectedDisplay = 0
            pendingDisplay = nil
            displays = []
            UIApplication.shared.isIdleTimerDisabled = false
            // Retransmission cycles must not extend the user's connection deadline.
            if wasConnected, let attempt { armDeadline(for: attempt) }
        case .connected(let streams):
            guard let first = streams.first else { fail("The host did not offer a video stream."); return }
            stream = first
            phase = .connected
            status = "Connected · waiting for video"
            deadline?.cancel()
            deadline = nil
            UIApplication.shared.isIdleTimerDisabled = true
        case .displays(let list):
            displays = list
            if !list.contains(where: { $0.id == selectedDisplay }) {
                let display = list.first(where: { $0.id == preferredDisplay })
                    ?? list.first(where: \.isPrimary) ?? list.first
                if let display { selectDisplay(display.id) }
                else {
                    selectedDisplay = 0
                    pendingDisplay = nil
                    resetPicture()
                    status = "The host has no available displays."
                }
            }
        case .streamDisplay(let id, let display):
            guard id == stream else { return }
            if display == pendingDisplay || display == 0 { pendingDisplay = nil }
            if selectedDisplay != display {
                resetPicture()
                selectedDisplay = display
                runner.attach(renderer, to: stream)
            }
            if let info = displays.first(where: { $0.id == display }) {
                videoSize = CGSize(width: info.width, height: info.height)
            }
            status = display == 0 ? "The host stopped this display. Choose another display or reconnect." : "Waiting for video…"
        case .needsRenderer(let id):
            if id == stream { runner.attach(renderer, to: id) }
        case .pictureSize(let id, let size):
            guard id == stream else { return }
            videoSize = size
        case .stats(let reports):
            guard selectedDisplay != 0, pendingDisplay == nil, let report = reports[stream] else { return }
            statistics = report.overlay
            hasPicture = report.state == .live
            if !hasPicture { releaseInput() }
            switch report.state {
            case .live: status = "Live"
            case .waiting: status = "Waiting for video…"
            case .interrupted: status = "Video interrupted · waiting for the host"
            }
        }
    }

    func selectDisplay(_ id: UInt32) {
        guard phase == .connected, displays.contains(where: { $0.id == id }) else { return }
        releaseInput()
        hasPicture = false
        pendingDisplay = id
        preferredDisplay = id
        status = "Switching display…"
        attempt?.runner.selectDisplay(id, on: stream)
    }

    func send(_ message: InputMessage) {
        switch message {
        case .key(let usage, let down, _):
            if down {
                guard canSendInput else { return }
                heldKeys.insert(usage)
            } else { guard heldKeys.remove(usage) != nil else { return } }
        case .button(let button, let down):
            if down {
                guard canSendInput else { return }
                heldButtons.insert(button.rawValue)
            } else { guard heldButtons.remove(button.rawValue) != nil else { return } }
        default: guard canSendInput else { return }
        }
        attempt?.runner.send(message)
    }

    func releaseInput() {
        inputResetGeneration &+= 1
        for usage in heldKeys.sorted() {
            attempt?.runner.send(.key(usage: usage, down: false, isRepeat: false))
        }
        for raw in heldButtons.sorted() {
            if let button = InputMessage.PointerButton(rawValue: raw) { attempt?.runner.send(.button(button, down: false)) }
        }
        heldKeys.removeAll()
        heldButtons.removeAll()
    }

    func sendKey(_ usage: UInt16) {
        guard !heldKeys.contains(usage) else { return }
        send(.key(usage: usage, down: true, isRepeat: false))
        send(.key(usage: usage, down: false, isRepeat: false))
    }
}
