# Lightray

A Swift 6.2+ UDP streaming protocol library for macOS 26+, with a deterministic core, X25519/PSK handshake, AES-GCM packet protection, media fragmentation, reliable input/control, loss recovery, and park/rebind/resume.
HEVC and Opus payloads are opaque; the package does not capture, encode, or decode media.

```sh
cd poc-astra
swift build
swift test
swift test -c release
```

Run a complete local Mac-to-Mac loopback benchmark with two dedicated event-loop threads:

```sh
swift run -c release lightray-demo benchmark --seconds 5 --mbps 20
swift run -c release lightray-demo benchmark --seconds 5 --mbps 80
swift run -c release lightray-demo benchmark --seconds 5 --mbps 1000
swift run -c release lightray-demo benchmark --seconds 5 --mbps 20 --reconnect
```

For separate terminals on this Mac:

```sh
swift run -c release lightray-demo host --port 47000 --seconds 60
swift run -c release lightray-demo client --host 127.0.0.1 --port 47000 --seconds 60 --reconnect
```

The demo uses a public fixed pairing key and synthetic payloads exclusively for local tests.
Applications must supply their own paired PSK and host reset secret.

```swift
import Lightray

let host = try LightrayHost(port: 47000, pairings: [pairingID: pairingPSK], secret: hostResetSecret) { sessionID, event in
    // Record the session ID, pause on .parked, and produce an IDR on .refreshRequired.
}
let client = try LightrayClient(peer: PeerAddress(host: "127.0.0.1", port: 47000), pairingID: pairingID, psk: pairingPSK) { sessionID, event in
    // Retain delivered frames for asynchronous decode and call reportDecoded after success.
}
// Keep the runtime objects alive while streaming.
client.park()
client.resume(decoderLost: true)
```

Import LightraySession for a synchronous sans-IO engine and LightrayTestSupport for virtual-time network simulations.
Default streams are host video 1, host audio 2, client microphone 3, client camera 4, reliable input 5, and unreliable datagrams 6; stream 0 is reserved for control.
Use CODEC_CONFIG on every IDR and supply the parameter-set serialization expected by your decoder integration.
Callbacks execute on the transport thread and must return promptly.

```sh
cd Benchmarks
BENCHMARK_DISABLE_JEMALLOC=true swift package benchmark --no-progress
```

The benchmark suite explicitly validates allocation counting with a positive control because the tooling's default malloc metric may report false zeros without jemalloc.
Run `scripts/ci.sh` for checks or `scripts/benchmark-local.sh` to capture local throughput reports.

See [protocol-v0.md](Docs/protocol-v0.md) for byte encodings and interoperable vectors, [architecture.md](Docs/architecture.md) for ownership, limits, and lifecycle integration, and [Definition.md](../Definition.md) for the original implementation plan.
