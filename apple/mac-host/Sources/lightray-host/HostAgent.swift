import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LightrayCore
import LightrayHostRuntime
import LightrayHostSupport

/// The registered agent owns the menu bar and runtime; the settings app may exit at any time.
@MainActor final class HostAgent: NSObject, NSApplicationDelegate, NSXPCListenerDelegate {
    private let store = HostSettingsStore()
    private var listener: NSXPCListener?
    private nonisolated let control = AgentControl()
    private var statusItem: NSStatusItem?
    private let statusText = NSMenuItem(title: "Preparing sharing…", action: nil, keyEquivalent: "")
    private var timer: Timer?
    private var signals: [DispatchSourceSignal] = []
    private var runtime: HostApp?
    private var startup: Task<Void, Never>?
    private var snapshot = HostSnapshot()
    private var stopping = false
    private var checking = false
    private var quiesced = false
    private var stopTask: Task<Void, Never>?
    private var peerRequirement = ""
    private var parentApp: URL { HostIdentity.parentApp(of: Bundle.main.bundleURL) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try prepareLog()
            log("host service starting, build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown")")
            peerRequirement = try HostPeerIdentity.requirement(for: parentApp)
            let listener = NSXPCListener(machServiceName: HostIdentity.service)
            listener.setConnectionCodeSigningRequirement(peerRequirement)
            listener.delegate = self
            self.listener = listener
            control.agent = self
            listener.resume()
            installMenu()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.reconcile() }
            }
            for number in [SIGINT, SIGTERM] {
                Darwin.signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in Task { @MainActor in await self?.stopRuntime(); NSApp.terminate(nil) } }
                source.resume(); signals.append(source)
            }
            Task { await reconcile() }
        } catch {
            log("host service setup failed: \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    private func prepareLog() throws {
        let url = HostIdentity.logURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5 * 1024 * 1024 {
            let previous = url.appendingPathExtension("previous")
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: url, to: previous)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw HostFailure.message("Could not open the host log.") }
        defer { close(fd) }
        fchmod(fd, 0o600)
        dup2(fd, STDOUT_FILENO); dup2(fd, STDERR_FILENO)
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Lightray Host")
        let menu = NSMenu()
        menu.addItem(statusText)
        menu.addItem(.separator())
        for (title, action) in [("Open Host Settings…", #selector(openSettings)), ("Show Host Log", #selector(showLog))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        item.menu = menu; statusItem = item
    }

    @objc private func openSettings() {
        NSWorkspace.shared.openApplication(at: parentApp, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func showLog() { NSWorkspace.shared.activateFileViewerSelecting([HostIdentity.logURL]) }

    private func update(_ state: HostSnapshot.State, _ message: String) {
        snapshot = HostSnapshot(state: state, message: message,
                                screenAllowed: CGPreflightScreenCaptureAccess(), inputAllowed: AXIsProcessTrusted())
        statusText.title = message
        statusItem?.button?.toolTip = "Lightray Host — \(message)"
    }

    private func reconcile() async {
        guard !quiesced, !stopping, !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let settings = try store.load()
            guard settings.enabled else { await stopRuntime(); return }
            let screen = CGPreflightScreenCaptureAccess()
            let input = AXIsProcessTrusted()
            guard screen, !settings.allowInput || input else {
                await stopRuntime()
                update(.blocked, !screen ? "Screen Recording permission is required." : "Accessibility permission is required for remote control.")
                return
            }
            guard runtime == nil, startup == nil, snapshot.state != .failed else { return }
            var options = HostOptions()
            options.port = settings.port
            options.frameRate = settings.quality.frameRate
            options.scale = settings.quality.scale
            options.inputMode = settings.allowInput ? .inject : .off
            options.requireCaptureReady = true
            let host = HostApp(options: options, pairings: StoredPairings())
            runtime = host
            update(.starting, "Preparing sharing…")
            startup = Task { [weak self] in
                do {
                    try await host.run()
                    guard let self, !Task.isCancelled else { await host.stop(); return }
                    self.update(.running, "Sharing is on. Ready for a paired device.")
                    self.startup = nil
                } catch {
                    await host.stop()
                    guard let self, !Task.isCancelled else { return }
                    self.runtime = nil; self.startup = nil
                    self.update(.failed, "Sharing could not start: \(error.localizedDescription)")
                    log(self.snapshot.message)
                }
            }
        } catch {
            await stopRuntime()
            update(.failed, "Could not load host configuration: \(error.localizedDescription)")
        }
    }

    fileprivate func statusData() -> Data {
        snapshot.screenAllowed = CGPreflightScreenCaptureAccess()
        snapshot.inputAllowed = AXIsProcessTrusted()
        snapshot.connectedDevice = runtime?.connectedPairing.map { String(format: "%016llx", $0) }
        return try! JSONEncoder().encode(snapshot)
    }

    fileprivate func requestPermission(_ permission: String) async -> Data {
        // Permission prompts originate in the actual capture/input process, only on a UI action.
        switch permission {
        case "screen":
            _ = CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case "input":
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        default: return statusData()
        }
        if snapshot.state == .failed { update(.blocked, "Checking permissions…") }
        await reconcile()
        return statusData()
    }

    fileprivate func quiesce() async {
        quiesced = true
        await stopRuntime()
    }

    fileprivate func stopRuntime() async {
        if let stopTask { await stopTask.value; return }
        stopping = true
        let stop = Task { @MainActor in
            update(.stopping, "Stopping sharing…")
            let task = startup
            task?.cancel()
            if let runtime { await runtime.stop() }
            await task?.value
            startup = nil; runtime = nil
            update(.stopped, "Sharing is off.")
        }
        stopTask = stop
        await stop.value
        stopTask = nil
        stopping = false
    }

    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        // NSXPCListener enforces the counterpart signature before dispatching any messages.
        connection.exportedInterface = NSXPCInterface(with: HostControlProtocol.self)
        connection.exportedObject = control
        connection.resume()
        return true
    }
}

private final class AgentControl: NSObject, HostControlProtocol, @unchecked Sendable {
    @MainActor weak var agent: HostAgent?
    func status(reply: @escaping (Data) -> Void) {
        Task { @MainActor in if let agent { reply(agent.statusData()) } }
    }
    func requestPermission(_ permission: String, reply: @escaping (Data) -> Void) {
        Task { @MainActor in if let agent { reply(await agent.requestPermission(permission)) } }
    }
    func stopSharing(reply: @escaping () -> Void) {
        Task { @MainActor in await agent?.quiesce(); reply() }
    }
}

extension StoredPairings: HostPairings {}
