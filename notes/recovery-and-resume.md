# Loss recovery and resume

Why the protocol repairs loss with FEC, retransmission and an early recovery frame together, and
what a resume costs from the client's return to the first frame on screen. The loss figures come
from a simulation. The resume budget combines the measurements in
[`macos-host.md`](macos-host.md) and [`ipados-client.md`](ipados-client.md) with estimated network
terms.

## Loss recovery

### The model

- 30 simulated minutes per cell, at 60 fps.
- Each frame is split into 1149-byte fragments (1200-byte datagrams) and paced at 1.25× the
  bitrate, or faster when a frame is large.
- Loss follows a time-based Gilbert–Elliott channel: rare random loss plus bursts.
- The AWDL scenario adds a 30–50 ms radio pause every second, which delays packets without
  dropping them.
- A frame that can't be decoded within its latency budget freezes the picture until a recovery
  frame arrives. A recovery frame is priced at 0.8× an IDR.
- Congestion is not modelled.

### Strategies

| Short name | FEC | Retransmission | Recovery frame |
|---|---|---|---|
| Refresh only | none | none | requested after the deadline |
| Retransmit | none | on every loss | requested after the deadline |
| Moonlight | 20%, at least 2 parity packets | none | requested as soon as a frame is known lost |
| Hybrid 10 | 10%, at least 1 | when it can land within the budget | requested as soon as a frame is known lost |
| Hybrid 20 | 20%, at least 2 | when it can land within the budget | requested as soon as a frame is known lost |

### Freezes per minute

| Scenario | Refresh only | Retransmit | Moonlight | Hybrid 10 | Hybrid 20 |
|---|---|---|---|---|---|
| LAN game, good Wi-Fi (RTT 4 ms, 0.10% loss) | 75.9 | 0 | 7.0 | 0 | 0 |
| LAN game, busy Wi-Fi (RTT 6 ms, 1.25% loss) | 238 | 0.33 | 66.7 | 0.27 | 0.17 |
| LAN game, good Wi-Fi with AWDL pauses | 76.6 | 0.03 | 7.2 | 0.10 | 0 |
| WAN desktop (RTT 30 ms, 0.13% loss), 3-frame budget | 44.4 | 3.1 | 2.3 | 0.70 | 0.50 |
| WAN desktop, 80 ms budget | 43.0 | 0.03 | 2.4 | 0.03 | 0 |
| iPad on cellular (RTT 60 ms, 1.33% loss), 3-frame budget | 102 | 103 | 25.2 | 31.8 | 25.8 |
| iPad on cellular, 140 ms budget | 81.7 | 4.0 | 25.4 | 1.8 | 1.4 |
| Bad WAN (RTT 100 ms, 4.03% loss), 220 ms budget | 62.0 | 17.6 | 60.7 | 9.9 | 9.5 |

Overhead, as extra bytes over the media: Retransmit tracks the loss rate (0.1–4.4%); Hybrid 10
costs 11–21%; Moonlight and Hybrid 20 cost 20–38%. Small desktop frames pay the most, because of
the minimum parity count.

### What the numbers say

- **FEC alone can't absorb Wi-Fi bursts.** Moonlight's scheme leaves 7–67 freezes a minute on a
  LAN, where a retransmission lands well inside three frames.
- **Retransmission alone fails once the round trip doesn't fit the budget:** 103 freezes a minute
  on cellular with a three-frame budget.
- **The hybrid gets both:** at most 0.27 freezes a minute on a LAN at ~11% overhead. On WAN it
  needs a budget that fits one retransmission, max(50 ms, 2 × RTT + 20 ms): 1.4–1.8 freezes a
  minute on cellular.
- **What a recovery frame costs barely matters on a LAN.** Re-run with every recovery frame
  priced as a full IDR, the hybrids' LAN results stayed at or below 0.23 freezes a minute, within
  noise of the original run.
- **Radio pauses aren't loss.** With AWDL pauses every strategy delivered about 85 frames a minute
  more than one frame late, and no recovery scheme changes that. The iPad's real Wi-Fi trace
  (`ipados-client.md`) shows a different pattern from the model: RTT spikes clustering every ~5 s
  for ~250 ms.
- At 4% loss and 100 ms RTT nothing works well; the rate controller has to reduce the load.

## Resume budget

From the client's return to the first new frame on its screen:

| Case | Total | Largest terms |
|---|---|---|
| Mac client, LAN blip, decoder kept, unchanged desktop (1080p) | 12–51 ms | waiting for a captured frame (0–17 ms), P-frame encode (8 ms), display refresh (0–17 ms) |
| iPad → Mac, LAN, host warm, decoder lost (1440p, 20 Mb/s) | 24–70 ms | capture wait, IDR encode (11–13 ms), IDR on the wire (5–17 ms), display refresh |
| iPad → Mac, WAN through a warm tunnel (RTT 40 ms, 20 Mb/s) | 73–152 ms | the round trip (40 ms); the IDR through the bottleneck (16–68 ms: a 40 KB fast-start IDR to a 165 KB full one) |
| Same, host pipeline cold | 146–379 ms | adds a cold encoder (23–28 ms) and a capture restart (50–200 ms, estimated) |
| Same, tunnel cold (stale keys, expired NAT mapping) | 163–592 ms | adds a WireGuard handshake (40 ms) and path discovery (50–400 ms) |
| Moonlight and Sunshine reconnecting, RTT 4 ms (estimate) | 240–1090 ms | ~22 round trips of HTTPS, RTSP and ENet setup; host session start (150–1000 ms) |
| Same, RTT 40 ms (estimate) | 1050–1900 ms | 900 ms of round trips plus host session start |

- On an iPad, the ~300 ms between `willEnterForeground` and `didBecomeActive` hides a LAN resume
  entirely.
- On iOS, Moonlight also tears the stream down when the app is backgrounded, so the user has to
  pick the host and app again. That is not counted above.
- **Tunnels are outside the protocol but set the WAN floor.** wireguard-go holds packets for a new
  handshake once a key is 180 s old, and Tailscale stops maintaining an idle peer's direct path
  after 45 s. A host that wants fast WAN resumes keeps the tunnel warm with keepalives while a
  client is parked. Neither tunnel propagates ECN, so congestion control has to work from delay.
