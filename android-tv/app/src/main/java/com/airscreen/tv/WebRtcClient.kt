package com.airscreen.tv

import android.content.Context
import android.media.MediaCodecList
import android.media.MediaFormat
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.SystemClock
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import org.webrtc.*

class WebRtcClient(
    context: Context,
    private val renderer: SurfaceViewRenderer,
    private val send: (JSONObject) -> Unit,
    private val onState: (String) -> Unit,
    private val onNoVideo: () -> Unit,
    private val onStats: (String) -> Unit
) {
    private val appContext = context.applicationContext
    private val eglBase = EglBase.create()
    private val factory: PeerConnectionFactory
    private var pc: PeerConnection? = null
    private var videoTransceiver: RtpTransceiver? = null
    private var h264Codecs: List<RtpCapabilities.CodecCapability> = emptyList()
    private var remoteVideo: VideoTrack? = null
    private val audio = AudioOutput()
    private var audioPackets = 0
    @Volatile private var closing = false
    private val main = Handler(Looper.getMainLooper())
    private var lastFrameAt = 0L
    private var watchdogStartedAt = 0L
    private var fallbackSent = false
    private var hasRemoteOffer = false
    private var codecName = "Auto"
    private var lastBytes = 0L
    private var lastStatsAt = 0L

    private val frameWatcher = object : VideoSink {
        override fun onFrame(frame: VideoFrame) {
            lastFrameAt = SystemClock.elapsedRealtime()
            renderer.onFrame(frame)
        }
    }

    private val statsPoller = object : Runnable {
        override fun run() {
            if (closing) return
            pc?.getStats { report ->
                try {
                    var video: RTCStats? = null
                    var pair: RTCStats? = null
                    for (stat in report.statsMap.values) {
                        if (stat.type == "inbound-rtp" && stat.members["kind"] == "video") video = stat
                        if (stat.type == "candidate-pair" && stat.members["state"] == "succeeded") pair = stat
                    }
                    val now = SystemClock.elapsedRealtime()
                    val bytes = (video?.members?.get("bytesReceived") as? Number)?.toLong() ?: 0L
                    val kbps = if (lastBytes > 0 && now > lastStatsAt) {
                        ((bytes - lastBytes) * 8.0 / (now - lastStatsAt)).coerceAtLeast(0.0)
                    } else 0.0
                    lastBytes = bytes
                    lastStatsAt = now
                    val fps = (video?.members?.get("framesPerSecond") as? Number)?.toInt() ?: 0
                    val height = (video?.members?.get("frameHeight") as? Number)?.toInt() ?: 0
                    val lost = (video?.members?.get("packetsLost") as? Number)?.toLong() ?: 0L
                    val received = (video?.members?.get("packetsReceived") as? Number)?.toLong() ?: 0L
                    val loss = if (lost + received > 0) lost * 100.0 / (lost + received) else 0.0
                    val rtt = ((pair?.members?.get("currentRoundTripTime") as? Number)?.toDouble() ?: 0.0) * 1000.0
                    val wifi = (appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)?.connectionInfo
                    val linkSpeed = wifi?.linkSpeed ?: 0
                    val rssi = wifi?.rssi ?: 0
                    val wifiLine = if (linkSpeed > 0) "\nWi-Fi %d Mbps · %d dBm".format(linkSpeed, rssi) else ""
                    val audioLabel = audio.activeCodec?.let { " · $it" } ?: ""
                    val text = "%s%s · %dp · %d fps\n%.1f Mbps · %.0f ms · %.1f%% loss%s".format(
                        codecName, audioLabel, height, fps, kbps / 1000.0, rtt, loss, wifiLine
                    )
                    main.post { onStats(text) }
                } catch (_: Exception) {}
            }
            main.postDelayed(this, 1000)
        }
    }

    private val watchdog = object : Runnable {
        override fun run() {
            if (closing || fallbackSent) return
            val now = SystemClock.elapsedRealtime()
            val last = lastFrameAt
            if (last == 0L) {
                if (now - watchdogStartedAt >= 3000) sendFallback()
                else main.postDelayed(this, 1000)
            } else if (now - last >= 3000) {
                sendFallback()
            } else {
                main.postDelayed(this, 1000)
            }
        }
    }

    init {
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context)
                .setEnableInternalTracer(false)
                .createInitializationOptions()
        )
        val encoder = DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true)
        val decoder = DefaultVideoDecoderFactory(eglBase.eglBaseContext)
        factory = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(encoder)
            .setVideoDecoderFactory(decoder)
            .createPeerConnectionFactory()
    }

    private fun state(message: String) {
        main.post { onState(message) }
    }

    fun helloMessage(deviceName: String, forceCodec: String? = null, pinned: Boolean = false): JSONObject {
        val caps = factory.getRtpReceiverCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO)
        val codecs = caps.codecs.map { it.name }.distinct()
        val profiles = caps.codecs
            .filter { it.name.equals("H264", ignoreCase = true) }
            .mapNotNull { it.parameters?.get("profile-level-id") }
            .distinct()
        // Only claim Opus if this box really has a decoder; the Mac takes the
        // list at its word and PCM still works everywhere.
        val audioCodecs = if (hasOpusDecoder()) listOf("opus", "pcm16") else listOf("pcm16")
        return JSONObject()
            .put("t", "hello")
            .put("v", 1)
            .put("name", deviceName)
            // Tells the Mac whether this TV still holds its half of the pair.
            .put("paired", pinned)
            .put("codecs", JSONArray(codecs))
            .put("h264Profiles", JSONArray(profiles))
            .put("audioCodecs", JSONArray(audioCodecs))
            .put("maxWidth", 2560)
            .put("maxHeight", 1440)
            .apply { if (forceCodec != null) put("forceCodec", forceCodec) }
    }

    private fun hasOpusDecoder(): Boolean = try {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
            !info.isEncoder && info.supportedTypes.any {
                it.equals(MediaFormat.MIMETYPE_AUDIO_OPUS, ignoreCase = true)
            }
        }
    } catch (e: Exception) {
        println("CODEC: could not list audio decoders: $e")
        false
    }

    fun start() {
        closing = false
        renderer.init(eglBase.eglBaseContext, null)
        renderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
        renderer.setEnableHardwareScaler(false)
        audio.start()
        createPeerConnection()
        lastBytes = 0L
        lastStatsAt = 0L
        main.removeCallbacks(statsPoller)
        main.postDelayed(statsPoller, 1000)
        state("Waiting for Mac")
    }

    private fun createPeerConnection() {
        val config = PeerConnection.RTCConfiguration(emptyList())
        config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
        config.bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
        config.rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE

        pc = factory.createPeerConnection(config, observer)
        videoTransceiver = pc?.addTransceiver(
            MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
            RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY)
        )

        val caps = factory.getRtpReceiverCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO)
        val allCodecs = caps.codecs
        val h264 = allCodecs.filter { it.name.equals("H264", ignoreCase = true) }
        h264Codecs = h264 + allCodecs.filter { !it.name.equals("H264", ignoreCase = true) }
        println("CODEC: receiver codecs=${allCodecs.size} H264=${h264.size}")
        if (h264Codecs.isNotEmpty()) {
            val error = videoTransceiver?.setCodecPreferences(h264Codecs)
            println("CODEC: initial preference err=$error")
        }
    }

    private fun resetPeerConnection() {
        main.removeCallbacks(watchdog)
        remoteVideo?.removeSink(frameWatcher)
        remoteVideo = null
        lastFrameAt = 0L
        watchdogStartedAt = 0L
        fallbackSent = false
        hasRemoteOffer = false
        pc?.close()
        pc = null
        createPeerConnection()
    }

    private fun startWatchdog() {
        println("WATCHDOG: start")
        watchdogStartedAt = SystemClock.elapsedRealtime()
        main.removeCallbacks(watchdog)
        main.postDelayed(watchdog, 3000)
    }

    private fun sendFallback() {
        if (fallbackSent) return
        fallbackSent = true
        println("WATCHDOG: no video, requesting VP8 reconnect")
        state("Optimising video…")
        onNoVideo()
    }

    fun handle(obj: JSONObject) {
        when (obj.optString("t")) {
            "offer" -> setRemoteOffer(obj.optString("sdp"))
            "ice" -> {
                val candidate = IceCandidate(
                    obj.optString("sdpMid"),
                    obj.optInt("sdpMLineIndex"),
                    obj.optString("candidate")
                )
                pc?.addIceCandidate(candidate)
            }
            "codec" -> {
                codecName = obj.optString("codecName", "Auto")
                val announced = obj.optString("audioCodec", "")
                state(if (announced.isEmpty()) "Codec: $codecName" else "Codec: $codecName · $announced")
            }
            "stop" -> close()
        }
    }

    private fun setRemoteOffer(sdp: String) {
        if (sdp.isBlank()) { state("Empty offer"); return }
        if (hasRemoteOffer) {
            println("CODEC: new offer, resetting peer connection")
            resetPeerConnection()
        }
        val pc = pc ?: return
        pc.setRemoteDescription(object : SdpObserver {
            override fun onSetSuccess() {
                hasRemoteOffer = true
                val error = videoTransceiver?.setCodecPreferences(h264Codecs)
                println("CODEC: after remote H264=${h264Codecs.size} err=$error")
                pc.createAnswer(object : SdpObserver {
                    override fun onCreateSuccess(answer: SessionDescription) {
                        pc.setLocalDescription(SimpleSdpObserver("local"), answer)
                        send(JSONObject().put("t", "answer").put("sdp", answer.description))
                        state("Answer sent")
                    }
                    override fun onCreateFailure(error: String?) { state("Answer failed: $error") }
                    override fun onSetSuccess() {}
                    override fun onSetFailure(error: String?) {}
                }, MediaConstraints())
            }
            override fun onCreateSuccess(desc: SessionDescription?) {}
            override fun onCreateFailure(error: String?) {}
            override fun onSetFailure(error: String?) { state("Remote offer failed: $error") }
        }, SessionDescription(SessionDescription.Type.OFFER, sdp))
    }

    fun close() {
        closing = true
        main.removeCallbacks(watchdog)
        main.removeCallbacks(statsPoller)
        remoteVideo?.removeSink(frameWatcher)
        remoteVideo = null
        audio.close()
        pc?.close()
        pc = null
        renderer.release()
    }

    private val observer = object : PeerConnection.Observer {
        override fun onSignalingChange(state: PeerConnection.SignalingState?) {}
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
            if (closing) return
            state("ICE: $state")
            if (state == PeerConnection.IceConnectionState.CONNECTED) startWatchdog()
        }
        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {}
        override fun onIceCandidate(candidate: IceCandidate?) {
            candidate ?: return
            send(
                JSONObject()
                    .put("t", "ice")
                    .put("candidate", candidate.sdp)
                    .put("sdpMid", candidate.sdpMid)
                    .put("sdpMLineIndex", candidate.sdpMLineIndex)
            )
        }
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
        override fun onAddStream(stream: MediaStream?) {}
        override fun onRemoveStream(stream: MediaStream?) {}
        override fun onDataChannel(channel: DataChannel?) {
            if (closing) return
            channel ?: return
            channel.registerObserver(object : DataChannel.Observer {
                override fun onBufferedAmountChange(previousAmount: Long) {}
                override fun onStateChange() {
                    state("Audio channel: ${channel.state()}")
                }
                override fun onMessage(buffer: DataChannel.Buffer) {
                    if (closing) return
                    val data = buffer.data ?: return
                    val bytes = ByteArray(data.remaining())
                    data.get(bytes)
                    audio.submit(bytes)
                    audioPackets++
                    if (audioPackets % 250 == 1) {
                        println(
                            "AUDIO: frame=$audioPackets bytes=${bytes.size} " +
                                "codec=${audio.activeCodec} dropped=${audio.droppedFrames}"
                        )
                    }
                }
            })
        }
        override fun onRenegotiationNeeded() {}
        override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) {
            if (closing) return
            val track = receiver?.track()
            if (track is VideoTrack && remoteVideo !== track) {
                remoteVideo = track
                main.post {
                    track.addSink(frameWatcher)
                    startWatchdog()
                    state("Video connected")
                }
            }
        }
        override fun onTrack(transceiver: RtpTransceiver?) {
            if (closing) return
            val track = transceiver?.receiver?.track()
            if (track is VideoTrack && remoteVideo !== track) {
                remoteVideo = track
                main.post {
                    track.addSink(frameWatcher)
                    startWatchdog()
                    state("Video connected")
                }
            }
        }
    }

    private class SimpleSdpObserver(private val label: String) : SdpObserver {
        override fun onCreateSuccess(desc: SessionDescription?) {}
        override fun onCreateFailure(error: String?) { println("$label create failed: $error") }
        override fun onSetSuccess() { println("$label set ok") }
        override fun onSetFailure(error: String?) { println("$label set failed: $error") }
    }
}
