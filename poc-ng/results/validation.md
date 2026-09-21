# Validation record — 21/09/2026

- `python -m pytest -q`: 68 passed, 4 expected failures, 22.08 seconds.
- The four strict expected failures reproduce published documentation-example contradictions; they are explained in `../FINDINGS.md`.
- 22 independent 640×360 network/lifecycle scenarios passed their declared assertions; 3,795 frames decoded with no pixel mismatches.
- Three additional 1080p runs passed their correctness/recovery assertions; 630 frames decoded with no pixel mismatches, with significant software capture-rate limitations and packet-loss effects recorded in the reports.
- The strict same-request-ID recovery experiment intentionally exited 1: 42 of 120 frames decoded and 2,617.32 ms of terminal no-output time.
- Both existing Swift implementations passed before and after this work: Astra 32 tests, Claude 31 tests.
- Editable installation and the `lightray-ng` CLI entry point were checked.
- Recorded JSON summaries were checked for scenario count, successful assertions, decoded-frame totals and absence of pixel mismatches.

The matrix combines its first 15 scenarios with seven lifecycle/configuration retests following the asynchronous encoder-cancellation fix, using identical input bytes, configuration and seed.
The new cancellation regression deliberately leaves an encode in flight during PARK and verifies cancellation and recovery.
The final capture scheduler uses a fixed cadence and records missed opportunities rather than moving the deadline after every late frame.

Detailed test logs from this session are at `/tmp/poc-ng-final-tests.log`, `/tmp/poc-ng-after-astra.log` and `/tmp/poc-ng-after-claude.log`.
These temporary logs are supplementary; the tests, source, compact reports and findings are in this folder's parent and can be rerun using its README.
