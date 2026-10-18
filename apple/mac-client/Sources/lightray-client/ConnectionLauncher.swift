import AppKit
import CoreGraphics
import LightrayCore
import SwiftUI

/// Owns one session at a time and keeps the SwiftUI host library available after disconnect.
@MainActor final class ConnectionLauncher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var configureApplicationMenu: ((NSMenu) -> Void)?
    var keepsRunningAfterWindowClose = false
    private var client: ClientApp?
    private let options: ClientOptions
    private let initialPairing: Pairing?
    private let model: HostLibraryModel
    private var connectionAttempt: UInt64 = 0
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)

    init(options: ClientOptions, pairing: Pairing?) {
        self.options = options
        initialPairing = pairing
        model = HostLibraryModel(options: options)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Lightray"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: HostsView(model: model) { [weak self] host in
            self?.connect(host)
        })
        window.setContentSize(NSSize(width: 700, height: 520))
        NotificationCenter.default.addObserver(self, selector: #selector(refreshScreens),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        showComputers()
        if !options.host.isEmpty || initialPairing != nil {
            let address = options.host.isEmpty ? "" : "\(options.host.contains(":") ? "[\(options.host)]" : options.host):\(options.port)"
            model.addHost(address: address, pairing: initialPairing)
        }
        if let seconds = options.exitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.model.draft = nil
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    @objc private func refreshScreens() {
        model.updateDisplays(NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            return LocalDisplay(id: id, uuid: uuid.map { CFUUIDCreateString(nil, $0) as String },
                                name: screen.localizedName, maximumFramesPerSecond: screen.maximumFramesPerSecond)
        })
    }

    private func showComputers() {
        refreshScreens()
        let menu = NSMenu()
        let app = NSMenuItem(); menu.addItem(app)
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Lightray", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = submenu
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let add = fileMenu.addItem(withTitle: "Add Host…", action: #selector(addHost), keyEquivalent: "n")
        add.target = self
        file.submenu = fileMenu
        menu.addItem(file)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        menu.addItem(edit)
        let editing = NSMenu(title: "Edit")
        editing.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editing.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editing.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editing.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editing
        configureApplicationMenu?(menu)
        NSApp.mainMenu = menu
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func addHost() {
        if model.draft == nil { model.addHost() }
    }

    private func connect(_ host: PairedHost) {
        refreshScreens()
        guard let connection = model.connection(for: host) else { return }
        var sessionOptions = options
        sessionOptions.host = connection.target.host
        sessionOptions.port = connection.target.port
        sessionOptions.screenID = connection.displayID
        sessionOptions.exitAfter = nil
        let session = ClientApp(options: sessionOptions, pairing: connection.pairing)
        session.configureApplicationMenu = configureApplicationMenu
        session.onReturnToComputers = { [weak self] in
            self?.connectionAttempt &+= 1
            self?.client = nil
            self?.model.notice = "Disconnected. Ready for another connection."
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
        do {
            try session.launch()
            window.orderOut(nil)
        } catch {
            connectionAttempt &+= 1
            session.stopSession()
            client = nil
            model.notice = "Connection could not start. Check the hostname and network, or edit the host to import its pairing again."
            showComputers()
        }
    }

    private func scheduleConnectionDeadline(_ session: ClientApp) {
        connectionAttempt &+= 1
        let attempt = connectionAttempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak session] in
            guard let self, let session, self.connectionAttempt == attempt, self.client === session else { return }
            self.connectionAttempt &+= 1
            session.stopSession()
            self.client = nil
            self.model.notice = "No connection after 12 seconds. Check that the host is running, the address is reachable and the pairing matches, then try again."
            self.showComputers()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { client?.stopSession() }
    func windowWillClose(_ notification: Notification) {
        if !keepsRunningAfterWindowClose { NSApp.terminate(nil) }
    }

    func reopen() {
        if let client { client.showWindows() }
        else { showComputers() }
    }
}
