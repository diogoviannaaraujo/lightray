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
    /// Quits after this many seconds, for scripted runs.
    var exitAfter: Double?
}

/// The client's windows and their glue. The endpoint, socket and timer live on `queue`, with a
/// decoder for each video stream that has shown something. Windows live on the main thread, one
/// for each stream that shows a display.
final class ClientApp: NSObject, NSApplicationDelegate, @unchecked Sendable {
    let options: ClientOptions
    let pairing: Pairing
    let queue = DispatchQueue(label: "lightray.net", qos: .userInteractive)
    private var endpoint: ClientEndpoint!
    private var socket: UDPSocket!
    private var timer: DispatchSourceTimer!

    // On `queue`.
    private var decoders: [UInt8: StreamDecoder] = [:]
    private var lastDecoded: [UInt8: Int] = [:]
    private var lastBytes = 0
    private var lastReport = monotonicMicros()
    private var lastLogged = monotonicMicros()

    // On the main thread.
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

    init(options: ClientOptions, pairing: Pairing) {
        self.options = options
        self.pairing = pairing
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        _ = window(for: 1)
        NSApp.activate()
        if let seconds = options.exitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
        do {
            try startNetwork()
        } catch {
            log("lightray-client: \(error)")
            exit(1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        queue.sync {
            endpoint?.close(now: monotonicMicros())
            for datagram in endpoint?.takeOutbox() ?? [] { socket.send(datagram, to: endpoint.config.host) }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Lightray (⌃⌥⌘Q)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        appItem.submenu = appMenu
        let displaysItem = NSMenuItem()
        menu.addItem(displaysItem)
        displaysItem.submenu = displaysMenu
        rebuildDisplaysMenu()
        let viewItem = NSMenuItem()
        menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        viewItem.submenu = viewMenu
        NSApp.mainMenu = menu
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
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [unowned self] in pump() }
        log("connecting to \(address) from port \(socket.localPort), with \(options.streams) video streams")
        queue.async { [self] in
            socket.start { [unowned self] datagram, from in
                endpoint.receive(datagram, from: from, now: monotonicMicros())
                pump()
            }
            timer.resume()
            endpoint.start(now: monotonicMicros())
            pump()
        }
    }

    private func pump() {
        let now = monotonicMicros()
        endpoint.tick(now: now)
        for datagram in endpoint.takeOutbox() { socket.send(datagram, to: endpoint.config.host) }
        for event in endpoint.takeEvents() { handle(event) }
        let wake = endpoint.nextWakeup(now: now) ?? now + 1_000_000
        timer.schedule(deadline: .now() + .microseconds(Int(min(wake > now ? wake - now : 0, 1_000_000))), leeway: .microseconds(100))
        report(now: now)
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .connecting:
            onMain { $0.setStatus("connecting") }
        case .connected(let id, let size, let streams):
            let fec = endpoint.session?.fec == true ? "FEC on" : "no FEC"
            log("session \(String(id, radix: 16)) established, datagrams up to \(size) bytes, \(fec), video streams \(streams)")
            onMain { app in
                app.videoStreams = streams
                app.restoring = app.bindings.filter { $0.value != 0 }
                app.setStatus("connected")
            }
        case .disconnected(let reason):
            log("disconnected: \(reason)")
            for decoder in decoders.values { decoder.invalidate() }
            decoders.removeAll()
            onMain { $0.setStatus("reconnecting") }
        case .displays(let list):
            onMain { $0.displaysArrived(list) }
        case .streamDisplay(let stream, let display):
            onMain { $0.streamShows(stream, display) }
        case .frame(let stream, let frame):
            decoder(for: stream).submit(frame)
        }
    }

    private func onMain(_ work: @escaping (ClientApp) -> Void) {
        DispatchQueue.main.async { [self] in work(self) }
    }

    /// The stream's decoder, created at its first frame together with a request for its window.
    private func decoder(for stream: UInt8) -> StreamDecoder {
        if let decoder = decoders[stream] { return decoder }
        let decoder = StreamDecoder(stream: stream)
        decoders[stream] = decoder
        decoder.onResult = { [unowned self] result in
            queue.async { [self] in
                switch result {
                case .picture(_, let id, let isKeyframe):
                    endpoint.decoded(stream: stream, frameID: id, isKeyframe: isKeyframe)
                case .failed(let id, let status):
                    log("stream \(stream): frame \(id) failed to decode (\(status)); asking for a keyframe")
                    endpoint.decoderFailed(stream: stream, frameID: id)
                    pump()
                }
            }
        }
        decoder.onSize = { [unowned self] size in onMain { $0.windows[stream]?.resize(to: size) } }
        if options.snapshot != nil {
            decoder.onPicture = { [unowned self] pixels in takeSnapshot(pixels, stream: stream) }
        }
        onMain { app in decoder.attach(app.window(for: stream).view) }
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
        for (stream, decoder) in decoders {
            let decoded = decoder.decoded
            let fps = Double(decoded - lastDecoded[stream, default: 0]) / seconds
            lastDecoded[stream] = decoded
            let v = session.videos[stream]?.stats ?? VideoReceiverStats()
            status[stream] = String(
                format: "%.0f fps · %.1f Mb/s · RTT %.1f ms · lost %d · keyframes %d · FEC-repaired %d · NACKed %d", fps,
                mbps, Double(c.rtt.smoothed) / 1000, v.framesLost + v.framesUndecodable, v.keyframesDelivered, v.fecRepaired,
                v.nackedFragments)
        }
        onMain { app in
            for (stream, text) in status { app.windows[stream]?.status = text }
        }
        if now >= lastLogged + 5_000_000 {
            lastLogged = now
            for stream in status.keys.sorted() {
                log("stream \(stream): \(status[stream]!) · \(socket.dropped) datagrams dropped on purpose")
            }
        }
    }

    // MARK: Windows and displays, on the main thread

    private func window(for stream: UInt8) -> StreamWindow {
        if let window = windows[stream] { return window }
        let window = StreamWindow(stream: stream, hostName: options.host) { [unowned self] message in
            queue.async { [self] in
                endpoint.send(message, now: monotonicMicros())
                pump()
            }
        }
        window.display = displays.first { $0.id == bindings[stream] }
        window.onUserClose = { [unowned self] stream in userClosed(stream) }
        windows[stream] = window
        return window
    }

    private func setStatus(_ text: String) {
        for window in windows.values { window.status = text }
    }

    private func displaysArrived(_ list: [DisplayInfo]) {
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
        if windows.isEmpty { NSApp.terminate(nil) }
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
