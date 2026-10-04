import CoreVideo
import Dispatch
import Foundation
import os
import Testing

@testable import LightrayCore

@Test func modifierFlagsPreserveSidesAndAcceptAccessibilityEvents() {
    for modifier in KeyMap.Modifier.allCases {
        #expect(!KeyMap.isDown(modifier, flags: 0))
        #expect(KeyMap.isDown(modifier, flags: KeyMap.flag(modifier)))
        #expect(KeyMap.isDown(modifier, flags: KeyMap.flag(modifier) | KeyMap.deviceMask(modifier)))
        for other in KeyMap.Modifier.allCases where KeyMap.flag(other) == KeyMap.flag(modifier) && KeyMap.deviceMask(other) != KeyMap.deviceMask(modifier) {
            #expect(!KeyMap.isDown(modifier, flags: KeyMap.flag(other) | KeyMap.deviceMask(other)))
        }
    }
}

@Test func modifierReconciliationHandlesMissingFlagsChanged() {
    let control = KeyMap.flag(.leftControl)
    #expect(KeyMap.reconciledModifiers(flags: control, held: []) == [0xE0])
    #expect(KeyMap.reconciledModifiers(flags: control, held: [0xE4]) == [0xE4])
    #expect(KeyMap.reconciledModifiers(flags: control | KeyMap.deviceMask(.rightControl), held: [0xE0]) == [0xE4])
    #expect(KeyMap.reconciledModifiers(flags: 0, held: [0xE0, 0xE4, 0xE1]).isEmpty)
    #expect(KeyMap.reconciledModifiers(flags: control | KeyMap.flag(.leftShift), held: []) == [0xE0, 0xE1])
}

/// Regression scenario: decode the published 16 × 16 IDR in `docs/video.md`.
@Test func decodesThePublishedIDR() throws {
    let bytes = Bytes(hex: idrExample)!
    let (header, offset) = try #require(FrameHeader.parse(bytes))
    let frame = DeliveredFrame(frameID: 1, header: header, bytes: bytes, payloadOffset: offset, completedAt: 0)
    let decoder = VideoDecoder()
    guard case .picture(let image, _, let isKeyframe) = decoder.decode(frame) else {
        Issue.record("the IDR did not decode")
        return
    }
    #expect(isKeyframe)
    #expect(CVPixelBufferGetWidth(image) == 16 && CVPixelBufferGetHeight(image) == 16)
}

/// The encoder's output, framed and reassembled, decodes; a predicted frame without its
/// keyframe fails instead of producing a picture.
@Test func encoderOutputDecodes() throws {
    // The encoder calls back on a thread of its own.
    let output = OSAllocatedUnfairLock(initialState: [EncodedFrame]())
    let done = DispatchSemaphore(value: 0)
    let encoder = try VideoEncoder(width: 320, height: 240, frameRate: 30, bitrate: 2_000_000) { frame in
        output.withLock { $0.append(frame) }
        done.signal()
    }
    for i in 0..<3 {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!
            memset(base, Int32(40 + 60 * i + 30 * plane), CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        encoder.encode(pixels, captureTimeMicros: UInt64(1_000_000 + i * 33_333), forceKeyframe: i == 0)
        _ = done.wait(timeout: .now() + 2)
    }
    let frames = output.withLock { $0 }
    try #require(frames.count == 3)
    #expect(frames[0].isKeyframe && frames[0].codecConfig != nil)
    #expect(!frames[1].isKeyframe)

    func delivered(_ frame: EncodedFrame, id: UInt32) -> DeliveredFrame {
        let header = FrameHeader(
            frameType: frame.isKeyframe ? .idr : .predicted, refKind: frame.isKeyframe ? .none : .previous,
            captureTimeMicros: 0, codecConfig: frame.codecConfig)
        let bytes = header.encoded + frame.payload
        let (parsed, offset) = FrameHeader.parse(bytes)!
        return DeliveredFrame(frameID: id, header: parsed, bytes: bytes, payloadOffset: offset, completedAt: 0)
    }
    let cold = VideoDecoder()
    if case .picture = cold.decode(delivered(frames[1], id: 2)) { Issue.record("a P-frame decoded without its reference") }
    let decoder = VideoDecoder()
    for (i, frame) in frames.enumerated() {
        guard case .picture(let image, _, _) = decoder.decode(delivered(frame, id: UInt32(i + 1))) else {
            Issue.record("frame \(i) did not decode")
            continue
        }
        #expect(CVPixelBufferGetWidth(image) == 320)
    }
}

@Test func malformedNALFramingIsRejected() {
    let valid: Bytes = [0, 0, 0, 2, 0x28, 1]
    #expect(VideoDecoder.hasValidNALFraming(valid[...]))
    #expect(VideoDecoder.hasValidNALFraming((valid + valid)[...]))
    #expect(VideoDecoder.hasValidNALFraming(([99] + valid)[1...]))
    for payload: Bytes in [[], [0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 1, 0x28], [0, 0, 0, 3, 0x28, 1], [255, 255, 255, 255, 0x28, 1], [0, 0, 0, 2, 0xa8, 1], [0, 0, 0, 2, 0x28, 0], valid + [0]] {
        #expect(!VideoDecoder.hasValidNALFraming(payload[...]))
    }
}

@Test func decoderRejectsInvalidParameterSets() {
    let decoder = VideoDecoder()
    let configs = [CodecConfig(vps: [], sps: [], pps: []), CodecConfig(vps: [1], sps: [2], pps: [3]), CodecConfig(vps: [0x42, 1], sps: [0x40, 1], pps: [0x44, 1])]
    for config in configs {
        let header = FrameHeader(frameType: .idr, refKind: .none, captureTimeMicros: 0, codecConfig: config)
        let bytes = header.encoded + [0, 0, 0, 2, 0x28, 1]
        let frame = DeliveredFrame(frameID: 1, header: header, bytes: bytes, payloadOffset: header.encoded.count, completedAt: 0)
        guard case .failed(let id, _) = decoder.decode(frame) else {
            Issue.record("Invalid parameter sets reached the decoder")
            continue
        }
        #expect(id == 1)
    }
}

@Test func keyMapRoundTrips() {
    for (code, usage) in KeyMap.pairs {
        #expect(KeyMap.usage(forKeyCode: code) == usage)
        #expect(KeyMap.keyCode(forUsage: usage) == code)
    }
    #expect(KeyMap.usage(forKeyCode: 0x00) == 0x04)  // A
    #expect(KeyMap.usage(forKeyCode: 0x37) == 0xE3)  // left Command
}

@Test func pairingTokenRoundTrips() {
    let pairing = Pairing.generate()
    #expect(Pairing(token: pairing.token) == pairing)
    #expect(Pairing(token: "lr1-00") == nil)
}

@Test func socketsExchangeDatagrams() throws {
    let queue = DispatchQueue(label: "test")
    let a = try UDPSocket(family: AF_INET6, queue: queue)
    let b = try UDPSocket(family: AF_INET, queue: queue)
    let got = DispatchSemaphore(value: 0)
    var received: (Bytes, PeerAddress)?
    a.start { bytes, from in
        received = (bytes, from)
        got.signal()
    }
    b.start { _, _ in }
    let (target, family) = try UDPSocket.resolve("127.0.0.1", port: a.localPort)
    #expect(family == AF_INET)
    b.send([1, 2, 3], to: target)
    #expect(got.wait(timeout: .now() + 2) == .success)
    #expect(received?.0 == [1, 2, 3])
    #expect(received?.1 == PeerAddress(ip: [127, 0, 0, 1], port: b.localPort))
    a.close()
    b.close()
}

let idrExample = "000001000000030001e24000530100500000001840010c01ffff01600000030090000003000003003cba02400000002642010101600000030090000003000003003ca0884596e96f0b9a020000030002000003003c10000000064401c0718112000001432801ac1ae0f33d5fdcfddf03600717810da9f57f7bb115b7924631e1020000cacc5d6c1c47cdb924cb879dd8cd3e9efad4eb38f5abc256ca0d205c7abc3897c1456af493a979ed56e5d4411b5d6d972bad41ed61679250c54bd927454a389f0ce54ba83c5be0ba8b8ff2ea1e0aa497e49ec2fa2d3d272d6e188d578c2f27e6f449751f96f27ff5ae8352f2988bf52c1aa503dce248121b4042e5b3faf9c3adf9fe7ee3c06bfe1199fa8b9dbfd30090fed9f9eeee3be33dc398516216bdafea5bbbeaac3ec37adc7fa611e4a3b589aee7e0fbe17cadea66770a486e9ae25821bd4b8925e02d311d842c4ffda14eb6c4f1b1598211604264759329ef4c1e7fb35f201bdfb25e12f9b0778d61e5eb242bf2202706106410a5ad36084f2cf64b27a9a039ed2f3c5c784c2129387bf43ee726767425c27a3a514fde71cef2456b108e7a27c0"

@Test func boundedDecoderCancellationReleasesPendingWork() throws {
    let bytes = Bytes(hex: idrExample)!
    let (header, offset) = try #require(FrameHeader.parse(bytes))
    let mailbox = DecodeQueue(maxFrames: 3, maxBytes: bytes.count * 3)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let worker = BoundedVideoDecoder(stream: 1, mailbox: mailbox, now: { 0 }) { frame in
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
        return .failed(frameID: frame.frameID, status: -1)
    }
    worker.onResult = { _, _, _ in Issue.record("cancelled decode reported a result") }
    let frame = DeliveredFrame(frameID: 1, header: header, bytes: bytes, payloadOffset: offset, completedAt: 0)
    worker.submit(frame)
    #expect(entered.wait(timeout: .now() + 2) == .success)
    var predicted = header
    predicted.frameType = .predicted
    for id: UInt32 in 2...500 {
        worker.submit(DeliveredFrame(frameID: id, header: predicted, bytes: bytes, payloadOffset: offset, completedAt: 0))
    }
    #expect(mailbox.retainedFrames == 1)
    worker.cancel()
    #expect(!worker.isActive && worker.retainedBytes == bytes.count)
    release.signal()
    worker.queue.sync {}
    #expect(worker.retainedBytes == 0 && worker.decoded == 0)
    #expect(worker.takeTimings().samples == 0)
}

@Test func socketFailuresAreObservableAndCloseIsIdempotent() throws {
    let queue = DispatchQueue(label: "socket-lifetime")
    let socket = try UDPSocket(family: AF_INET, queue: queue)
    let (target, _) = try UDPSocket.resolve("127.0.0.1", port: socket.localPort)
    #expect(socket.receiveBufferBytes > 0 && socket.sendBufferBytes > 0)
    #expect(!socket.send(Bytes(repeating: 0, count: 65536), to: target))
    #expect(socket.sendFailures == 1 && socket.lastSendError == EMSGSIZE)
    socket.close()
    let replacement = try UDPSocket(family: AF_INET, queue: queue)
    defer { replacement.close() }
    socket.close()
    #expect(!socket.send([1], to: target))
    #expect(socket.lastSendError == EBADF && socket.localPort == 0)
    let (replacementTarget, _) = try UDPSocket.resolve("127.0.0.1", port: replacement.localPort)
    #expect(replacement.send([1], to: replacementTarget))
}

@Test func socketCanCloseFromItsReadCallback() throws {
    let queue = DispatchQueue(label: "socket-callback-close")
    let socket = try UDPSocket(family: AF_INET, queue: queue)
    let port = socket.localPort
    let done = DispatchSemaphore(value: 0)
    socket.start { _, _ in socket.close(); done.signal() }
    let (target, _) = try UDPSocket.resolve("127.0.0.1", port: port)
    #expect(socket.send([1], to: target))
    #expect(done.wait(timeout: .now() + 2) == .success)
    queue.sync {}
    socket.close()
    #expect(!socket.send([2], to: target))
}
