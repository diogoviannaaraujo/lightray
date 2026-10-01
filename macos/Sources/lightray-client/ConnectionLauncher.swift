import AppKit
import CoreGraphics
import LightrayMac

/// Owns one session at a time and keeps the computer list available after disconnect.
final class ConnectionLauncher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var client: ClientApp?
    private let options: ClientOptions
    private let store = PairedHostsStore()
    private var hosts: [PairedHost] = []
    private var pairing: Pairing?
    private var selectedPairingID: UInt64?
    private var catalogError = false
    private var connectionAttempt: UInt64 = 0
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    private let computers = NSPopUpButton()
    private let name = NSTextField(string: "")
    private let address = NSTextField(string: "")
    private let screen = NSPopUpButton()
    private let remember = NSButton(checkboxWithTitle: "Remember this computer", target: nil, action: nil)
    private let forget = NSButton(title: "Forget selected computer", target: nil, action: nil)
    private let pairingStatus = NSTextField(labelWithString: "Import a pairing file to authorize the connection.")
    private let status = NSTextField(wrappingLabelWithString: "Availability is checked when you connect.")
    private var screens: [NSScreen] = []

    init(options: ClientOptions, pairing: Pairing?) {
        self.options = options
        self.pairing = pairing
        super.init()
        if options.rememberHosts {
            do { hosts = try store.load() }
            catch { catalogError = true }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        showComputers()
        if !options.host.isEmpty {
            name.stringValue = "Windows host"
            address.stringValue = options.host.contains(":") ? "[\(options.host)]:\(options.port)" : "\(options.host):\(options.port)"
        }
        if pairing != nil { pairingStatus.stringValue = "Pairing ready for this connection." }
        if let seconds = options.exitAfter { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) } }
    }

    private func buildWindow() {
        window.title = "Lightray — Computers"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let title = NSTextField(labelWithString: "Lightray")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = NSColor(calibratedRed: 0.15, green: 0.76, blue: 0.86, alpha: 1)
        let subtitle = NSTextField(labelWithString: "Your remote desktop, with your settings.")
        subtitle.textColor = .secondaryLabelColor
        name.placeholderString = "Computer name"
        address.placeholderString = "Address or hostname:port"
        name.setAccessibilityLabel("Computer name")
        address.setAccessibilityLabel("Host address")
        computers.setAccessibilityLabel("Paired computers")
        screen.setAccessibilityLabel("Local display")
        computers.target = self; computers.action = #selector(selectComputer)
        refreshScreens()
        if let wanted = options.screenID, let index = screens.firstIndex(where: { displayID($0) == wanted }) { screen.selectItem(at: index) }
        remember.state = options.rememberHosts ? .on : .off
        remember.isEnabled = options.rememberHosts && !catalogError
        let importButton = NSButton(title: "Import pairing file…", target: self, action: #selector(importPairing))
        forget.target = self; forget.action = #selector(forgetComputer)
        let connect = NSButton(title: "Connect", target: self, action: #selector(connectComputer))
        connect.keyEquivalent = "\r"
        pairingStatus.font = .systemFont(ofSize: 12)
        pairingStatus.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, subtitle, NSTextField(labelWithString: "Computers"), computers, name, address, NSTextField(labelWithString: "Open the session on"), screen, importButton, pairingStatus, remember, connect, forget, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            computers.widthAnchor.constraint(equalTo: stack.widthAnchor),
            name.widthAnchor.constraint(equalTo: stack.widthAnchor),
            address.widthAnchor.constraint(equalTo: stack.widthAnchor),
            screen.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        refreshComputers()
        if catalogError { status.stringValue = "The saved computer list could not be loaded. You can connect without saving; the existing list will be preserved." }
        placeWindow()
    }

    private func refreshComputers() {
        computers.removeAllItems()
        computers.addItem(withTitle: "New computer")
        for host in hosts { computers.addItem(withTitle: host.name) }
        forget.isEnabled = false
    }

    private func refreshScreens() {
        let previous = selectedScreen.flatMap(displayUUID)
        screens = NSScreen.screens
        screen.removeAllItems()
        for item in screens { screen.addItem(withTitle: "\(item.localizedName) · up to \(item.maximumFramesPerSecond) FPS") }
        if let previous, let index = screens.firstIndex(where: { displayUUID($0) == previous }) { screen.selectItem(at: index) }
        else if previous != nil { status.stringValue = "The selected display was disconnected. Using the available display shown below." }
    }

    private func displayID(_ value: NSScreen) -> UInt32? { (value.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
    private func displayUUID(_ value: NSScreen) -> String? {
        guard let id = displayID(value), let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    private var selectedScreen: NSScreen? { screens.indices.contains(screen.indexOfSelectedItem) ? screens[screen.indexOfSelectedItem] : nil }
    private func placeWindow() {
        if let selectedScreen {
            let frame = selectedScreen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        } else { window.center() }
    }

    private func showComputers() {
        refreshScreens()
        let menu = NSMenu()
        let app = NSMenuItem(); menu.addItem(app)
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Lightray", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = submenu
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        menu.addItem(edit)
        let editing = NSMenu(title: "Edit")
        editing.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editing.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editing.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editing.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editing
        NSApp.mainMenu = menu
        placeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func selectComputer() {
        pairing = nil
        selectedPairingID = nil
        forget.isEnabled = false
        guard computers.indexOfSelectedItem > 0 else {
            name.stringValue = ""; address.stringValue = ""
            pairingStatus.stringValue = "Import a pairing file to authorize the connection."
            return
        }
        let host = hosts[computers.indexOfSelectedItem - 1]
        name.stringValue = host.name; address.stringValue = host.address
        selectedPairingID = host.pairingID
        forget.isEnabled = options.rememberHosts && !catalogError
        if let uuid = host.displayUUID, let index = screens.firstIndex(where: { displayUUID($0) == uuid }) { screen.selectItem(at: index) }
        else if host.displayUUID != nil { status.stringValue = "The saved display is unavailable. Select a display for this session." }
        do {
            let saved = try PairingStore.read(host.pairingFileName)
            guard saved.id == host.pairingID else { throw PairingStore.StoreError.invalidPairing }
            pairing = saved
            pairingStatus.stringValue = "Saved pairing ready."
        } catch { pairingStatus.stringValue = "Saved pairing is missing or invalid. Import it again." }
    }

    @objc private func importPairing() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Import pairing"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let self, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 1024, let text = String(data: data, encoding: .utf8), let imported = Pairing(token: text) else { throw PairingStore.StoreError.invalidPairing }
                self.pairing = imported
                self.pairingStatus.stringValue = "Pairing imported. Its contents are not shown or logged."
            } catch { self.pairingStatus.stringValue = "Could not import a valid pairing file." }
        }
    }

    @objc private func connectComputer() {
        guard let pairing else { status.stringValue = "Import or select a valid pairing first."; return }
        do {
            let target = try ConnectionTarget(address.stringValue)
            refreshScreens()
            var sessionOptions = options
            sessionOptions.host = target.host; sessionOptions.port = target.port
            sessionOptions.screenID = selectedScreen.flatMap(displayID)
            sessionOptions.exitAfter = nil
            if remember.state == .on {
                let host = PairedHost(pairingID: pairing.id, name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), address: target.address, displayUUID: selectedScreen.flatMap(displayUUID))
                var updated = hosts.filter { $0.pairingID != host.pairingID }
                updated.append(host)
                // Validate public metadata before saving private pairing material.
                try store.validate(updated)
                try PairingStore.save(pairing, as: host.pairingFileName)
                try store.save(updated)
                hosts = updated
                refreshComputers()
                selectedPairingID = host.pairingID
                computers.selectItem(at: hosts.count)
                forget.isEnabled = true
            }
            let session = ClientApp(options: sessionOptions, pairing: pairing)
            session.onReturnToComputers = { [weak self] in
                self?.connectionAttempt &+= 1
                self?.client = nil
                self?.status.stringValue = "Disconnected. Ready for another connection."
                self?.showComputers()
            }
            var wasConnected = false
            session.onConnectionState = { [weak self, weak session] connected in
                guard let self, let session, self.client === session else { return }
                if connected {
                    wasConnected = true
                    self.connectionAttempt &+= 1
                } else if wasConnected {
                    wasConnected = false
                    self.scheduleConnectionDeadline(session)
                }
            }
            client = session
            scheduleConnectionDeadline(session)
            do { try session.launch() }
            catch { session.stopSession(); client = nil; showComputers(); throw error }
            window.orderOut(nil)
        } catch ConnectionTarget.ParseError.invalidPort { status.stringValue = "Use a port between 1 and 65535, for example 192.168.1.2:7373." }
        catch ConnectionTarget.ParseError.invalidHost { status.stringValue = "Enter an IP address or hostname, without a URL or spaces." }
        catch PairedHostsStore.StoreError.invalidRecord { status.stringValue = "Use a computer name of 1–100 bytes and keep at most 32 saved computers." }
        catch { status.stringValue = "Connection could not start. Check the hostname and network, or import the pairing again." }
    }

    private func scheduleConnectionDeadline(_ session: ClientApp) {
        connectionAttempt &+= 1
        let attempt = connectionAttempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak session] in
            guard let self, let session, self.connectionAttempt == attempt, self.client === session else { return }
            self.connectionAttempt &+= 1
            session.stopSession()
            self.client = nil
            self.status.stringValue = "No connection after 12 seconds. Check that the host is running, the address is reachable and the pairing matches, then try again."
            self.showComputers()
        }
    }

    @objc private func forgetComputer() {
        guard !catalogError, options.rememberHosts, let selectedPairingID, let host = hosts.first(where: { $0.pairingID == selectedPairingID }) else { return }
        do {
            let updated = hosts.filter { $0.pairingID != selectedPairingID }
            try PairingStore.remove(host.pairingFileName)
            try store.save(updated)
            hosts = updated; refreshComputers(); selectComputer()
            status.stringValue = "Computer forgotten on this Mac. Host-side access must be revoked separately."
        } catch { status.stringValue = "The computer could not be removed. The saved list was preserved." }
    }

    func applicationWillTerminate(_ notification: Notification) { client?.stopSession() }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
