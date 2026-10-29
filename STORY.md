# The cheap TV stick that became a screen-sharing engine

I bought a small Android TV stick for a spare screen. I did not want to buy an
Apple TV just to put my Mac's screen on it, so I started with the thing I had:

**One HDMI stick, one Mac, and no cloud.**

## Getting in

The stick had no keyboard. I enabled Developer Options, turned on USB debugging,
and found it listening on port 5555 over Wi-Fi. My Mac could ping it. `nc` could
open the port. `adb` still said **"No route to host."**

So I wrote a tiny relay: `127.0.0.1:5556` on the Mac forwards to the stick's
`5555`. ADB talked to localhost, the relay walked the bytes across the Wi-Fi, and
the TV appeared. That was the first lesson: *ping is not a connection, and a port
being open is not a protocol.*

## The first picture

I built a Mac menu-bar app with ScreenCaptureKit and WebRTC. The TV showed the
screen. It was also soft: WebRTC had quietly dropped the picture to 640×360 to
save bandwidth. I pinned the resolution, raised the bitrate, and told it to give
up frame rate before pixels. Text became readable.

## The codec detour

VP8 worked, but H.264 was the better bet: hardware decode, better compression,
and 1440p on a box that could not do VP8 at 1440p. Forcing it was not a setting:

- `preferredCodec = H264` did nothing to the offer.
- Filtering the SDP to H.264 made `setLocalDescription` hang.
- A H.264-only offer connected audio but left the video black.

So I wrote the encoder myself: a native **VideoToolbox H.264 encoder** in
ObjC++, exposed through WebRTC's `RTCVideoEncoderFactory`, pinned to a single
constrained-baseline profile so the TV's decoder would accept it. The TV lit up
with `OMX.realtek.video.dec.avc` at 2560×1440.

## The typing lag

It still felt slightly behind VP8. VideoToolbox was holding frames. I set
`MaxFrameDelayCount = 1`, prioritised encoding speed over quality, shortened
keyframes to one second, and removed the fixed rate-limit window. H.264 went from
about 33 fps to 52–60 fps, and typing felt normal.

If H.264 ever fails, the TV notices no frame for three seconds and reconnects
with **VP8**. The app does not restart; you see "Optimising video…" for a moment
and the picture comes back.

## Making it safe and boring

The first version trusted the LAN. The current one does not:

- TLS 1.3 with mutual authentication.
- A self-signed certificate on each end, pinned by fingerprint.
- A six-digit code derived from both certificates, shown on both screens.
- Bonjour discovery, so there is no IP address to type.
- Opus audio at ~128 kbps instead of 1.5 Mbps of raw PCM.

The TV sends its decoder capabilities first. The Mac picks H.264 or VP8 before
it sends a single frame. If the TV has no Opus decoder, it gets PCM. Nothing has
to guess.

## What it is

A one-click Mac → Android TV screen-share engine. No Apple TV, no cloud, no
account. It runs on a cheap 32-bit stick, handles 1080p and 1440p, shows a small
HUD with codec, resolution, fps, bitrate, latency, packet loss, Wi-Fi link and
signal, and recovers from a bad codec negotiation without asking the user.

It is not AirPlay. It does not receive an iPhone's screen, and it does not do
DRM. It is the piece I could build end-to-end: capture, encode, transport,
decode, pairing, diagnostics, and the unglamorous network debugging in between.
