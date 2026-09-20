import Benchmark
import CryptoKit
import Darwin
import LightrayCore
import LightrayCrypto
import LightrayEngine
import LightrayRuntime
import LightrayTestSupport

// mac -> mac over 127.0.0.1 with the real Darwin socket path.
//
// Phase 0 measured `sendto` alone at about 4 µs per packet — more than AES-GCM —
// and no public batching API exists (`sendmsg_x` is private), so the syscall is
// the floor here, not the protocol.

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.cpuTotal, .wallClock, .throughput],
        warmupIterations: 10,
        maxDuration: .seconds(3)
    )

    let keys = DirectionKeys(SymmetricKey(data: (0..<KeySchedule.outputSize).map { UInt8($0) }))

    /// One 1200-byte datagram out and back on loopback, sealed and opened.
    func loopbackRoundTrip(_ name: String, mode: PacketProtection.Mode) {
        Benchmark(name) { benchmark in
            guard let sender = try? UDPSocket(), let receiver = try? UDPSocket() else {
                benchmark.stopMeasurement()
                return
            }
            let destination = UDPSocket.loopback(port: receiver.localPort)
            let protection = PacketProtection(mode: mode, send: keys, receive: keys)
            let datagram = UnsafeMutableRawBufferPointer.allocate(byteCount: 1200, alignment: 64)
            let plaintext = UnsafeMutableRawBufferPointer.allocate(byteCount: 1168, alignment: 64)
            let received = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 64)
            let opened = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 64)
            defer {
                datagram.deallocate(); plaintext.deallocate()
                received.deallocate(); opened.deallocate()
                sender.closeSocket(); receiver.closeSocket()
            }
            datagram.initializeMemory(as: UInt8.self, repeating: 0)
            plaintext.initializeMemory(as: UInt8.self, repeating: 0xAB)

            var sequence: UInt32 = 0
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                sequence &+= 1
                var w = ByteWriter(datagram)
                try! PacketHeader(sessionID: 1, transportSeq: sequence, sendTimeMicros: 0).encode(into: &w)
                guard let sealed = protection.seal(
                    plaintext: UnsafeRawBufferPointer(plaintext),
                    header: UnsafeRawBufferPointer(rebasing: datagram[..<Wire.headerSize]),
                    packetNumber: UInt64(sequence),
                    into: UnsafeMutableRawBufferPointer(rebasing: datagram[Wire.headerSize...]))
                else { continue }
                let total = Wire.headerSize + sealed
                _ = sender.send(UnsafeRawBufferPointer(rebasing: datagram[..<total]), to: destination)
                guard let got = receiver.receive(into: received) else { continue }
                blackHole(protection.open(
                    sealed: UnsafeRawBufferPointer(rebasing: received[Wire.headerSize..<got.length]),
                    header: UnsafeRawBufferPointer(rebasing: received[..<Wire.headerSize]),
                    packetNumber: UInt64(sequence), into: opened))
            }
            benchmark.stopMeasurement()
        }
    }

    loopbackRoundTrip("Loopback 1200 B with AES-GCM", mode: .aesGCM)
    loopbackRoundTrip("Loopback 1200 B plaintext", mode: .plaintext)

    Benchmark("sendto 1200 B (syscall floor)") { benchmark in
        guard let sender = try? UDPSocket(), let receiver = try? UDPSocket() else { return }
        let destination = UDPSocket.loopback(port: receiver.localPort)
        let datagram = UnsafeMutableRawBufferPointer.allocate(byteCount: 1200, alignment: 64)
        let sink = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 64)
        defer {
            datagram.deallocate(); sink.deallocate()
            sender.closeSocket(); receiver.closeSocket()
        }
        datagram.initializeMemory(as: UInt8.self, repeating: 0x11)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            _ = sender.send(UnsafeRawBufferPointer(datagram), to: destination)
            while receiver.receive(into: sink) != nil {}
        }
        benchmark.stopMeasurement()
    }

    // The whole stack, both runtimes, over real sockets: what a frame costs end
    // to end including both kqueue threads.
    Benchmark("End-to-end frame over loopback runtimes",
              configuration: .init(metrics: [.wallClock, .throughput], warmupIterations: 2,
                                   maxDuration: .seconds(5), maxIterations: 240)) { benchmark in
        let psk = SymmetricKey(data: [UInt8](repeating: 0x5A, count: 32))
        let streams = [
            StreamDescriptor(id: 1, kind: .video, direction: .hostToClient, streamClass: .media),
        ]
        var config = SessionConfig()
        config.bitrate = 20_000_000
        guard let host = try? LightrayHost(psk: psk, streams: streams, config: config),
              let client = try? LightrayClient(psk: psk, pairingID: 1, streams: streams, config: config)
        else { return }
        host.start(); client.start()
        defer { client.stop(); host.stop() }
        client.connect(host: "127.0.0.1", port: host.localPort)
        var waited = 0
        while client.phase != .connected, waited < 2000 { usleep(1_000); waited += 1 }

        var source = SyntheticFrameSource(stream: 1, bitrate: 20_000_000, framerate: 60)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            host.submit(source.next(at: SystemClock.shared.now()))
            usleep(1_000)
        }
        benchmark.stopMeasurement()
        blackHole(host.loopStats.sent)
    }
}
