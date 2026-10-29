import Foundation
import WebRTC

final class WebRTCSession: NSObject, RTCPeerConnectionDelegate {
    private let factory: RTCPeerConnectionFactory
    private let width: Int
    private let height: Int
    private let maxBitrate: Int
    private let send: (SignalMessage) -> Void
    private var pc: RTCPeerConnection?
    private var source: RTCVideoSource?
    private var track: RTCVideoTrack?
    private var capturer: RTCVideoCapturer?
    private var audioChannel: RTCDataChannel?
    var onState: ((String) -> Void)?

    init(factory: RTCPeerConnectionFactory, width: Int, height: Int, maxBitrate: Int,
         send: @escaping (SignalMessage) -> Void) {
        self.factory = factory
        self.width = width
        self.height = height
        self.maxBitrate = maxBitrate
        self.send = send
        super.init()
    }

    func start() {
        print("RTC: start")
        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            print("RTC: no peer connection")
            onState?("Could not create peer connection")
            return
        }
        self.pc = pc
        self.audioChannel = pc.dataChannel(forLabel: "audio", configuration: RTCDataChannelConfiguration())

        let source = factory.videoSource()
        source.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: 60)
        self.source = source
        let capturer = RTCVideoCapturer(delegate: source)
        self.capturer = capturer
        let track = factory.videoTrack(with: source, trackId: "video0")
        self.track = track
        pc.add(track, streamIds: ["stream0"])

        if let sender = pc.senders.first(where: { $0.track is RTCVideoTrack }) {
            let params = sender.parameters
            if let encoding = params.encodings.first {
                encoding.maxBitrateBps = NSNumber(value: maxBitrate)
                encoding.minBitrateBps = NSNumber(value: maxBitrate / 5)
                encoding.maxFramerate = 60
                encoding.scaleResolutionDownBy = 1.0
                encoding.networkPriority = .high
                encoding.bitratePriority = 1.0
            }
            params.degradationPreference = NSNumber(
                value: RTCDegradationPreference.maintainResolution.rawValue
            )
            sender.parameters = params
            print("RTC: sender tuned \(width)x\(height) @ \(maxBitrate / 1_000_000) Mbps / maintain resolution")
        }

        print("RTC: creating offer")
        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            if let error {
                print("RTC: offer failed \(error)")
                self.onState?("Offer failed: \(error.localizedDescription)")
                return
            }
            guard let sdp else { return }
            let reordered = Self.h264First(sdp.sdp)
            let local = RTCSessionDescription(type: .offer, sdp: reordered)
            print("RTC: offer reordered H264-first=\(reordered != sdp.sdp)")
            pc.setLocalDescription(local) { error in
                if let error {
                    self.onState?("Set local failed: \(error.localizedDescription)")
                    return
                }
                print("RTC: sending offer len=\(reordered.count)")
                self.send(SignalMessage(t: "offer", sdp: reordered))
                self.onState?("Offer sent")
            }
        }
    }

    func sendAudio(_ data: Data) {
        guard let channel = audioChannel, channel.readyState == .open else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    func push(pixelBuffer: CVPixelBuffer, timeStamp: CMTime) {
        guard let source, let capturer else { return }
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let nanos = Int64(timeStamp.seconds * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: nanos)
        source.capturer(capturer, didCapture: frame)
    }

    func handle(_ message: SignalMessage) {
        guard let pc else { return }
        switch message.t {
        case "answer":
            print("RTC: answer received")
            guard let sdp = message.sdp else { return }
            pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
                if let error { self?.onState?("Set remote failed: \(error.localizedDescription)") }
                else { self?.onState?("Answer received") }
            }
        case "ice":
            print("RTC: ice received")
            guard let candidate = message.candidate else { return }
            let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: message.sdpMLineIndex ?? 0, sdpMid: message.sdpMid)
            pc.add(ice) { error in
                if let error { print("ICE add error: \(error)") }
            }
        case "stop":
            close()
            onState?("Stopped by TV")
        default:
            break
        }
    }

    /// Put H.264 payload types first in the video m-line, keeping every codec.
    private static func h264First(_ sdp: String) -> String {
        let lines = sdp.components(separatedBy: "\r\n")
        var h264: Set<String> = []
        for line in lines where line.hasPrefix("a=rtpmap:") && line.contains(" H264/90000") {
            let rest = line.dropFirst("a=rtpmap:".count)
            if let pt = rest.split(separator: " ").first { h264.insert(String(pt)) }
        }
        guard !h264.isEmpty else { return sdp }
        return lines.map { line -> String in
            guard line.hasPrefix("m=video ") else { return line }
            let parts = line.split(separator: " ")
            guard parts.count > 3 else { return line }
            let prefix = parts.prefix(3)
            let payloads = parts.dropFirst(3)
            let preferred = payloads.filter { h264.contains(String($0)) }
            let rest = payloads.filter { !h264.contains(String($0)) }
            return (prefix + preferred + rest).joined(separator: " ")
        }.joined(separator: "\r\n")
    }

    func close() {
        pc?.close()
        pc = nil
        track = nil
        source = nil
        audioChannel = nil
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onState?("ICE: \(newState.rawValue)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        send(SignalMessage(t: "ice", candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
