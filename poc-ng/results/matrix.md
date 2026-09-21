# HEVC end-to-end results

Real UDP on localhost with a seeded user-space impairment relay; software HEVC encode and decode through PyAV/FFmpeg.
Capture means submission of a decoded sample picture to the live encoder; latency ends at decoded output, before display.
Both endpoints use the same machine's monotonic clock; these measurements do not establish one-way latency on unsynchronized remote machines.

| Scenario | Decoded / sent | p50 ms | p95 ms | p99 ms | Max decode gap ms | Pixel errors | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| clean | 180 / 180 | 12.472 | 31.319 | 45.547 | 38.877 | 0 | PASS |
| lan | 180 / 180 | 13.271 | 34.092 | 47.059 | 37.647 | 0 | PASS |
| wan | 180 / 180 | 34.632 | 62.864 | 65.48 | 44.459 | 0 | PASS |
| long_rtt | 180 / 180 | 75.874 | 77.958 | 78.543 | 41.15 | 0 | PASS |
| random_loss | 180 / 180 | 15.206 | 43.39 | 56.155 | 111.384 | 0 | PASS |
| burst_loss | 180 / 180 | 15.38 | 58.092 | 90.172 | 110.436 | 0 | PASS |
| reordering | 180 / 180 | 25.651 | 47.83 | 62.544 | 74.734 | 0 | PASS |
| corruption | 180 / 180 | 14.384 | 43.376 | 50.341 | 106.243 | 0 | PASS |
| constrained | 180 / 180 | 35.073 | 42.178 | 86.178 | 41.699 | 0 | PASS |
| reverse_loss | 180 / 180 | 17.354 | 33.731 | 49.571 | 38.093 | 0 | PASS |
| lost_response | 180 / 180 | 14.415 | 16.097 | 16.948 | 38.5 | 0 | PASS |
| blackout | 168 / 180 | 15.242 | 34.765 | 47.652 | 442.996 | 0 | PASS |
| lost_recovery | 172 / 180 | 14.256 | 33.783 | 48.86 | 303.239 | 0 | PASS |
| decoder_reset | 179 / 180 | 14.069 | 32.385 | 47.69 | 82.181 | 0 | PASS |
| rebind | 180 / 180 | 14.431 | 32.939 | 47.124 | 39.785 | 0 | PASS |
| park_resume | 171 / 171 | 14.353 | 34.582 | 45.023 | 361.19 | 0 | PASS |
| resume_state_loss | 171 / 171 | 14.665 | 33.736 | 47.122 | 360.619 | 0 | PASS |
| expiry | 171 / 171 | 14.474 | 36.238 | 48.066 | 370.056 | 0 | PASS |
| host_restart | 121 / 121 | 14.646 | 44.392 | 47.239 | 2041.688 | 0 | PASS |
| mtu_change | 180 / 180 | 14.555 | 32.148 | 47.489 | 40.141 | 0 | PASS |
| resolution_change | 180 / 180 | 12.698 | 32.683 | 48.357 | 39.089 | 0 | PASS |
| framerate_change | 122 / 122 | 18.278 | 42.472 | 47.448 | 73.061 | 0 | PASS |

Failures are preserved, not excluded from the report.
The maximum decode gap includes intentional parks and network outages.
This is a protocol experiment, not a production throughput benchmark or full v0 conformance claim.
