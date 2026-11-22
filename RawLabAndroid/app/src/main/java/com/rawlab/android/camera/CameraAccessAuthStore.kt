package com.rawlab.android.camera

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class CameraAccessAuthRecord(
    val user: String,
    val password: String,
    val fingerprint: String,
)

internal class CameraAccessAuthStore(
    private val store: KeyValueStore,
    private val cipher: CipherBox,
) {
    internal interface KeyValueStore {
        fun getString(key: String): String?
        fun putString(key: String, value: String)
        fun remove(key: String)
    }

    internal interface CipherBox {
        fun encrypt(plaintext: ByteArray): ByteArray
        fun decrypt(ciphertext: ByteArray): ByteArray
    }

    constructor(context: Context) : this(
        store = SharedPreferencesKeyValueStore(
            context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE),
        ),
        cipher = AndroidKeystoreCipherBox(KEY_ALIAS),
    )

    fun load(cameraId: String): CameraAccessAuthRecord? {
        val key = storageKey(cameraId) ?: return null
        val encoded = store.getString(key) ?: return null
        return try {
            val encrypted = Base64.getDecoder().decode(encoded)
            val plaintext = cipher.decrypt(encrypted)
            decodeRecord(plaintext)
        } catch (_: Throwable) {
            null
        }
    }

    fun save(cameraId: String, record: CameraAccessAuthRecord): Boolean {
        val key = storageKey(cameraId) ?: return false
        val trimmedUser = record.user.trim()
        val normalizedFingerprint = normalizeSha256Fingerprint(record.fingerprint) ?: return false
        if (trimmedUser.isEmpty() || record.password.isEmpty()) return false
        return try {
            val payload = encodeRecord(
                CameraAccessAuthRecord(
                    user = trimmedUser,
                    password = record.password,
                    fingerprint = normalizedFingerprint,
                ),
            )
            val encrypted = cipher.encrypt(payload)
            store.putString(key, Base64.getEncoder().encodeToString(encrypted))
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun delete(cameraId: String) {
        val key = storageKey(cameraId) ?: return
        store.remove(key)
    }

    private fun storageKey(cameraId: String): String? {
        val trimmed = cameraId.trim()
        return if (trimmed.isEmpty()) null else "cam:$trimmed"
    }

    private class SharedPreferencesKeyValueStore(
        private val prefs: SharedPreferences,
    ) : KeyValueStore {
        override fun getString(key: String): String? = prefs.getString(key, null)

        override fun putString(key: String, value: String) {
            prefs.edit().putString(key, value).apply()
        }

        override fun remove(key: String) {
            prefs.edit().remove(key).apply()
        }
    }

    private class AndroidKeystoreCipherBox(
        private val alias: String,
    ) : CipherBox {
        private val lock = Any()

        override fun encrypt(plaintext: ByteArray): ByteArray = synchronized(lock) {
            try {
                encryptOnce(plaintext, getOrCreateKey())
            } catch (_: Throwable) {
                deleteKey()
                encryptOnce(plaintext, getOrCreateKey())
            }
        }

        override fun decrypt(ciphertext: ByteArray): ByteArray = synchronized(lock) {
            if (ciphertext.size < 3 || ciphertext[0] != CIPHER_FORMAT_VERSION) {
                throw IllegalArgumentException("Unsupported ciphertext format")
            }
            val ivLength = ciphertext[1].toInt() and 0xFF
            if (ivLength !in 12..16 || 2 + ivLength >= ciphertext.size) {
                throw IllegalArgumentException("Invalid IV length")
            }
            val iv = ciphertext.copyOfRange(2, 2 + ivLength)
            val body = ciphertext.copyOfRange(2 + ivLength, ciphertext.size)
            val key = loadExistingKey() ?: throw IllegalStateException("Keystore key missing")
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
            cipher.doFinal(body)
        }

        private fun encryptOnce(plaintext: ByteArray, key: SecretKey): ByteArray {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key)
            val iv = cipher.iv
            val encrypted = cipher.doFinal(plaintext)
            return ByteArray(2 + iv.size + encrypted.size).apply {
                this[0] = CIPHER_FORMAT_VERSION
                this[1] = iv.size.toByte()
                System.arraycopy(iv, 0, this, 2, iv.size)
                System.arraycopy(encrypted, 0, this, 2 + iv.size, encrypted.size)
            }
        }

        private fun getOrCreateKey(): SecretKey {
            loadExistingKey()?.let { return it }
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
            val spec = KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
            generator.init(spec)
            return generator.generateKey()
        }

        private fun loadExistingKey(): SecretKey? {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            return keyStore.getKey(alias, null) as? SecretKey
        }

        private fun deleteKey() {
            runCatching {
                val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
                if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
            }
        }
    }

    companion object {
        private const val PREFS_NAME = "camera-access-auth"
        private const val KEY_ALIAS = "rawlab_camera_access_auth_v1"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val CIPHER_FORMAT_VERSION: Byte = 1
        private const val RECORD_FORMAT_VERSION: Byte = 1
        private const val MAX_FIELD_BYTES = 16 * 1024

        internal fun encodeRecord(record: CameraAccessAuthRecord): ByteArray {
            val out = ByteArrayOutputStream()
            val data = DataOutputStream(out)
            data.writeByte(RECORD_FORMAT_VERSION.toInt())
            writeField(data, record.user)
            writeField(data, record.password)
            writeField(data, record.fingerprint)
            data.flush()
            return out.toByteArray()
        }

        internal fun decodeRecord(bytes: ByteArray): CameraAccessAuthRecord? {
            val input = DataInputStream(ByteArrayInputStream(bytes))
            if (bytes.isEmpty() || input.readByte() != RECORD_FORMAT_VERSION) return null
            val user = readField(input)?.trim() ?: return null
            val password = readField(input) ?: return null
            val fingerprint = readField(input)?.let(::normalizeSha256Fingerprint) ?: return null
            if (user.isEmpty() || password.isEmpty() || input.available() != 0) return null
            return CameraAccessAuthRecord(user = user, password = password, fingerprint = fingerprint)
        }

        private fun writeField(data: DataOutputStream, value: String) {
            val utf8 = value.toByteArray(StandardCharsets.UTF_8)
            data.writeInt(utf8.size)
            data.write(utf8)
        }

        private fun readField(input: DataInputStream): String? {
            val len = input.readInt()
            if (len !in 0..MAX_FIELD_BYTES || input.available() < len) return null
            val buf = ByteArray(len)
            input.readFully(buf)
            return String(buf, StandardCharsets.UTF_8)
        }
    }
}
