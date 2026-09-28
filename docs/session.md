# Session lifecycle

> **Not yet written.** This document will replace [reconnect.md](reconnect.md), which holds
> the version 0 text. What is already decided is below; [gaps.md](gaps.md) lists the
> measurements it waits on.

It will define how a session lives through a client's absences: parking, resuming, suspending
video, taking a session over after the client's app restarts, and expiry.

## Decided

- **States.** Active; video suspended, where audio continues; parked warm, where the host keeps
  capture and the encoder alive; parked cold, where it releases both; and expired.
- **Parking.** `PARK` says how long the client expects to be away. The host keeps the pipeline
  warm for a window it clamps to its own limits; the default windows are in
  [modes.md](modes.md).
- **Suspending video.** A client whose picture is hidden but whose audio still plays, such as a
  backgrounded iPad app playing sound, suspends video instead of parking. Returning costs an
  IDR. Suspension is per video stream: hiding one display's window suspends that stream alone
  ([displays.md](displays.md#parking-and-resuming)).
- **Resuming.** `RESUME` carries, for each video stream, whether the client's decoder survived
  and which frame it last decoded; the input resume points; and what the client wants as its
  first frame. Input may follow `RESUME` in the same datagram.
- **The host's answer**, for each video stream on its own: a P-frame or long-term-reference
  refresh when that stream's decoder still holds a usable reference; otherwise an IDR, which may
  be a smaller "fast-start" IDR when bandwidth is short.
- **Displays.** The display each video stream shows survives a park and a take-over. The host
  sends its list of displays after a resume ([displays.md](displays.md)).
- **Relaunching.** A client whose app was killed reconnects with a new handshake that takes over
  its session ([handshake.md](handshake.md#taking-over-a-session)), and must get back as fast
  as a resume.
- **App suspension is a park.** On iPadOS, an app leaving the foreground parks its session.
  System sleep still ends a session.
- **Rebinding.** The rules for a changed address, and the cap on what a host sends to a new IP
  address, are in [packets.md](packets.md#addresses).

## Still to decide

- Whether a host sends keepalives to a client parked warm, to keep a VPN's path to it alive.
  Tailscale stops maintaining an idle peer's direct path after 45 s
  ([notes/recovery-and-resume.md](../notes/recovery-and-resume.md#resume-budget)).
- What survives a take-over beyond the session identifier, stream table, settings and pipeline,
  and whether a take-over from a new IP address resets rate control as a rebind does.

## Waiting on

- Whether a Windows host can hold a warm park, and what a cold one costs.
- Whether a resume must budget for a capture restart, and whether hosts need a "video
  unavailable" notice.
- Whether Windows encoders can produce a fast-start IDR.
