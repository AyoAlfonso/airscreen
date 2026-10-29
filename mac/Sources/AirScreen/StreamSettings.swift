import Foundation

enum StreamQuality: String, CaseIterable, Identifiable {
    case hd1080 = "1080p"
    case qhd1440 = "1440p"

    var id: String { rawValue }
    var width: Int { self == .qhd1440 ? 2560 : 1920 }
    var height: Int { self == .qhd1440 ? 1440 : 1080 }
}

enum StreamBitrate: Int, CaseIterable, Identifiable {
    case mbps8 = 8_000_000
    case mbps10 = 10_000_000
    case mbps15 = 15_000_000
    case mbps25 = 25_000_000

    var id: Int { rawValue }
    var label: String { "\(rawValue / 1_000_000) Mbps" }
}

enum CodecChoice: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case h264 = "H.264"
    case vp8 = "VP8 (fallback)"

    var id: String { rawValue }
}

/// There is deliberately no "force Opus": the Mac will not send a codec the TV
/// has not advertised, so such an option would behave exactly like `auto` on
/// every TV that can decode Opus and do nothing on every TV that cannot.
enum AudioChoice: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case pcm16 = "PCM (lossless)"

    var id: String { rawValue }
}
