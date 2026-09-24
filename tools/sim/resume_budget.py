"""Resume latency budgets for Lightray v1 scenarios.

Each component is (low_ms, high_ms, source). Sources:
  M  = measured on this Apple M4 (ResumeProbe, this session)
  S  = Phase 0 spikes (git history, Spikes/FINDINGS.md)
  C  = read from source code (wireguard-go, Tailscale magicsock, Sunshine, moonlight-common-c)
  E  = estimate / assumption, stated
Totals are low = sum of lows, high = sum of highs; they are budgets, not measurements.
"""

KB = 1024


def tx_ms(size_kb, mbps):
    return size_kb * KB * 8 / (mbps * 1e6) * 1e3


def budget(name, parts):
    lo = sum(p[1] for p in parts)
    hi = sum(p[2] for p in parts)
    return {"name": name, "parts": parts, "lo": lo, "hi": hi}


scenarios = []

# 1. iPad -> Mac, LAN Wi-Fi, back after 2 min. Decoder lost (iOS invalidates VT sessions in background),
#    host pipeline warm (encoder + capture kept alive). 1440p-class HEVC at 20 Mb/s.
rtt = 4
scenarios.append(budget("iPad→Mac, LAN, host warm, decoder lost (1440p, 20 Mb/s)", [
    ("Client: new socket + RESUME out", 0.2, 0.5, "S"),
    ("½ RTT up (Wi-Fi LAN, RTT 3–6 ms)", 1.5, 3, "E"),
    ("Host: capture frame (reuse last / wait next)", 0, 16.7, "E"),
    ("Host: IDR encode, warm encoder", 10.9, 13.1, "M"),
    ("IDR 165 KB on wire (burst 300 Mb/s … paced 1 frame)", tx_ms(165, 300), 16.7, "M/E"),
    ("½ RTT down", 1.5, 3, "E"),
    ("Client: decoder create (hidden if started at foreground)", 0, 3.0, "M"),
    ("Client: first IDR decode", 5.1, 5.4, "M"),
    ("Display: next vsync (120 Hz)", 0, 8.3, "E"),
]))

# 2. Mac client -> host, LAN, short blip (e.g. Wi-Fi roam) with decoder alive: resume with a P-frame.
scenarios.append(budget("Mac client, LAN blip, decoder alive, unchanged desktop (1080p)", [
    ("Client: RESUME out (+ last decoded frame id)", 0.2, 0.5, "S"),
    ("½ RTT up", 1.5, 3, "E"),
    ("Host: capture frame", 0, 16.7, "E"),
    ("Host: P-frame encode referencing acked frame", 7.6, 8.5, "M"),
    ("P-frame 1–2 KB on wire", 0.1, 0.3, "M"),
    ("½ RTT down", 1.5, 3, "E"),
    ("Client: decode", 1.2, 2.5, "M"),
    ("Display: next vsync (60 Hz)", 0, 16.7, "E"),
]))

# 3. iPad -> Mac over Tailscale, tunnel warm (keys fresh, direct path alive), RTT 40 ms, 20 Mb/s path.
rtt = 40
scenarios.append(budget("iPad→Mac, WAN via Tailscale, tunnel warm (RTT 40 ms, 20 Mb/s)", [
    ("Client: new socket + RESUME out", 0.2, 0.5, "S"),
    ("½ RTT up", 20, 20, "E"),
    ("Host: capture frame", 0, 16.7, "E"),
    ("Host: IDR encode, warm", 10.9, 13.1, "M"),
    ("IDR on the bottleneck: 40 KB fast-start … 165 KB full", tx_ms(40, 20), tx_ms(165, 20), "M/E"),
    ("½ RTT down", 20, 20, "E"),
    ("Client: first IDR decode (decoder pre-created)", 5.1, 5.4, "M"),
    ("Display: next vsync (120 Hz)", 0, 8.3, "E"),
]))

# 4. Same, tunnel cold: WireGuard keypair older than RejectAfterTime (180 s) and NAT mapping expired.
scenarios.append(budget("iPad→Mac, WAN via Tailscale, tunnel cold (keys stale, NAT expired)", [
    ("Everything in the warm-tunnel budget", scenarios[-1]["lo"], scenarios[-1]["hi"], "above"),
    ("WireGuard handshake before data (1 RTT, staged packets)", 40, 40, "C"),
    ("Path re-discovery: DERP detour / disco + hole punch", 50, 400, "C/E"),
]))

# 5. Same as 3 but the host tore the pipeline down (pipeline_idle_after passed).
scenarios.append(budget("iPad→Mac, WAN, tunnel warm, host pipeline cold", [
    ("Everything in the warm-tunnel budget", scenarios[2]["lo"], scenarios[2]["hi"], "above"),
    ("Cold encoder first IDR instead of warm (1440p)", 34.1 - 10.9, 38.5 - 10.9, "M"),
    ("Capture restart (ScreenCaptureKit / DXGI) — not measured", 50, 200, "E"),
]))

# Reference: GameStream (Moonlight/Sunshine) session start, counted in round trips from source.
def gamestream(rtt_ms, host_init_lo, host_init_hi):
    # /serverinfo + /resume over HTTPS (TCP + TLS 1.3 + request, x2 connections) ~ 6 RTT,
    # RTSP OPTIONS/DESCRIBE/SETUP x3/ANNOUNCE/PLAY = 7 transactions, each a fresh TCP connection (2 RTT) = 14 RTT,
    # ENet connect ~1.5 RTT, video/audio UDP ping ~1 RTT.
    rtts = 6 + 14 + 1.5 + 1
    return budget(f"Moonlight/Sunshine reconnect (RTT {rtt_ms} ms) — estimate", [
        ("~22.5 protocol round trips (HTTPS, 7 RTSP over new TCP each, ENet, pings)", rtts * rtt_ms, rtts * rtt_ms, "C"),
        ("Host session start: capture + encoder init, cold first IDR", host_init_lo, host_init_hi, "E"),
        ("iOS only: stream torn down on background, user re-selects host and app", 0, 0, "C (not counted)"),
    ])


scenarios.append(gamestream(4, 150, 1000))
scenarios.append(gamestream(40, 150, 1000))

if __name__ == "__main__":
    for s in scenarios:
        print(f"\n{s['name']}: {s['lo']:.0f}–{s['hi']:.0f} ms")
        for (label, lo, hi, src) in s["parts"]:
            print(f"   {lo:7.1f} – {hi:7.1f} ms  [{src}]  {label}")
