import Foundation

/// Framing for audio on the WebRTC data channel.
///
/// Every frame carries its codec in a leading byte. The alternative — trusting
/// the `audioCodec` field of the `codec` signaling message — races: the data
/// channel and the signaling socket are different transports, so a frame can
/// arrive before the message that explains it. One byte per 20 ms removes the
/// race entirely.
///
/// Mirrored by `AudioWire.kt` on the TV.
enum AudioWireCodec: UInt8 {
    case pcm16 = 1   // interleaved little-endian Int16, 48 kHz stereo
    case opus = 2    // one Opus packet, 48 kHz stereo, 20 ms

    var wireName: String {
        switch self {
        case .pcm16: return "pcm16"
        case .opus: return "opus"
        }
    }

    init?(wireName: String) {
        switch wireName.lowercased() {
        case "pcm16": self = .pcm16
        case "opus": self = .opus
        default: return nil
        }
    }
}

enum AudioWire {
    static func frame(_ codec: AudioWireCodec, _ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 1)
        out.append(codec.rawValue)
        out.append(payload)
        return out
    }
}

/// Which audio codec to put on the wire.
///
/// Pure and exhaustively enumerated by `tools/chaos_audio.swift`. The rule it
/// encodes: **never send a codec the receiver has not claimed.** A TV that says
/// nothing about audio is an older or hand-rolled client and gets PCM, which
/// every receiver understands.
enum AudioNegotiation {
    static func resolve(choice: AudioChoice, offered: [String]?, encoderAvailable: Bool) -> AudioWireCodec {
        guard choice == .auto else { return .pcm16 }
        guard encoderAvailable else { return .pcm16 }
        guard let offered, offered.contains(where: {
            $0.caseInsensitiveCompare(AudioWireCodec.opus.wireName) == .orderedSame
        }) else { return .pcm16 }
        return .opus
    }
}
