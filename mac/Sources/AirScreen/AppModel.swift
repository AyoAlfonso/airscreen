import Foundation
import WebRTC
import CoreGraphics
import AppKit

@MainActor
final class AppModel: ObservableObject {
    struct PairingRequest: Identifiable {
        let id = UUID()
        let requestedAt = Date()
        /// SHA-256 of the TV's client certificate. This is the pairing key.
        let fingerprint: String
        let name: String
        /// Commits to both certificates. The TV derives the same value from its
        /// side of the handshake; the user checks the two agree.
        let code: String
    }

    @Published var status = "Idle"
    @Published var isSharing = false
    @Published var deviceName = Host.current().localizedName ?? "This Mac"
    @Published var quality: StreamQuality = .hd1080
    @Published var bitrate: StreamBitrate = .mbps15
    @Published var codec: CodecChoice = .auto
    @Published var audioChoice: AudioChoice = .auto
    @Published private(set) var pairingRequest: PairingRequest?
    @Published private(set) var activeAudioCodec: String?

    private let paired = PairedDevices()
    private let pairingPanel = PairingPanel()
    private var identity: TLSIdentity?
    private var signaling: SignalingServer?
    private var capturer: ScreenCapturer?
    private var session: WebRTCSession?
    private var factory: RTCPeerConnectionFactory?
    private var factoryCodec: CodecChoice?
    private var activity: NSObjectProtocol?
    private var currentCodec: CodecChoice?
    private var currentAudio: AudioWireCodec = .pcm16
    /// What the connected TV said it can decode. Kept so the VP8 fallback
    /// re-resolves audio the same way the first attempt did.
    private var offeredAudioCodecs: [String]?
    private var didFallback = false
    private var helloTimeout: DispatchWorkItem?
    private var pairingTimeout: DispatchWorkItem?
    /// Non-nil only once a TV has been approved. Nothing is captured or offered
    /// while this is nil.
    private var authorizedFingerprint: String?
    /// The certificate the currently connected TV presented, set at TLS ready.
    private var peerFingerprint = ""
    private var pendingHello: SignalMessage?

    /// How long the user has to answer a pairing prompt before it is refused.
    private static let pairingTimeoutSeconds = 60.0
    private static let signalingPort: UInt16 = 47890
    /// How long a connected TV has to identify itself before it is cut.
    private static let helloTimeoutSeconds = 5.0
    /// Approvals arriving sooner than this after the prompt appears are
    /// discarded. Nobody reads a six-digit code, looks across the room at the
    /// TV and clicks in under a second — but a window appearing under the
    /// pointer does collect a stray click, and SwiftUI delivers it to whatever
    /// button it lands on. Observed in testing: the panel was approving itself
    /// the instant it opened.
    private static let minimumPromptSeconds = 1.0

    init() {
        setbuf(stdout, nil)
        if !CGPreflightScreenCaptureAccess() {
            print("TCC: requesting screen capture access")
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = CGRequestScreenCaptureAccess()
        }
        RTCInitializeSSL()
        if ProcessInfo.processInfo.environment["AIRSCREEN_AUTOSTART"] == "1" {
            DispatchQueue.main.async { [weak self] in self?.start() }
        }
    }

    // MARK: - Codec selection

    private func resolvedCodec(from hello: SignalMessage) -> CodecChoice {
        if let force = hello.forceCodec, force.caseInsensitiveCompare("VP8") == .orderedSame {
            return .vp8
        }
        if codec != .auto { return codec }
        guard let offered = hello.codecs, !offered.isEmpty else { return .h264 }
        let hasH264 = offered.contains { $0.caseInsensitiveCompare("H264") == .orderedSame }
        guard hasH264 else { return .vp8 }
        if let profiles = hello.h264Profiles, !profiles.isEmpty {
            let baseline = profiles.contains {
                $0.lowercased().hasPrefix("42e0") || $0.lowercased().hasPrefix("42e01f")
            }
            return baseline ? .h264 : .vp8
        }
        return .h264
    }

    private func ensureFactory(for codec: CodecChoice) {
        guard factoryCodec != codec || factory == nil else { return }
        if codec == .h264 {
            factory = RTCPeerConnectionFactory(
                encoderFactory: H264VideoEncoderFactory(),
                decoderFactory: RTCDefaultVideoDecoderFactory()
            )
        } else {
            factory = RTCPeerConnectionFactory(
                encoderFactory: VP8EncoderFactory(),
                decoderFactory: RTCDefaultVideoDecoderFactory()
            )
        }
        factoryCodec = codec
    }

    // MARK: - Lifecycle

    func start() {
        guard !isSharing else { return }

        let identity: TLSIdentity
        do {
            identity = try TLSIdentity.loadOrCreate()
        } catch {
            status = "Could not create a TLS identity: \(error.localizedDescription)"
            return
        }
        self.identity = identity

        let signaling = SignalingServer(identity: identity)
        signaling.onConnect = { [weak self] peer in
            Task { @MainActor in self?.handleConnect(peerFingerprint: peer) }
        }
        signaling.onDisconnect = { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }
        signaling.onMessage = { [weak self] message in
            Task { @MainActor in self?.handleMessage(message) }
        }
        signaling.onListenerError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isSharing else { return }
                self.stop()
                self.status = "Could not listen on \(Self.signalingPort): \(error.localizedDescription)"
            }
        }

        do {
            try signaling.start(port: Self.signalingPort, serviceName: deviceName)
        } catch {
            status = "Could not start: \(error.localizedDescription)"
            self.identity = nil
            return
        }

        self.signaling = signaling
        isSharing = true
        currentCodec = nil
        authorizedFingerprint = nil
        didFallback = false
        status = "Waiting for TV…"
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "AirScreen is sharing the screen"
        )
    }

    func stop() {
        cancelTimers()
        clearPairing()
        endSession()
        signaling?.stop()
        signaling = nil
        identity = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        currentCodec = nil
        authorizedFingerprint = nil
        didFallback = false
        isSharing = false
        activeAudioCodec = nil
        status = "Idle"
    }

    // MARK: - Signaling

    private func handleConnect(peerFingerprint: String) {
        guard isSharing else { return }
        endSession()
        clearPairing()
        currentCodec = nil
        authorizedFingerprint = nil
        didFallback = false
        self.peerFingerprint = peerFingerprint

        // Unreachable while the transport demands a client certificate — TLS
        // rejects those with alert 116 and never reaches `.ready`. Kept because
        // the fingerprint is the pairing key: an empty one would be remembered
        // as nothing and re-prompt forever, so it must never reach `hello`.
        guard !peerFingerprint.isEmpty else {
            reject(code: "client_cert_required", message: "The TV did not present a certificate")
            return
        }
        status = "TV connected — identifying"

        helloTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.authorizedFingerprint == nil, self.pairingRequest == nil else { return }
            print("SIGNAL: no hello, dropping peer")
            self.reject(code: "no_hello", message: "The TV did not identify itself")
        }
        helloTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.helloTimeoutSeconds, execute: timeout)
    }

    private func handleDisconnect() {
        cancelTimers()
        clearPairing()
        endSession()
        currentCodec = nil
        authorizedFingerprint = nil
        peerFingerprint = ""
        offeredAudioCodecs = nil
        activeAudioCodec = nil
        status = isSharing ? "TV disconnected — waiting" : "Idle"
    }

    private func handleMessage(_ message: SignalMessage) {
        guard isSharing else { return }
        print("SIGNAL: recv \(message.t)")
        switch message.t {
        case "hello":
            handleHello(message)
        case "fallback":
            handleFallback()
        default:
            // answer / ice / stop only mean anything inside an approved session.
            guard authorizedFingerprint != nil else {
                print("SIGNAL: ignoring \(message.t) from an unapproved device")
                return
            }
            session?.handle(message)
        }
    }

    private func handleHello(_ hello: SignalMessage) {
        helloTimeout?.cancel()
        helloTimeout = nil
        guard authorizedFingerprint == nil, pairingRequest == nil else {
            print("SIGNAL: duplicate hello ignored")
            return
        }
        guard (hello.v ?? 1) == 1 else {
            reject(code: "unsupported_version", message: "This Mac speaks AirScreen protocol 1")
            return
        }
        let fingerprint = peerFingerprint
        guard !fingerprint.isEmpty else {
            reject(code: "client_cert_required", message: "The TV did not present a certificate")
            return
        }
        let name = hello.name?.isEmpty == false ? hello.name! : "TV"

        // Both halves or neither. If the Mac remembers this TV but the TV has
        // lost its pin, streaming anyway produces a session the TV refuses and
        // no way back: the Mac would never prompt again, so the pair could
        // never be repaired. Reproduced on device before this check existed.
        let tvStillHasUs = hello.paired ?? false
        guard paired.isPaired(fingerprint), tvStillHasUs else {
            if paired.isPaired(fingerprint) && !tvStillHasUs {
                print("PAIR: this Mac remembers the TV but the TV has forgotten us — re-pairing")
            }
            beginPairing(fingerprint: fingerprint, name: name, hello: hello)
            return
        }
        print("PAIR: already approved [\(fingerprint.prefix(16))]")
        paired.touch(fingerprint: fingerprint)
        authorize(fingerprint: fingerprint, hello: hello)
    }

    private func handleFallback() {
        guard authorizedFingerprint != nil else { return }
        guard currentCodec == .h264, !didFallback else {
            status = "Video failed after fallback"
            return
        }
        didFallback = true
        print("SIGNAL: fallback requested, switching to VP8")
        endSession()
        status = "H.264 unavailable — switching to VP8"
        beginSession(codec: .vp8)
    }

    private func reject(code: String, message: String) {
        clearPairing()
        endSession()
        currentCodec = nil
        authorizedFingerprint = nil
        signaling?.send(SignalMessage(t: "error", code: code, message: message),
                        thenDisconnect: true)
        status = "Refused a TV: \(message)"
    }

    // MARK: - Pairing

    private func beginPairing(fingerprint: String, name: String, hello: SignalMessage) {
        guard let identity else { return }
        pendingHello = hello
        status = "\(name) wants to connect"
        signaling?.send(SignalMessage(t: "pair-required", name: deviceName))
        let code = Pairing.shortAuthString(
            macFingerprint: identity.fingerprint,
            tvFingerprint: fingerprint
        )
        let request = PairingRequest(fingerprint: fingerprint, name: name, code: code)
        print("PAIR: prompting for \(name) [\(fingerprint.prefix(16))] code=\(code)")
        pairingRequest = request
        pairingPanel.show(
            request: request,
            macName: deviceName,
            approve: { [weak self] in self?.approvePairing() },
            deny: { [weak self] in self?.denyPairing() }
        )

        pairingTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pairingRequest != nil else { return }
            self.denyPairing(message: "No answer — pairing timed out")
        }
        pairingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pairingTimeoutSeconds, execute: timeout)
    }

    func approvePairing() {
        guard let request = pairingRequest, let hello = pendingHello else { return }
        let onScreenFor = Date().timeIntervalSince(request.requestedAt)
        guard onScreenFor >= Self.minimumPromptSeconds else {
            print("PAIR: ignoring approval after only \(Int(onScreenFor * 1000))ms on screen")
            return
        }
        pairingTimeout?.cancel()
        pairingTimeout = nil
        // Only ever approve the TV that is still on the other end of this
        // connection; a reconnect between prompt and click must not inherit it.
        guard request.fingerprint == peerFingerprint else {
            print("PAIR: peer changed before approval, discarding")
            clearPairing()
            return
        }
        print("PAIR: approved \(request.name) after \(Int(onScreenFor * 1000))ms [\(request.fingerprint.prefix(16))]")
        paired.remember(fingerprint: request.fingerprint, name: request.name)
        pairingPanel.dismiss()
        pairingRequest = nil
        pendingHello = nil
        signaling?.send(SignalMessage(t: "paired", name: deviceName))
        authorize(fingerprint: request.fingerprint, hello: hello)
    }

    func denyPairing(message: String = "Pairing declined on the Mac") {
        guard pairingRequest != nil else { return }
        pairingTimeout?.cancel()
        pairingTimeout = nil
        pairingPanel.dismiss()
        pairingRequest = nil
        pendingHello = nil
        print("PAIR: denied — \(message)")
        signaling?.send(SignalMessage(t: "error", code: "pairing_denied", message: message),
                        thenDisconnect: true)
        status = message
    }

    /// Drop every remembered TV. They have to be approved again, and because the
    /// certificate is untouched the code they are shown does not change.
    func forgetPairedDevices() {
        paired.forgetAll()
        status = "Forgot every paired TV"
    }

    var pairedDeviceCount: Int { paired.all.count }

    private func clearPairing() {
        pairingTimeout?.cancel()
        pairingTimeout = nil
        if pairingRequest != nil { pairingPanel.dismiss() }
        pairingRequest = nil
        pendingHello = nil
    }

    private func cancelTimers() {
        helloTimeout?.cancel()
        helloTimeout = nil
        pairingTimeout?.cancel()
        pairingTimeout = nil
    }

    // MARK: - Session

    private func authorize(fingerprint: String, hello: SignalMessage) {
        authorizedFingerprint = fingerprint
        offeredAudioCodecs = hello.audioCodecs
        let video = resolvedCodec(from: hello)
        print("SIGNAL: hello codecs=\(hello.codecs ?? []) audio=\(hello.audioCodecs ?? []) -> \(video.rawValue)")
        endSession()
        beginSession(codec: video)
    }

    private func beginSession(codec chosen: CodecChoice) {
        guard authorizedFingerprint != nil else {
            print("RTC: refusing to start a session with no approved device")
            return
        }
        ensureFactory(for: chosen)
        guard let factory, let signaling else { return }
        currentCodec = chosen

        // Build the encoder before announcing, so the announcement is true even
        // if AudioToolbox cannot give us an Opus encoder on this machine.
        let wanted = AudioNegotiation.resolve(
            choice: audioChoice, offered: offeredAudioCodecs, encoderAvailable: true
        )
        let encoder = wanted == .opus ? OpusEncoder() : nil
        let audio = AudioNegotiation.resolve(
            choice: audioChoice, offered: offeredAudioCodecs, encoderAvailable: encoder != nil
        )
        if wanted == .opus && encoder == nil {
            print("AUDIO: no Opus encoder on this Mac, sending PCM")
        }
        currentAudio = audio
        print("AUDIO: wire codec \(audio.wireName)")
        activeAudioCodec = audio.wireName

        signaling.send(SignalMessage(
            t: "codec",
            codecName: chosen == .h264 ? "H.264" : "VP8",
            audioCodec: audio.wireName
        ))

        let session = WebRTCSession(
            factory: factory,
            width: quality.width,
            height: quality.height,
            maxBitrate: bitrate.rawValue
        ) { message in
            signaling.send(message)
        }
        session.onState = { [weak self] state in
            Task { @MainActor in
                self?.status = state
                if state.contains("Stopped by TV") {
                    self?.endSession()
                    self?.status = "TV stopped — waiting"
                }
            }
        }
        self.session = session
        session.start()

        let capturer = ScreenCapturer()
        self.capturer = capturer
        capturer.onFrame = { [weak session] pixelBuffer, time in
            session?.push(pixelBuffer: pixelBuffer, timeStamp: time)
        }
        // Runs on the capture queue. `encoder` is owned by this closure and
        // touched nowhere else, so there is no cross-queue state here.
        capturer.onAudio = { [weak session] pcm in
            guard let session else { return }
            if let encoder {
                for packet in encoder.encode(pcm: pcm) {
                    session.sendAudio(AudioWire.frame(.opus, packet))
                }
            } else {
                session.sendAudio(AudioWire.frame(.pcm16, pcm))
            }
        }
        capturer.onError = { [weak self] message in
            Task { @MainActor in self?.status = message }
        }
        Task {
            do {
                try await capturer.start(width: quality.width, height: quality.height)
            } catch {
                print("CAPTURE: failed \(error)")
                await MainActor.run {
                    self.status = "Capture failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func endSession() {
        session?.close()
        session = nil
        if let capturer {
            Task { await capturer.stop() }
        }
        capturer = nil
    }
}
