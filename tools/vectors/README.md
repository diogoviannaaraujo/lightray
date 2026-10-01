# Test vectors

Generates every hex example in [`docs/`](../../docs) and [`vectors.json`](vectors.json), and
checks that the documents still match them. The examples are worked from fixed inputs through
both sides of the protocol, so a document can't show bytes that one side would produce and the
other reject.

`vectors.json` holds the inputs and outputs of the worked examples in a form any language can
read. It is the file to test an implementation against. The Swift here only produces it.

## Commands

Requires macOS and Swift 6. The package uses CryptoKit and nothing else.

```bash
swift run --package-path tools/vectors lightray-vectors check
```

| Command | What it does |
|---|---|
| `check [docs]` | Compares every marked block with its vector, checks every relative link and heading anchor, and checks that `vectors.json` is current. Exits 1 on any problem. |
| `update [docs]` | Rewrites marked blocks from their vectors and writes `vectors.json`. |
| `generate [file]` | Writes `vectors.json` only. |
| `print <name>` | Prints one vector as the documents show it. |
| `list` | Lists the vector names. |

## Marking a block

A fenced block directly after a marker is generated:

````markdown
<!-- vector: packets.close -->
```
3400020001
```
````

To add one, give it a name in `Catalog.blocks` in `Sources/LightrayVectors/Catalog.swift`, put
the marker and an empty block in the document, and run `update`.

## How the generator is checked

```bash
swift test --package-path tools/vectors
```

- **Noise.** The handshake and transport messages match the published
  `Noise_NNpsk0_25519_AESGCM_SHA256` vector from cacophony, the Noise test vectors most
  implementations check against. `Tests/LightrayVectorsTests/Fixtures/` holds that one entry
  unchanged, with its source.
- **X25519.** The keys and shared secret match RFC 7748, section 6.1, and version 0's worked
  example.
- **Lightray.** Building the worked example runs the host's side against the client's and stops
  unless they agree: the host opens the INIT, the client opens the RESPONSE, and both hold the
  same traffic keys. Changing any cleartext INIT byte makes the INIT fail to open.

## Independent FEC reference

`fec_reference.py` uses Python 3.9 or later and the standard library to generate GF(256) fixtures with bitwise multiplication and a Vandermonde matrix, independently of the Swift implementation.
The core tests consume the checked-in fixture to verify coefficients, parity bytes, zero padding, and recovery.

```sh
python3 tools/vectors/fec_reference.py --check macos/Tests/LightrayCoreTests/Fixtures/fec-reference.json
swift test --package-path macos --filter fecMatchesIndependentFixture
```

To regenerate after reviewing an intentional change, use `--output` with the same fixture path and inspect the diff.
