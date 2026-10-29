package com.airscreen.tv

import java.security.MessageDigest

/**
 * Mirror of `Pairing.swift`. The two must agree byte for byte, or every pairing
 * attempt shows mismatched codes and the user correctly refuses it.
 *
 * Shared vectors live in `tools/chaos_pairing.py`.
 */
object Pairing {
    private const val SALT = "AirScreen-SAS-v1:"

    /**
     * Six digits committing to both certificates in the handshake. Derived
     * locally on each side and never sent, so a relay cannot make the two
     * agree: it has to substitute its own certificate on each leg.
     */
    fun shortAuthString(macFingerprint: String, tvFingerprint: String): String {
        val input = SALT + macFingerprint.lowercase() + ":" + tvFingerprint.lowercase()
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
        var value = 0L
        for (i in 0 until 8) value = (value shl 8) or (digest[i].toLong() and 0xFF)
        // Swift does this in UInt64. Kotlin's Long is signed, so the modulo has
        // to be unsigned or the two sides disagree whenever bit 63 is set.
        return String.format("%06d", java.lang.Long.remainderUnsigned(value, 1_000_000L))
    }

    /** `123456` -> `123 456`, for display only. */
    fun grouped(code: String): String =
        if (code.length == 6) "${code.substring(0, 3)} ${code.substring(3)}" else code

    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
