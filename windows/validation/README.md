# Windows validation — 2026-10-15

Initial implementation against Apple/protocol base `2aac433`, tested locally on Windows 11 x64 with an RTX 4090. These results describe the working source tree; no implementation commit or published release has been created.

- `udp-1080p60-600s.json`: 36,000/36,000 generated, encoded, authenticated-UDP-delivered and hardware-decoded frames, 60 fps for ten minutes; zero decoder failures or session disconnects. Peak retained protocol memory 5,164 bytes, final retained memory zero. Timing arrays in the benchmark are bounded separately from protocol queues.
- `winui-connected.jsonl`: the actual WinUI client connected to the independent Rust synthetic host, attached the D3D11 swap chain, and reported 1080p60 through its ten-second run. The first FPS sample covers a partial startup second. Both applications exited cleanly after the test.
- `../platform/validation-results.json`: native codec soak and actual Apple VideoToolbox fixture, GPU resize/reset, WGC recovery, DPAPI and HID mapping tests.
- `host-lifecycle.json`: actual current-user login task registration, ready sharing agent, agent survival after settings handle destruction, and Stop Sharing from a fresh handle. The task and test agent were removed; sharing remained disabled. A concurrent test correctly refused to run over the active test service. This checks task configuration without logging Windows out.

The regular suite has 20 portable protocol tests, 11 runtime tests, and four platform tests; three additional hardware tests run explicitly on the GPU. Formatting and Clippy pass with warnings denied. Both independently published WinUI applications pass startup/shutdown smoke tests, and the C ABI checks handle lifetime, command/event buffers, capacity negotiation and stale handles. The pipe regression exercises an abandoned client followed by a healthy request on an isolated, current-user control channel.

`udp-1080p60-loss5.json` records a separate ten-second run with seeded 5% packet loss: all 600 frames delivered and decoded using FEC and retransmission.

The UDP soak uses a synthetic moving pattern and a composition swap chain without a visible consumer. Its CPU call durations and GPU submissions are not physical displayed FPS, scanout latency, or input-to-photon measurements. The connected WinUI check verifies surface attachment separately. Complex game content, physical multi-display hotplug/lock interaction, and real remote input still need interactive acceptance.

**MacBook network interoperability remains pending in both directions.** Apple wire vectors and bitstream fixtures provide independent compatibility checks, but cannot establish a successful live Mac session.
