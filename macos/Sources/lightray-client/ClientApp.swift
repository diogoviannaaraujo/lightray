import AppKit
import CoreImage
import LightrayCore
import UniformTypeIdentifiers

struct ClientOptions {
    var host = ""
    var port: UInt16 = 7373
    var maxDatagramSize = 1200
    var dropRate = 0.0
    /// How many displays can be shown at once: one video stream each.
    var streams = 4
    /// Show every display of the host once the list arrives.
    var allDisplays = false
    /// Displays to show at start, by the host's `display_id`, one stream each in table order.
    var show: [UInt32] = []
    /// Writes each stream's picture to a PNG 3 seconds after its first one: this path for the first
    /// stream, and this path with `-<stream>` before the extension for the others.
    var snapshot: String?
    /// Offer FEC to the host.
    var offerFEC = true
    /// Use a local pointer when the host does not composite the hardware cursor.
    var localCursor: Bool?
    var screenID: UInt32?
    var showStatistics: Bool?
    var keyboardMapping: RemoteKeyboard.Mapping?
    var rememberPreferences = true
    var launcher = false
    var rememberHosts = true
    /// Quits after this many seconds, for scripted runs.
    var exitAfter: Double?
}

/// The client's windows and their glue, on the main thread: a window for each stream that shows a
/// display, the menus, and the session's preferences. The runner does the network and the
/// decoding.
final class ClientApp: NSObject, NSApplicationDelegate, NSMenuItemValidation, @unchecked Sendable {
    let options: ClientOptions
    let pairing: Pairing
    private let runner: ClientRunner

    private var windows: [UInt8: StreamWindow] = [:]
    private var videoStreams: [UInt8] = [1]
    private var bindings: [UInt8: UInt32] = [:]
    private var displays: [DisplayInfo] = []
    /// Displays asked for and not yet confirmed, including those asked for again after a
    /// reconnection; and whether `--all-displays` has run.
    private var restoring: [UInt8: UInt32] = [:]
    private var showedAll = false
    private let displaysMenu = NSMenu(title: "Displays")
    private var snapshotsTaken = Set<UInt8>()
    private var firstPicture: [UInt8: UInt64] = [:]
    private let preferencesStore = SessionPreferencesStore()
    private var preferences = SessionPreferences()
    var onReturnToComputers: (() -> Void)?
    var onConnectionState: ((Bool) -> Void)?
    private var didStop = false

    init(options: ClientOptions, pairing: Pairing) {
        self.options = options
        self.pairing = pairing
        var settings = ClientRunner.Settings(host: options.host, port: options.port, pairing: pairing)
        settings.maxDatagramSize = options.maxDatagramSize
        settings.streams = options.streams
        settings.offerFEC = options.offerFEC
        settings.dropRate = options.dropRate
        runner = ClientRunner(settings: settings)
        super.init()
        if options.rememberPreferences {
            do { preferences = try preferencesStore.load(hostID: pairing.id) }
            catch { log("Cannot load session preferences; using defaults: \(error)") }
        }
        if let mapping = options.keyboardMapping { preferences.keyboardMapping = mapping }
        if let statistics = options.showStatistics { preferences.showStatistics = statistics }
        if let cursor = options.localCursor { preferences.localCursor = cursor }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try launch() }
        catch { log("lightray-client: \(error)"); exit(1) }
    }

    func launch() throws {
        buildMenu()
        _ = window(for: 1)
        NSApp.activate()
        if let seconds = options.exitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
        runner.onEvent = { [weak self] event in self?.handle(event) }
        if options.snapshot != nil {
            runner.onPicture = { [weak self] stream, pixels in self?.takeSnapshot(pixels, stream: stream) }
        }
        try runner.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopSession()
    }

    /// Ends the session, telling the host, and closes its windows.
    func stopSession() {
        guard !didStop else { return }
        didStop = true
        for window in windows.values { window.view.releaseEverything() }
        runner.stop()
        for window in Array(windows.values) { window.close() }
        windows.removeAll()
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Lightray (⌃⌥⌘Q)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        if onReturnToComputers != nil {
            let computers = appMenu.addItem(withTitle: "Disconnect and Show Computers", action: #selector(returnToComputers(_:)), keyEquivalent: "")
            computers.target = self
        }
        appItem.submenu = appMenu
        let displaysItem = NSMenuItem()
        menu.addItem(displaysItem)
        displaysItem.submenu = displaysMenu
        rebuildDisplaysMenu()
        let viewItem = NSMenuItem()
        menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let controls = viewMenu.addItem(withTitle: "Session Menu (⌃⌥⌘S)", action: #selector(showSessionMenu(_:)), keyEquivalent: "")
        controls.target = self
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        let stats = viewMenu.addItem(withTitle: "Show Statistics (⌃⌥⌘M)", action: #selector(toggleStatistics(_:)), keyEquivalent: "")
        stats.target = self
        viewItem.submenu = viewMenu
        let inputItem = NSMenuItem()
        menu.addItem(inputItem)
        let inputMenu = NSMenu(title: "Input")
        for (title, action) in [
            ("Swap Command and Control", #selector(toggleKeyboardMapping(_:))),
            ("Release Input (⌃⌥⌘Esc)", #selector(releaseInput(_:))),
            ("Resume Input", #selector(resumeInput(_:))),
            ("Send Alt+Tab (⌃⌥⌘Tab)", #selector(sendAltTab(_:))),
            ("Send Windows Key (⌃⌥⌘W)", #selector(sendWindowsKey(_:))),
            ("Send Ctrl+Esc", #selector(sendControlEscape(_:))),
        ] {
            let item = inputMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        inputItem.submenu = inputMenu
        NSApp.mainMenu = menu
    }

    private var focusedWindow: StreamWindow? {
        windows.values.first { $0.window.isKeyWindow } ?? windows.values.first { $0.window.isMainWindow }
    }

    private func updatePreferences(_ preferences: SessionPreferences) {
        self.preferences = preferences
        for window in windows.values { window.view.applyPreferences(preferences) }
        if options.rememberPreferences {
            do { try preferencesStore.save(preferences, hostID: pairing.id) }
            catch { log("Cannot save session preferences: \(error)") }
        }
    }
    private func resetPreferences() {
        if options.rememberPreferences { preferencesStore.reset(hostID: pairing.id) }
        updatePreferences(SessionPreferences())
    }
    @objc private func showSessionMenu(_ sender: Any?) { focusedWindow?.view.toggleSessionMenu() }
    @objc private func returnToComputers(_ sender: Any?) { stopSession(); onReturnToComputers?() }
    @objc private func toggleStatistics(_ sender: Any?) {
        var updated = preferences
        updated.showStatistics = !updated.showStatistics
        updatePreferences(updated)
    }
    @objc private func toggleKeyboardMapping(_ sender: Any?) {
        var updated = preferences
        updated.keyboardMapping = updated.keyboardMapping == .physical ? .commandControl : .physical
        updatePreferences(updated)
    }
    @objc private func releaseInput(_ sender: Any?) { focusedWindow?.view.setInputEnabled(false) }
    @objc private func resumeInput(_ sender: Any?) { focusedWindow?.view.setInputEnabled(true) }
    @objc private func sendAltTab(_ sender: Any?) { focusedWindow?.view.sendShortcut(.altTab) }
    @objc private func sendWindowsKey(_ sender: Any?) { focusedWindow?.view.sendShortcut(.windowsKey) }
    @objc private func sendControlEscape(_ sender: Any?) { focusedWindow?.view.sendShortcut(.controlEscape) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let view = focusedWindow?.view else { return false }
        if menuItem.action == #selector(toggleStatistics(_:)) { menuItem.state = view.statisticsVisible ? .on : .off }
        if menuItem.action == #selector(toggleKeyboardMapping(_:)) { menuItem.state = view.keyboardMapping == .commandControl ? .on : .off }
        if menuItem.action == #selector(resumeInput(_:)) { return !view.inputEnabled && view.streamState == .live }
        if menuItem.action == #selector(releaseInput(_:)) { return view.canSendInput }
        if [#selector(sendAltTab(_:)), #selector(sendWindowsKey(_:)), #selector(sendControlEscape(_:))].contains(menuItem.action) { return view.canSendInput }
        return true
    }

    // MARK: The runner's events

    private func handle(_ event: ClientRunner.Event) {
        switch event {
        case .connecting:
            firstPicture.removeAll()
            setStatus("connecting")
        case .connected(let streams):
            videoStreams = streams
            restoring = bindings.filter { $0.value != 0 }
            setStatus("connected · waiting for video")
            onConnectionState?(true)
        case .disconnected:
            firstPicture.removeAll()
            setStatus("reconnecting")
            onConnectionState?(false)
        case .displays(let list):
            displaysArrived(list)
        case .streamDisplay(let stream, let display):
            streamShows(stream, display)
        case .needsRenderer(let stream):
            runner.attach(window(for: stream).view.renderer, to: stream)
        case .pictureSize(let stream, let size):
            windows[stream]?.resize(to: size)
        case .stats(let reports):
            for (stream, report) in reports {
                windows[stream]?.status = report.status
                windows[stream]?.view.statisticsText = report.overlay
                windows[stream]?.view.streamState = report.state
            }
        }
    }

    // MARK: Windows and displays, on the main thread

    private func window(for stream: UInt8) -> StreamWindow {
        if let window = windows[stream] { return window }
        let window = StreamWindow(stream: stream, hostName: options.host) { [unowned self] message in
            runner.send(message)
        }
        if let screenID = options.screenID, let screen = NSScreen.screens.first(where: { $0.cgDirectDisplayID == screenID }) {
            window.window.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - window.window.frame.width / 2, y: screen.visibleFrame.midY - window.window.frame.height / 2))
            log("stream \(stream): presentation screen id=\(screenID) max_fps=\(screen.maximumFramesPerSecond)")
        }
        window.view.applyPreferences(preferences)
        window.view.onPreferencesChange = { [weak self] in self?.updatePreferences($0) }
        window.view.onResetPreferences = { [weak self] in self?.resetPreferences() }
        window.view.onDisconnect = { [weak self] in
            guard let self else { return }
            if onReturnToComputers != nil { returnToComputers(nil) } else { NSApp.terminate(nil) }
        }
        window.view.onHotkey = { [weak self, weak window] action in
            guard let self, let window else { return }
            switch action {
            case .quit: NSApp.terminate(nil)
            case .statistics: self.toggleStatistics(nil)
            case .releaseInput: window.view.setInputEnabled(false)
            case .fullScreen: window.window.toggleFullScreen(nil)
            case .altTab: window.view.sendShortcut(.altTab)
            case .windowsKey: window.view.sendShortcut(.windowsKey)
            case .sessionMenu: window.view.toggleSessionMenu()
            }
        }
        window.display = displays.first { $0.id == bindings[stream] }
        window.onUserClose = { [unowned self] stream in userClosed(stream) }
        windows[stream] = window
        return window
    }

    private func setStatus(_ text: String) {
        for window in windows.values {
            window.status = text
            window.view.releaseEverything()
            window.view.statisticsText = text
            window.view.streamState = .waiting
        }
    }

    private func displaysArrived(_ list: [DisplayInfo]) {
        for display in list { log("display id=\(display.id) native=\(display.width)x\(display.height) refresh_millihertz=\(display.refreshMillihertz)") }
        displays = list
        for (stream, window) in windows { window.display = list.first { $0.id == bindings[stream] } }
        // After a reconnection, ask again for what each stream showed; the host has only bound
        // the first stream to its primary display.
        restoring = restoring.filter { _, display in list.contains { $0.id == display } }
        for (stream, display) in restoring { select(display, on: stream) }
        if !options.show.isEmpty, !showedAll {
            showedAll = true
            for (stream, id) in zip(videoStreams, options.show) where list.contains(where: { $0.id == id }) {
                select(id, on: stream)
            }
        }
        if options.allDisplays, !showedAll {
            showedAll = true
            let primary = list.first(where: \.isPrimary)?.id
            for display in list where display.id != primary {
                guard let stream = freeStream(excluding: [videoStreams.first ?? 1]) else { break }
                select(display.id, on: stream)
            }
        }
        rebuildDisplaysMenu()
    }

    private func streamShows(_ stream: UInt8, _ display: UInt32) {
        let wanted = restoring[stream]
        let previous = bindings[stream] ?? 0
        if wanted == display { restoring[stream] = nil }
        bindings[stream] = display
        defer { rebuildDisplaysMenu() }
        if display == 0 {
            windows[stream]?.view.streamState = .waiting
            // A stream with a request on its way keeps its window until the answer.
            guard wanted == nil, let window = windows[stream] else { return }
            log("stream \(stream): the host stopped showing \(window.display?.name ?? "its display")")
            runner.stopDecoding(stream)
            if windows.count == 1 {
                // The last window stays, so that the client does not seem to quit. If its display
                // went away (a Screen Sharing session that ends takes its virtual display with
                // it), the window moves to the primary display, as a new session would start.
                window.display = nil
                if previous != 0, !displays.contains(where: { $0.id == previous }),
                    let primary = displays.first(where: \.isPrimary) ?? displays.first
                {
                    log("stream \(stream): showing \(primary.name) instead")
                    window.status = "switching to \(primary.name)"
                    select(primary.id, on: stream)
                } else {
                    window.status = "no display: choose one from the Displays menu"
                }
                return
            }
            windows[stream] = nil
            window.close()
            return
        }
        window(for: stream).display = displays.first { $0.id == display }
    }

    private func userClosed(_ stream: UInt8) {
        windows[stream] = nil
        bindings[stream] = 0
        restoring[stream] = nil
        runner.selectDisplay(0, on: stream)
        if windows.isEmpty {
            if onReturnToComputers != nil { returnToComputers(nil) } else { NSApp.terminate(nil) }
        }
        rebuildDisplaysMenu()
    }

    /// A stream that shows nothing and has no request on its way.
    private func freeStream(excluding: Set<UInt8> = []) -> UInt8? {
        videoStreams.first { (bindings[$0] ?? 0) == 0 && restoring[$0] == nil && !excluding.contains($0) }
    }

    private func select(_ display: UInt32, on stream: UInt8) {
        restoring[stream] = display
        runner.selectDisplay(display, on: stream)
    }

    private func rebuildDisplaysMenu() {
        displaysMenu.removeAllItems()
        guard !displays.isEmpty else {
            displaysMenu.addItem(withTitle: "No displays yet", action: nil, keyEquivalent: "")
            return
        }
        for display in displays {
            let shown = bindings.values.contains(display.id)
            let item = NSMenuItem(
                title: "\(shown ? "Go to" : "Show") \(display.name) (\(display.width)×\(display.height))",
                action: #selector(showDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: display.id)
            displaysMenu.addItem(item)
        }
        displaysMenu.addItem(.separator())
        let switchItem = NSMenuItem(title: "Switch This Window To", action: nil, keyEquivalent: "")
        let switchMenu = NSMenu()
        for display in displays {
            let item = NSMenuItem(title: display.name, action: #selector(switchWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: display.id)
            switchMenu.addItem(item)
        }
        switchItem.submenu = switchMenu
        displaysMenu.addItem(switchItem)
    }

    /// Brings forward the window showing the display, or opens one on a free stream.
    @objc private func showDisplay(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        if let stream = bindings.first(where: { $0.value == id })?.key, let window = windows[stream] {
            window.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let stream = freeStream() else {
            log("every video stream is in use; close a window first")
            NSSound.beep()
            return
        }
        select(id, on: stream)
    }

    @objc private func switchWindow(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value,
            let key = windows.values.first(where: { $0.window.isKeyWindow }) ?? windows.values.first
        else { return }
        select(id, on: key.stream)
    }

    // MARK: Snapshots

    /// Runs on the stream's decode queue.
    private func takeSnapshot(_ pixels: CVPixelBuffer, stream: UInt8) {
        let now = monotonicMicros()
        let ready: Bool = DispatchQueue.main.sync {
            guard !snapshotsTaken.contains(stream) else { return false }
            let first = firstPicture[stream] ?? now
            firstPicture[stream] = first
            guard now >= first + 3_000_000 else { return false }
            snapshotsTaken.insert(stream)
            return true
        }
        guard ready, var path = options.snapshot else { return }
        if stream != 1 {
            let url = URL(fileURLWithPath: path)
            path = url.deletingPathExtension().path + "-\(stream)." + (url.pathExtension.isEmpty ? "png" : url.pathExtension)
        }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent),
            let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, cgImage, nil)
        log(CGImageDestinationFinalize(destination) ? "snapshot of stream \(stream) written to \(path)" : "snapshot failed")
    }
}
