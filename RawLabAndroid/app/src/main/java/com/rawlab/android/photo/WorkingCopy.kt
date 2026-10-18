package com.rawlab.android.photo

import java.io.File
import java.io.IOException
import java.io.InputStream

object WorkingCopy {
    fun import(directory: File, input: InputStream): File {
        directory.mkdirs()
        val destination = File.createTempFile("raw-", ".input", directory)
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
