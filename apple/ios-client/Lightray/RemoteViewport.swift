import AVFoundation
import CoreGraphics

/// Where the remote picture sits in the surface at a zoom level. Host positions are normalised:
/// 0 is the display's left or top edge, 1 its right or bottom.
struct RemoteViewport: Equatable {
    static let maximumZoom: CGFloat = 5
    /// Finger speed, in points per second, that adds one more pointer gain on top of 1:1.
    static let accelerationSpeed: CGFloat = 1200
    static let maximumAcceleration: CGFloat = 1.5

    /// How a zoomed picture follows the cursor.
    enum Follow: Equatable {
        /// Touchpad: keeps the cursor in the middle of the surface, short of the picture's edges.
        case center
        /// Mouse: the whole surface spans the display, so the cursor stays under the pointer.
        case proportional
    }

    var bounds: CGSize
    var videoSize: CGSize
    var zoom: CGFloat {
        didSet { zoom = Self.clampedZoom(zoom) }
    }

    init(bounds: CGSize, videoSize: CGSize, zoom: CGFloat = 1) {
        self.bounds = bounds
        self.videoSize = videoSize
        self.zoom = Self.clampedZoom(zoom)
    }

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        zoom.isFinite ? min(max(zoom, 1), maximumZoom) : 1
    }

    /// The picture at 1×, aspect-fit and centred.
    var fitted: CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        return AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: bounds))
    }

    var contentSize: CGSize {
        let fitted = fitted.size
        return CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
    }

    /// Where the whole picture goes, beyond the surface's edges once zoomed.
    func contentFrame(cursor: CGPoint, follow: Follow) -> CGRect {
        let size = contentSize
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(x: Self.origin(bounds: bounds.width, content: size.width, cursor: cursor.x, follow: follow),
                      y: Self.origin(bounds: bounds.height, content: size.height, cursor: cursor.y, follow: follow),
                      width: size.width, height: size.height)
    }

    private static func origin(bounds: CGFloat, content: CGFloat, cursor: CGFloat, follow: Follow) -> CGFloat {
        // Letterbox an axis that still fits.
        guard content > bounds else { return (bounds - content) / 2 }
        let cursor = min(max(cursor, 0), 1)
        switch follow {
        case .center: return min(max(bounds / 2 - cursor * content, bounds - content), 0)
        case .proportional: return cursor * (bounds - content)
        }
    }

    /// The host position under a mouse pointer, for `.proportional`. Nil in a letterbox margin
    /// unless `clamp` is set.
    func hostPoint(forPointerAt point: CGPoint, clamp: Bool = false) -> CGPoint? {
        let size = contentSize
        guard size.width > 0, size.height > 0,
              let x = Self.pointerCoordinate(point.x, bounds: bounds.width, content: size.width, clamp: clamp),
              let y = Self.pointerCoordinate(point.y, bounds: bounds.height, content: size.height, clamp: clamp)
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func pointerCoordinate(_ point: CGFloat, bounds: CGFloat, content: CGFloat, clamp: Bool) -> CGFloat? {
        let value = content > bounds ? point / bounds : (point - (bounds - content) / 2) / content
        guard clamp || (0...1).contains(value) else { return nil }
        return min(max(value, 0), 1)
    }

    /// The host position of a point on the picture as it is shown in `frame`.
    static func hostPoint(at point: CGPoint, in frame: CGRect, clamp: Bool = false) -> CGPoint? {
        guard frame.width > 0, frame.height > 0, clamp || frame.contains(point) else { return nil }
        return CGPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1),
                       y: min(max((point.y - frame.minY) / frame.height, 0), 1))
    }

    /// How far a touchpad finger moves the cursor. The cursor tracks the picture as shown, so
    /// zooming in gives finer control; faster movements cover more of the display.
    func hostDelta(forTranslation translation: CGPoint, speed: CGFloat) -> CGVector {
        let size = contentSize
        guard size.width > 0, size.height > 0 else { return .zero }
        let gain = 1 + min(max(speed, 0) / Self.accelerationSpeed, Self.maximumAcceleration)
        return CGVector(dx: translation.x / size.width * gain, dy: translation.y / size.height * gain)
    }

    /// The layer transform that moves the 1× picture onto `frame`. A layer transforms about its
    /// centre, which is also the centre of the fitted picture.
    func transform(for frame: CGRect) -> CGAffineTransform {
        let fitted = fitted
        guard fitted.width > 0, frame.width > 0 else { return .identity }
        let scale = frame.width / fitted.width
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: frame.midX - fitted.midX, y: frame.midY - fitted.midY))
    }
}

/// A touchpad's tap to click, with double-tap and drag. A tap presses the primary button and holds
/// it for `holdInterval`. A touch landing in that time keeps it held: dragging then moves with the
/// button down, and tapping again makes a double click. This only decides; the surface keeps time.
struct TapDrag: Equatable {
    static let holdInterval = Duration.milliseconds(250)

    enum State: Equatable { case idle, pending, armed, dragging }
    enum Event: Equatable { case tap, touchDown, dragBegan, dragEnded, releaseTimer, touchesEndedWithoutGesture, otherGesture }
    enum Action: Equatable { case press, release, scheduleRelease, cancelRelease }

    private(set) var state = State.idle

    mutating func handle(_ event: Event) -> [Action] {
        switch (event, state) {
        case (.tap, .idle):
            state = .pending
            return [.press, .scheduleRelease]
        case (.tap, _):
            state = .pending
            return [.cancelRelease, .release, .press, .scheduleRelease]
        case (.touchDown, .pending):
            state = .armed
            return [.cancelRelease]
        case (.dragBegan, .armed):
            state = .dragging
            return []
        case (.dragEnded, .dragging), (.releaseTimer, .pending), (.touchesEndedWithoutGesture, .armed):
            state = .idle
            return [.release]
        case (.otherGesture, .pending), (.otherGesture, .armed), (.otherGesture, .dragging):
            state = .idle
            return [.cancelRelease, .release]
        default:
            return []
        }
    }
}
