import AppKit
import CoreMedia
import CoreVideo
import Foundation
import LightrayCore
import LightrayMac
import ScreenCaptureKit

/// Where a pipeline's pictures come from: a display, or the test pattern.
protocol FrameSource: AnyObject {
    var width: Int { get }
    var height: Int { get }
    /// Runs on the pipeline's queue with each new picture and its capture time in microseconds.
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)? { get set }
    /// Runs once if the source stops on its own.
    var onFailure: ((String) -> Void)? { get set }
    func stop()
}

/// Captures one display with ScreenCaptureKit, as NV12 at the display's pixel size (or scaled),
/// with the cursor drawn in. Only complete frames are passed on: ScreenCaptureKit sends nothing
/// new while the screen is still, which is when the host sends nothing either.
final class ScreenCapture: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    private let queue: DispatchQueue
    private var stream: SCStream?
    private(set) var width = 0
    private(set) var height = 0
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onFailure: ((String) -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    func start(displayID: CGDirectDisplayID, frameRate: Int, scale: Double) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError("display \(displayID) is not available")
        }
        let mode = CGDisplayCopyDisplayMode(displayID)
        width = Int(Double(mode?.pixelWidth ?? display.width) * scale) & ~1
        height = Int(Double(mode?.pixelHeight ?? display.height) * scale) & ~1

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
            let pixels = sample.imageBuffer
        else { return }
        // Sample times are on the host clock, the same one `monotonicMicros` reads.
        let micros = CMTimeConvertScale(sample.presentationTimeStamp, timescale: 1_000_000, method: .default).value
        onFrame?(pixels, UInt64(max(micros, 0)))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?("capture stopped: \(error.localizedDescription)")
    }
}

struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The displays this host can stream, primary first, as `docs/displays.md` describes them. The
/// identifier is the display's `CGDirectDisplayID`, which macOS keeps for a display while it
/// stays connected.
enum HostDisplays {
    static func current() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let main = CGMainDisplayID()
        let screens = await MainActor.run {
            NSScreen.screens.map { screen -> (UInt32, String, Int, Bool) in
                let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                return (number, screen.localizedName, screen.maximumFramesPerSecond,
                        screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1)
            }
        }
        return content.displays.map { display -> DisplayInfo in
            let id = display.displayID
            let mode = CGDisplayCopyDisplayMode(id)
            let bounds = CGDisplayBounds(id)
            let screen = screens.first { $0.0 == id }
            let refresh = (mode?.refreshRate ?? 0) > 0 ? mode!.refreshRate : Double(screen?.2 ?? 60)
            return DisplayInfo(
                id: id, isPrimary: id == main, supportsHDR: screen?.3 ?? false,
                width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height,
                refreshMillihertz: UInt32(refresh * 1000), layoutX: Int32(bounds.minX), layoutY: Int32(bounds.minY),
                layoutWidth: UInt32(bounds.width), layoutHeight: UInt32(bounds.height),
                name: screen?.1 ?? "Display \(id)")
        }.sorted { ($0.isPrimary ? 0 : 1, $0.id) < ($1.isPrimary ? 0 : 1, $1.id) }
    }

    /// What CoreGraphics says about the active displays: which, their modes, where they sit and
    /// which is primary. Cheap enough to compare every second.
    static func signature() -> [Int] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return [] }
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).flatMap { id -> [Int] in
            let mode = CGDisplayCopyDisplayMode(id)
            let bounds = CGDisplayBounds(id)
            return [Int(id), id == main ? 1 : 0, mode?.pixelWidth ?? 0, mode?.pixelHeight ?? 0,
                    Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height)]
        }
    }

    /// Two synthetic displays side by side, for `--test-pattern`.
    static func testPatterns(width: Int, height: Int) -> [DisplayInfo] {
        (1...2).map { i in
            DisplayInfo(
                id: UInt32(i), isPrimary: i == 1, width: width, height: height, refreshMillihertz: 60_000,
                layoutX: Int32((i - 1) * width), layoutY: 0, layoutWidth: UInt32(width), layoutHeight: UInt32(height),
                name: "Test pattern \(i == 1 ? "A" : "B")")
        }
    }
}
