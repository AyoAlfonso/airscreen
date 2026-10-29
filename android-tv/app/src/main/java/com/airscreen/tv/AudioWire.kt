package com.airscreen.tv

/**
 * Framing for audio on the WebRTC data channel. Mirrors `AudioWire.swift`.
 *
 * The leading byte names the codec, so a frame that overtakes the signaling
 * message describing it still decodes correctly — the data channel and the
 * signaling socket are separate transports and do race.
 */
object AudioWire {
    const val TAG_PCM16: Byte = 1
    const val TAG_OPUS: Byte = 2
}
