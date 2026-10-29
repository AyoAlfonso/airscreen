import Foundation
import Network
import Security
import CryptoKit

/// Signaling transport: TLS 1.3 over TCP, newline-delimited JSON, advertised
/// over Bonjour as `_airscreen._tcp`.
///
/// Both ends present a self-signed certificate and neither is chain-validated:
/// trust comes from pinning, established once by the user comparing a code
/// derived from both certificates (see `Pairing`). Requiring a client
/// certificate is what stops a relay from replaying a TV's identity to the Mac
/// after the pair is made.
///
/// Authorisation is a separate step and lives in `AppModel`. Reaching this
/// class only means a TLS session was opened; `onConnect` reports who opened
/// it and the model decides whether that peer may stream.
final class SignalingServer {
    private let queue = DispatchQueue(label: "com.airscreen.signaling")
    private let lock = NSLock()
    private let identity: TLSIdentity
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private var announcedConnect = false

    /// 64 KiB, as in protocol.md. A peer that exceeds it is sent an error and cut.
    private static let maxLineLength = 65_536

    /// Passes the SHA-256 of the peer's leaf certificate, or "" if the TV
    /// presented none.
    var onConnect: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onMessage: ((SignalMessage) -> Void)?
    /// The listener died — the port is taken, or the network went away. Without
    /// this the app sits showing "Waiting for TV…" over a socket that was never
    /// bound.
    var onListenerError: ((Error) -> Void)?

    var fingerprint: String { identity.fingerprint }

    init(identity: TLSIdentity) {
        self.identity = identity
    }

    func start(port: UInt16 = 47890, serviceName: String) throws {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.identity) else {
            throw NSError(domain: "AirScreen", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not use the TLS identity"])
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        // Ask every TV for a certificate. The handshake itself trusts on first
        // use; which certificates are acceptable is decided in `AppModel`
        // against the paired list, so that an unknown TV can still reach the
        // pairing prompt instead of being dropped with no explanation.
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "AirScreen", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Bad port \(port)"])
        }
        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.service = NWListener.Service(
            name: serviceName,
            type: "_airscreen._tcp",
            txtRecord: NWTXTRecord(["v": "1"])
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.adopt(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            print("SIGNAL: listener \(state)")
            if case .failed(let error) = state { self?.onListenerError?(error) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let current = connection
        let wasAnnounced = announcedConnect
        connection = nil
        announcedConnect = false
        buffer.removeAll()
        let activeListener = listener
        listener = nil
        lock.unlock()

        current?.cancel()
        activeListener?.cancel()
        if wasAnnounced { onDisconnect?() }
    }

    /// Cut the current peer without taking the listener down, so another TV can
    /// connect. Used when pairing is refused.
    func disconnectPeer() {
        lock.lock()
        let current = connection
        let wasAnnounced = announcedConnect
        connection = nil
        announcedConnect = false
        buffer.removeAll()
        lock.unlock()

        current?.cancel()
        if wasAnnounced { onDisconnect?() }
    }

    /// - Parameter thenDisconnect: cut the peer once this message is actually
    ///   on the wire. Cancelling a connection drops anything still queued on
    ///   it, so sending an `error` and disconnecting in the same breath is a
    ///   race the error usually loses — the TV then shows "connection failed"
    ///   instead of the reason it was refused.
    func send(_ message: SignalMessage, thenDisconnect: Bool = false) {
        guard let data = message.encodedLine() else {
            if thenDisconnect { disconnectPeer() }
            return
        }
        lock.lock()
        let current = connection
        lock.unlock()
        guard let current else { return }
        current.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { print("SIGNAL: send failed \(error)") }
            if thenDisconnect { self?.disconnectPeer() }
        })
        if thenDisconnect {
            // Do not leave a peer connected forever if the completion never
            // lands.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.disconnectPeer() }
        }
    }

    private func adopt(_ incoming: NWConnection) {
        lock.lock()
        let previous = connection
        let previousAnnounced = announcedConnect
        connection = incoming
        announcedConnect = false
        buffer.removeAll()
        lock.unlock()

        if let previous {
            previous.cancel()
            if previousAnnounced { onDisconnect?() }
        }

        incoming.stateUpdateHandler = { [weak self, weak incoming] state in
            guard let self, let incoming else { return }
            switch state {
            case .ready:
                print("SIGNAL: TLS ready with \(incoming.endpoint)")
                let peer = Self.peerFingerprint(of: incoming)
                self.lock.lock()
                let isCurrent = self.connection === incoming
                if isCurrent { self.announcedConnect = true }
                self.lock.unlock()
                if isCurrent { self.onConnect?(peer) }
            case .failed(let error):
                print("SIGNAL: connection failed \(error)")
                self.retire(incoming)
            case .cancelled:
                self.retire(incoming)
            default:
                break
            }
        }
        incoming.start(queue: queue)
        receive(on: incoming)
    }

    /// SHA-256 of the peer's leaf certificate, or "" when it sent none.
    private static func peerFingerprint(of connection: NWConnection) -> String {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata else { return "" }
        var leaf: String?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            guard leaf == nil else { return }
            let ref = sec_certificate_copy_ref(certificate).takeRetainedValue()
            let der = SecCertificateCopyData(ref) as Data
            leaf = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        }
        return leaf ?? ""
    }

    private func retire(_ ended: NWConnection) {
        lock.lock()
        guard connection === ended else { lock.unlock(); return }
        let wasAnnounced = announcedConnect
        connection = nil
        announcedConnect = false
        buffer.removeAll()
        lock.unlock()
        if wasAnnounced { onDisconnect?() }
    }

    private func receive(on current: NWConnection) {
        current.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self, weak current] data, _, isComplete, error in
            guard let self, let current else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                let (lines, oversize) = self.extractLines()
                self.lock.unlock()
                if oversize {
                    self.send(SignalMessage(t: "error", code: "line_too_long", message: "max 64 KiB"),
                              thenDisconnect: true)
                    return
                }
                for line in lines { self.handle(line: line) }
            }
            if isComplete || error != nil {
                current.cancel()
                return
            }
            self.receive(on: current)
        }
    }

    /// Caller holds `lock`.
    private func extractLines() -> ([Data], Bool) {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.isEmpty { continue }
            if line.count > Self.maxLineLength { return (lines, true) }
            lines.append(line)
        }
        // A peer that never sends a newline must not be able to grow the buffer
        // without bound.
        if buffer.count > Self.maxLineLength { return (lines, true) }
        return (lines, false)
    }

    private func handle(line: Data) {
        do {
            let message = try JSONDecoder().decode(SignalMessage.self, from: line)
            print("SIGNAL: server recv \(message.t)")
            onMessage?(message)
        } catch {
            send(SignalMessage(t: "error", code: "bad_json", message: "invalid message"))
        }
    }
}
