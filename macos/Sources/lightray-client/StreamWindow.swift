import AppKit
import LightrayCore

/// The window that shows one video stream. Its view reports input with the display the stream
/// shows, so that pointer positions land on the right display on the host.
final class StreamWindow: NSObject, NSWindowDelegate {
    let stream: UInt8
    let window: NSWindow
    let view: VideoView
    private let hostName: String
    var display: DisplayInfo? {
        didSet {
            view.displayID = display?.id ?? 0
            updateTitle()
        }
    }
    var status = "connecting" { didSet { updateTitle() } }
    /// Set when the host unbinds the stream, so that closing the window is not read as the user's.
    var closedByHost = false
    var onUserClose: ((UInt8) -> Void)?

    init(stream: UInt8, hostName: String, onInput: @escaping (InputMessage) -> Void) {
        self.stream = stream
        self.hostName = hostName
        view = VideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        window = NSWindow(
            contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.contentView = view
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 420, height: 260)
        window.isReleasedWhenClosed = false
        window.delegate = self
        view.onInput = onInput
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        updateTitle()
    }

    private func updateTitle() {
        window.title = "Lightray — \(display?.name ?? hostName) — \(status)"
    }

    func close() {
        closedByHost = true
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        view.releaseEverything()
        if !closedByHost { onUserClose?(stream) }
    }

    /// The first picture, or one of a new size, fits the window to the video's aspect ratio.
    func resize(to size: CGSize) {
        guard view.videoSize != size else { return }
        view.videoSize = size
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.contentAspectRatio = size
        let scale = screen.backingScaleFactor
        let visible = screen.visibleFrame.size
        var points = CGSize(width: size.width / scale, height: size.height / scale)
        let fit = min(1, visible.width * 0.9 / points.width, visible.height * 0.9 / points.height)
        points = CGSize(width: (points.width * fit).rounded(), height: (points.height * fit).rounded())
        if !window.styleMask.contains(.fullScreen) {
            window.setContentSize(points)
        }
        window.invalidateCursorRects(for: view)
    }
}
