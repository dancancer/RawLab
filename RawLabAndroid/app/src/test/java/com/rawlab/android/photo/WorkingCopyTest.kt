package com.rawlab.android.photo

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class WorkingCopyTest {
    @Test fun fileDefaultsUseLegacyCapabilityAndExplicitRetrySkipsProbe() {
        val mode = com.rawlab.android.settings.X3fMode.LEGACY
        val kind = com.rawlab.android.format.PhotoInputKind.RAW
        val file = java.io.File("camera.X3F")
        assertEquals(mode, defaultEditSettingsFor(file, kind, false, false, x3fDefaultMode = { mode }).x3fMode)
        assertEquals(mode, defaultEditSettingsFor(file, kind, false, false, mode,
            x3fDefaultMode = { error("explicit Legacy retry must not probe again") }).x3fMode)
    }

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

    @Test fun freeSpaceIsCheckedAtEntryOnlyBelowOneSampleInterval() {
        val root = Files.createTempDirectory("rawlab-copy-budget").toFile()
        val checks = java.util.concurrent.atomic.AtomicInteger()
        val directory = object : File(root.path) {
            override fun getUsableSpace(): Long { checks.incrementAndGet(); return Long.MAX_VALUE / 4 }
        }
        try {
            val payload = ByteArray(200 * 1024)
            val file = WorkingCopy.import(directory, ByteArrayInputStream(payload), expectedBytes = payload.size.toLong())
            assertEquals(payload.size.toLong(), file.length())
            assertEquals("free-space checking stays at the entry below one 8MB sample interval",
                1L, checks.get().toLong())
        } finally { root.deleteRecursively() }
    }

    @Test fun largeImportSamplesFreeSpaceOncePerEightMegabytes() {
        val root = Files.createTempDirectory("rawlab-copy-sampling").toFile()
        val checks = java.util.concurrent.atomic.AtomicInteger()
        val directory = object : File(root.path) {
            override fun getUsableSpace(): Long { checks.incrementAndGet(); return Long.MAX_VALUE / 4 }
        }
        try {
            val payload = ByteArray(17 * 1024 * 1024)
            val file = WorkingCopy.import(directory, ByteArrayInputStream(payload), expectedBytes = payload.size.toLong())
            assertEquals(payload.size.toLong(), file.length())
            assertEquals("272 chunks must not statvfs per chunk; entry plus one sample per crossed 8MB",
                3L, checks.get().toLong())
        } finally { root.deleteRecursively() }
    }

    @Test fun totalSpacePreflightRejectsOversizedBatchBeforeAnyFileCopy() {
        val root = Files.createTempDirectory("rawlab-total-preflight").toFile()
        val directory = object : File(root.path) {
            override fun getUsableSpace(): Long = 100L
        }
        try {
            val first = File(root, "first.raw").apply { writeBytes(ByteArray(60)) }
            val second = File(root, "second.raw").apply { writeBytes(ByteArray(60)) }
            val outDir = object : File(root, "out") {
                override fun getUsableSpace(): Long = 100L
            }.apply { mkdirs() }
            val out1 = File(outDir, "a.raw")
            val out2 = File(outDir, "b.raw")

            val result = runCatching {
                WorkingCopy.requireTotalSpace(directory, first.length() + second.length())
                WorkingCopy.copyFile(first, out1, spaceDirectory = outDir)
                WorkingCopy.copyFile(second, out2, spaceDirectory = outDir)
            }
            assertTrue(result.exceptionOrNull() is WorkingCopyStorageFull)
            assertFalse("Preflight must reject before copying first file", out1.exists())
            assertFalse("Preflight must reject before copying second file", out2.exists())

            val small = File(root, "small.raw").apply { writeBytes(ByteArray(40)) }
            WorkingCopy.requireTotalSpace(directory, first.length() + small.length())
            WorkingCopy.copyFile(first, out1, spaceDirectory = outDir)
            WorkingCopy.copyFile(small, out2, spaceDirectory = outDir)
            assertEquals(60L, out1.length())
            assertEquals(40L, out2.length())
        } finally { root.deleteRecursively() }
    }

    @Test fun preflightBatchInputsSpaceSumsMissingInputsAndRejectsOversizedBatch() {
        val root = Files.createTempDirectory("rawlab-batch-preflight").toFile()
        try {
            val f1 = File(root, "one.dng").apply { writeBytes(ByteArray(60)) }
            val f2 = File(root, "two.dng").apply { writeBytes(ByteArray(60)) }
            val f3 = File(root, "already.dng").apply { writeBytes(ByteArray(60)) }
            val destDir = object : File(root, "inputs") {
                override fun getUsableSpace(): Long = 100L
            }.apply { mkdirs() }
            val existingDest = File(destDir, "already.dng").apply { writeBytes(ByteArray(60)) }
            val u1 = android.net.TestUri.of(f1.absolutePath, scheme = "file", authority = "")
            val u2 = android.net.TestUri.of(f2.absolutePath, scheme = "file", authority = "")
            val u3 = android.net.TestUri.of(f3.absolutePath, scheme = "file", authority = "")
            val dests = mapOf(
                u1 to File(destDir, "one.dng"),
                u2 to File(destDir, "two.dng"),
                u3 to existingDest,
            )
            val resolver = object : android.content.ContentResolver(null) {}
            val failed = runCatching {
                com.rawlab.android.batch.preflightBatchInputsSpace(
                    uris = listOf(u1, u2, u3),
                    resolver = resolver,
                    inputsRoot = destDir,
                    destinationFor = { dests.getValue(it) },
                )
            }
            assertTrue(failed.exceptionOrNull() is WorkingCopyStorageFull)
            // Removing one missing file drops remaining missing total to 60 <= 100 (existingDest is skipped).
            com.rawlab.android.batch.preflightBatchInputsSpace(
                uris = listOf(u1, u3),
                resolver = resolver,
                inputsRoot = destDir,
                destinationFor = { dests.getValue(it) },
            )
        } finally { root.deleteRecursively() }
    }
}
