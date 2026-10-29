import Foundation
import Security
import CryptoKit

/// Persistent self-signed TLS identity for the signaling listener.
///
/// macOS exposes no public API for building a self-signed `SecIdentity`, so the
/// key pair is minted once with the system `openssl` and cached as a PKCS#12 in
/// Application Support. RSA with `PBE-SHA1-3DES` is the only combination
/// `SecPKCS12Import` accepts from the LibreSSL that ships with macOS: EC keys
/// fault the importer and AES-PBE comes back `errSecDecode`.
///
/// The certificate is never chain-validated. The TV pins `fingerprint`, and the
/// user compares the derived short auth string on both screens once. See
/// `Pairing`.
struct TLSIdentity {
    let identity: SecIdentity
    /// Lowercase hex SHA-256 over the DER certificate. This is what the TV pins.
    let fingerprint: String

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AirScreen", isDirectory: true)
    }()
    private static var p12URL: URL { directory.appendingPathComponent("identity.p12") }
    private static var passURL: URL { directory.appendingPathComponent("identity.pass") }

    static func loadOrCreate() throws -> TLSIdentity {
        if let existing = try? load() { return existing }
        // Either nothing is cached yet or what is cached no longer imports.
        try? FileManager.default.removeItem(at: p12URL)
        try? FileManager.default.removeItem(at: passURL)
        try mint()
        return try load()
    }

    /// Throws away the cached identity. The next `loadOrCreate` mints a new one,
    /// which invalidates every TV's pin and forces re-pairing.
    static func reset() throws {
        try? FileManager.default.removeItem(at: p12URL)
        try? FileManager.default.removeItem(at: passURL)
    }

    private static func load() throws -> TLSIdentity {
        let data = try Data(contentsOf: p12URL)
        let passphrase = try String(contentsOf: passURL, encoding: .utf8)
        var items: CFArray?
        let status = SecPKCS12Import(
            data as CFData,
            [kSecImportExportPassphrase as String: passphrase] as CFDictionary,
            &items
        )
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]],
              let first = entries.first,
              let raw = first[kSecImportItemIdentity as String] else {
            throw error("could not import TLS identity (OSStatus \(status))")
        }
        let identity = raw as! SecIdentity

        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            throw error("TLS identity has no certificate")
        }
        let der = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return TLSIdentity(identity: identity, fingerprint: digest)
    }

    private static func mint() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        let scratch = fm.temporaryDirectory.appendingPathComponent("airscreen-identity-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }

        let key = scratch.appendingPathComponent("key.pem")
        let cert = scratch.appendingPathComponent("cert.pem")
        let passphrase = randomPassphrase()

        try run("/usr/bin/openssl", [
            "req", "-x509", "-sha256", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
            "-subj", "/CN=AirScreen/O=AirScreen",
            "-keyout", key.path, "-out", cert.path
        ])
        try run("/usr/bin/openssl", [
            "pkcs12", "-export",
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
            "-inkey", key.path, "-in", cert.path,
            "-out", p12URL.path, "-passout", "pass:\(passphrase)"
        ])

        try passphrase.write(to: passURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passURL.path)
    }

    private static func randomPassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        try process.run()
        let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr, encoding: .utf8) ?? ""
            throw error("\(launchPath) \(arguments.first ?? "") failed: \(detail)")
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "AirScreen.TLS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
