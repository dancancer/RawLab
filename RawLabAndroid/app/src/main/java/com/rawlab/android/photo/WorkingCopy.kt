package com.rawlab.android.photo

import java.io.File
import java.io.IOException
import java.io.InputStream

object WorkingCopy {
    fun import(directory: File, input: InputStream, sourceName: String? = null): File {
        directory.mkdirs()
        val extension = if (sourceName?.substringAfterLast('.', "")?.equals("x3f", ignoreCase = true) == true) ".x3f" else ".input"
        val destination = File.createTempFile("raw-", extension, directory)
        try {
            val count = input.use { source -> destination.outputStream().use { source.copyTo(it) } }
            if (count == 0L) throw IOException("Empty input")
            return destination
        } catch (error: Throwable) {
            destination.delete()
            throw error
        }
    }
}
