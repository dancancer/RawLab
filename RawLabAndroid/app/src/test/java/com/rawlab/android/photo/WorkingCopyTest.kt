package com.rawlab.android.photo

import java.io.ByteArrayInputStream
import java.io.File
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

    @Test fun x3fExtensionSurvivesWithoutTrustingTheOriginalPath() {
        val directory = Files.createTempDirectory("rawlab-x3f-copy").toFile()
        try {
            val bytes = "FOVbtest".toByteArray()
            val file = WorkingCopy.import(directory, ByteArrayInputStream(bytes), "../../unsafe.X3F")
            assertEquals("x3f", file.extension)
            assertEquals(directory.canonicalFile, file.parentFile!!.canonicalFile)
            assertArrayEquals(bytes, file.readBytes())
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

    @Test fun maxBytesStopsAnUndeclaredLengthStreamBeforeAFullCopy() {
        val directory = Files.createTempDirectory("rawlab-copy-limit").toFile()
        try {
            assertThrows(WorkingCopyTooLarge::class.java) {
                WorkingCopy.import(directory, ByteArrayInputStream(ByteArray(8)), maxBytes = 4)
            }
            assertTrue(directory.listFiles().orEmpty().isEmpty())
        } finally { directory.deleteRecursively() }
    }

    @Test fun expectedBytesChecksRemainingSpaceBeforeCreatingAFile() {
        val root = Files.createTempDirectory("rawlab-copy-space").toFile()
        val directory = object : File(root.path) {
            override fun getUsableSpace(): Long = 0L
        }
        try {
            assertThrows(WorkingCopyStorageFull::class.java) {
                WorkingCopy.import(directory, ByteArrayInputStream(byteArrayOf(1)), expectedBytes = 1)
            }
            assertTrue(root.listFiles().orEmpty().isEmpty())
        } finally { root.deleteRecursively() }
    }
}
