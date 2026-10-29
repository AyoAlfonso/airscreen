package com.airscreen.tv

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.cert.X509Certificate
import java.util.Calendar
import javax.security.auth.x500.X500Principal

/**
 * This TV's TLS client identity, plus the set of Macs it has been paired with.
 *
 * The key pair lives in the AndroidKeyStore and cannot be exported, which is
 * what makes the pairing meaningful: a relay on the network can replay anything
 * the TV *says*, but it cannot complete a handshake as the TV.
 *
 * AndroidKeyStore mints a self-signed certificate alongside the key, so there
 * is no certificate builder to carry.
 */
class DeviceIdentity(context: Context) {
    companion object {
        const val ALIAS = "airscreen-tv"
        private const val PREFS = "airscreen"
        private const val KEY_PINS = "pinned_macs"
    }

    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    val certificate: X509Certificate
    val privateKey: PrivateKey

    /** SHA-256 of this TV's DER certificate. The Mac's pairing record is keyed on it. */
    val fingerprint: String

    init {
        if (!keyStore.containsAlias(ALIAS)) generate()
        if (!canSign()) {
            // A key left by an older build whose authorisations do not cover
            // what TLS asks for. It would fail every handshake with an opaque
            // "Keystore operation failed", so replace it. The cost is that this
            // TV has to be paired again, which is the honest outcome: its
            // identity really did change.
            println("IDENTITY: stored key cannot sign for TLS, regenerating")
            keyStore.deleteEntry(ALIAS)
            generate()
        }
        certificate = keyStore.getCertificate(ALIAS) as X509Certificate
        privateKey = keyStore.getKey(ALIAS, null) as PrivateKey
        fingerprint = Pairing.sha256Hex(certificate.encoded)
    }

    /**
     * TLS signs a digest that it has already computed, so it asks for raw
     * ECDSA. A key without [KeyProperties.DIGEST_NONE] accepts `initSign` and
     * then fails inside the keystore, which is why this probes a real
     * signature rather than just loading the key.
     */
    private fun canSign(): Boolean = try {
        val key = keyStore.getKey(ALIAS, null) as PrivateKey
        Signature.getInstance("NONEwithECDSA").run {
            initSign(key)
            update(ByteArray(32))
            sign()
        }
        true
    } catch (e: Exception) {
        println("IDENTITY: key self-test failed: $e")
        false
    }

    private fun generate() {
        val notAfter = Calendar.getInstance().apply { add(Calendar.YEAR, 10) }
        val spec = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
        )
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            // DIGEST_NONE is the one that matters: TLS hashes the transcript
            // itself and hands the keystore a raw 32-byte digest to sign.
            .setDigests(
                KeyProperties.DIGEST_NONE,
                KeyProperties.DIGEST_SHA256,
                KeyProperties.DIGEST_SHA384,
                KeyProperties.DIGEST_SHA512
            )
            .setCertificateSubject(X500Principal("CN=AirScreen TV"))
            .setCertificateSerialNumber(BigInteger.ONE)
            .setCertificateNotAfter(notAfter.time)
            .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
            initialize(spec)
            generateKeyPair()
        }
    }

    fun isPinned(macFingerprint: String): Boolean =
        macFingerprint.isNotEmpty() && pins().contains(macFingerprint.lowercase())

    fun pin(macFingerprint: String) {
        if (macFingerprint.isEmpty()) return
        prefs.edit().putStringSet(KEY_PINS, pins() + macFingerprint.lowercase()).apply()
    }

    fun forgetAll() = prefs.edit().remove(KEY_PINS).apply()

    fun pinnedCount(): Int = pins().size

    /** `getStringSet` hands back storage the framework owns; copy before use. */
    private fun pins(): Set<String> =
        prefs.getStringSet(KEY_PINS, emptySet())?.toSet() ?: emptySet()
}
