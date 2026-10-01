import AppKit
import CoreImage
import LightrayCore
import LightrayMac
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

/// The client's windows and their glue. The endpoint, socket and timer live on `queue`, with a
/// decoder for each video stream that has shown something. Windows live on the main thread, one
/// for each stream that shows a display.
final class ClientApp: NSObject, NSApplicationDelegate, NSMenuItemValidation, @unchecked Sendable {
    let options: ClientOptions
    let pairing: Pairing
    let queue = DispatchQueue(label: "lightray.net", qos: .userInteractive)
    private var endpoint: ClientEndpoint!
    private var socket: UDPSocket!
    private var timer: DispatchSourceTimer!

    // On `queue`.
    private var sessionRevision: UInt64 = 0
    private var decoders: [UInt8: StreamDecoder] = [:]
    private var lastDecoded: [UInt8: Int] = [:]
    private var lastBytes = 0
    private var lastReport = monotonicMicros()
    private var lastLogged = monotonicMicros()
    private var activities: [UInt8: StreamActivity] = [:]
    private var connectedAt: UInt64 = 0
    private var firstDecodeLogged = Set<UInt8>()

    // On the main thread.
    private var uiSessionRevision: UInt64 = 0
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
    private var running = false

    init(options: ClientOptions, pairing: Pairing) {
        self.options = options
        self.pairing = pairing
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
        try startNetwork()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopSession()
    }

    func stopSession() {
        guard !didStop else { return }
        didStop = true
        for window in windows.values { window.view.releaseEverything() }
        queue.sync {
            running = false
            timer?.cancel()
            endpoint?.close(now: monotonicMicros())
            for datagram in endpoint?.takeOutboundDatagrams() ?? [] { socket?.send(datagram.bytes, to: datagram.destination) }
            for decoder in decoders.values { decoder.invalidate() }
            decoders.removeAll()
            socket?.close()
        }
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

    // MARK: Network

    private func startNetwork() throws {
        let (address, family) = try UDPSocket.resolve(options.host, port: options.port)
        var config = ClientConfig(pairingID: pairing.id, psk: pairing.psk, host: address)
        config.maxDatagramSize = options.maxDatagramSize
        config.videoStreamCount = options.streams
        config.offerFEC = options.offerFEC
        endpoint = ClientEndpoint(config: config, unixTime: unixSeconds)
        socket = try UDPSocket(family: family, queue: queue)
        socket.dropRate = options.dropRate
        for warning in socket.optionWarnings { log("socket: \(warning)") }
        log("socket buffers: receive \(socket.receiveBufferBytes), send \(socket.sendBufferBytes) bytes")
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in self?.pump() }
        log("connecting to \(address) from port \(socket.localPort), with \(options.streams) video streams")
        queue.async { [self] in
            running = true
            socket.start { [weak self] datagram, from in
                guard let self, running else { return }
                endpoint.receive(datagram, from: from, now: monotonicMicros())
                pump()
            }
            timer.resume()
            endpoint.start(now: monotonicMicros())
            pump()
        }
    }

    private func pump() {
        guard running else { return }
        let now = monotonicMicros()
        endpoint.tick(now: now)
        for datagram in endpoint.takeOutboundDatagrams() { socket.send(datagram.bytes, to: datagram.destination) }
        for event in endpoint.takeEvents() { handle(event) }
        let wake = endpoint.nextWakeup(now: now) ?? now + 1_000_000
        timer.schedule(deadline: .now() + .microseconds(Int(min(wake > now ? wake - now : 0, 1_000_000))), leeway: .microseconds(100))
        report(now: now)
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .connecting:
            resetDecoders(status: "connecting")
        case .connected(let id, let size, let streams):
            connectedAt = monotonicMicros()
            let fec = endpoint.session?.fec == true ? "FEC on" : "no FEC"
            log("session \(String(id, radix: 16)) established, datagrams up to \(size) bytes, \(fec), video streams \(streams)")
            onMain { app in
                app.videoStreams = streams
                app.restoring = app.bindings.filter { $0.value != 0 }
                app.setStatus("connected · waiting for video")
                app.onConnectionState?(true)
            }
        case .disconnected(let reason):
            log("disconnected: \(reason)")
            resetDecoders(status: "reconnecting")
            onMain { $0.onConnectionState?(false) }
        case .displays(let list):
            onMain { $0.displaysArrived(list) }
        case .streamDisplay(let stream, let display):
            onMain { $0.streamShows(stream, display) }
        case .frame(let stream, let frame):
            if let lost = decoder(for: stream).submit(frame) {
                endpoint.decoderFailed(stream: stream, frameID: lost)
            }
        }
    }

    private func onMain(_ work: @escaping (ClientApp) -> Void) {
        DispatchQueue.main.async { [self] in if !didStop { work(self) } }
    }

    private func resetDecoders(status: String) {
        sessionRevision &+= 1
        for decoder in decoders.values { decoder.invalidate() }
        decoders.removeAll()
        lastDecoded.removeAll()
        activities.removeAll()
        connectedAt = 0
        firstDecodeLogged.removeAll()
        lastBytes = 0
        lastReport = monotonicMicros()
        let revision = sessionRevision
        onMain { app in
            app.uiSessionRevision = revision
            app.firstPicture.removeAll()
            app.setStatus(status)
        }
    }

    /// The stream's decoder, created at its first frame together with a request for its window.
    private func decoder(for stream: UInt8) -> StreamDecoder {
        if let decoder = decoders[stream] { return decoder }
        let decoder = StreamDecoder(stream: stream)
        let revision = sessionRevision
        decoders[stream] = decoder
        lastDecoded[stream] = 0
        decoder.onResult = { [weak self, weak decoder] result, epoch in
            guard let self, let decoder else { return }
            self.queue.async { [self] in
                guard self.sessionRevision == revision, self.decoders[stream] === decoder, decoder.isCurrent(epoch) else { return }
                switch result {
                case .picture(_, let id, let isKeyframe):
                    if self.firstDecodeLogged.insert(stream).inserted, self.connectedAt != 0 {
                        log("stream \(stream): first_decoded_frame_us=\(monotonicMicros() - self.connectedAt) after_authenticated_connection")
                    }
                    self.endpoint.decoded(stream: stream, frameID: id, isKeyframe: isKeyframe)
                case .failed(let id, let status):
                    log("stream \(stream): frame \(id) failed to decode (\(status)); asking for a keyframe")
                    self.endpoint.decoderFailed(stream: stream, frameID: id)
                    self.pump()
                }
            }
        }
        decoder.onSize = { [weak self, weak decoder] size, epoch in
            self?.onMain { app in
                guard app.uiSessionRevision == revision, decoder?.isCurrent(epoch) == true else { return }
                app.windows[stream]?.resize(to: size)
            }
        }
        if options.snapshot != nil {
            decoder.onPicture = { [weak self, weak decoder] pixels, epoch in
                guard let self, let decoder else { return }
                takeSnapshot(pixels, stream: stream, decoder: decoder, epoch: epoch, revision: revision)
            }
        }
        onMain { app in
            guard app.uiSessionRevision == revision, decoder.isActive else { return }
            decoder.attach(app.window(for: stream).view)
        }
        return decoder
    }

    private func report(now: UInt64) {
        guard now >= lastReport + 1_000_000, let session = endpoint.session else { return }
        let seconds = Double(now - lastReport) / 1_000_000
        lastReport = now
        let c = session.connection
        let mbps = Double(c.stats.bytesReceived - lastBytes) * 8 / seconds / 1_000_000
        lastBytes = c.stats.bytesReceived
        var status: [UInt8: String] = [:]
        var overlays: [UInt8: String] = [:]
        var states: [UInt8: StreamActivity.State] = [:]
        for (stream, decoder) in decoders {
            let decoded = decoder.decoded
            states[stream] = activities[stream, default: StreamActivity()].observe(decodedCount: decoded, now: now)
            let fps = Double(decoded - lastDecoded[stream, default: 0]) / seconds
            lastDecoded[stream] = decoded
            let v = session.videos[stream]?.stats ?? VideoReceiverStats()
            let timings = decoder.takeTimings()
            func ms(_ value: Double?) -> String { value.map { String(format: "%.2f ms", $0) } ?? "—" }
            let rtt = ms(c.rtt.hasSample ? Double(c.rtt.smoothed) / 1000 : nil)
            let decode = ms(timings.meanDecodeMillis), wait = ms(timings.meanQueueMillis)
            let capture = ms(timings.meanCaptureMillis), encode = ms(timings.meanEncodeMillis)
            overlays[stream] = "Capture/convert \(capture) · Encode \(encode)\nNetwork RTT \(rtt)\nDecode \(decode) · Queue \(wait)\n" + String(format: "%.0f decoded FPS · %.1f Mb/s (connection)\nLost %d · Decode drops %d", fps, mbps, v.framesLost + v.framesUndecodable, decoder.dropped)
            status[stream] = String(
                format: "%.0f decoded fps · %.1f connection Mb/s · RTT %.1f ms · lost %d · keyframes %d · FEC-repaired %d · NACKed %d", fps,
                mbps, Double(c.rtt.smoothed) / 1000, v.framesLost + v.framesUndecodable, v.keyframesDelivered, v.fecRepaired,
                v.nackedFragments)
            status[stream]! += " · capture/convert \(capture) · encode \(encode) · decode \(decode) · decode wait \(wait)"
            if let sample = timings.lastHostSample {
                status[stream]! += " · host sample \(sample.sampleID) capture_us \(sample.captureMicros) encode_us \(sample.encodeMicros)"
            }
        }
        onMain { app in
            for (stream, text) in status {
                app.windows[stream]?.status = text
                app.windows[stream]?.view.statisticsText = overlays[stream] ?? "Waiting for measurements…"
                if let state = states[stream] { app.windows[stream]?.view.streamState = state }
            }
        }
        if now >= lastLogged + 5_000_000 {
            lastLogged = now
            for stream in status.keys.sorted() {
                log("stream \(stream): \(status[stream]!) · decode queue drops \(decoders[stream]?.dropped ?? 0) · send errors \(socket.sendFailures) · receive errors \(socket.receiveFailures) · \(socket.dropped) datagrams dropped on purpose")
            }
        }
    }

    // MARK: Windows and displays, on the main thread

    private func window(for stream: UInt8) -> StreamWindow {
        if let window = windows[stream] { return window }
        let window = StreamWindow(stream: stream, hostName: options.host) { [unowned self] message in
            queue.async { [self] in
                guard running else { return }
                endpoint.send(message, now: monotonicMicros())
                pump()
            }
        }
        if let screenID = options.screenID, let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screenID }) {
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
            queue.async { [self] in decoders.removeValue(forKey: stream)?.invalidate() }
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
        queue.async { [self] in
            endpoint.selectDisplay(0, on: stream)
            decoders.removeValue(forKey: stream)?.invalidate()
            pump()
        }
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
        queue.async { [self] in
            endpoint.selectDisplay(display, on: stream)
            pump()
        }
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
    private func takeSnapshot(_ pixels: CVPixelBuffer, stream: UInt8, decoder: StreamDecoder, epoch: UInt64, revision: UInt64) {
        let now = monotonicMicros()
        let ready: Bool = DispatchQueue.main.sync {
            guard uiSessionRevision == revision, decoder.isCurrent(epoch), !snapshotsTaken.contains(stream) else { return false }
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
