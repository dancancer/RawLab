package com.rawlab.android.photo

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class WorkingCopyTest {
    @Test fun preservesBytesAndDoesNotUseUntrustedFilename() {
        val directory = Files.createTempDirectory("rawlab-copy").toFile()
        try {
            val bytes = byteArrayOf(1, 2, 3, 0, -1)
            val file = WorkingCopy.import(directory, ByteArrayInputStream(bytes))
            assertArrayEquals(bytes, file.readBytes())
            assertEquals(directory.canonicalFile, file.parentFile!!.canonicalFile)
        } finally { directory.deleteRecursively() }
    }

    @Test fun emptyOrFailedImportLeavesNoPartialFile() {
        val directory = Files.createTempDirectory("rawlab-copy").toFile()
        try {
            assertThrows(IOException::class.java) { WorkingCopy.import(directory, ByteArrayInputStream(byteArrayOf())) }
            val failed = object : InputStream() { override fun read(): Int = throw IOException("provider unavailable") }
            assertThrows(IOException::class.java) { WorkingCopy.import(directory, failed) }
            assertEquals(0, directory.listFiles()!!.size)
        } finally { directory.deleteRecursively() }
    }
}
