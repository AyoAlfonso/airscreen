import Foundation
import CryptoKit

/// Short authentication string shown on both screens during pairing.
///
/// The connection is mutually authenticated: the Mac serves a certificate and
/// requires one back from the TV. The code commits to *both*, so each end can
/// compute it and a machine in the middle cannot make them agree — it has to
/// substitute its own certificate on each leg, so the Mac and the TV end up
/// hashing different pairs and the two codes diverge where the user can see it.
///
/// The code never travels on the wire. A relay that controls the session could
/// rewrite a transmitted code; it cannot forge one each side derives locally.
///
/// Stable for the life of the two certificates, which is the point: it
/// identifies the pair of machines, it is not a session secret.
///
/// The TV reimplements this in `Pairing.kt`. Keep the two in step —
/// `tools/chaos_pairing.py` holds the shared vectors.
enum Pairing {
    static let salt = "AirScreen-SAS-v1:"

    /// - Parameters:
    ///   - macFingerprint: lowercase hex SHA-256 of the Mac's DER certificate.
    ///   - tvFingerprint: lowercase hex SHA-256 of the TV's DER certificate.
    static func shortAuthString(macFingerprint: String, tvFingerprint: String) -> String {
        let input = salt + macFingerprint.lowercased() + ":" + tvFingerprint.lowercased()
        let digest = SHA256.hash(data: Data(input.utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    /// `123456` -> `123 456`, for display only.
    static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }
}

/// TVs the user has approved, keyed by the SHA-256 of the TV's client
/// certificate.
///
/// Keyed on the certificate rather than on a self-declared device id because
/// anything a TV merely *claims* can be replayed by whoever saw it claim it.
/// A certificate cannot be presented without the matching private key.
///
/// This is the Mac's half of pairing: it answers "may this TV stream?". The
/// TV's half is the pinned Mac fingerprint, answering "is this the Mac I
/// paired with?". Both have to hold or pairing runs again.
final class PairedDevices {
    struct Device: Codable {
        var name: String
        var pairedAt: Date
        var lastSeenAt: Date
    }

    private var devices: [String: Device] = [:]
    private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = base
                .appendingPathComponent("AirScreen", isDirectory: true)
                .appendingPathComponent("paired.json")
        }
        load()
    }

    func isPaired(_ fingerprint: String) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return devices[fingerprint] != nil
    }

    func name(of fingerprint: String) -> String? { devices[fingerprint]?.name }

    func remember(fingerprint: String, name: String) {
        guard !fingerprint.isEmpty else { return }
        let now = Date()
        if var existing = devices[fingerprint] {
            existing.name = name
            existing.lastSeenAt = now
            devices[fingerprint] = existing
        } else {
            devices[fingerprint] = Device(name: name, pairedAt: now, lastSeenAt: now)
        }
        save()
    }

    func touch(fingerprint: String) {
        guard var existing = devices[fingerprint] else { return }
        existing.lastSeenAt = Date()
        devices[fingerprint] = existing
        save()
    }

    func forget(fingerprint: String) {
        devices.removeValue(forKey: fingerprint)
        save()
    }

    func forgetAll() {
        devices.removeAll()
        save()
    }

    var all: [(fingerprint: String, device: Device)] {
        devices.map { (fingerprint: $0.key, device: $0.value) }
            .sorted { $0.device.lastSeenAt > $1.device.lastSeenAt }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        devices = (try? decoder.decode([String: Device].self, from: data)) ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(devices) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: url, options: .atomic)
    }
}
