package com.airscreen.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * The short auth string is implemented three times: here in Kotlin, in
 * `Pairing.swift`, and in `tools/chaos_pairing.py`. If they drift, pairing
 * shows two different codes and a correct user refuses to pair — a bug that
 * presents as an attack.
 *
 * These vectors come from `python3 tools/chaos_pairing.py`, which also checks
 * the Swift side. Regenerate both together or not at all.
 */
class PairingTest {
    private val macA = "c8ac76dcff2e8e2de6a63d4b4e4e32e0b0e7c6e58ccb7bcfe0c6e7a4bfd35b9f"
    private val tvA = "bf8b9f72d73f78d2b0e8d0c0c8b9cc1b6b6cd3d4f9f46f4b1dcf8f98d9bb1aa3"

    private data class Vector(val mac: String, val tv: String, val code: String)

    private val vectors = listOf(
        Vector(sha("mac-a"), sha("tv-a"), "016685"),
        Vector(sha("mac-a"), sha("tv-b"), "770252"),
        Vector(sha("mac-b"), sha("tv-a"), "302740"),
        Vector("00".repeat(32), "ff".repeat(32), "668059"),
        Vector("ff".repeat(32), "00".repeat(32), "751380"),
        Vector(sha("mac-a").uppercase(), sha("tv-a"), "016685"),
        // First eight digest bytes are 0xf014…, so bit 63 is set. A signed
        // modulo here would return a negative remainder and disagree with Swift.
        Vector(sha("signbit-mac"), sha("signbit-tv"), "122972"),
    )

    private fun sha(seed: String) = Pairing.sha256Hex(seed.toByteArray(Charsets.UTF_8))

    @Test
    fun `matches the shared vectors`() {
        for ((index, v) in vectors.withIndex()) {
            assertEquals(
                "vector $index (${v.mac.take(12)} x ${v.tv.take(12)})",
                v.code,
                Pairing.shortAuthString(v.mac, v.tv)
            )
        }
    }

    @Test
    fun `code commits to both certificates`() {
        val base = Pairing.shortAuthString(macA, tvA)
        assertNotEquals(base, Pairing.shortAuthString(macA, sha("other-tv")))
        assertNotEquals(base, Pairing.shortAuthString(sha("other-mac"), tvA))
        // Swapping the two must not produce the same code, or a relay could
        // mirror one side's pair back at the other.
        assertNotEquals(
            Pairing.shortAuthString(macA, tvA),
            Pairing.shortAuthString(tvA, macA)
        )
    }

    @Test
    fun `code is always six digits`() {
        for (i in 0 until 400) {
            val code = Pairing.shortAuthString(sha("m$i"), sha("t$i"))
            assertEquals("length for $i", 6, code.length)
            assertEquals("digits only for $i", true, code.all { it.isDigit() })
        }
    }
}
