package com.rawlab.android.photo

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.io.IOException
import java.io.InputStream

internal class WorkingCopyTooLarge : IOException()
internal class WorkingCopyStorageFull : IOException()

object WorkingCopy {
    // 分块循环里的余量抽查间隔：statvfs 在入口查一次，之后每写入 8MB 抽查一次；
    // 真正写满由 output.write 抛 ENOSPC 异常兜底，不再每 64KB 分块 statvfs 一次。
    private const val SPACE_CHECK_BYTES = 8L * 1024 * 1024

    fun declaredBytes(resolver: ContentResolver, uri: Uri): Long {
        if (uri.scheme == "file") {
            val file = uri.path?.let(::File)
            if (file != null && file.isFile) return file.length()
        }
        runCatching {
            resolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                if (descriptor.declaredLength >= 0L) return descriptor.declaredLength
            }
        }
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) {
                    val size = cursor.getLong(0)
                    if (size >= 0L) return size
                }
            }
        }
        return -1L
    }

    fun requireTotalSpace(directory: File, totalBytes: Long) {
        if (totalBytes <= 0L) return
        if (!directory.exists()) directory.mkdirs()
        if (directory.usableSpace < totalBytes) throw WorkingCopyStorageFull()
    }

    fun import(directory: File, input: InputStream, sourceName: String? = null,
        maxBytes: Long = Long.MAX_VALUE, expectedBytes: Long = -1L): File {
        directory.mkdirs()
        if (expectedBytes > maxBytes) throw WorkingCopyTooLarge()
        if (expectedBytes >= 0 && directory.usableSpace < expectedBytes) throw WorkingCopyStorageFull()
        val extension = if (sourceName?.substringAfterLast('.', "")?.equals("x3f", ignoreCase = true) == true) ".x3f" else ".input"
        val destination = File.createTempFile("raw-", extension, directory)
        copyStream(destination, input, directory, maxBytes, expectedBytes, requireNonEmpty = true)
        return destination
    }

    fun copyTo(
        destination: File,
        input: InputStream,
        expectedBytes: Long = -1L,
        spaceDirectory: File = destination.parentFile ?: File("."),
        maxBytes: Long = Long.MAX_VALUE,
    ) {
        if (expectedBytes > maxBytes) throw WorkingCopyTooLarge()
        if (expectedBytes >= 0 && spaceDirectory.usableSpace < expectedBytes) throw WorkingCopyStorageFull()
        destination.parentFile?.mkdirs()
        copyStream(destination, input, spaceDirectory, maxBytes, expectedBytes, requireNonEmpty = false)
    }

    fun copyFile(
        source: File,
        destination: File,
        spaceDirectory: File = destination.parentFile ?: File("."),
    ) {
        source.inputStream().use { input ->
            copyTo(destination, input, expectedBytes = source.length(), spaceDirectory = spaceDirectory)
        }
    }

    private fun copyStream(
        destination: File,
        input: InputStream,
        spaceDirectory: File,
        maxBytes: Long,
        expectedBytes: Long,
        requireNonEmpty: Boolean,
    ) {
        try {
            var total = 0L
            var nextSpaceCheck = SPACE_CHECK_BYTES
            input.use { source -> destination.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = source.read(buffer)
                    if (count < 0) break
                    var written = count.toLong()
                    if (count == 0) {
                        val single = source.read()
                        if (single < 0) break
                        buffer[0] = single.toByte()
                        written = 1L
                    }
                    total += written
                    if (total > maxBytes) throw WorkingCopyTooLarge()
                    if (total >= nextSpaceCheck) {
                        nextSpaceCheck += SPACE_CHECK_BYTES
                        // 已知期望尺寸时按剩余额度抽查；否则只保证当前块写得下。
                        val required = if (expectedBytes >= 0) maxOf(written, expectedBytes - total) else written
                        if (spaceDirectory.usableSpace < required) throw WorkingCopyStorageFull()
                    }
                    output.write(buffer, 0, written.toInt())
                }
            } }
            if (requireNonEmpty && total == 0L) throw IOException("Empty input")
        } catch (error: Throwable) {
            destination.delete()
            throw error
        }
    }
}
