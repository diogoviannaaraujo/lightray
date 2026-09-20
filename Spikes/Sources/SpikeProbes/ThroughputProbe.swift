import CryptoKit
import Darwin
import Foundation
import Synchronization

// "Loopback UDP with crypto sustains ≥ 1 Gbps on a single loop thread."
// One sender thread (seal + sendto) and one receiver thread (kqueue + recv + open),
// 1200-byte datagrams over 127.0.0.1 via dual-stack sockets. CPU time per packet is
// measured per thread so the headroom is visible even when the peer is the bottleneck.

struct FlowResult: Sendable {
    var sent = 0, sendErrors = 0, sendCPU: UInt64 = 0, sendWall: UInt64 = 0
    var received = 0, authFailures = 0, recvCPU: UInt64 = 0
}

func runFlow(crypto: Bool, targetPPS: Int?, seconds: Double, rcvbuf: Int32) -> FlowResult {
    let rx = udp6(); _ = bind6(rx)
    _ = setInt(rx, SOL_SOCKET, SO_RCVBUF, rcvbuf)
    let tx = udp6(); _ = bind6(tx)
    _ = setInt(tx, SOL_SOCKET, SO_SNDBUF, 4 << 20)
    let dst = addr6("127.0.0.1", localPort(rx))
    let keys = PacketKeys(key: SymmetricKey(size: .bits128), iv: (0..<12).map { _ in UInt8.random(in: 0...255) })
    let done = Atomic<Bool>(false)
    let result = Mutex(FlowResult())

    let receiver = spawnThread(qos: QOS_CLASS_USER_INTERACTIVE) {
        let kq = kqueue()
        var ev = kevent64_s(ident: UInt64(rx), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: 0, ext: (0, 0))
        _ = kevent64(kq, &ev, 1, nil, 0, 0, nil)
        let pkt = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 16)
        let plain = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 16)
        var got = 0, bad = 0
        let cpu0 = cpuTimeNs()
        var idle = timespec(tv_sec: 0, tv_nsec: 200_000_000)
        while true {
            let n = kevent64(kq, nil, 0, &ev, 1, 0, &idle)
            if n == 0 { if done.load(ordering: .acquiring) { break } else { continue } }
            while true {
                let len = recv(rx, pkt.baseAddress, pkt.count, 0)
                if len <= 0 { break }
                got += 1
                if crypto {
                    let pn = UInt64(UInt32(bigEndian: pkt.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
                    let ok = openPacket(keys, pn: pn, header: UnsafeRawBufferPointer(rebasing: pkt[..<16]),
                                        sealed: UnsafeRawBufferPointer(rebasing: pkt[16..<len]), out: plain)
                    if ok == nil { bad += 1 }
                }
            }
        }
        let cpu = cpuTimeNs() - cpu0
        pkt.deallocate(); plain.deallocate(); close(kq)
        result.withLock { $0.received = got; $0.authFailures = bad; $0.recvCPU = cpu }
    }

    onThread(qos: QOS_CLASS_USER_INTERACTIVE) {
        let pkt = UnsafeMutableRawBufferPointer.allocate(byteCount: 1200, alignment: 16)
        let body = UnsafeMutableRawBufferPointer.allocate(byteCount: 1168, alignment: 16)
        body.initializeMemory(as: UInt8.self, repeating: 0x33)
        pkt.initializeMemory(as: UInt8.self, repeating: 0)
        var sent = 0, errs = 0
        let kq = kqueue()
        var ev = kevent64_s()
        let t0 = nowNs(), cpu0 = cpuTimeNs()
        let end = t0 + UInt64(seconds * 1e9)
        var seq: UInt32 = 0
        func sendOne() {
            seq &+= 1
            pkt.storeBytes(of: seq.bigEndian, toByteOffset: 8, as: UInt32.self)
            if crypto {
                _ = sealPacket(keys, pn: UInt64(seq), header: UnsafeRawBufferPointer(rebasing: pkt[..<16]),
                               plaintext: UnsafeRawBufferPointer(body), out: UnsafeMutableRawBufferPointer(rebasing: pkt[16...]))
            }
            while send(tx, UnsafeRawBufferPointer(pkt), to: dst) < 0 { errs += 1; sched_yield() }
            sent += 1
        }
        if let pps = targetPPS {
            // Pacer shape: 1 ms NOTE_CRITICAL ticks, send whatever is due.
            while true {
                let now = nowNs()
                if now >= end { break }
                let due = Int(Double(now - t0) / 1e9 * Double(pps))
                while sent < due { sendOne() }
                var tick = kevent64_s(ident: 1, filter: Int16(EVFILT_TIMER), flags: UInt16(EV_ADD | EV_ONESHOT),
                                      fflags: UInt32(NOTE_NSECONDS | NOTE_CRITICAL), data: 1_000_000, udata: 0, ext: (0, 0))
                _ = kevent64(kq, &tick, 1, &ev, 1, 0, nil)
            }
        } else {
            while nowNs() < end { for _ in 0..<64 { sendOne() } }
        }
        let cpu = cpuTimeNs() - cpu0, wall = nowNs() - t0
        close(kq); pkt.deallocate(); body.deallocate()
        result.withLock { $0.sent = sent; $0.sendErrors = errs; $0.sendCPU = cpu; $0.sendWall = wall }
    }
    done.store(true, ordering: .releasing)
    pthread_join(receiver, nil)
    close(rx); close(tx)
    return result.withLock { $0 }
}

public func throughputProbe(quick: Bool = false) -> Report {
    var rep = Report("Loopback UDP throughput, 1200-byte datagrams, one thread per side")
    let secs = quick ? 0.5 : 2.0
    let gbitPPS = Int(1e9 / (1200 * 8))
    let cases: [(String, Bool, Int?)] = [
        ("unpaced, plaintext", false, nil),
        ("unpaced, AES-GCM", true, nil),
        ("paced 1 Gbps, AES-GCM", true, gbitPPS),
        ("paced 2 Gbps, AES-GCM", true, gbitPPS * 2),
    ]
    for (name, crypto, pps) in cases {
        let r = runFlow(crypto: crypto, targetPPS: pps, seconds: secs, rcvbuf: 8 << 20)
        let wall = Double(r.sendWall) / 1e9
        let txG = Double(r.sent) * 1200 * 8 / wall / 1e9
        let rxG = Double(r.received) * 1200 * 8 / wall / 1e9
        let loss = r.sent > 0 ? 100 * Double(r.sent - r.received) / Double(r.sent) : 0
        rep.add(String(format: "%-24@ tx %.2f Gbps (%.2f µs CPU/pkt, %d EAGAIN/ENOBUFS)  rx %.2f Gbps (%.2f µs CPU/pkt)  loss %.2f%%  auth-fail %d",
                       name as NSString, txG, Double(r.sendCPU) / Double(max(r.sent, 1)) / 1000, r.sendErrors,
                       rxG, Double(r.recvCPU) / Double(max(r.received, 1)) / 1000, loss, r.authFailures))
    }
    rep.add("budget at 1 Gbps: 9.6 µs per 1200-byte packet per thread")
    return rep
}
