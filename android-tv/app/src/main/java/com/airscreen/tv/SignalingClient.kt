package com.airscreen.tv

import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.Socket
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager

/**
 * Signaling transport: TLS 1.3 over TCP, newline-delimited JSON.
 *
 * Both ends present self-signed certificates. The handshake trusts on first
 * use — refusing an unknown Mac here would leave no way to pair a new one —
 * and [onHandshake] reports whether the Mac was already pinned. Deciding what
 * an unpinned Mac may do is [MainActivity]'s job, not this class's.
 */
class SignalingClient(
    private val host: String,
    private val port: Int,
    private val identity: DeviceIdentity,
    /// Built after the handshake: whether this Mac is pinned is part of
    /// `hello`, and that is not known until its certificate has been seen.
    private val buildHello: (macFingerprint: String, pinned: Boolean) -> JSONObject,
    private val onMessage: (JSONObject) -> Unit,
    private val onState: (String) -> Unit,
    private val onHandshake: (macFingerprint: String, pinned: Boolean) -> Unit
) {
    private var socket: Socket? = null
    private var writer: BufferedWriter? = null
    private val main = Handler(Looper.getMainLooper())

    /** SHA-256 of the certificate the Mac served, set during the handshake. */
    @Volatile
    var macFingerprint: String = ""
        private set

    @Volatile
    private var running = false

    fun connect() {
        running = true
        Thread {
            try {
                val s = openTlsSocket()
                socket = s
                val w = BufferedWriter(OutputStreamWriter(s.getOutputStream(), Charsets.UTF_8))
                writer = w

                val fingerprint = macFingerprint
                val pinned = identity.isPinned(fingerprint)
                main.post { onHandshake(fingerprint, pinned) }

                val hello = buildHello(fingerprint, pinned)
                w.write(hello.toString())
                w.newLine()
                w.flush()
                main.post { onState(if (pinned) "Connected to Mac" else "New Mac — pairing") }

                val reader = BufferedReader(InputStreamReader(s.getInputStream(), Charsets.UTF_8))
                while (running) {
                    val line = reader.readLine() ?: break
                    if (line.isBlank()) continue
                    try {
                        val obj = JSONObject(line)
                        main.post { onMessage(obj) }
                    } catch (e: Exception) {
                        main.post { onState("Bad message from Mac") }
                    }
                }
            } catch (e: Exception) {
                println("SIGNAL: connect failed: $e")
                if (running) main.post { onState("Connection failed: ${e.message}") }
            } finally {
                println("SIGNAL: reader ended running=$running")
                close()
            }
        }.start()
    }

    private fun openTlsSocket(): SSLSocket {
        val context = SSLContext.getInstance("TLSv1.3")
        context.init(arrayOf(ClientKeyManager()), arrayOf(PinRecordingTrustManager()), null)
        val s = context.socketFactory.createSocket() as SSLSocket
        s.enabledProtocols = arrayOf("TLSv1.3")
        s.tcpNoDelay = true
        s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
        s.startHandshake()
        return s
    }

    fun send(obj: JSONObject) {
        val w = writer
        if (w == null) {
            println("SIGNAL: send ${obj.optString("t")} DROPPED (no writer)")
            return
        }
        println("SIGNAL: send ${obj.optString("t")}")
        try {
            w.write(obj.toString())
            w.newLine()
            w.flush()
        } catch (e: Exception) {
            println("SIGNAL: send failed ${e.message}")
            main.post { onState("Send failed: ${e.message}") }
        }
    }

    fun close() {
        running = false
        try { writer?.close() } catch (_: Exception) {}
        try { socket?.close() } catch (_: Exception) {}
        writer = null
        socket = null
    }

    /** Always offers this TV's AndroidKeyStore identity; there is only one. */
    private inner class ClientKeyManager : X509ExtendedKeyManager() {
        override fun getClientAliases(keyType: String?, issuers: Array<Principal>?) =
            arrayOf(DeviceIdentity.ALIAS)

        override fun chooseClientAlias(
            keyType: Array<out String>?, issuers: Array<Principal>?, socket: Socket?
        ) = DeviceIdentity.ALIAS

        override fun getServerAliases(keyType: String?, issuers: Array<Principal>?): Array<String>? = null

        override fun chooseServerAlias(
            keyType: String?, issuers: Array<Principal>?, socket: Socket?
        ): String? = null

        override fun getCertificateChain(alias: String?): Array<X509Certificate> =
            arrayOf(identity.certificate)

        override fun getPrivateKey(alias: String?): PrivateKey = identity.privateKey
    }

    /**
     * Records the Mac's certificate instead of validating a chain — these are
     * self-signed by design and there is no authority to check them against.
     * Trust comes from the pin, enforced a layer up.
     */
    private inner class PinRecordingTrustManager : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            throw CertificateException("AirScreen TVs never act as a server")
        }

        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            val leaf = chain?.firstOrNull() ?: throw CertificateException("Mac sent no certificate")
            macFingerprint = Pairing.sha256Hex(leaf.encoded)
            println("TLS: mac cert ${macFingerprint.take(16)}")
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 5_000
    }
}
