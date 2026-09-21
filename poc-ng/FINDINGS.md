# Protocol review from the independent HEVC demo

Reviewed on 21/09/2026 against the `docs/` tree introduced by commit `8a70c9a`.
The demo implements that wire format independently; it does not treat the older implementations as the protocol definition.
The findings below distinguish reproducible specification problems, explicit experiment policies, and implementation limitations.

## Documentation revision status

The protocol documentation was revised on 21/09/2026 to correct the examples and clarify recovery attempts, pacing, deadlines, frame-ID wrap, configuration transitions, client liveness, and reliable-state retention across ordinary resume.
The findings below describe the pre-revision specification and preserve the evidence behind those changes.
The four broken-example expected failures have been replaced by passing checks against the corrected documentation, including actual HEVC decoding and datagram authentication.
The demo runtime still resets reliable state on resume and therefore does not yet conform to the revised retention requirement.
LTR reference lifetime and the broader HEVC/HDR contract remain open in [gaps.md](../docs/gaps.md).

## 1. A lost recovery frame can make the specified retry rule stall permanently

[video.md](../docs/video.md) requires repeating the same `REFRESH_REQUEST.req_id` until a satisfying frame arrives, while forbidding the sender to produce more than one recovery frame per request ID.
Once that recovery frame is lost beyond its retransmission deadline, repeating that ID cannot produce another recovery frame.

Reproduction: `python -m ng.demo --scenarios lost_recovery --seconds 4 --strict-recovery`.
The test resets the decoder, lets the sender receive its recovery request, and blocks protected host-to-client traffic for 250 ms so the recovery IDR expires.
The strict run fails its end-of-run recovery assertion; [results/strict-recovery.json](results/strict-recovery.json) preserves the measurement.
`test_literal_recovery_rule_has_no_progress_after_lost_idr` also demonstrates the state-machine dead end without real-time scheduling.

Experiment policy: repeats retain the same ID within an attempt, but after `max(2 × frame_deadline, 3 × srtt)` without recovery the receiver starts a new attempt with a new ID.
The protocol should define the attempt's lifetime, what frame/decoder event satisfies it, and when a new ID or escalation is permitted.
This policy is not presented as existing normative text.

## 2. Historical LTR acknowledgement does not imply a currently usable decoder reference

[video.md](../docs/video.md) calls `LTR_ANY` always deliverable, while requiring the receiver to discard acknowledgements after a decoder reset.
A recovery frame already in flight may refer to the decoder instance that was destroyed.
Resolution/profile changes and encoder replacement likewise need an explicit reference lifetime, and delayed acknowledgements must not reintroduce an obsolete reference.

`test_decoder_reset_blocks_old_ltr_even_after_ack` checks the receiver-side guard; the live matrix exercises IDR recovery after decoder reset.
Real successful LTR recovery is not tested by this demo because libx265 does not provide the required acknowledged-token control through this adapter.
The recommendation is a decoder/reference epoch or an equally precise invalidation rule, with IDR required after reference loss.

## 3. Plain resume does not make unseen old reliable messages disappear

[input.md](../docs/input.md) restarts reliable message sequence numbers at zero on resume, while [reconnect.md](../docs/reconnect.md) preserves traffic keys and replay state.
A delayed packet that was never received is not a replay, even if its reliable message sequence is zero from the previous active period.
It can therefore authenticate after resume and collide with a new message zero.

`test_old_unseen_reliable_packet_survives_plain_resume_replay_window` constructs the protected packets and demonstrates that the old packet still opens after newer PARK/RESUME packets.
This demonstrates the missing epoch distinction, not an attacker forging encryption.
The protocol needs a reliable-channel epoch, retained monotonic message sequences, a well-defined authenticated packet cutoff, or new keys on resume.
The demo does not silently invent a new wire field to fix this.

## 4. A fresh host reset key cannot prove that an old session is gone

[handshake.md](../docs/handshake.md) generates the host reset-token key at startup.
After host restart, a token derived with the new key does not match the token that the client obtained from the old host instance, so the client must ignore it.
The docs specify how to act on a valid `SESSION_UNKNOWN` but leave this restart path without a bounded fallback.

`test_fresh_host_reset_key_cannot_authenticate_old_session_reset` verifies the mismatch.
The `host_restart` scenario discards traffic keys, session state, reset-token key and replay cache and verifies a new handshake followed by a decoded IDR.
Experiment policy: after two seconds without authenticated inbound traffic an active/resuming client abandons its old session and starts a fresh handshake with the same pairing PSK.
This timeout should be specified or explicitly assigned to the application; it is not equivalent to trusting an invalid reset token.

## 5. Configuration generation is not a decoder-reference epoch

[control.md](../docs/control.md) advances the generation for any accepted change but prohibits forcing an IDR for bitrate or frame-rate changes.
A receiver therefore cannot reject prediction merely because its generation differs from the last decoded frame.
`test_generation_change_without_idr_preserves_prediction` and the live `framerate_change` scenario preserve the chain through the generation transition.
The live `resolution_change` scenario instead rebuilds the encoder and verifies a self-contained IDR and correct decoded output at the new resolution.

The spec should distinguish reference-preserving changes from decoder-rebuilding changes and state what to do with held old frames, delayed STATE/RESULT messages and old reference acknowledgements.
The receiver in this experiment accepts a newer generation's self-contained IDR without waiting for its reliable configuration message.

## 6. Pacing and loss timers need compatible definitions

[video.md](../docs/video.md) says every frame must be spread across at least one frame interval, but its recommended token bucket can release a small frame immediately from accumulated tokens and drain larger frames faster when the configured rate exceeds their size divided by the interval.
[feedback.md](../docs/feedback.md) first prohibits NACKing beyond the highest observed fragment index, then allows it for a missing tail after a short inactivity timer.
A short inactivity interval can occur while a valid paced frame is still being sent.

The demo uses the stated bucket/rate approach with a 32-datagram burst cap and a link-rate ceiling, and delays an unobserved tail until at least two frame intervals have elapsed as well as the reorder window.
`test_no_nack_for_unsent_paced_tail` checks that distinction, and clean-link scenarios assert zero NACKs.
The docs should define a pacing envelope rather than a literal minimum duration for every small frame, make the tail exception explicit, and define the origins of sender and receiver deadlines.
Here sender expiry starts at submission; receiver expiry starts at first fragment arrival or first observation of a whole-frame gap.
These are local clocks and are not assumed synchronized by the wire protocol.
A first implementation using one frame interval reproduced a false tail NACK on a lossless 320×180 run: the initial paced keyframe took about 38 ms to arrive, beyond the nominal 33 ms interval.
Two intervals leave scheduler slack while retaining one interval of the default three-interval deadline for repair; this is a measured demo policy, not a universal network bound.

## 7. Four worked-example contradictions are executable

At review time, the following tests were marked `xfail(strict=True)` so the problems remain visible instead of being normalized into permissive parsers:

| Test | Published problem |
| --- | --- |
| `test_published_idr_example_is_valid` | The 8-byte CODEC_CONFIG cannot contain three u32 lengths plus VPS/SPS/PPS. |
| `test_published_media_fragment_is_valid` | Fragment index 2 of 5 has 8 bytes of payload with stride 1149, violating the non-last-fragment rule. |
| `test_published_packet_obeys_media_packing` | The complete packet example combines MEDIA_FRAGMENT and PONG, which its own packing rules forbid. |
| `test_published_ltr_length_difference` | The prose says omitting the u32 LTR reference saves two bytes; it saves four. |

Correction to the preliminary review: the LTR_ANY hex example itself is a valid 13-byte header, not 12 bytes.
`test_published_ltr_any_example_has_complete_header` passes.
The documented INIT SHA-256 vector and FEEDBACK bitmap/chained-arrival example also pass independently.

## 8. Wrap and codec constraints still need explicit decisions

[video.md](../docs/video.md) says frame IDs increment, wrap, and never use zero; it does not define the successor/predecessor operation across that boundary.
The demo skips zero and tests prediction across `0xFFFFFFFF -> 1`.
Transport packet numbers, replay-window reconstruction and wrapping microsecond deltas are tested separately and keep their specified arithmetic.

The actual encoded dependency structure must match the protocol reference metadata.
This demo enforces no B frames, one short-term reference, closed GOPs and genuine IDR NAL types.
That is a deliberately narrow interoperable profile, not evidence that arbitrary HEVC with reordering or multiple unreported references works with the metadata model.
HDR profile, bit depth, chroma and color metadata remain untested and insufficiently pinned by the HDR boolean alone.

## 9. The asynchronous codec boundary needs lifecycle cancellation

A fixed-cadence run exposed a demo bug: PARK could arrive while the encoder was working, and its completed output was then submitted to the already parked transport.
The application adapter now checks that the session is still active and has the same identity after the asynchronous encode finishes; otherwise it discards that output before assigning a frame ID.
`test_encoding_in_flight_during_park` deliberately slows encoding across the transition and asserts that cancellation happened and streaming recovered.
This is an implementation finding, not evidence that PARK's wire format is wrong.

## Recorded 1080p limits

The 1920×1080, 60 fps target, 8 Mbps software path submitted 239 frames in six seconds on the clean link, about 40 fps, and decoded all 239 without pixel mismatches.
The fixed-grid capture scheduler recorded 121 skipped opportunities, rather than hiding slow encoding by moving each next capture deadline later.
At 1% forward/reverse packet loss it decoded 170 of 211 submitted frames, with a 100.499 ms p95 end-to-end latency; correctness/recovery assertions passed, but this is visibly worse service than the clean run.
These numbers include software codec and reference-validation overhead and must not be described as hardware VideoToolbox performance.
The source counters, stage timings and loss rates are in [results/1080p.json](results/1080p.json).

## Measurement interpretation and implementation limits

The passing matrix demonstrates real encrypted UDP transport and decoded-picture integrity under its stated profiles and policies.
It does not prove full Lightray conformance, independent-vendor interoperability, display latency, hardware throughput, LTR operation, or behavior on actual cellular/Wi-Fi paths.
The oracle uses the same codec library on a clean path; this is a transport-corruption check, not a cross-decoder codec certification.

The library adapter explicitly refuses live bitrate changes and reports a required sustained-loss backstop as unsupported.
The FFmpeg libx265 wrapper initializes its rate-control parameters when opening the encoder; simply assigning `CodecContext.bit_rate` after opening is not proof that encoder rate control changed.
`test_backstop_requirement_is_detected_without_claiming_codec_support` verifies that this limitation remains observable.
A hardware/encoder adapter with verified live rate control is still required to test actual bitrate-floor enforcement.
This is an implementation coverage gap, not a new protocol defect.

The next protocol revision should settle recovery-attempt lifetime, reference validity, resume epochs and host-restart liveness first, then turn the corrected wire examples into a shared conformance-vector file used by every implementation.
