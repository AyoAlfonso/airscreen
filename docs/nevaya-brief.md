# AirScreen — a one-page brief for a casting platform

## What it is

A Mac → Android TV screen-share engine built on WebRTC. Native macOS capture and
VideoToolbox H.264, a small Android TV receiver, TLS 1.3 + certificate pairing,
Bonjour discovery, Opus audio, and a diagnostics HUD. No cloud, no account, no
media server.

**It is not an AirPlay receiver.** It does not receive an iPhone/iPad's AirPlay
stream, does not handle FairPlay/DRM, and is not Apple-certified. Guest AirPlay
in hotels is a different product with a different certification path.

## What is genuinely different

| Area | AirScreen |
|---|---|
| Codec selection | TV advertises H.264/VP8 profiles in `hello`; Mac chooses before the offer |
| Failure recovery | No frames for 3 s → TV reconnects with forced VP8; no app restart |
| H.264 encoder | Native VideoToolbox, baseline `42e01f`, hardware encode verified |
| Low latency | `MaxFrameDelayCount=1`, speed-over-quality, 1 s keyframes, no fixed VBV window |
| 1440p on cheap hardware | H.264 1440p works where VP8 failed on a 32-bit stick |
| Diagnostics | Codec, resolution, fps, stream bitrate, RTT, loss, Wi-Fi link, RSSI |
| Security | TLS 1.3 mutual auth, self-signed certs, certificate pinning, 6-digit SAS |
| Discovery | Bonjour/NSD; no IP addresses typed or hardcoded |
| Audio | Opus ~128 kbps, PCM fallback; one-byte codec tag |
| Testing | Differential pairing vectors, pairing protocol chaos, audio matrix, codec matrix |

## What it could offer a hospitality platform

- A low-latency **staff/meeting-room casting** path to Android TV or low-cost
  dongles, independent of Apple TV hardware.
- A **diagnostics layer** for "casting is bad in room 412" calls: codec,
  resolution, fps, RTT, loss, Wi-Fi link and RSSI.
- A **codec negotiation/fallback engine** that survives heterogeneous TV hardware.
- A **Mac-side capture/encode component** for back-of-house, reception or
  meeting-room screens.

## What guest AirPlay would additionally require

- An AirPlay receiver implementation and **Apple/MFi certification**.
- FairPlay/DRM handling and content-provider agreements.
- QR-per-room provisioning and checkout wipe.
- Hotel VLAN/isolation, multi-device sessions, MDM/remote support.
- 24/7 operations and a security review.

## Demo in five minutes

1. Open the TV app; it discovers the Mac over Bonjour.
2. Compare the six-digit code on both screens; approve once.
3. Share the Mac screen: H.264 1080p/1440p, audio, HUD.
4. Force a broken H.264 path; the TV falls back to VP8 automatically.
5. Show the chaos results: pairing 16/16, audio 36 combinations, codec matrix.

## The honest ask

If the goal is **guest iPhone AirPlay**, we should talk about an Apple-certified
receiver, not this. If the goal is **low-latency Mac/meeting-room casting to
Android TV with real diagnostics**, this is a working engine and a credible
starting point.
