# LightrayCore

The Swift package the Lightray apps share on macOS and iOS: the protocol in
[`docs/`](../docs/README.md), and what an app needs around it to run a host or a client.

- **The protocol**, with no I/O: the handshake, packets, reliable streams, video with FEC, and the
  host and client endpoints. An endpoint takes datagrams and the time, and returns datagrams and
  events.
- **Around it:**
  - the UDP socket and the clock;
  - pairing tokens and their storage, saved computers and per-host session preferences;
  - the HID ↔ Mac key-code map, and the remote keyboard, which can swap Command and Control for
    Windows hosts;
  - the VideoToolbox encoder, and a bounded decoder that drops what it cannot keep up with and
    measures its timings;
  - `VideoRenderer`, which shows decoded pictures in an `AVSampleBufferDisplayLayer`;
  - `ClientRunner`, which runs a client's endpoint and decoders on queues of their own and leaves
    the app its windows and input.

The Mac host and client are in [`macos/`](../macos/README.md), and the iPad client is in
[`ios/`](../ios/README.md). Both need this directory beside them.

## Build and test

Requires macOS 27 or iOS 27, and Swift 6.4. The package builds in the Swift 6 language mode.

```bash
swift test --package-path apple
```

The tests reproduce every value in [`tools/vectors/vectors.json`](../tools/vectors/vectors.json),
parse and re-encode the hex examples in the version 0 documents, decode the IDR published in
[`video.md`](../docs/video.md) with VideoToolbox, and run a host against a client over a simulated
path with loss, jitter and address changes. The names of the conformance tests they cover are in
the test files.

For iOS, from this directory:

```bash
xcodebuild -scheme LightrayCore -destination 'generic/platform=iOS' build
```

In the iOS Simulator every test passes except `encoderOutputDecodes`: the simulator has no
hardware HEVC encoder.
