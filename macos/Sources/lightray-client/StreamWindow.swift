import AVFoundation
import AppKit
import LightrayCore
import LightrayMac

/// Connects the bounded decoder to a view, rejecting output from invalidated epochs.
final class StreamDecoder: @unchecked Sendable {
    let stream: UInt8
    private let worker: BoundedVideoDecoder
    private var view: VideoView?
    private var pending: (pixels: CVPixelBuffer, epoch: UInt64)?
    private var size: CGSize?
    var onResult: ((VideoDecoder.Result, UInt64) -> Void)?
    var onSize: ((CGSize, UInt64) -> Void)?
    var onPicture: ((CVPixelBuffer, UInt64) -> Void)?

    init(stream: UInt8) {
        self.stream = stream
        worker = BoundedVideoDecoder(stream: stream)
        worker.onResult = { [weak self] result, epoch, present in
            guard let self, worker.isCurrent(epoch) else { return }
            if case .picture(let pixels, _, _) = result {
                if let view {
                    if present { view.enqueue(pixels) }
                } else {
                    pending = (pixels, epoch)
                }
                let newSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                if newSize != size {
                    size = newSize
                    onSize?(newSize, epoch)
                }
                onPicture?(pixels, epoch)
            }
            onResult?(result, epoch)
        }
    }

    var decoded: Int { worker.decoded }
    var dropped: Int { worker.dropped }
    func takeTimings() -> DecodeTimings { worker.takeTimings() }
    var isActive: Bool { worker.isActive }
    func isCurrent(_ epoch: UInt64) -> Bool { worker.isCurrent(epoch) }

    @discardableResult
    func submit(_ frame: DeliveredFrame) -> UInt32? { worker.submit(frame) }

    func attach(_ view: VideoView) {
        worker.queue.async { [self] in
            guard worker.isActive else { return }
            self.view = view
            if let pending, worker.isCurrent(pending.epoch) { view.enqueue(pending.pixels) }
            pending = nil
        }
    }

    func invalidate() {
        worker.cancel()
        worker.queue.async { [self] in
            view = nil
            pending = nil
        }
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
