package com.rawlab.android.photo

import java.io.File
import java.io.IOException
import java.io.InputStream

internal class WorkingCopyTooLarge : IOException()
internal class WorkingCopyStorageFull : IOException()

object WorkingCopy {
    fun import(directory: File, input: InputStream, sourceName: String? = null,
        maxBytes: Long = Long.MAX_VALUE, expectedBytes: Long = -1L): File {
        directory.mkdirs()
        if (expectedBytes > maxBytes) throw WorkingCopyTooLarge()
        if (expectedBytes >= 0 && directory.usableSpace < expectedBytes) throw WorkingCopyStorageFull()
        val extension = if (sourceName?.substringAfterLast('.', "")?.equals("x3f", ignoreCase = true) == true) ".x3f" else ".input"
        val destination = File.createTempFile("raw-", extension, directory)
        try {
            var total = 0L
            input.use { source -> destination.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = source.read(buffer)
                    if (count < 0) break
                    if (count == 0) {
                        val single = source.read()
                        if (single < 0) break
                        buffer[0] = single.toByte()
                        total += 1
                        if (total > maxBytes) throw WorkingCopyTooLarge()
                        if ((destination.parentFile?.usableSpace ?: 0L) < 1) throw WorkingCopyStorageFull()
                        output.write(buffer, 0, 1)
                        continue
                    }
                    total += count
                    if (total > maxBytes) throw WorkingCopyTooLarge()
                    if ((destination.parentFile?.usableSpace ?: 0L) < count) throw WorkingCopyStorageFull()
                    output.write(buffer, 0, count)
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
