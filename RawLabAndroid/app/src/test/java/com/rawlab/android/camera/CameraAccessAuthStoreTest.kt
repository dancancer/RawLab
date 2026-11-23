package com.rawlab.android.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class CameraAccessAuthStoreTest {

    private class InMemoryKvStore : CameraAccessAuthStore.KeyValueStore {
        val values = linkedMapOf<String, String>()
        override fun getString(key: String): String? = values[key]
        override fun putString(key: String, value: String) {
            values[key] = value
        }
        override fun remove(key: String) {
            values.remove(key)
        }
    }

    private class JvmAesGcmCipherBox : CameraAccessAuthStore.CipherBox {
        private val key: SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        private val random = SecureRandom()

        override fun encrypt(plaintext: ByteArray): ByteArray {
            val iv = ByteArray(12).also(random::nextBytes)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
            val body = cipher.doFinal(plaintext)
            return byteArrayOf(1, iv.size.toByte()) + iv + body
        }

        override fun decrypt(ciphertext: ByteArray): ByteArray {
            require(ciphertext.size > 14 && ciphertext[0].toInt() == 1)
            val ivLen = ciphertext[1].toInt() and 0xFF
            val iv = ciphertext.copyOfRange(2, 2 + ivLen)
            val body = ciphertext.copyOfRange(2 + ivLen, ciphertext.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
            return cipher.doFinal(body)
        }
    }

    private val validFpA = formatSha256Fingerprint("camera-host-key-a".toByteArray(StandardCharsets.UTF_8))
    private val validFpB = formatSha256Fingerprint("camera-host-key-b".toByteArray(StandardCharsets.UTF_8))

    @Test
    fun roundTripEncryptsAtRestAndIsolatesPerCamera() {
        val kv = InMemoryKvStore()
        val store = CameraAccessAuthStore(kv, JvmAesGcmCipherBox())

        assertTrue(store.save("cam-a", CameraAccessAuthRecord("sony_admin", "s3cr3t:pw!", "$validFpA=")))
        assertTrue(store.save("cam-b", CameraAccessAuthRecord("other_user", "other-pass", validFpB)))

        assertEquals(2, kv.values.size)
        val rawStored = kv.values.values.joinToString("\n")
        assertFalse(rawStored.contains("sony_admin"))
        assertFalse(rawStored.contains("s3cr3t:pw!"))

        val loadedA = store.load("cam-a")
        assertNotNull(loadedA)
        assertEquals("sony_admin", loadedA!!.user)
        assertEquals("s3cr3t:pw!", loadedA.password)
        assertEquals(validFpA, loadedA.fingerprint)

        store.delete("cam-a")
        assertNull(store.load("cam-a"))
        assertNotNull(store.load("cam-b"))
    }

    @Test
    fun tamperedOrCorruptEntriesReturnNullSafely() {
        val kv = InMemoryKvStore()
        val store = CameraAccessAuthStore(kv, JvmAesGcmCipherBox())

        assertTrue(store.save("cam-a", CameraAccessAuthRecord("user", "pass", validFpA)))
        val key = kv.values.keys.single()
        val original = kv.values.getValue(key)
        val mutatedChar = if (original.last() == 'A') 'B' else 'A'
        kv.values[key] = original.dropLast(1) + mutatedChar
        assertNull(store.load("cam-a"))

        kv.values[key] = "not!valid!base64"
        assertNull(store.load("cam-a"))
    }

    @Test
    fun rejectsBlankCredentialsOrInvalidFingerprint() {
        val kv = InMemoryKvStore()
        val store = CameraAccessAuthStore(kv, JvmAesGcmCipherBox())

        assertFalse(store.save("", CameraAccessAuthRecord("user", "pass", validFpA)))
        assertFalse(store.save("cam-a", CameraAccessAuthRecord("  ", "pass", validFpA)))
        assertFalse(store.save("cam-a", CameraAccessAuthRecord("user", "", validFpA)))
        assertFalse(store.save("cam-a", CameraAccessAuthRecord("user", "pass", "bad-fp")))
        assertNull(store.load("cam-a"))
    }
}
