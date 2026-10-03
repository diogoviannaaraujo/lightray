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
    /// Quits after this many seconds, for scripted runs.
    var exitAfter: Double?
}

/// The client's windows and their glue, on the main thread: a window for each stream that shows a
/// display, and the Displays menu. The runner does the network and the decoding.
final class ClientApp: NSObject, NSApplicationDelegate, @unchecked Sendable {
    let options: ClientOptions
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

    init(options: ClientOptions, pairing: Pairing) {
        self.options = options
        var settings = ClientRunner.Settings(host: options.host, port: options.port, pairing: pairing)
        settings.maxDatagramSize = options.maxDatagramSize
        settings.streams = options.streams
        settings.offerFEC = options.offerFEC
        settings.dropRate = options.dropRate
        runner = ClientRunner(settings: settings)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        _ = window(for: 1)
        NSApp.activate()
        if let seconds = options.exitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
        runner.onEvent = { [unowned self] event in handle(event) }
        if options.snapshot != nil {
            runner.onPicture = { [unowned self] stream, pixels in takeSnapshot(pixels, stream: stream) }
        }
        do {
            try runner.start()
        } catch {
            log("lightray-client: \(error)")
            exit(1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runner.close()
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

    // MARK: The runner's events

    private func handle(_ event: ClientRunner.Event) {
        switch event {
        case .connecting:
            setStatus("connecting")
        case .connected(let streams):
            videoStreams = streams
            restoring = bindings.filter { $0.value != 0 }
            setStatus("connected")
        case .disconnected:
            setStatus("reconnecting")
        case .displays(let list):
            displaysArrived(list)
        case .streamDisplay(let stream, let display):
            streamShows(stream, display)
        case .needsRenderer(let stream):
            runner.attach(window(for: stream).view.renderer, to: stream)
        case .pictureSize(let stream, let size):
            windows[stream]?.resize(to: size)
        case .stats(let lines):
            for (stream, text) in lines { windows[stream]?.status = text }
        }
    }

    // MARK: Windows and displays, on the main thread

    private func window(for stream: UInt8) -> StreamWindow {
        if let window = windows[stream] { return window }
        let window = StreamWindow(stream: stream, hostName: options.host) { [unowned self] message in
            runner.send(message)
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
        if windows.isEmpty { NSApp.terminate(nil) }
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
