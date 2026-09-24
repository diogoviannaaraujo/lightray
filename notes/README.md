# Notes

Measured platform behaviour that host and client implementations depend on, and the evidence
behind the protocol's defaults. Notes are informative: where a note and the specification in
[`docs/`](../docs) disagree, the specification wins.

| Note | What it covers |
|---|---|
| [`ipados-client.md`](ipados-client.md) | An iPad client: what survives the app leaving the foreground, decoder rebuild, decode cost, UDP receive, Wi-Fi jitter, AEAD cost |
| [`macos-host.md`](macos-host.md) | A Mac host: VideoToolbox costs on the resume path, long-term-reference recovery, chroma formats, rate-control behaviour |
| [`recovery-and-resume.md`](recovery-and-resume.md) | Why loss recovery combines FEC, retransmission and early refresh, and what a resume costs end to end |

Windows host measurements are being made on the `windows-validation` branch.

## Where the numbers came from

The probes, the simulator and their raw output are not in the tree. They are in the history at
commit `3cf4c28`. To look at them without disturbing a checkout:

```bash
git worktree add ../lightray-research 3cf4c28
```
