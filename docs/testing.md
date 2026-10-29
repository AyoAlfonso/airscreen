# Tests and encoder tuning

## Current test set

```sh
python3 tools/chaos_pairing.py --check          # Python vs Swift pairing vectors
cd android-tv && gradle :app:testDebugUnitTest  # Kotlin pairing vectors
python3 tools/chaos_pairing_protocol.py         # TLS + pairing state machine, 16 checks

swiftc -o /tmp/chaos_audio tools/chaos_audio.swift \
  mac/Sources/AirScreen/AudioWire.swift mac/Sources/AirScreen/StreamSettings.swift
/tmp/chaos_audio
```

The pairing code is implemented three times (Swift, Kotlin, Python) and checked
against shared vectors. The audio matrix enumerates the full cross product.

The original plain-TCP P0 harnesses (`tools/chaos_signaling.py`,
`tools/chaos_codec.py`, `tools/mock_tv.py`) are kept for the codec-selection
history but are not used with the TLS listener.

## Encoder tuning

The sender is tuned for sharp text rather than frame rate:

- `degradationPreference = maintainResolution` — drops fps instead of
  downscaling the picture.
- 15 Mbps default at 1080p; 25 Mbps for 1440p.
- VideoToolbox low-latency tuning: `MaxFrameDelayCount=1`, speed-over-quality,
  1-second keyframes, no fixed `DataRateLimits`; hardware encode verified (`value=1`).
- `scaleResolutionDownBy = 1.0`; the TV renderer's extra hardware scaler is off.
- H.264 is preferred; the TV decodes with MediaCodec.

If the picture still looks soft, check the TV's decoded resolution:

```sh
adb logcat -d | grep -E "frame resolution changed|initDecodeInternal"
```

It should say `1920x1080` (or `2560x1440`), not `640x360`, and the decoder
should be `OMX.realtek.video.dec.avc` (H.264), not `...vp8`.
