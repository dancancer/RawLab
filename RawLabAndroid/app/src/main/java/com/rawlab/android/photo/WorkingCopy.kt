package com.rawlab.android.photo

import java.io.File
import java.io.IOException
import java.io.InputStream

internal class WorkingCopyTooLarge : IOException()
internal class WorkingCopyStorageFull : IOException()

object WorkingCopy {
    // 分块循环里的余量抽查间隔：statvfs 在入口查一次，之后每写入 8MB 抽查一次；
    // 真正写满由 output.write 抛 ENOSPC 异常兜底，不再每 64KB 分块 statvfs 一次。
    private const val SPACE_CHECK_BYTES = 8L * 1024 * 1024

    fun import(directory: File, input: InputStream, sourceName: String? = null,
        maxBytes: Long = Long.MAX_VALUE, expectedBytes: Long = -1L): File {
        directory.mkdirs()
        if (expectedBytes > maxBytes) throw WorkingCopyTooLarge()
        if (expectedBytes >= 0 && directory.usableSpace < expectedBytes) throw WorkingCopyStorageFull()
        val extension = if (sourceName?.substringAfterLast('.', "")?.equals("x3f", ignoreCase = true) == true) ".x3f" else ".input"
        val destination = File.createTempFile("raw-", extension, directory)
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
                        if (directory.usableSpace < required) throw WorkingCopyStorageFull()
                    }
                    output.write(buffer, 0, written.toInt())
                }
            } }
            if (total == 0L) throw IOException("Empty input")
            return destination
        } catch (error: Throwable) {
            destination.delete()
            throw error
        }
    }
}
