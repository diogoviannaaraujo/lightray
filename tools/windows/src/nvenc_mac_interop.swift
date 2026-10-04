import CoreVideo
import CryptoKit
import Foundation
import LightrayCore
import LightrayMac

struct ProbeFailure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeFailure(message: message) }
}
func records(_ data: Bytes) throws -> [Bytes] {
    var reader = ByteReader(data)
    var result: [Bytes] = []
    while !reader.isAtEnd {
        let count = Int(try reader.u32())
        try require(count <= 32 << 20 && result.count < 4096, "Record limit exceeded")
        result.append(Bytes(try reader.take(count)))
    }
    return result
}
func hashPixels(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> String {
    try require(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height, "Decoded size mismatch")
    try require(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "Expected video-range NV12")
    try require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess, "Cannot lock decoded pixels")
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { throw ProbeFailure(message: "Missing NV12 planes") }
    var pixels = Data(capacity: width * height * 3 / 2)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    try require(yStride >= width && uvStride >= width, "Invalid decoded pitch")
    for row in 0..<height { pixels.append(y.advanced(by: row * yStride).assumingMemoryBound(to: UInt8.self), count: width) }
    for component in 0..<2 {
        for row in 0..<height / 2 {
            let source = uv.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width / 2 { pixels.append(source[column * 2 + component]) }
        }
    }
    return SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
}

do {
    try require(CommandLine.arguments.count == 3, "Usage: interop NATIVE_RUN_DIRECTORY NEW_JSON")
    let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    try require(!FileManager.default.fileExists(atPath: output.path), "Output already exists")
    var results: [[String: Any]] = []
    for (width, height) in [(1920,1080), (2560,1440), (3840,2160)] {
        let directory = input.appendingPathComponent("\(width)x\(height)")
        let payloads = try records(Bytes(Data(contentsOf: directory.appendingPathComponent("native-nvenc.payloads"))))
        let configs = try records(Bytes(Data(contentsOf: directory.appendingPathComponent("native-nvenc.configs"))))
        try require(payloads.count == 120 && configs.count == 120, "Expected 120 encoded access units")
        let sender = VideoSender(stream: 1, bitrate: 40_000_000, frameRate: 60)
        let receiver = VideoReceiver(stream: 1)
        let decoder = VideoDecoder()
        var hashes: [String] = []
        var fragmentCount = 0
        var now: UInt64 = 1_000_000
        for index in 0..<120 {
            let isIDR = index == 0 || index == 60
            let sets = try records(configs[index])
            try require(isIDR ? sets.count == 3 : sets.isEmpty, "Invalid codec configuration count")
            let config = isIDR ? CodecConfig(vps: sets[0], sps: sets[1], pps: sets[2]) : nil
            sender.submit(EncodedFrame(isKeyframe: isIDR, payload: payloads[index], codecConfig: config, captureTimeMicros: now), now: now, datagramSize: 1200, budget: 100_000)
            var ticks = 0
            while let wake = sender.nextDeadline(now: now) {
                ticks += 1
                try require(ticks <= 10000, "Fragment drain failed to make progress")
                now = max(now, wake)
                for bytes in sender.drain(now: now, datagramSize: 1200, seal: { $0 }) {
                    try require(bytes.count + Packet.overhead <= 1200, "Fragment exceeds negotiated datagram size")
                    let parsed = Chunk.parse(bytes)
                    try require(parsed.malformed == 0 && parsed.chunks.count == 1, "Malformed media chunk")
                    guard case .mediaFragment(let fragment) = parsed.chunks[0] else { throw ProbeFailure(message: "Unexpected chunk") }
                    receiver.receive(fragment, now: now, budget: 100_000)
                    fragmentCount += 1
                }
                now += 1
            }
            let frames = receiver.takeFrames()
            try require(frames.count == 1, "Frame lost during local fragmentation/reassembly")
            for frame in frames {
                try require(frame.frameID == UInt32(index + 1) && Bytes(frame.payload) == payloads[index], "Reassembled frame mismatch")
                switch decoder.decode(frame) {
                case .picture(let image, let frameID, let keyframe):
                    try require(frameID == UInt32(index + 1) && keyframe == isIDR, "Decoder identity mismatch")
                    hashes.append(try hashPixels(image, width: width, height: height))
                    receiver.decoded(frameID: frameID, isKeyframe: keyframe)
                case .failed(_, let status): throw ProbeFailure(message: "Mac VideoDecoder failed: \(status)")
                }
            }
            now += 16_667
        }
        decoder.invalidate()
        results.append(["width":width, "height":height, "frames":hashes.count, "media_fragments":fragmentCount, "sha256_yuv420p":hashes])
    }
    let report: [String: Any] = ["status":"passed", "runs":results, "limits":["Native Mac reference decoder; no window, socket, encryption, packet loss or input", "Local media fragmentation/reassembly only; not end-to-end network interoperability", "VideoToolbox hardware selection not forced or instrumented by the production decoder"]]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
    print("Native Mac VideoDecoder accepted 360 NVENC frames after reference media fragmentation/reassembly")
} catch {
    FileHandle.standardError.write(Data("Interop failed: \(error)\n".utf8))
    exit(1)
}
