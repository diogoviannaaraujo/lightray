import CryptoKit
import LightrayCore

/// Seals and opens protected packets.
///
/// One instance belongs to one connection on one thread. CryptoKit has no
/// in-place AEAD API and CommonCrypto exposes no public GCM, so seal and open
/// each allocate (Phase 0 measured 4 and 7 allocations, ~1.3 µs per 1200-byte
/// packet). That is the one documented exception to the zero-allocation rule.
///
/// `mode` exists so benchmarks can isolate protocol cost from crypto cost; the
/// switch is monomorphic, so the hot path carries no existential.
public final class PacketProtection {
    public enum Mode: Sendable {
        case aesGCM
        /// TestSupport and benchmarks only: copies bytes and appends a zero tag.
        case plaintext
    }

    public let mode: Mode
    public var send: DirectionKeys
    public var receive: DirectionKeys
    private let nonceScratch = UnsafeMutableRawBufferPointer.allocate(byteCount: KeySchedule.ivSize, alignment: 16)

    public init(mode: Mode = .aesGCM, send: DirectionKeys, receive: DirectionKeys) {
        self.mode = mode
        self.send = send
        self.receive = receive
        nonceScratch.initializeMemory(as: UInt8.self, repeating: 0)
    }

    deinit { nonceScratch.deallocate() }

    public var tagSize: Int { Wire.tagSize }

    /// Replaces both directions' keys, which is what a re-handshake that adopted
    /// a parked session does: same session, same stats, brand-new keys.
    public func rekey(send: DirectionKeys, receive: DirectionKeys) {
        self.send = send
        self.receive = receive
    }

    /// Seals `plaintext` into `out` as ciphertext ‖ tag. Returns bytes written.
    public func seal(plaintext: UnsafeRawBufferPointer, header: UnsafeRawBufferPointer,
                     packetNumber: UInt64, into out: UnsafeMutableRawBufferPointer) -> Int? {
        guard out.count >= plaintext.count + Wire.tagSize else { return nil }
        switch mode {
        case .plaintext:
            if plaintext.count > 0 {
                UnsafeMutableRawBufferPointer(rebasing: out[..<plaintext.count]).copyMemory(from: plaintext)
            }
            UnsafeMutableRawBufferPointer(rebasing: out[plaintext.count..<(plaintext.count + Wire.tagSize)])
                .initializeMemory(as: UInt8.self, repeating: 0)
            return plaintext.count + Wire.tagSize
        case .aesGCM:
            send.writeNonce(packetNumber, into: nonceScratch)
            guard let nonce = try? AES.GCM.Nonce(data: UnsafeRawBufferPointer(nonceScratch)),
                  let box = try? AES.GCM.seal(plaintext, using: send.key, nonce: nonce, authenticating: header)
            else { return nil }
            let n = box.ciphertext.copyBytes(to: out)
            let t = box.tag.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: out[n...]))
            return n + t
        }
    }

    /// Opens ciphertext ‖ tag into `out`. Returns the plaintext length, or nil
    /// when authentication fails — which is also how a tampered header, a wrong
    /// packet number and a wrong PSK all present themselves.
    public func open(sealed: UnsafeRawBufferPointer, header: UnsafeRawBufferPointer,
                     packetNumber: UInt64, into out: UnsafeMutableRawBufferPointer) -> Int? {
        let bodyLength = sealed.count - Wire.tagSize
        guard bodyLength >= 0, out.count >= bodyLength else { return nil }
        switch mode {
        case .plaintext:
            if bodyLength > 0 {
                UnsafeMutableRawBufferPointer(rebasing: out[..<bodyLength])
                    .copyMemory(from: UnsafeRawBufferPointer(rebasing: sealed[..<bodyLength]))
            }
            return bodyLength
        case .aesGCM:
            receive.writeNonce(packetNumber, into: nonceScratch)
            guard let nonce = try? AES.GCM.Nonce(data: UnsafeRawBufferPointer(nonceScratch)),
                  let box = try? AES.GCM.SealedBox(nonce: nonce,
                                                   ciphertext: UnsafeRawBufferPointer(rebasing: sealed[..<bodyLength]),
                                                   tag: UnsafeRawBufferPointer(rebasing: sealed[bodyLength...])),
                  let plain = try? AES.GCM.open(box, using: receive.key, authenticating: header)
            else { return nil }
            return plain.copyBytes(to: out)
        }
    }

    /// Seals a handshake body with a one-shot key, whose nonce is the IV itself
    /// because that key protects exactly one packet.
    public static func sealHandshake(body: UnsafeRawBufferPointer, prefix: UnsafeRawBufferPointer,
                                     keys: DirectionKeys, into out: UnsafeMutableRawBufferPointer) -> Int? {
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: KeySchedule.ivSize, alignment: 16)
        defer { scratch.deallocate() }
        keys.writeNonce(0, into: scratch)
        guard let nonce = try? AES.GCM.Nonce(data: UnsafeRawBufferPointer(scratch)),
              let box = try? AES.GCM.seal(body, using: keys.key, nonce: nonce, authenticating: prefix)
        else { return nil }
        guard out.count >= box.ciphertext.count + Wire.tagSize else { return nil }
        let n = box.ciphertext.copyBytes(to: out)
        let t = box.tag.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: out[n...]))
        return n + t
    }

    public static func openHandshake(sealed: UnsafeRawBufferPointer, prefix: UnsafeRawBufferPointer,
                                     keys: DirectionKeys, into out: UnsafeMutableRawBufferPointer) -> Int? {
        let bodyLength = sealed.count - Wire.tagSize
        guard bodyLength >= 0, out.count >= bodyLength else { return nil }
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: KeySchedule.ivSize, alignment: 16)
        defer { scratch.deallocate() }
        keys.writeNonce(0, into: scratch)
        guard let nonce = try? AES.GCM.Nonce(data: UnsafeRawBufferPointer(scratch)),
              let box = try? AES.GCM.SealedBox(nonce: nonce,
                                               ciphertext: UnsafeRawBufferPointer(rebasing: sealed[..<bodyLength]),
                                               tag: UnsafeRawBufferPointer(rebasing: sealed[bodyLength...])),
              let plain = try? AES.GCM.open(box, using: keys.key, authenticating: prefix)
        else { return nil }
        return plain.copyBytes(to: out)
    }
}

/// A 2048-bit sliding window over reconstructed packet numbers.
///
/// At 1 Gbps that tolerates 19.7 ms of reordering, and 393 ms at 50 Mbps — far
/// more than any path this protocol targets.
public struct ReplayWindow: Sendable {
    public static let width = 2048
    private static let words = width / 64

    private var bits: [UInt64]
    /// Highest packet number accepted so far; 0 with `seen == false` means empty.
    public private(set) var highest: UInt64 = 0
    public private(set) var seen = false

    public init() { bits = [UInt64](repeating: 0, count: Self.words) }

    /// Accepts `packetNumber` if it is new and inside the window, recording it.
    /// A duplicate or a number older than the window is rejected.
    public mutating func accept(_ packetNumber: UInt64) -> Bool {
        guard seen else {
            seen = true
            highest = packetNumber
            set(packetNumber)
            return true
        }
        if packetNumber > highest {
            let shift = packetNumber - highest
            if shift >= UInt64(Self.width) {
                for i in 0..<Self.words { bits[i] = 0 }
            } else {
                shiftLeft(by: Int(shift))
            }
            highest = packetNumber
            set(packetNumber)
            return true
        }
        let behind = highest - packetNumber
        guard behind < UInt64(Self.width) else { return false }
        guard !isSet(packetNumber) else { return false }
        set(packetNumber)
        return true
    }

    /// True when the number is already recorded or has fallen out of the window.
    public func isReplay(_ packetNumber: UInt64) -> Bool {
        guard seen else { return false }
        if packetNumber > highest { return false }
        let behind = highest - packetNumber
        if behind >= UInt64(Self.width) { return true }
        return isSet(packetNumber)
    }

    public mutating func reset() {
        for i in 0..<Self.words { bits[i] = 0 }
        highest = 0
        seen = false
    }

    /// Bit 0 is `highest`, bit n is `highest - n`.
    private func isSet(_ pn: UInt64) -> Bool {
        let offset = Int(highest - pn)
        return bits[offset >> 6] & (1 << UInt64(offset & 63)) != 0
    }

    private mutating func set(_ pn: UInt64) {
        let offset = Int(highest - pn)
        guard offset < Self.width else { return }
        bits[offset >> 6] |= 1 << UInt64(offset & 63)
    }

    private mutating func shiftLeft(by n: Int) {
        let wordShift = n >> 6
        let bitShift = UInt64(n & 63)
        if wordShift > 0 {
            var i = Self.words - 1
            while i >= 0 {
                bits[i] = i - wordShift >= 0 ? bits[i - wordShift] : 0
                i -= 1
            }
        }
        if bitShift > 0 {
            var carry: UInt64 = 0
            for i in 0..<Self.words {
                let w = bits[i]
                bits[i] = (w << bitShift) | carry
                carry = w >> (64 - bitShift)
            }
        }
    }
}
