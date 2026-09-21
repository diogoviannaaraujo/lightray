# Recorded experiments

Measurements were collected locally on 21/09/2026; each JSON report records Python, platform, codec-library versions, input SHA-256, configuration, seed, counters and assertions.

- [matrix.md](matrix.md) / [matrix.json](matrix.json): the full 640×360, 30 fps, 1 Mbps network and lifecycle matrix, six seconds of scheduled streaming per scenario.
- [1080p.md](1080p.md) / [1080p.json](1080p.json): additional 1920×1080, 60 fps target, 8 Mbps software-encoder runs to expose encoder/scheduler limits as well as transport behavior.
- [strict-recovery.json](strict-recovery.json): the intentionally failing four-second lost-recovery experiment using the documentation's literal same-request-ID retry rule.

The `.h265` videos and per-frame/event traces are retained locally in the ignored `../artifacts/` directory; the compact files here are the reviewable record suitable for version control.
The first 15 matrix traces live under `artifacts/validated/`; the seven lifecycle/configuration traces were rerun after the asynchronous encode-cancellation fix and live under `artifacts/validated-lifecycle/`.
Both groups use the identical `artifacts/validated/sample-h265.mp4` source, configuration and seed; the JSON report records this collection method.
See [FINDINGS.md](../FINDINGS.md) for what these measurements do and do not establish.
