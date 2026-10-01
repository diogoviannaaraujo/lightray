// Experimental C ABI only; no production session handles or ownership contract yet.
@_cdecl("lightray_probe_open_packet")
public func probeOpenPacket(
    _ input: UnsafePointer<UInt8>?, _ count: Int32,
    _ key: UnsafePointer<UInt8>?, _ keyCount: Int32,
    _ packetNumber: UInt64,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int32
) -> Int32 {
    guard let input, let key, let output, count >= Packet.minimumLength,
        count <= 65_535, keyCount == 32, capacity >= count - Int32(Packet.overhead),
        packetNumber < UInt64.max
    else { return -1 }
    let datagram = Array(UnsafeBufferPointer(start: input, count: Int(count)))
    let trafficKey = TrafficKey(Array(UnsafeBufferPointer(start: key, count: 32)))
    guard let plaintext = Packet.open(datagram, packetNumber: packetNumber, key: trafficKey) else { return -2 }
    for (index, byte) in plaintext.enumerated() { output[index] = byte }
    return Int32(plaintext.count)
}
