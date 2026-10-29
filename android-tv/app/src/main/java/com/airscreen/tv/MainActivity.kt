package com.airscreen.tv

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import org.webrtc.SurfaceViewRenderer

class MainActivity : Activity() {
    private lateinit var renderer: SurfaceViewRenderer
    private lateinit var intro: LinearLayout
    private lateinit var controls: LinearLayout
    private lateinit var pairing: LinearLayout
    private lateinit var pairingCode: TextView
    private lateinit var pairingTitle: TextView
    private lateinit var connectButton: Button
    private lateinit var stopButton: Button
    private lateinit var status: TextView
    private lateinit var statsView: TextView
    private lateinit var hint: TextView

    private lateinit var identity: DeviceIdentity
    private var signaling: SignalingClient? = null
    private var webRtc: WebRtcClient? = null
    private var fallbackAttempted = false
    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var macHost: String? = null
    private var macName: String? = null
    private var macPort: Int = 47890

    /** Certificate the connected Mac served, and whether it was already pinned. */
    private var macFingerprint: String = ""
    private var macTrusted = false

    private val handler = Handler(Looper.getMainLooper())

    private val hideControls = Runnable {
        controls.animate().alpha(0f).setDuration(150).withEndAction {
            controls.visibility = View.GONE
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUi()
        identity = DeviceIdentity(this)

        val root = FrameLayout(this)
        renderer = SurfaceViewRenderer(this)
        root.addView(renderer, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))

        status = TextView(this).apply {
            text = ""
            setTextColor(0xFFF5F5F7.toInt())
            textSize = 15f
            setPadding(dp(32), dp(24), dp(32), dp(24))
            visibility = View.GONE
        }
        root.addView(status, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT
        ))

        intro = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(48), dp(48), dp(48), dp(48))
        }

        val title = TextView(this).apply {
            text = "AirScreen"
            setTextColor(0xFFF5F5F7.toInt())
            textSize = 44f
            gravity = Gravity.CENTER
        }
        val subtitle = TextView(this).apply {
            text = "Share your Mac screen"
            setTextColor(0xFFA1A1A6.toInt())
            textSize = 18f
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, dp(36))
        }
        connectButton = Button(this).apply {
            text = "Searching for Mac…"
            isAllCaps = false
            textSize = 18f
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                setColor(0xFF0A84FF.toInt())
                cornerRadius = dp(12).toFloat()
            }
            // Setting a background clears the theme's padding, which clipped
            // the first and last letters of longer Mac names.
            setPadding(dp(32), dp(14), dp(32), dp(14))
            minWidth = dp(240)
            minHeight = dp(56)
            maxLines = 1
            stateListAnimator = null
            isEnabled = false
            alpha = 0.5f
        }

        hint = TextView(this).apply {
            text = "Open AirScreen on your Mac · same Wi-Fi"
            setTextColor(0xFF6E6E73.toInt())
            textSize = 13f
            gravity = Gravity.CENTER
            setPadding(0, dp(18), 0, 0)
        }
        intro.addView(title)
        intro.addView(subtitle)
        intro.addView(connectButton)
        intro.addView(hint)
        root.addView(intro, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER
        ))

        pairing = buildPairingView()
        root.addView(pairing, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER
        ))

        controls = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(24), dp(12), dp(10), dp(12))
            background = GradientDrawable().apply {
                setColor(0xE61C1C1E.toInt())
                cornerRadius = dp(26).toFloat()
                setStroke(dp(1), 0x33FFFFFF)
            }
            visibility = View.GONE
            alpha = 0f
        }
        val label = TextView(this).apply {
            text = "Sharing from Mac"
            setTextColor(0xFFF5F5F7.toInt())
            textSize = 16f
            setPadding(0, 0, dp(16), 0)
        }
        statsView = TextView(this).apply {
            text = ""
            setTextColor(0xFFA1A1A6.toInt())
            textSize = 14f
            setLineSpacing(dp(4).toFloat(), 1f)
            setPadding(0, dp(4), dp(18), 0)
        }
        stopButton = Button(this).apply {
            text = "Stop"
            isAllCaps = false
            textSize = 16f
            setTextColor(0xFFFF453A.toInt())
            background = GradientDrawable().apply {
                setColor(0x33FF453A)
                cornerRadius = dp(20).toFloat()
            }
            minWidth = dp(104)
            minHeight = dp(48)
            stateListAnimator = null
            setOnClickListener { stopSession() }
            setOnFocusChangeListener { _, hasFocus ->
                if (hasFocus) showControls()
            }
        }
        val dot = TextView(this).apply {
            text = "●"
            setTextColor(0xFF30D158.toInt())
            textSize = 12f
            setPadding(0, 0, dp(8), 0)
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(dot)
            addView(label)
        }
        val info = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(header)
            addView(statsView)
        }
        controls.addView(info)
        controls.addView(stopButton)
        root.addView(controls, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
        ).apply { bottomMargin = dp(48) })

        setContentView(root)

        connectButton.setOnClickListener {
            fallbackAttempted = false
            startSession()
        }

        startDiscovery()
    }

    private fun buildPairingView(): LinearLayout {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(56), dp(44), dp(56), dp(44))
            background = GradientDrawable().apply {
                setColor(0xF21C1C1E.toInt())
                cornerRadius = dp(22).toFloat()
                setStroke(dp(1), 0x33FFFFFF)
            }
            visibility = View.GONE
        }
        pairingTitle = TextView(this).apply {
            text = "Pair with your Mac"
            setTextColor(0xFFF5F5F7.toInt())
            textSize = 26f
            gravity = Gravity.CENTER
        }
        pairingCode = TextView(this).apply {
            text = "— — —"
            setTextColor(0xFFF5F5F7.toInt())
            textSize = 64f
            gravity = Gravity.CENTER
            letterSpacing = 0.18f
            setPadding(0, dp(22), 0, dp(22))
        }
        val explain = TextView(this).apply {
            text = "Check this code matches the one on your Mac, then choose Allow there."
            setTextColor(0xFFA1A1A6.toInt())
            textSize = 15f
            gravity = Gravity.CENTER
        }
        val warn = TextView(this).apply {
            text = "If the codes differ, decline — something is intercepting the connection."
            setTextColor(0xFF6E6E73.toInt())
            textSize = 13f
            gravity = Gravity.CENTER
            setPadding(0, dp(14), 0, 0)
        }
        box.addView(pairingTitle)
        box.addView(pairingCode)
        box.addView(explain)
        box.addView(warn)
        return box
    }

    private fun startSession(forceCodec: String? = null) {
        val host = macHost
        if (host == null) {
            setStatus("No Mac found yet")
            return
        }
        intro.visibility = View.GONE
        status.visibility = View.GONE
        renderer.visibility = View.VISIBLE
        macFingerprint = ""
        macTrusted = false

        val r = WebRtcClient(
            context = this,
            renderer = renderer,
            send = { message -> signaling?.send(message) },
            onState = { state -> setStatus(state) },
            onNoVideo = { restartWithVP8() },
            onStats = { text -> statsView.text = formatStats(text) }
        )
        val s = SignalingClient(
            host = host,
            port = macPort,
            identity = identity,
            buildHello = { _, pinned ->
                r.helloMessage(Build.MODEL ?: "Android TV", forceCodec, pinned)
            },
            onMessage = { message -> handleSignal(message) },
            onState = { state -> setStatus(state) },
            onHandshake = { fingerprint, pinned ->
                macFingerprint = fingerprint
                macTrusted = pinned
                println("PAIR: mac=${fingerprint.take(16)} pinned=$pinned")
            }
        )
        signaling = s
        webRtc = r
        r.start()
        s.connect()
        setStatus("Connecting…")
    }

    /**
     * Everything the Mac sends passes through here first. An offer is only
     * handed to WebRTC once this Mac is pinned or the user has just approved it
     * on the Mac — otherwise a Mac that quietly changed identity would be
     * trusted again with nobody asked.
     */
    private fun handleSignal(message: JSONObject) {
        when (message.optString("t")) {
            "pair-required" -> showPairing(message.optString("name", "your Mac"))
            "paired" -> {
                identity.pin(macFingerprint)
                macTrusted = true
                hidePairing()
                setStatus("Paired with ${message.optString("name", "your Mac")}")
            }
            "error" -> {
                val text = message.optString("message").ifEmpty { message.optString("code", "Refused") }
                hidePairing()
                setStatus(text)
                stopSession(sendStop = false)
            }
            "offer" -> {
                if (!macTrusted) {
                    setStatus("This Mac is not paired with this TV")
                    stopSession(sendStop = false)
                    return
                }
                hidePairing()
                webRtc?.handle(message)
            }
            else -> webRtc?.handle(message)
        }
    }

    private fun showPairing(name: String) {
        if (macFingerprint.isEmpty()) return
        pairingTitle.text = "Pair with $name"
        pairingCode.text = Pairing.grouped(
            Pairing.shortAuthString(macFingerprint, identity.fingerprint)
        )
        pairing.visibility = View.VISIBLE
        renderer.visibility = View.INVISIBLE
        status.visibility = View.GONE
    }

    private fun hidePairing() {
        pairing.visibility = View.GONE
        if (webRtc != null) renderer.visibility = View.VISIBLE
    }

    private fun restartWithVP8() {
        if (fallbackAttempted) return
        fallbackAttempted = true
        println("WATCHDOG: restarting session with VP8")
        stopSession(sendStop = false)
        startSession(forceCodec = "VP8")
        setStatus("Optimising video…")
    }

    private fun stopSession(sendStop: Boolean = true) {
        if (sendStop) {
            signaling?.send(JSONObject().put("t", "stop"))
        }
        webRtc?.close()
        webRtc = null
        signaling?.close()
        signaling = null
        handler.removeCallbacks(hideControls)
        controls.visibility = View.GONE
        pairing.visibility = View.GONE
        renderer.visibility = View.INVISIBLE
        intro.visibility = View.VISIBLE
        status.visibility = View.GONE
        macTrusted = false
        macFingerprint = ""
    }

    private fun setStatus(state: String) {
        status.text = state
        status.visibility = View.VISIBLE
        handler.postDelayed({ status.visibility = View.GONE }, 5000)
    }

    private fun showControls() {
        if (webRtc == null) return
        handler.removeCallbacks(hideControls)
        controls.visibility = View.VISIBLE
        controls.animate().alpha(1f).setDuration(150).start()
        stopButton.requestFocus()
        handler.postDelayed(hideControls, 3000)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN && webRtc != null) {
            if (event.keyCode == KeyEvent.KEYCODE_BACK) {
                stopSession()
                return true
            }
            if (controls.visibility != View.VISIBLE) {
                showControls()
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_DOWN) showControls()
        return super.onTouchEvent(event)
    }

    override fun onStop() {
        if (webRtc != null) stopSession()
        super.onStop()
    }

    override fun onDestroy() {
        stopSession(sendStop = false)
        stopDiscovery()
        super.onDestroy()
    }

    private fun onMacFound(host: String, port: Int, name: String) {
        macHost = host
        macPort = port
        macName = name
        connectButton.text = "Connect to $name"
        connectButton.isEnabled = true
        connectButton.alpha = 1f
        // Whether *this* Mac is paired is not knowable until its certificate
        // arrives in the handshake, so the idle screen does not claim either way.
        hint.text = "Press OK to connect"
        if (!connectButton.hasFocus()) connectButton.requestFocus()
    }

    private fun onMacLost() {
        macHost = null
        macName = null
        connectButton.text = "Searching for Mac…"
        connectButton.isEnabled = false
        connectButton.alpha = 0.5f
        hint.text = "Open AirScreen on your Mac · same Wi-Fi"
    }

    private fun startDiscovery() {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        multicastLock = wifi?.createMulticastLock("airscreen")?.apply {
            setReferenceCounted(true)
            acquire()
        }
        val nsd = getSystemService(Context.NSD_SERVICE) as NsdManager
        nsdManager = nsd
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                handler.post { setStatus("Searching for Mac…") }
            }

            override fun onServiceFound(service: NsdServiceInfo) {
                if (!service.serviceType.contains("_airscreen")) return
                nsd.resolveService(service, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        println("NSD: resolve failed $errorCode")
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        val host = serviceInfo.host?.hostAddress ?: return
                        handler.post {
                            onMacFound(host, serviceInfo.port, serviceInfo.serviceName ?: "Mac")
                        }
                    }
                })
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                handler.post {
                    // `onServiceLost` carries a name, not a resolved address.
                    if (service.serviceName != null && service.serviceName == macName) onMacLost()
                }
            }

            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                handler.post { setStatus("Could not search the network ($errorCode)") }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        discoveryListener = listener
        nsd.discoverServices("_airscreen._tcp.", NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun stopDiscovery() {
        discoveryListener?.let { listener ->
            try { nsdManager?.stopServiceDiscovery(listener) } catch (_: Exception) {}
        }
        discoveryListener = null
        nsdManager = null
        try { multicastLock?.release() } catch (_: Exception) {}
        multicastLock = null
    }

    private fun formatStats(raw: String): String {
        val lines = raw.split("\n")
        val video = lines.getOrNull(0) ?: ""
        val stream = lines.getOrNull(1) ?: ""
        val wifi = lines.getOrNull(2) ?: ""
        return "🖥  $video\n📶  $wifi\n⚡  $stream"
    }

    private fun hideSystemUi() {
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            )
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }
}
