import Foundation
import Testing

@testable import LightrayVectors

@Test func exampleHandshakeHoldsTogether() {
    let example = Example()
    #expect(example.initDatagram.count == Example.maxDatagramSize)
    #expect(example.responseDatagram.count <= example.initDatagram.count)
    #expect(example.sessionUnknown.count == 22)
    #expect(example.clientToHostKey != example.hostToClientKey)
}

@Test func initFailsUnderAnotherPSK() {
    let example = Example()
    var psk = Example.psk
    psk[0] ^= 1
    #expect(Handshake.readInit(example.initDatagram, psk: psk, ephemeralPrivate: Example.hostEphemeralPrivate) == nil)
}

@Test(arguments: [2, 3, 4, 11])
func everyCleartextInitByteIsAuthenticated(offset: Int) {
    // Reserved bytes (2, 3) and the pairing id (4 through 11) are in the prologue.
    var datagram = Example().initDatagram
    datagram[offset] ^= 1
    #expect(Handshake.readInit(datagram, psk: Example.psk, ephemeralPrivate: Example.hostEphemeralPrivate) == nil)
}

@Test func packetNumbersReconstruct() {
    let cases: [(UInt64, UInt32, UInt64)] = [
        (0, 0, 0),
        (8, 7, 7),
        (0xffff_fffe, 3, 0x1_0000_0003),
        (0x1_0000_0002, 0xffff_fffd, 0xffff_fffd),
        (0x1_0000_0000, 0x8000_0000, 0x1_8000_0000),
        (0x1_0000_0000, 0x8000_0001, 0x8000_0001),
        (0x1_8000_0000, 0, 0x2_0000_0000),
        // Near 2⁶⁴, where a sum in the comparison would overflow.
        (0xffff_ffff_8000_0000, 1, 0xffff_ffff_0000_0001),
        (0xffff_ffff_ffff_fff0, 0xffff_fff8, 0xffff_ffff_ffff_fff8),
    ]
    for (expected, transportSeq, packetNumber) in cases {
        #expect(Packet.reconstruct(expected: expected, transportSeq: transportSeq) == packetNumber)
    }
}

@Test func sealedPacketsOpenOnlyWhenUntouched() {
    let key = Bytes(repeating: 0x42, count: 32)
    let packetNumber: UInt64 = 0x1_0000_0005
    let header = ProtectedHeader(sessionID: 1, transportSeq: 5, sendTimeMicros: 9)
    let sealed = Packet.seal(header: header, packetNumber: packetNumber, key: key, chunks: Packet.close(0))
    #expect(Packet.open(sealed, key: key, expected: 0x1_0000_0000)?.packetNumber == packetNumber)
    // The high 32 bits never travel, but they are in the nonce: a wrong guess fails to open.
    #expect(Packet.open(sealed, key: key, expected: 0x2_0000_0000) == nil)
    var tampered = sealed
    tampered[1] ^= 1
    #expect(Packet.open(tampered, key: key, expected: 0x1_0000_0000) == nil)
}

@Test func slugsFollowGitHub() {
    #expect(Docs.slug("`RESUME` (`0x33`)") == "resume-0x33")
    #expect(Docs.slug("Resetting input across a resume") == "resetting-input-across-a-resume")
    #expect(Docs.slug("Why — a dash") == "why--a-dash")
}

@Test func blockNamesAreUnique() {
    let names = Catalog.blocks().map(\.name)
    #expect(Set(names).count == names.count)
}
