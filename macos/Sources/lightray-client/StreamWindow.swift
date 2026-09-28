import AVFoundation
import AppKit
import LightrayCore
import LightrayMac

/// Decoding for one video stream, on a queue of its own. It is created on the network queue the
/// moment its stream delivers a frame, so that no frame waits for a window; the picture reaches
/// the window's view once there is one.
///
/// Frames that arrive in a burst, after a Wi-Fi stall say, are all decoded, since each refers to
/// the one before, but only the newest is shown: the window catches up at once instead of
/// replaying the stall.
final class StreamDecoder: @unchecked Sendable {
    let stream: UInt8
    let queue: DispatchQueue
    private let decoder = VideoDecoder()
    private let lock = NSLock()
    private var decodedCount = 0
    private var waiting = 0

    // On `queue`.
    private var view: VideoView?
    private var pending: CVPixelBuffer?
    private var size: CGSize?
    /// Called on `queue` with each result, to report it to the endpoint.
    var onResult: ((VideoDecoder.Result) -> Void)?
    /// Called on `queue` when the picture's size changes.
    var onSize: ((CGSize) -> Void)?
    /// Called on `queue` with each picture.
    var onPicture: ((CVPixelBuffer) -> Void)?

    init(stream: UInt8) {
        self.stream = stream
        queue = DispatchQueue(label: "lightray.decode.\(stream)", qos: .userInteractive)
    }

    var decoded: Int { lock.withLock { decodedCount } }

    func submit(_ frame: DeliveredFrame) {
        lock.withLock { waiting += 1 }
        queue.async { [self] in decode(frame) }
    }

    func attach(_ view: VideoView) {
        queue.async { [self] in
            self.view = view
            if let pending { view.enqueue(pending) }
            pending = nil
        }
    }

    func invalidate() {
        queue.async { [self] in
            decoder.invalidate()
            view = nil
        }
    }

    private func decode(_ frame: DeliveredFrame) {
        let result = decoder.decode(frame)
        let newerWaiting = lock.withLock {
            waiting -= 1
            return waiting > 0
        }
        if case .picture(let pixels, _, _) = result {
            lock.withLock { decodedCount += 1 }
            if let view {
                if !newerWaiting { view.enqueue(pixels) }
            } else {
                pending = pixels
            }
            let newSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            if newSize != size {
                size = newSize
                onSize?(newSize)
            }
            onPicture?(pixels)
        }
        onResult?(result)
    }
}

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
