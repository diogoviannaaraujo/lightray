# iPad client

What an iPad client can rely on when the app leaves the foreground and comes back, and what
decoding, the network and encryption cost on the device.

Measured on 24 September 2026 on an iPad mini (A17 Pro, `iPad16,1`) running iPadOS 27.0, on Wi-Fi
(5 GHz, channel 48, 160 MHz), against a Mac (Apple M4, macOS 27.0) on Ethernet on the same LAN.
These are single runs on one device: read the numbers as orders of magnitude.

## Lifecycle: what survives leaving the app

| Case | Away | Process after leaving | Old socket on return | Decoder on return |
|---|---|---|---|---|
| Nothing active | 8 s | suspended after 0.3–0.4 s | reclaimed | invalidated |
| Background task | 14 s | kept running | alive | invalidated |
| Background task | 107 s | ran 26.4 s until the task expired, 5.0 s more, then suspended | reclaimed | invalidated |
| Audio playing | 41 s | kept running | alive | invalidated |
| Picture-in-picture | 57 s | kept running | alive | **alive** (old session decoded in 2.9 ms) |

- **A reclaimed socket fails every operation:** send `EPIPE` (32), receive `ENOTCONN` (57),
  `SO_ERROR` `EBADF` (9). The first send on it raised `SIGPIPE` and killed the process, with no
  crash report, until the socket was given `SO_NOSIGPIPE`. Reclaiming happened within 8 s of
  suspension.
- **A new socket works at once:** creating and binding one took 0.19–0.43 ms, and its first send
  succeeded every time.
- **A message sent from `didEnterBackground` always got out:** heartbeats continued for 0.3–0.4 s
  after it.
- **`willEnterForeground` came 300–306 ms before `didBecomeActive`** on every return: the
  app-switch animation. Work started at `willEnterForeground` is hidden behind it.
- **The decoder does not survive the background** except under picture-in-picture: `-12903`
  (`kVTInvalidSessionErr`). Rebuilding cost 8.6–9.3 ms and the first IDR decode 5.7–6.2 ms.
- **Opening Control Center fires `willResignActive`** without backgrounding the app.
- **Wi-Fi off for about 10 s and back on the same network:** `NWPathMonitor` reported
  `unsatisfied` within ~160 ms and `satisfied` ~250 ms after `en0` returned. Heartbeats resumed
  on the same socket and port after a 17.2 s gap; the socket survived.

## Decoding

| Stream | Decoder create | First IDR decode | Steady P-frame decode p50 / p99 |
|---|---|---|---|
| 1080p HEVC, 20 Mb/s | 34.3 ms (first in process), 1.0 ms warm | 5.8 ms | 2.1 / 2.7 ms |
| 1440p HEVC, 20 Mb/s | 2.5–4.2 ms | 8.0 ms | 3.3 / 4.6 ms |
| 2266×1488 (native), 40 Mb/s | 2.6–4.0 ms | 7.8 ms | 3.1 / 4.2 ms |
| 2160p HEVC, 40 Mb/s | 17.0 ms (first 4K), 1.8 ms warm | 11.3 ms | 6.2 / 7.8 ms |

HEVC Main10 4:2:0, Main 4:2:2 10-bit, Main 4:4:4 10-bit and Main 4:4:4 8-bit clips (1080p, encoded
with libx265) all decoded without error, at 2.0–3.7 ms per frame.

## Network and crypto

- **UDP receive, 1200-byte datagrams, 3 s each:**

  | Offered | Loss | Longest arrival gap |
  |---|---|---|
  | 50 Mb/s | 0 | 29 ms |
  | 100 Mb/s | 0.11% | 35 ms |
  | 200 Mb/s | 0.02% | 20 ms |
  | 400 Mb/s | 1.52% | 68 ms |

  `SO_RCVBUF` accepted 8 MB.
- **30 s of 1 kHz pings to the Mac:** RTT p50 2.4 ms, p90 14.6 ms, p99 43.2 ms, max 104.9 ms.
  Elevated-RTT clusters recurred every ~5 s and lasted ~250 ms on average (8.3% of pings above
  17.4 ms). The Mac saw the same ~5 s pattern in uplink arrivals.
- **AEAD per 1200-byte datagram:**

  | Cipher | Seal | Open |
  |---|---|---|
  | AES-256-GCM | 2.7 µs (first measured, includes warm-up) | 1.1 µs |
  | AES-128-GCM | 1.0 µs | 0.9 µs |
  | ChaCha20-Poly1305 | 2.6 µs | 2.4 µs |

## Implications

- **Always resume from a new socket.** Never reuse a socket that lived through suspension, and
  never send on one without `SO_NOSIGPIPE`.
- **Start resuming at `willEnterForeground`.** A LAN resume (~25–75 ms) completes inside the
  ~300 ms animation.
- **Assume a resuming iPad client has lost its decoder.** Only picture-in-picture keeps it.
- **Audio keeps a session and its socket alive, so a "video suspended" state is worth having:**
  video stops, audio continues, and returning needs only an IDR.
- **Reconnecting from a fresh launch must cost the same as a resume,** because iPadOS may
  terminate a suspended app at any time to reclaim memory.
- **`willResignActive` is not a reason to park.**
