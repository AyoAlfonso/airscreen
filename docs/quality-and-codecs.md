# Quality, codecs, and the C++ route

## Test results on the Strong LEAP / UHD Google TV Stick

| Test | Result |
|---|---|
| 1080p, 10 Mbps, VP8 | **Works:** decoder 1920×1080, ~38–46 fps, hardware VP8 decoder |
| 1440p, 25 Mbps, VP8 | Decoder initialises at 2560×1440, **0 frames rendered** |
| **1440p, 25 Mbps, H.264 (VideoToolbox)** | **Works:** decoder `OMX.realtek.video.dec.avc`, 2560×1440; peak ~56–58 fps, but sustained rate can drop under thermal/network load |
| **1080p, 15 Mbps, H.264, low-latency tuning** | **Works:** hardware VideoToolbox encode (`value=1`), decoder `OMX.realtek.video.dec.avc`, 1920×1080, ~52–60 fps |
| **Codec handshake** | TV `hello` advertises H.264/VP8 profiles; Mac selects H.264 only when baseline matches, otherwise VP8 |
| **Chaos codec matrix** | All 5 capability cases and H.264 → VP8 fallback pass (`tools/chaos_codec.py`) |
| **Automatic fallback** | Broken H.264 → TV watchdog → reconnect with `forceCodec: VP8` → decoder `OMX.realtek.video.dec.vp8`, ~59 fps |
| 1440p, 15 Mbps, VP8 | Same: decoder initialises, **0 frames** |
| H.264 `preferredCodec` | No effect; VP8 still negotiated |
| H.264-only SDP filter | `setLocalDescription` hangs; offer never sent |
| H.264-first SDP reorder | Offer accepted, but Android still answers VP8 |
| H.264-only encoder factory | Audio connects, **no video** (profile mismatch) |
| Android `setCodecPreferences` | H264 list accepted/reordered, still VP8; fixed `createAnswer` ordering |

**Conclusion:** VP8 is limited to 1080p on this unit; **H.264 via a VideoToolbox
hardware encoder unlocks 1440p** at ~56–58 fps. The previous H.264 failures were
profile/negotiation issues, not a hardware limit. The working PoC is a native
ObjC++ `RTCVideoEncoder` with a single constrained-baseline profile (`42e01f`).

## Why H.264 is hard here

- WebRTC negotiates codecs from the SDP offer; `preferredCodec` is only an
  encoder-factory hint.
- The correct API is `RTCRtpTransceiver.setCodecPreferences`, fed from
  `RTCRtpSender/Receiver.getCapabilities("video")`.
- H.264 has profiles (`42e01f`, `4d0032`, `640032`). Sender and receiver profile
  strings must intersect. A H.264-only list can leave no common profile, which
  is what happened (audio only, no video).
- On macOS ObjC, `RTCRtpCodecCapability` has no public initializer in the
  prebuilt WebRTC framework, so `setCodecPreferences` is awkward; SDP filtering
  is rejected by `setLocalDescription`.
- Chromium tracks the Android H.264 profile mismatch:
  <https://issues.chromium.org/40283913>
- WebRTC Android decoder profiles:
  <https://chromium.googlesource.com/external/webrtc/+/HEAD/sdk/android/src/java/org/webrtc/MediaCodecVideoDecoderFactory.java>

## C++ options

### 1. libwebrtc C++ with a custom `VideoEncoderFactory` / `VideoDecoderFactory` — **PoC built**

- Build libwebrtc from source (large: ~20 GB checkout, hours) or obtain a
  prebuilt with C++ headers.
- Implement `webrtc::VideoEncoderFactory` returning a VideoToolbox H.264
  encoder on macOS, and a MediaCodec H.264 decoder on Android.
- Force exactly one H.264 profile (e.g. baseline `42e01f`) in the SDP fmtp.
- Bridge the C++ core to Swift/ObjC++ and Kotlin/JNI.
- **Implemented PoC:** `mac/Sources/AirScreen/H264VideoEncoderFactory.mm` — a
  VideoToolbox H.264 encoder exposed through `RTCVideoEncoderFactory`, advertising
  only baseline `42e01f`. It negotiates H.264 and decodes on the TV at 1440p.
- **Effort for the PoC:** moderate; **control:** maximum; **risk:** H.264-only
  factory has no VP8 fallback yet.

### 2. GStreamer `webrtcbin` (C)

- Mac: `avfvideosrc` (screen capture) → `vtenc_h264` → `webrtcbin`.
- Android: `webrtcbin` → `amcviddec` / `decodebin` → `autovideosink`.
- Force H.264 with caps; GStreamer handles RTP/RTCP/SRTP.
- **Effort:** medium-high; **control:** good; **risk:** packaging, plugin
  availability, audio/system capture.

### 3. Custom RTP/SRTP pipeline

- VideoToolbox/MediaCodec + libsrtp + RTP packetisation (RFC 6184) + jitter
  buffer + RTCP/NACK/PLI.
- **Effort:** very high (reinventing WebRTC); **control:** total.
- Only worth it if you need something WebRTC cannot express.

### 4. Commercial/prebuilt WebRTC SDK with codec control

- Fastest if H.264/HEVC is a hard requirement; removes codec/profile work.
- **Effort:** low; **cost:** licence.

## Recommendation

1. Keep **1080p H.264** as the default — it is hardware-decoded and the safest sustained quality on this box.
2. Use the quality selector for 1440p when you want sharper text; drop to 1080p
   if the box gets hot or the frame rate falls.
3. The H.264 PoC is built. The TV advertises codec capabilities in `hello`; the
   Mac chooses the codec before the offer. If no frame renders for 3 seconds,
   the TV reconnects with a forced VP8 hello and the Mac switches factories.
4. If the goal is 1440p, test a 64-bit box with hardware H.264/HEVC decode before
   investing in the C++ pipeline.

## References

- WebRTC codec selection: <https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpTransceiver/setCodecPreferences>
- Chromium H.264 profile issue: <https://issues.chromium.org/40283913>
- libwebrtc: <https://webrtc.googlesource.com/src/>
- VideoToolbox: <https://developer.apple.com/documentation/videotoolbox>
- GStreamer WebRTC: <https://gstreamer.freedesktop.org/documentation/webrtc/index.html>
- H.264 for WebRTC notes: <https://webrtchacks.com/what-i-learned-about-h-264-for-webrtc-video-tim-panton/>
- Android hardware encoding notes: <https://medium.com/bumble-tech/webrtc-on-android-how-to-enable-hardware-encoding-on-multiple-devices-5bd819c0ce5>
