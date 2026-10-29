# AirScreen protocol (v1)

Newline-delimited JSON over **TLS 1.3**, LAN only. Port `47890`, advertised over
Bonjour as `_airscreen._tcp`.

## Transport and trust

Both ends present a self-signed certificate and **neither chain is validated** —
there is no authority on a home network to validate them against. Trust comes
from pinning, established once by pairing:

- The Mac keeps an RSA identity in Application Support and serves it.
- The TV keeps an EC identity in the AndroidKeyStore and presents it when asked
  (`peer_authentication_required`). It cannot be exported, so a relay can replay
  anything the TV *says* but cannot complete a handshake as the TV.
- The Mac records approved TVs by **certificate fingerprint**, not by any
  self-declared id. An id can be replayed by whoever watched it being sent.
- The TV pins the Mac's fingerprint when it receives `paired`.

The handshake itself trusts on first use. Refusing an unknown peer there would
leave no way to pair a new one, so the gate is above the transport: the Mac
captures nothing and sends no `offer` until a TV is approved, and the TV refuses
an `offer` from a Mac it has not pinned.

### Pairing code

Six digits over SHA-256 of `"AirScreen-SAS-v1:" + macFingerprint + ":" +
tvFingerprint`, taking the first eight bytes big-endian as an **unsigned** 64-bit
integer modulo 1,000,000, zero-padded.

Both ends compute it locally and **it is never sent**. That is the whole point:
a relay that controls the session could rewrite a transmitted code, but it
cannot make two independently derived codes agree — it has to substitute its own
certificate on each leg, so the Mac and the TV hash different pairs and the
codes visibly differ.

Three implementations must agree: `mac/Sources/AirScreen/Pairing.swift`,
`android-tv/.../Pairing.kt`, `tools/chaos_pairing.py`. Run
`python3 tools/chaos_pairing.py --check` and `gradle :app:testDebugUnitTest`.

## Messages

### hello (TV → Mac)

```json
{"t":"hello","v":1,"name":"Living Room TV","paired":true,
 "codecs":["H264","VP8"],"h264Profiles":["42e01f"],
 "audioCodecs":["opus","pcm16"],"maxWidth":2560,"maxHeight":1440,
 "forceCodec":"VP8"}
```

`forceCodec` is optional and set only by the TV's no-video fallback. A TV that
omits `audioCodecs` is treated as PCM-only.

`paired` says whether the TV has already pinned the certificate this Mac just
served. **A pairing has two halves and the Mac re-runs it unless both survive.**
If the Mac alone remembered the TV it would stream to a receiver that refuses
the offer, and never prompt again — the pair could not be repaired. Absent is
read as `false`: a peer that does not say gets asked.

### pair-required (Mac → TV)

```json
{"t":"pair-required","name":"Ayo's MacBook Pro"}
```

Sent when the TV's certificate is not on the Mac's approved list. The TV shows
its locally derived code; the user approves on the **Mac**. Carries no code.

### paired (Mac → TV)

```json
{"t":"paired","name":"Ayo's MacBook Pro"}
```

The user approved. The TV pins the Mac's fingerprint.

### codec (Mac → TV)

```json
{"t":"codec","codecName":"H.264","audioCodec":"opus"}
```

Advisory. Audio frames are self-describing, so the TV decodes correctly even if
this message is late or lost.

### offer / answer / ice / stop / error

```json
{"t":"offer","sdp":"v=0..."}
{"t":"answer","sdp":"v=0..."}
{"t":"ice","candidate":"candidate:...","sdpMid":"0","sdpMLineIndex":0}
{"t":"stop","reason":"user"}
{"t":"error","code":"pairing_denied","message":"..."}
```

### fallback (TV → Mac)

```json
{"t":"fallback"}
```

No frames arrived within three seconds of ICE connecting. The Mac rebuilds the
session on VP8, once.

## Audio framing (WebRTC data channel, label `audio`)

Every message is one audio frame, with a leading codec byte:

| Byte | Codec | Payload |
|------|-------|---------|
| `0x01` | PCM16 | interleaved little-endian Int16, 48 kHz stereo |
| `0x02` | Opus | one Opus packet, 48 kHz stereo, 20 ms |

The tag is authoritative. The data channel and the signaling socket are separate
transports and do race, so a frame can overtake the `codec` message that
describes it; one byte per 20 ms removes the ambiguity. Opus runs about 10–20×
smaller than PCM, which is the headroom video actually wants.

## Rules

- One line = one JSON object, UTF-8, `\n` terminated.
- Max line length 64 KiB. Over it, or 64 KiB buffered with no newline at all →
  `error` and close.
- Unknown `t` → ignored.
- A TV that presents no certificate is refused by TLS itself (alert 116,
  `certificate_required`) and gets no application-level error. Every other
  refusal does send one, and the Mac waits for it to flush before closing.
- `answer`, `ice` and `stop` are only acted on inside an approved session.
- A TV that does not send `hello` within 5 s is dropped.
- A pairing prompt the user does not answer within 60 s is refused.
