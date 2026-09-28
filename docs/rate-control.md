# Rate control

> **Not yet written.** It replaces version 0's manually set bitrate and loss backstop
> ([feedback.md](feedback.md)). What is already decided is below; [gaps.md](gaps.md) lists
> the measurements it waits on.

It will define how a sender chooses how fast to send, so that the stream follows the path
instead of overrunning it.

## Decided

- **A sender MUST run delay-based congestion control**, driven by the per-packet arrival times
  in `FEEDBACK`. libwebrtc's Google Congestion Control is the reference design. It works from
  delay rather than from loss or ECN marks, because tunnels such as WireGuard and Tailscale
  don't carry ECN ([notes/recovery-and-resume.md](../notes/recovery-and-resume.md#resume-budget)).
- **A circuit breaker**, in the manner of RFC 8083, stops a sender whose controller fails to
  rein it in.
- **FEC and retransmissions count inside the target rate.**
- **The target changes every 0.1 to 1 s,** and the encoder follows it without an IDR.
- **Degradation follows the client's preset** ([modes.md](modes.md)): `GAME` keeps the frame
  rate and lowers quality, then resolution; `DESKTOP` keeps quality and lowers the frame rate.
- **A change of IP address resets the controller** ([packets.md](packets.md#validating-a-new-address)).
- **One rate per session.** With several video streams, the controller divides its rate among
  the streams that show a display, after audio, by a weight the client may set for each; by
  default in proportion to each stream's pixel rate ([displays.md](displays.md#what-a-session-has-once)).
- **Probing** for spare capacity uses `PADDING` ([packets.md](packets.md#padding-0x00)).
- **Target:** after a link's capacity halves, queueing delay returns under twice its baseline
  within one second.

## Waiting on

- How fast Windows encoders follow a new target.
- Whether the pacing requirement is achievable on Windows.
