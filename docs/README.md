# Lightray protocol, version 1

Lightray is a UDP protocol for low-latency interactive streaming: one machine (the **host**)
sends encoded video and audio to another (the **client**), and the client sends back input and,
optionally, its microphone. It is built for the case where a person is controlling what they are
watching, so a late frame is worse than a missing one.

What sets it apart is **session continuity**. A client that goes away, because its app was sent
to the background, its lid closed or its network dropped for a moment, comes back to the same
session in about one round trip and one frame. The host makes that possible by keeping capture
and the encoder running while the client is away.

This directory is the protocol definition. When it is finished it will be complete enough to
build a conforming host or client from, in any language, without reference to any existing
implementation.

## Status

Version 1 is being written. It replaces version 0, which stays in the git history. Until every
document is rewritten, some still hold version 0 text and say so at the top; the reading map
below gives the state of each. They are being written in this order:

1. `packets.md` and `handshake.md`
2. `video.md` and `audio.md`
3. `feedback.md` and `rate-control.md`
4. `control.md` and `modes.md`
5. `session.md`, replacing `reconnect.md`
6. `input.md`
7. `registries.md`, `conformance.md` and `gaps.md`

Steps 2 to 6 wait on measurements of Windows hosts; [gaps.md](gaps.md) lists what each one
needs.

[displays.md](displays.md) was written ahead of that order. It defines how a session shows several
of the host's displays; the documents above define the bytes of its messages as they are
rewritten.

## What the protocol does

- **Establishes a session** in one round trip, with a Noise handshake keyed by a pairing secret
  the application supplies. Every packet after that is encrypted and authenticated.
- **Carries video as frames** split across datagrams and protected by forward error correction,
  and **audio as small frames** with redundant copies of recent ones.
- **Repairs loss in escalating steps:** forward error correction first, then retransmission when
  it can still arrive in time, then a recovery frame the client asks for, and only then a
  keyframe.
- **Controls its own rate** from per-packet delay feedback, so the stream follows the path
  instead of overrunning it.
- **Lets the client choose trade-offs:** a preset, such as `GAME` or `DESKTOP`, and individual
  controls, all changeable at any time.
- **Survives the client going away.** A parked session resumes, a relaunched app takes its
  session over, and a change of network costs no keyframe.
- **Defines input:** keyboard, pointer and gamepads, and a cursor channel from host to client.
- **Shows several displays at once,** each on a video stream of its own, independent of the
  others, with one audio stream and one set of input for all of them.

## What the protocol does not do

- **It does not encode or decode anything.** It constrains what the video encoder may produce
  ([video.md](video.md)), but it never inspects a payload.
- **It does not capture the screen or inject input.** It defines what input messages mean; the
  host decides how to deliver them.
- **It does not traverse NAT**, discover peers, or pair devices. The application supplies an
  address, a pairing identifier and a pre-shared key.
- **It does not tunnel.** VPNs such as WireGuard and Tailscale work beneath it, at the operating
  system level. Nothing here is specific to them, and the default 1200-byte datagram fits inside
  them.

## Codecs are pinned to the version

Version 1 means **H.265 (HEVC)** video and **Opus** audio at 48 kHz. The video is low-delay,
with no B-frames and no reordering, in the Main or Main10 profile and optionally 4:4:4; the
exact contract is in [video.md](video.md). Nothing on the wire carries a codec identifier. A peer that
disagrees about codecs disagrees about the version, and fails the version check instead of
negotiating.

> **Why.** Codec negotiation is a large, rarely exercised surface that exists to serve a
> flexibility this protocol does not need: both ends ship together. Pinning the codecs to the
> version turns a negotiation failure into a version failure, which is simpler to specify,
> simpler to test, and impossible to get subtly wrong.

## Presets

A client chooses a preset when it connects, can override any single control within it, and can
change either at any time. `GAME` keeps the frame rate and latency, and gives up picture quality
first when bandwidth drops. `DESKTOP` keeps the picture sharp, and gives up frame rate first.
[modes.md](modes.md) defines both.

## Design targets

The defaults are tuned for three uses:

1. playing games on a Mac from a Windows host, over a LAN;
2. using one Mac from another over the internet;
3. using a Mac from an iPad over the internet, where coming back from the background matters
   most.

They are judged against three targets:

- A client that returns after about two minutes sees a new frame one round trip and one frame
  later: 25–70 ms on a LAN with a warm host.
- On busy LAN Wi-Fi, `GAME` freezes at most 0.5 times a minute, at no more than 15% overhead.
- After a link's capacity halves, rate control brings queueing delay back under twice its
  baseline within one second.

The measurements behind these numbers are in [`notes/`](../notes/README.md).

## How to read this directory

| Document | Read it when | State |
|---|---|---|
| [handshake.md](handshake.md) | Establishing a session, deriving keys, taking over a session | Version 1 |
| [packets.md](packets.md) | Building or parsing any packet after the handshake | Version 1 |
| [video.md](video.md) | Sending or receiving video, or repairing its loss | Version 0, to be rewritten |
| [displays.md](displays.md) | Showing more than one of the host's displays, or choosing which one | Version 1; its byte layouts come with the documents it names |
| [audio.md](audio.md) | Sending or receiving audio | Version 0, to be rewritten |
| [feedback.md](feedback.md) | Reporting what arrived, requesting repair, measuring the path | Version 0, to be rewritten |
| [rate-control.md](rate-control.md) | Choosing how fast to send | Not yet written |
| [control.md](control.md) | Changing settings mid-session | Version 0, to be rewritten |
| [modes.md](modes.md) | Presets and the controls a client can set | Not yet written |
| [session.md](session.md) | Parking, resuming, suspending video, expiry | Not yet written |
| [input.md](input.md) | Keyboard, pointer, gamepads, the cursor, and the microphone | Version 0, to be rewritten |
| [registries.md](registries.md) | Looking up any number that appears on the wire | Partly version 1 |
| [conformance.md](conformance.md) | Checking an implementation, or handling bad input | Partly version 1 |
| [gaps.md](gaps.md) | Finding out what version 1 leaves unresolved | Version 1 |
| [reconnect.md](reconnect.md) | Nothing: replaced by `session.md` | Version 0 |

## Conformance language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**, **SHOULD**,
**SHOULD NOT**, **RECOMMENDED**, **NOT RECOMMENDED**, **MAY** and **OPTIONAL** in these
documents are to be interpreted as described in BCP 14 (RFC 2119 and RFC 8174) when, and only
when, they appear in all capitals, as shown here.

Text in a blockquote beginning **Why** is rationale. It explains a decision and is not
normative; an implementation is never obliged by it.

## Notation

- All integers are **unsigned and big-endian** unless the field is explicitly named as
  signed. `u8`, `u16`, `u32`, `u64` and `i16` denote widths in bits.
- All lengths count **bytes**, and a length field never includes its own width or the
  width of the type tag that precedes it.
- `a ‖ b` is concatenation. `x[m..n)` is bytes `m` up to but not including `n`.
- Field diagrams list fields top to bottom in wire order.
- **Reserved** means: a sender MUST write zero, and a receiver MUST ignore the value.
  This is what lets a later version use the space without a version bump.

Hex examples are raw bytes, 16 to a line, decoded underneath; a trace of intermediate values
gives one labelled value to a line. None is written by hand:
[`tools/vectors`](../tools/vectors/README.md) works each example through both sides of the
protocol from the inputs the document states, and checks that the documents still show exactly
what it produces. The same values are in
[`tools/vectors/vectors.json`](../tools/vectors/vectors.json), for testing an implementation.

## A session at a glance

```
client                                                        host
  |                                                             |
  |--- INIT (padded to max_datagram_size) --------------------->|
  |<-- RESPONSE (session id, accepted parameters) --------------|
  |                                                             |
  |=== protected datagrams, both directions ===================>|
  |     media, input, feedback, repair requests                 |
  |<============================================================|
  |                                                             |
  |--- PARK (how long the client expects to be away) ---------->|  host keeps capture
  |                          (silence)                          |  and the encoder warm
  |--- RESUME (new source port, decoder state) ---------------->|
  |<-- STATE, then a P-frame, a refresh or a keyframe ----------|
  |                                                             |
```

A session begins with one round trip and ends when either side sends `CLOSE`, when the host
expires it, or when the host forgets it. Everything in between is protected datagrams.

## Versioning

The version is a `u8` carried in the clear in the second byte of every handshake packet. This
directory defines version 1. Version 1 is not compatible with version 0.

A receiver that sees a version it does not implement, version 0 included, MUST silently discard
the packet and SHOULD count the event. It MUST NOT reply, because a reply would be an
amplification opportunity and there is nothing to negotiate.

Versions 2–239 are reserved for future revisions of this protocol. Versions 240–255 are
reserved for private use and MUST NOT be assigned by a future revision.

## Windows client work

Para revisar o trabalho publicado, começar pelo [guia do pull request](windows/pull-request-review.md), com mapa dos fontes, testes, evidências, relatórios e pendências de integração.

Incremento de experiência Mac → Windows: [painel em milissegundos e atalhos de teclado](windows/client-ux-progress.md), orientado pela [investigação do Parsec e plano de evolução](reviews/parsec-reference-2026-09-29.md).

Prioridade atual desde 29/09/2026: [host Windows nativo com NVENC](windows/host-implementation-plan.md), com a [primeira campanha de encoding e interoperabilidade](windows/host-nvenc-progress.md) concluída no laboratório.
Etapa mais recente: [componente NVENC e integração UDP local](windows/host-live-progress.md), com lifecycle, memória e limites documentados.
Incremento anterior: [ponte C do host e transporte autenticado](windows/host-bridge-progress.md), ainda em pacote isolado de laboratório.
O trabalho do cliente abaixo permanece preservado e não deve ser confundido com encoding do host.

Relatório para revisão e repasse ao desenvolvedor: [resultados Windows e próximos passos, 29/09/2026](windows/developer-report-2026-09-29.md).

The [implementation plan](windows/implementation-plan.md), [compatibility profile](windows/compatibility-profile.md), [validation plan](windows/validation-plan.md), and [foundation progress](windows/foundation-progress.md) distinguish the implemented desktop subset from future protocol features.

Execução mais recente do cliente Windows: [apresentação D3D11](windows/presentation-probe-progress.md), após [core Swift x64](windows/swift-core-progress.md), [decode 1440p/4K](windows/resolution-validation-progress.md), [primeira validação nativa](windows/native-validation-progress.md) e [correções de robustez](windows/robustness-progress.md).

Telemetria Windows → Mac: [captura/conversão, encode e conciliação de amostras](windows/host-telemetry-progress.md).

Atualização de 01/10/2026 para o desenvolvedor: [relatório consolidado](windows/developer-report-2026-10-01.md) e [plano detalhado de produto e validação](windows/product-validation-plan-2026-10-01.md).
Os incrementos mais recentes são [recuperação limitada de captura](windows/capture-recovery-progress.md) e [menu de sessão, preferências e teclado](windows/session-controls-progress.md), com o Samsung reservado aos testes visuais.

Conexão gráfica e alternativa de captura: [execução F01/F02 com Windows Graphics Capture e NVENC](windows/connection-capture-progress-2026-10-01.md), com vídeo/input reais no Samsung e teste 4K com alvo de 90 FPS.
