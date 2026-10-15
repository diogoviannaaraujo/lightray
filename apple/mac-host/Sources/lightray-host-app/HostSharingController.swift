import AppKit
import ApplicationServices
import CoreGraphics
import LightrayCore
import LightrayHostSupport
import SystemConfiguration

@MainActor final class HostSharingController: NSWindowController {
    let service: HostService
    var onStateChange: (() -> Void)?
    private let port = NSTextField(string: "7373")
    private let quality = NSPopUpButton()
    private let allowInput = NSButton(checkboxWithTitle: "Allow keyboard and mouse control", target: nil, action: nil)
    private let screenStatus = NSTextField(labelWithString: "")
    private let inputStatus = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "Sharing is off.")
    private let address = NSTextField(wrappingLabelWithString: "")
    private let startStop = NSButton(title: "Start Sharing", target: nil, action: nil)
    private var permissionTimer: Timer?

    init() {
        service = HostService()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Lightray Host — Share This Mac"
        window.isReleasedWhenClosed = false
        window.center()
        buildWindow()
        service.onChange = { [weak self] in
            self?.refresh()
            self?.onStateChange?()
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.window?.isVisible == true { await self?.service.refresh() } }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    private func buildWindow() {
        let saved = service.settings
        port.stringValue = String(saved.port)
        port.placeholderString = "7373"
        port.setAccessibilityLabel("Sharing port")
        for profile in HostQuality.allCases { quality.addItem(withTitle: profile.title) }
        if let index = HostQuality.allCases.firstIndex(of: saved.quality) { quality.selectItem(at: index) }
        quality.setAccessibilityLabel("Streaming quality")
        allowInput.state = saved.allowInput ? .on : .off
        let title = NSTextField(labelWithString: "Share This Mac")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: "Share this Mac with your other devices. Start Sharing enables the background service now and at login. Closing this app keeps sharing on; Stop Sharing keeps it off until you start it again.")
        explanation.textColor = .secondaryLabelColor
        let screenButton = NSButton(title: "Screen Recording…", target: self, action: #selector(screenPermission))
        let inputButton = NSButton(title: "Accessibility…", target: self, action: #selector(inputPermission))
        let screenRow = NSStackView(views: [screenButton, screenStatus])
        let inputRow = NSStackView(views: [inputButton, inputStatus])
        let copy = NSButton(title: "Copy Pairing Code", target: self, action: #selector(copyPairing))
        let export = NSButton(title: "Export Pairing File…", target: self, action: #selector(exportPairing))
        let pairingRow = NSStackView(views: [copy, export])
        let pairingHelp = NSTextField(wrappingLabelWithString: "On your iPad, choose Add computer, enter this Mac’s address, and paste its pairing code. Keep the code private: it authorizes access to this Mac.")
        pairingHelp.textColor = .secondaryLabelColor
        pairingHelp.font = .systemFont(ofSize: 12)
        address.isSelectable = true
        address.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        startStop.target = self
        startStop.action = #selector(toggleSharing)
        startStop.keyEquivalent = "\r"
        let log = NSButton(title: "Show Host Log", target: self, action: #selector(showLog))
        let retry = NSButton(title: "Retry Sharing", target: self, action: #selector(startSharing))
        let background = NSButton(title: "Background Service…", target: self, action: #selector(backgroundSettings))
        let actions = NSStackView(views: [startStop, retry, log])
        let settings = NSGridView(views: [
            [NSTextField(labelWithString: "Port"), port],
            [NSTextField(labelWithString: "Quality"), quality],
        ])
        settings.rowSpacing = 10
        settings.columnSpacing = 16
        settings.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [title, explanation, settings, allowInput,
                                        screenRow, inputRow, background, NSBox.separator(),
                                        address, pairingRow, pairingHelp, NSBox.separator(), actions, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window!.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window!.contentView!.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window!.contentView!.bottomAnchor, constant: -24),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pairingHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            address.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            port.widthAnchor.constraint(equalToConstant: 100),
        ])
    }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func refreshPermissions() {
        screenStatus.stringValue = service.snapshot.screenAllowed ? "Allowed" : "Required for sharing"
        inputStatus.stringValue = service.snapshot.inputAllowed ? "Allowed" : "Required for remote control"
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? ProcessInfo.processInfo.hostName
        address.stringValue = "This Mac: \(name).local:\(port.stringValue)\nYou can also use this Mac’s IP address or Tailscale name."
    }

    private func refresh() {
        refreshPermissions()
        port.isEnabled = !service.isActive && !service.busy
        quality.isEnabled = port.isEnabled
        allowInput.isEnabled = port.isEnabled
        startStop.title = service.isActive ? "Stop Sharing" : "Start Sharing"
        startStop.isEnabled = !service.busy && (service.configurationError == nil || service.isActive)
        status.stringValue = service.snapshot.message
    }

    @objc func toggleSharing() {
        if service.isActive { Task { await service.stop() }; return }
        startSharing()
    }

    @objc private func startSharing() {
        guard !service.busy else { return }
        guard let number = UInt16(port.stringValue), number > 0 else {
            status.stringValue = "Enter a port between 1 and 65535."
            return
        }
        do { _ = try hostPairing() }
        catch { showError(error); return }
        let profile = HostQuality.allCases[quality.indexOfSelectedItem]
        let input = allowInput.state == .on
        Task { await service.start(port: number, quality: profile, allowInput: input) }
    }

    @objc private func backgroundSettings() { service.registration.openSettings() }

    private func hostPairing() throws -> Pairing {
        if FileManager.default.fileExists(atPath: PairingStore.path("host-pairing")) {
            return try PairingStore.read("host-pairing")
        }
        let pairing = Pairing.generate()
        try PairingStore.save(pairing, as: "host-pairing")
        return pairing
    }

    @objc private func copyPairing() {
        do {
            let pairing = try hostPairing()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pairing.token, forType: .string)
            status.stringValue = "Pairing code copied. Paste it into Lightray on your other device."
        } catch { showError(error) }
    }

    @objc private func exportPairing() {
        do {
            let pairing = try hostPairing()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Lightray-pairing.txt"
            panel.beginSheetModal(for: window!) { [weak self] result in
                guard result == .OK, let url = panel.url else { return }
                do {
                    try Data((pairing.token + "\n").utf8).write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } catch { self?.showError(error) }
            }
        } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        status.stringValue = "Could not access this Mac’s pairing: \(error.localizedDescription)"
    }

    @objc private func showLog() {
        if FileManager.default.fileExists(atPath: service.logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([service.logURL])
        } else { status.stringValue = "The host log will be available after starting sharing." }
    }

    @objc private func screenPermission() { Task { await service.requestPermission("screen") } }
    @objc private func inputPermission() { Task { await service.requestPermission("input") } }

}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
