import Foundation

/// One line of the signaling protocol. Every field is optional because the
/// same shape carries every message type; see `protocol/protocol.md`.
///
/// Note what is deliberately absent: the pairing code. The TV derives it from
/// the certificate it was served, never from the wire — a machine in the middle
/// could rewrite a code that travelled inside the session it controls.
struct SignalMessage: Codable {
    let t: String
    var v: Int? = nil
    var sdp: String? = nil
    var candidate: String? = nil
    var sdpMid: String? = nil
    var sdpMLineIndex: Int32? = nil
    var reason: String? = nil
    var code: String? = nil
    var message: String? = nil
    var name: String? = nil
    /// Stable per-install id the TV generates once. Diagnostic only — the
    /// pairing record is keyed on the TV's certificate, which cannot be
    /// claimed by a peer that does not hold the key.
    var deviceId: String? = nil
    /// TV → Mac in `hello`: "I have already pinned the certificate you just
    /// served me." A pairing has two halves and both must survive, so the Mac
    /// re-runs pairing when this is false even if it still remembers the TV.
    /// Absent is read as false: a peer that does not say gets asked.
    var paired: Bool? = nil
    var codecs: [String]? = nil
    var h264Profiles: [String]? = nil
    var audioCodecs: [String]? = nil
    var maxWidth: Int? = nil
    var maxHeight: Int? = nil
    var forceCodec: String? = nil
    var codecName: String? = nil
    /// "opus" or "pcm16". Advisory: every audio frame is self-describing, so the
    /// TV never has to have seen this to decode correctly.
    var audioCodec: String? = nil

    func encodedLine() -> Data? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return data + Data([0x0A])
    }
}
