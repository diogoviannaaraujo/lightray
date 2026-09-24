// Two ways an iPad client might keep its process, socket and decoder alive in the background:
// playing audio (a streamed desktop usually has some), and picture-in-picture of the stream.
// The probe only needs to know whether heartbeats keep flowing while either is active.
import AVFoundation
import AVKit
import SwiftUI
import UIKit

final class AudioKeepAlive {
    static let shared = AudioKeepAlive()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var running = false

    func setEnabled(_ on: Bool) {
        on ? start() : stop()
    }

    private func start() {
        guard !running else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            if player.engine == nil { engine.attach(player) }
            let fmt = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fmt.sampleRate / 10)) else { return }
            buf.frameLength = buf.frameCapacity  // silence
            try engine.start()
            player.scheduleBuffer(buf, at: nil, options: .loops)
            player.play()
            running = true
            Report.line("KEEPALIVE audio started")
        } catch {
            Report.line("KEEPALIVE audio failed: \(error)")
        }
    }

    private func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        running = false
        Report.line("KEEPALIVE audio stopped")
    }
}

final class PiPKeepAlive: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = PiPKeepAlive()
    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var timer: Foundation.Timer?
    private var samples: [CMSampleBuffer] = []
    private var index = 0
    private var frame: Int64 = 0

    /// Main thread. Needs the 1080p stream from DecodeProbe, so run the decode probe first.
    func setEnabled(_ on: Bool) {
        if !on {
            timer?.invalidate(); timer = nil
            controller = nil
            Report.line("KEEPALIVE pip disabled")
            return
        }
        samples = DecodeProbe.shared.pipSamples
        guard !samples.isEmpty else { Report.line("KEEPALIVE pip needs the decode probe to run first"); return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { Report.line("KEEPALIVE pip unsupported"); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { Report.line("KEEPALIVE pip audio session failed: \(error)") }
        displayLayer.videoGravity = .resizeAspect
        let c = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self))
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = true
        controller = c
        timer = Foundation.Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.feed() }
        Report.line("KEEPALIVE pip armed (starts automatically when the app goes to the background)")
    }

    private func feed() {
        guard !samples.isEmpty, displayLayer.sampleBufferRenderer.isReadyForMoreMediaData else { return }
        let src = samples[index]
        index = (index + 1) % samples.count
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: frame, timescale: 30),
                                        decodeTimeStamp: .invalid)
        frame += 1
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: src, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                    sampleBufferOut: &out) == noErr, let out else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(out, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        displayLayer.sampleBufferRenderer.enqueue(out)
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { Report.line("KEEPALIVE pip started") }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { Report.line("KEEPALIVE pip stopped") }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Report.line("KEEPALIVE pip failed to start: \(error.localizedDescription)")
    }
}

/// Hosts the PiP display layer in the SwiftUI view tree; PiP can only start from a visible layer.
struct PiPLayerView: UIViewRepresentable {
    final class LayerView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            PiPKeepAlive.shared.displayLayer.frame = bounds
        }
    }
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.layer.addSublayer(PiPKeepAlive.shared.displayLayer)
        return v
    }
    func updateUIView(_ uiView: LayerView, context: Context) {}
}
