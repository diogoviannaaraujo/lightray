# Windows platform adapter

`lightray-windows` implements Windows APIs in Rust. It does not build or link the legacy C++ laboratory under `tools/windows`.

- Capture uses a two-buffer, free-threaded Windows Graphics Capture pool with the cursor enabled. A D3D11 video processor scales BGRA into limited-range BT.709 NV12. Native NVIDIA NVENC encodes HEVC Main using a synchronous low-latency session, a registered GPU texture, and one compressed bitstream buffer.
- Decode discovers registered HEVC Media Foundation transforms with `MFTEnumEx`, including packaged Microsoft HEVC Video Extensions. It requires D3D11 awareness and an HEVC Main hardware decoder profile, binds an `IMFDXGIDeviceManager`, rejects CPU output buffers, and converts GPU NV12 surfaces directly into an aspect-fit composition swap chain. It never reads uncompressed pixels onto the CPU.
- Input maps USB HID keyboard usages to Windows scan codes, handles Unicode text and five pointer buttons, and maps normalized coordinates into the physical virtual desktop. Display enumeration is cached for pointer events and refreshed after one second or an unknown display. `release_all` is also called on injector destruction.
- Pairing secrets use current-user DPAPI with application-specific optional entropy. Desktop availability excludes the lock screen and secure desktop.

## Ownership and recovery

Construct and use each `CaptureEncoder` or `DecoderRenderer` on one dedicated worker thread. Each owns an MTA initialization reference until its native objects have been destroyed. D3D11 multithread protection is enabled, and device frame latency is limited to one.

`DecoderRenderer::swap_chain` transfers one COM reference to its caller. Attach it to `SwapChainPanel` on the UI thread, then release that transferred reference; the panel and renderer keep their own references. Detach the panel before destroying its window. Resize is serialized with decoding. GPU device removal is observable with `is_device_lost`; recreate the renderer and reattach its new swap chain rather than attempting to retain resources from the removed device.

Capture recovery discards the invalid frame pool and recreates capture at most once per 250 ms, with a ten-second deadline. Geometry changes rebuild the GPU converter. Recovery requires a fresh capture before sending another frame and forces an IDR. Static desktops retain the last converted NV12 surface for forced IDRs and a one-second keepalive frame.

`VideoConfig::from_parameter_sets` parses raw VPS/SPS/PPS received from Apple peers and derives display dimensions from the HEVC SPS. HEVC access units cross the public API using four-byte, big-endian NAL lengths. Annex B conversion exists only at the native codec boundaries.

`last_timings` reports CPU call durations: capture includes capture acquisition or synthetic drawing plus GPU conversion submission; encode includes NVENC submission and compressed-bitstream wait; decode excludes presentation; presentation includes output-view setup, GPU conversion submission, and `Present`. These values are not GPU timestamps or input-to-photon measurements.

## Validation

From the repository root:

```powershell
cargo test --manifest-path windows/Cargo.toml -p lightray-windows
cargo clippy --manifest-path windows/Cargo.toml -p lightray-windows --all-targets -- -D warnings
cargo test --manifest-path windows/Cargo.toml -p lightray-windows -- --ignored
cargo run --release --manifest-path windows/Cargo.toml -p lightray-windows --example media_smoke -- 36000
```

Normal tests cover HID mappings, malformed HEVC framing, DPAPI round trips and tampering, and Apple VideoToolbox parameter sets. Hardware tests are ignored on ordinary CI and explicitly exercise GPU decoder resize/reconfiguration, Apple VideoToolbox decoding with a six-frame loss and IDR recovery, and recreation after closing a real WGC frame pool. The moving-pattern example supports `--capture` for real desktop capture and `--encode-only` for encoder diagnostics.
