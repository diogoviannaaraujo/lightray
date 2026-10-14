import AppKit
import ApplicationServices
import CoreGraphics
import LightrayCore
import SystemConfiguration

final class HostSharingController: NSWindowController {
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

    init(executable: URL) {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lightray")
        service = HostService(executable: executable, logURL: logs.appendingPathComponent("host.log"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Share This Mac — Lightray"
        window.isReleasedWhenClosed = false
        window.center()
        buildWindow()
        service.onChange = { [weak self] in
            self?.refresh()
            self?.onStateChange?()
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if self?.window?.isVisible == true { self?.refreshPermissions() }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init(executable:)") }

    private func buildWindow() {
        let defaults = UserDefaults.standard
        let savedPort = defaults.integer(forKey: "sharing.port")
        port.stringValue = savedPort > 0 && savedPort <= 65535 ? String(savedPort) : "7373"
        port.placeholderString = "7373"
        port.setAccessibilityLabel("Sharing port")
        for profile in HostQuality.allCases { quality.addItem(withTitle: profile.title) }
        if let value = defaults.string(forKey: "sharing.quality"),
           let index = HostQuality.allCases.firstIndex(where: { $0.rawValue == value }) { quality.selectItem(at: index) }
        quality.setAccessibilityLabel("Streaming quality")
        allowInput.state = defaults.object(forKey: "sharing.input") == nil || defaults.bool(forKey: "sharing.input") ? .on : .off
        let title = NSTextField(labelWithString: "Share This Mac")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: "Use this Mac from your iPad or another Mac. Sharing stays on while Lightray is open, even when you close this window.")
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
        let actions = NSStackView(views: [startStop, log])
        let settings = NSGridView(views: [
            [NSTextField(labelWithString: "Port"), port],
            [NSTextField(labelWithString: "Quality"), quality],
        ])
        settings.rowSpacing = 10
        settings.columnSpacing = 16
        settings.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [title, explanation, settings, allowInput,
                                        screenRow, inputRow, NSBox.separator(),
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
        screenStatus.stringValue = CGPreflightScreenCaptureAccess() ? "Allowed" : "Required for sharing"
        inputStatus.stringValue = AXIsProcessTrusted() ? "Allowed" : "Required for remote control"
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? ProcessInfo.processInfo.hostName
        address.stringValue = "This Mac: \(name).local:\(port.stringValue)\nYou can also use this Mac’s IP address or Tailscale name."
    }

    private func refresh() {
        refreshPermissions()
        port.isEnabled = !service.isActive
        quality.isEnabled = !service.isActive
        allowInput.isEnabled = !service.isActive
        startStop.title = service.isActive ? "Stop Sharing" : "Start Sharing"
        startStop.isEnabled = service.state != .stopping
        switch service.state {
        case .stopped: status.stringValue = "Sharing is off."
        case .starting: status.stringValue = "Preparing screen capture…"
        case .running: status.stringValue = "Sharing is on. Ready for a paired device to connect."
        case .stopping: status.stringValue = "Stopping sharing…"
        case .failed(let message): status.stringValue = message
        }
    }

    @objc func toggleSharing() {
        if service.isActive { service.stop(); return }
        guard let number = UInt16(port.stringValue), number > 0 else {
            status.stringValue = "Enter a port between 1 and 65535."
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            showWindow(nil)
            status.stringValue = "Allow Lightray in Screen Recording, then start sharing. You may need to quit and reopen the app."
            return
        }
        guard allowInput.state != .on || AXIsProcessTrusted() else {
            showWindow(nil)
            status.stringValue = "Allow Lightray in Accessibility, or turn off keyboard and mouse control for viewing only."
            return
        }
        do { _ = try hostPairing() }
        catch { showError(error); return }
        let profile = HostQuality.allCases[quality.indexOfSelectedItem]
        let defaults = UserDefaults.standard
        defaults.set(Int(number), forKey: "sharing.port")
        defaults.set(profile.rawValue, forKey: "sharing.quality")
        defaults.set(allowInput.state == .on, forKey: "sharing.input")
        service.start(port: number, quality: profile, allowInput: allowInput.state == .on)
    }

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

    @objc private func screenPermission() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        refreshPermissions()
    }

    @objc private func inputPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refreshPermissions()
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
