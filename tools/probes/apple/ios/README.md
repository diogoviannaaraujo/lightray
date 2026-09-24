# iPad probe

Measures, on a real iPad, the things the protocol's resume path and defaults depend on and that
the iOS Simulator cannot reproduce:

| Measurement | Why the specification needs it |
|---|---|
| Suspension timing, and what happens to a UDP socket across suspension | Whether `RESUME` must always come from a new socket, and how long `PARK` has to get out |
| `willEnterForeground` → `didBecomeActive` | How much of a resume the app-switch animation hides |
| VideoToolbox decoder after a background/foreground cycle, and rebuild cost | Whether a returning client always needs an IDR, and how long the rebuild takes |
| Decoder creation, first IDR and steady P-frame decode at 1080p, 1440p, native and 4K | The client side of the resume budget |
| Hardware decode of HEVC Main10, 4:2:2 10-bit and 4:4:4 | Which chroma and HDR options `DESKTOP` mode can offer |
| AES-256-GCM, AES-128-GCM and ChaCha20-Poly1305 per datagram | The cost of the Noise `AESGCM` cipher on the client |
| UDP receive at 50–400 Mb/s | Receive-path headroom and socket buffer limits |
| 30 s of 1 kHz pings to the Mac | Wi-Fi jitter, including AWDL stalls, which sizes the latency budgets |
| Heartbeats while backgrounded with audio or picture-in-picture | Whether a client can keep its session alive instead of parking |

## One-time setup

1. Connect the iPad by USB and tap Trust.
2. On the iPad: Settings → Privacy & Security → Developer Mode → On (the iPad restarts).
3. In Xcode → Settings → Accounts, sign in with an Apple ID. A free personal team is enough; its
   team ID is the ten-character code shown next to the team, or in `security find-identity -v -p codesigning`
   once Xcode has created a certificate.
4. The first launch asks for Local Network access on the iPad. Allow it, or nothing reaches the Mac.

## Running

```bash
./run-device.sh <TEAM_ID> 192.168.1.109 -auto
```

This builds and installs the app, launches it, and runs `ProbeHost` in the foreground, writing
`tools/probes/results/ipad-<model>-<date>.txt`. With `-auto` the app runs every measurement
once (about 90 seconds; keep the app in front). The Wi-Fi jitter trace is only meaningful with
the Mac on Ethernet and the iPad on Wi-Fi.

Then run the lifecycle cases by hand, watching `ProbeHost`'s output:

| Case | Do | Expect in the log |
|---|---|---|
| Short absence | Home, wait 30 s, reopen | `PARK`, a heartbeat gap, `RESUME …`, `FOREGROUND …`, `DECODER_AFTER_BACKGROUND …` |
| Long absence | Home, wait 3 min, reopen | The same, after a longer suspension |
| Screen lock | Lock, wait 60 s, unlock | The same, or a longer gap |
| Audio keep-alive | Toggle it on, Home, wait 60 s | Whether heartbeats continue while in the background |
| Picture-in-picture | Run the decoder probe, toggle PiP on, Home | `KEEPALIVE pip started`, and whether heartbeats continue |
| Network change | In the foreground, turn Wi-Fi off and on | `PATH …`, and whether heartbeats resume on the old socket |

The app also appends everything to `Documents/probe.log`, which survives a broken socket and is
visible in the Files app.

## Simulator smoke test

```bash
./build.sh sim
```

The Simulator shares the Mac's network stack and hardware, so run `ProbeHost` and launch the app
with `-host 127.0.0.1 -auto` only to check the plumbing; its numbers describe the Mac, not an iPad.
