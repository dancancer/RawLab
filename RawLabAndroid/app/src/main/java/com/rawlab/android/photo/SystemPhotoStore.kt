package com.rawlab.android.photo

import com.rawlab.android.format.PhotoFiles
import com.rawlab.android.format.PhotoInputKind
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.DigestInputStream
import java.security.MessageDigest

internal class UnsupportedSystemPhoto : IOException()
internal class ChangedSystemPhoto : IOException()

internal object SystemPhotoStore {
    @Synchronized
    fun retain(directory: File, input: InputStream, name: String, mime: String?): File {
        val digest = MessageDigest.getInstance("SHA-256")
        val temporary = WorkingCopy.import(directory, DigestInputStream(input, digest), name)
        try {
            val header = temporary.inputStream().use { input ->
                val bytes = ByteArray(64)
                bytes.copyOf(input.read(bytes).coerceAtLeast(0))
            }
            val detected = when {
                header.startsWith("FOVb".toByteArray()) -> "x3f"
                header.startsWith(byteArrayOf(-1, -40, -1)) -> "jpg"
                header.startsWith(byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)) -> "png"
                header.size >= 12 && String(header, 4, 4, Charsets.US_ASCII) == "ftyp" &&
                    String(header, 8, header.size - 8, Charsets.US_ASCII).chunked(4)
                        .any { it in setOf("heic", "heix", "hevc", "hevx") } -> "heic"
                else -> null
            }
            val kind = PhotoFiles.kind(name, mime) ?: detected?.let { PhotoFiles.kind("photo.$it", null) }
                ?: throw UnsupportedSystemPhoto()
            if (detected != null && PhotoFiles.kind("photo.$detected", null) != kind) throw UnsupportedSystemPhoto()
            val suffix = detected ?: if (kind == PhotoInputKind.RAW) "raw" else when {
                name.endsWith(".png", true) || mime == "image/png" -> "png"
                name.endsWith(".heic", true) || mime == "image/heic" -> "heic"
                name.endsWith(".heif", true) || mime in setOf("image/heif", "image/heif-sequence") -> "heif"
                else -> "jpg"
            }
            val hash = digest.digest().joinToString("") { "%02x".format(it) }
            val destination = File(directory, "$hash.$suffix")
            if (destination.exists()) {
                validate(destination)
            } else {
                // 身份绑定完整内容和固定私有路径，重新分享同一原片会复用编辑记录。
                Files.move(temporary.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
                File(directory, "$hash.name").writeText(name.substringAfterLast('/').substringAfterLast('\\'))
            }
            return destination
        } finally { temporary.delete() }
    }

    fun originalName(file: File): String? = File(file.parentFile, "${file.nameWithoutExtension}.name")
        .takeIf { it.isFile }?.readText()

    fun validate(file: File) {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        if (digest.digest().joinToString("") { "%02x".format(it) } != file.nameWithoutExtension) throw ChangedSystemPhoto()
    }

    private fun ByteArray.startsWith(prefix: ByteArray) = size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }
}
