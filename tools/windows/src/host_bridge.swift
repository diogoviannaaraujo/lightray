import Foundation

// Experimental ABI v1. All endpoint access is serialized; no callback crosses the ABI.
private final class BridgeHost {
    let endpoint: HostEndpoint
    var generation: UInt64 = 0
    var now: UInt64 = 0
    var failed = false
    var datagrams: [Bytes] = []
    var events: [Bytes] = []
    var queuedBytes = 0
    init(_ endpoint: HostEndpoint) { self.endpoint = endpoint }

    func clock(_ value: UInt64) -> Bool {
        guard value >= now, value <= UInt64.max - 120_000_000 else { return false }
        now = value
        return true
    }

    func collect() -> Int32 {
        for event in endpoint.takeEvents() {
            var body = ByteWriter()
            var kind: UInt8
            switch event {
            case .sessionStarted(let sessionID, let peer):
                generation += 1
                datagrams.removeAll(); events.removeAll(); queuedBytes = 0
                kind = 1; body.u32(sessionID); body.append(bridgePeer(peer))
            case .sessionEnded(let sessionID, let reason):
                // Unsent media from the ended session must not be presented after close.
                datagrams.removeAll(); events.removeAll(); queuedBytes = 0
                kind = 2; body.u32(sessionID)
                let text = Bytes(reason.utf8.prefix(256)); body.u16(UInt16(text.count)); body.append(text)
            case .keyframeNeeded(let stream): kind = 3; body.u8(stream)
            case .displayRequested(let stream, let display, let request): kind = 4; body.u8(stream); body.u32(display); body.u32(request)
            case .input(let input): kind = 5; body.append(input.encoded)
            case .paused:
                generation += 1
                datagrams.removeAll(); events.removeAll(); queuedBytes = 0
                kind = 6
            case .resumed: kind = 7
            }
            var record = ByteWriter(); record.u8(kind); record.u64(generation); record.append(body.bytes)
            events.append(record.bytes)
        }
        for (bytes, peer) in endpoint.takeOutbox() {
            let record = bridgePeer(peer) + bytes
            datagrams.append(record); queuedBytes += record.count
        }
        guard events.count <= 64, datagrams.count <= 256, queuedBytes <= 512 << 10 else {
            failed = true
            endpoint.close(now: now)
            _ = endpoint.takeOutbox(); _ = endpoint.takeEvents()
            datagrams.removeAll(); events.removeAll(); queuedBytes = 0
            return -5
        }
        return 0
    }
}
private let bridgeLock = NSLock()
nonisolated(unsafe) private var bridgeHosts: [UInt64: BridgeHost] = [:]
nonisolated(unsafe) private var bridgeNextHandle: UInt64 = 1

private func bridgePeer(_ peer: PeerAddress) -> Bytes {
    var writer = ByteWriter(); writer.u8(UInt8(peer.ip.count)); writer.append(peer.ip); writer.u16(peer.port)
    return writer.bytes
}
private func bridgeData(_ pointer: UnsafePointer<UInt8>?, _ count: Int32, maximum: Int) -> Bytes? {
    guard count >= 0, count <= maximum else { return nil }
    if count == 0 { return [] }
    guard let pointer else { return nil }
    return Bytes(UnsafeBufferPointer(start: pointer, count: Int(count)))
}
private func bridgeWith(_ handle: UInt64, _ operation: (BridgeHost) -> Int32) -> Int32 {
    bridgeLock.lock(); defer { bridgeLock.unlock() }
    guard let host = bridgeHosts[handle] else { return -2 }
    guard !host.failed else { return -5 }
    return operation(host)
}
private func bridgeNALs(_ bytes: Bytes, maxCount: Int = 4096) -> [Bytes]? {
    var reader = ByteReader(bytes)
    var nals: [Bytes] = []
    while !reader.isAtEnd {
        guard nals.count < maxCount, let size = try? reader.u32(), size >= 2,
            let nal = try? reader.take(Int(size)), nal[nal.startIndex] & 0x80 == 0,
            nal[nal.index(after: nal.startIndex)] & 7 != 0 else { return nil }
        nals.append(Bytes(nal))
    }
    return nals.isEmpty ? nil : nals
}

@_cdecl("lr_host_abi_version")
public func bridgeABIVersion() -> UInt32 { 1 }

@_cdecl("lr_host_create")
public func bridgeCreate(_ pairingID: UInt64, _ psk: UnsafePointer<UInt8>?, _ pskCount: Int32, _ resetKey: UnsafePointer<UInt8>?, _ resetCount: Int32, _ bitrate: Int32, _ fps: Int32, _ fec: Int32) -> UInt64 {
    guard pskCount == 32, resetCount == 32, let key = bridgeData(psk, pskCount, maximum: 32),
        let reset = bridgeData(resetKey, resetCount, maximum: 32), bitrate >= 1_000_000, bitrate <= 200_000_000,
        fps >= 1, fps <= 240, fec >= 0, fec <= 50 else { return 0 }
    bridgeLock.lock(); defer { bridgeLock.unlock() }
    guard bridgeHosts.count < 16, bridgeNextHandle < UInt64.max else { return 0 }
    var config = HostConfig(); config.bitrate = Int(bitrate); config.frameRate = Int(fps); config.fecPercent = Int(fec)
    let host = BridgeHost(HostEndpoint(config: config, hostSecret: reset, psk: { $0 == pairingID ? key : nil }))
    let handle = bridgeNextHandle; bridgeNextHandle += 1; bridgeHosts[handle] = host
    return handle
}

@_cdecl("lr_host_destroy")
public func bridgeDestroy(_ handle: UInt64) -> Int32 {
    bridgeLock.lock(); defer { bridgeLock.unlock() }
    guard bridgeHosts.removeValue(forKey: handle) != nil else { return -2 }
    return 0
}

@_cdecl("lr_host_receive")
public func bridgeReceive(_ handle: UInt64, _ data: UnsafePointer<UInt8>?, _ count: Int32, _ ip: UnsafePointer<UInt8>?, _ ipCount: Int32, _ port: UInt16, _ now: UInt64, _ unix: UInt64) -> Int32 {
    guard count > 0, let bytes = bridgeData(data, count, maximum: 1200), ipCount == 4 || ipCount == 16,
        let address = bridgeData(ip, ipCount, maximum: 16), port != 0, unix < UInt64.max - 3600 else { return -1 }
    return bridgeWith(handle) { host in
        guard host.clock(now) else { return -1 }
        host.endpoint.receive(bytes, from: PeerAddress(ip: address, port: port), now: now, unixTime: unix)
        host.endpoint.tick(now: now)
        return host.collect()
    }
}

@_cdecl("lr_host_tick")
public func bridgeTick(_ handle: UInt64, _ now: UInt64) -> Int32 {
    bridgeWith(handle) { host in
        guard host.clock(now) else { return -1 }
        host.endpoint.tick(now: now)
        return host.collect()
    }
}

@_cdecl("lr_host_close")
public func bridgeClose(_ handle: UInt64, _ now: UInt64) -> Int32 {
    bridgeWith(handle) { host in
        guard host.clock(now) else { return -1 }
        host.endpoint.close(now: now)
        return host.collect()
    }
}

@_cdecl("lr_host_generation")
public func bridgeGeneration(_ handle: UInt64) -> UInt64 {
    bridgeLock.lock(); defer { bridgeLock.unlock() }
    guard let host = bridgeHosts[handle], !host.failed, host.endpoint.session != nil else { return 0 }
    return host.generation
}

@_cdecl("lr_host_next_wakeup")
public func bridgeWakeup(_ handle: UInt64, _ now: UInt64, _ result: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard let result else { return -1 }
    return bridgeWith(handle) { host in
        guard host.clock(now) else { return -1 }
        result.pointee = host.endpoint.nextWakeup(now: now) ?? UInt64.max
        return 0
    }
}

private func bridgePop(_ handle: UInt64, _ event: Bool, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int32, _ required: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let required, capacity >= 0, capacity <= 1 << 20, capacity == 0 || output != nil else { return -1 }
    required.pointee = 0
    return bridgeWith(handle) { host in
        guard let bytes = event ? host.events.first : host.datagrams.first else { return 0 }
        required.pointee = Int32(bytes.count)
        guard let output, capacity >= bytes.count else { return -3 }
        for (index, byte) in bytes.enumerated() { output[index] = byte }
        if event { host.events.removeFirst() } else { host.datagrams.removeFirst(); host.queuedBytes -= bytes.count }
        return Int32(bytes.count)
    }
}
@_cdecl("lr_host_pop_datagram")
public func bridgePopDatagram(_ handle: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int32, _ required: UnsafeMutablePointer<Int32>?) -> Int32 {
    bridgePop(handle, false, output, capacity, required)
}
@_cdecl("lr_host_pop_event")
public func bridgePopEvent(_ handle: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int32, _ required: UnsafeMutablePointer<Int32>?) -> Int32 {
    bridgePop(handle, true, output, capacity, required)
}

@_cdecl("lr_host_submit")
public func bridgeSubmit(_ handle: UInt64, _ generation: UInt64, _ stream: UInt8, _ payload: UnsafePointer<UInt8>?, _ count: Int32, _ configuration: UnsafePointer<UInt8>?, _ configCount: Int32, _ idr: Int32, _ capture: UInt64, _ now: UInt64) -> Int32 {
    bridgeSubmitFrame(handle, generation, stream, payload, count, configuration, configCount, idr, capture, now, nil)
}

@_cdecl("lr_host_submit_timed")
public func bridgeSubmitTimed(_ handle: UInt64, _ generation: UInt64, _ stream: UInt8, _ payload: UnsafePointer<UInt8>?, _ count: Int32, _ configuration: UnsafePointer<UInt8>?, _ configCount: Int32, _ idr: Int32, _ capture: UInt64, _ now: UInt64, _ captureDuration: UInt32, _ encodeDuration: UInt32, _ sampleID: UInt64) -> Int32 {
    guard let timings = HostFrameTimings(captureMicros: captureDuration, encodeMicros: encodeDuration, sampleID: sampleID) else { return -1 }
    return bridgeSubmitFrame(handle, generation, stream, payload, count, configuration, configCount, idr, capture, now, timings)
}

private func bridgeSubmitFrame(_ handle: UInt64, _ generation: UInt64, _ stream: UInt8, _ payload: UnsafePointer<UInt8>?, _ count: Int32, _ configuration: UnsafePointer<UInt8>?, _ configCount: Int32, _ idr: Int32, _ capture: UInt64, _ now: UInt64, _ timings: HostFrameTimings?) -> Int32 {
    guard (idr == 0 || idr == 1), let bytes = bridgeData(payload, count, maximum: 4 << 20),
        let nals = bridgeNALs(bytes), let configBytes = bridgeData(configuration, configCount, maximum: 65532) else { return -1 }
    let types = nals.map { ($0[0] >> 1) & 63 }.filter { $0 <= 31 }
    guard !types.isEmpty, types.allSatisfy({ idr == 1 ? ($0 == 19 || $0 == 20) : $0 <= 9 }) else { return -1 }
    var config: CodecConfig?
    if idr == 1 {
        guard let sets = bridgeNALs(configBytes, maxCount: 3), sets.count == 3,
            zip(sets, [32, 33, 34]).allSatisfy({ Int(($0.0[0] >> 1) & 63) == $0.1 }) else { return -1 }
        config = CodecConfig(vps: sets[0], sps: sets[1], pps: sets[2])
    } else if !configBytes.isEmpty { return -1 }
    return bridgeWith(handle) { host in
        guard generation != 0, generation == host.generation, let session = host.endpoint.session,
            !session.paused, session.videos[stream] != nil else { return -4 }
        guard capture <= now, now - capture <= 100_000, host.clock(now) else { return -1 }
        host.endpoint.submit(EncodedFrame(isKeyframe: idr == 1, payload: bytes, codecConfig: config, captureTimeMicros: capture, hostTimings: timings), stream: stream, now: now)
        host.endpoint.tick(now: now)
        return host.collect()
    }
}

@_cdecl("lr_host_control")
public func bridgeControl(_ handle: UInt64, _ generation: UInt64, _ data: UnsafePointer<UInt8>?, _ count: Int32, _ now: UInt64) -> Int32 {
    guard let bytes = bridgeData(data, count, maximum: 4096), let message = ControlMessage(bytes) else { return -1 }
    if case .selectDisplay = message { return -1 }
    return bridgeWith(handle) { host in
        guard generation != 0, generation == host.generation, host.endpoint.isStreaming else { return -4 }
        guard host.clock(now) else { return -1 }
        host.endpoint.send(message); host.endpoint.tick(now: now)
        return host.collect()
    }
}
