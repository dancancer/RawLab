package com.rawlab.android.photo

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class SystemPhotoStoreTest {
    @Test fun sharedBytesHaveAStablePrivateIdentityAcrossNamesAndStoreInstances() {
        val root = Files.createTempDirectory("rawlab-system-photo").toFile()
        try {
            val bytes = byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3)
            val first = SystemPhotoStore.retain(root, ByteArrayInputStream(bytes), "../../one.png", "image/png")
            val reopened = SystemPhotoStore.retain(root, ByteArrayInputStream(bytes), "renamed.bin", "application/octet-stream")
            assertEquals(first, reopened)
            assertEquals(root.canonicalFile, first.parentFile!!.canonicalFile)
            assertArrayEquals(bytes, reopened.readBytes())
            assertEquals("one.png", SystemPhotoStore.originalName(reopened))
            first.writeText("changed source")
            assertThrows(IOException::class.java) { SystemPhotoStore.validate(first) }
            assertThrows(IOException::class.java) {
                SystemPhotoStore.retain(root, ByteArrayInputStream(bytes), "one.png", "image/png")
            }
        } finally { root.deleteRecursively() }
    }
    @Test fun octetStreamUsesSupportedSuffixOrContentWithoutAdmittingGifOrTiff() {
        val root = Files.createTempDirectory("rawlab-system-kinds").toFile()
        try {
            val x3f = SystemPhotoStore.retain(root, ByteArrayInputStream("FOVb-source".toByteArray()), "unknown.bin", "application/octet-stream")
            assertEquals("x3f", x3f.extension)
            val tiffRaw = byteArrayOf(73, 73, 42, 0, 8, 0, 0, 0, 1, 2, 3)
            val raw = SystemPhotoStore.retain(root, ByteArrayInputStream(tiffRaw), "camera.NEF", "application/octet-stream")
            assertEquals("raw", raw.extension)
            assertThrows(IOException::class.java) {
                SystemPhotoStore.retain(root, ByteArrayInputStream("camera data".toByteArray()), "camera.NEF", "application/octet-stream")
            }
            for (name in listOf("animation.gif", "scan.tiff")) assertThrows(IOException::class.java) {
                SystemPhotoStore.retain(root, ByteArrayInputStream("unsupported".toByteArray()), name, "application/octet-stream")
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun unknownContentIsRejectedBeforeTheWholeInputIsRead() {
        val root = Files.createTempDirectory("rawlab-system-header").toFile()
        try {
            val total = 1_000_000
            var read = 0
            val input = object : InputStream() {
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    if (read == total) return -1
                    val count = minOf(length, total - read)
                    java.util.Arrays.fill(buffer, offset, offset + count, 7)
                    read += count
                    return count
                }
                override fun read(): Int = if (read == total) -1 else { read++; 7 }
            }
            assertThrows(IOException::class.java) {
                SystemPhotoStore.retain(root, input, "unknown.bin", "application/octet-stream")
            }
            assertTrue("unknown input was copied in full: $read bytes", read < total)
        } finally { root.deleteRecursively() }
    }

    @Test fun rawContainerHeadersAreRecognizedOnlyWithTheirRawNames() {
        val root = Files.createTempDirectory("rawlab-system-raw-headers").toFile()
        try {
            val headers = listOf(
                "photo.ORF" to "IIRO".toByteArray(),
                "photo.RW2" to byteArrayOf(73, 73, 85, 0),
                "photo.MRW" to byteArrayOf(0, 77, 82, 77),
                "photo.RAF" to "FUJIFILMCCD-RAW".toByteArray(),
                "photo.CR3" to byteArrayOf(0, 0, 0, 0, 102, 116, 121, 112, 99, 114, 120, 32),
                "photo.CRW" to byteArrayOf(73, 73, 26, 0, 0, 0, 72, 69, 65, 80, 67, 67, 68, 82),
            )
            headers.forEach { (name, header) ->
                val file = SystemPhotoStore.retain(root, ByteArrayInputStream(header + byteArrayOf(1)), name, "application/octet-stream")
                assertEquals("raw", file.extension)
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun successfulCopyUsesSeparateTemporaryDirectoryAndStartupRemovesOwnedParts() {
        val store = Files.createTempDirectory("rawlab-system-store").toFile()
        val temporary = Files.createTempDirectory("rawlab-system-cache").toFile()
        try {
            val bytes = byteArrayOf(-1, -40, -1, 1, 2, 3)
            val file = SystemPhotoStore.retain(store, ByteArrayInputStream(bytes), "photo.jpg", "image/jpeg", temporary)
            assertEquals(store.canonicalFile, file.parentFile!!.canonicalFile)
            assertTrue(temporary.listFiles().orEmpty().isEmpty())
            val hash = "a".repeat(64)
            File(temporary, "raw-left.input").writeText("stale")
            File(store, "raw-old.input").writeText("stale")
            File(store, "raw-old.x3f").writeText("stale")
            File(store, ".$hash.jpg.part").writeText("stale")
            File(store, ".$hash.name.part").writeText("stale")
            File(store, "keep.txt").writeText("keep")
            SystemPhotoStore.cleanupTemporary(temporary, store)
            assertTrue(temporary.listFiles().orEmpty().none { it.name == "raw-left.input" })
            assertTrue(store.listFiles().orEmpty().none { it.name == "raw-old.input" || it.name == "raw-old.x3f" })
            assertTrue(store.listFiles().orEmpty().none { it.name == ".$hash.jpg.part" || it.name == ".$hash.name.part" })
            assertTrue(File(store, "keep.txt").isFile)
        } finally {
            store.deleteRecursively()
            temporary.deleteRecursively()
        }
    }

    @Test fun declaredInputLargerThanOneGiBIsRejectedBeforeCopy() {
        val root = Files.createTempDirectory("rawlab-system-limit").toFile()
        try {
            val jpeg = byteArrayOf(-1, -40, -1, 1)
            assertThrows(SystemPhotoTooLarge::class.java) {
                SystemPhotoStore.retain(root, ByteArrayInputStream(jpeg), "photo.jpg", "image/jpeg",
                    expectedBytes = SystemPhotoStore.MAX_BYTES + 1)
            }
            assertTrue(root.listFiles().orEmpty().isEmpty())
        } finally { root.deleteRecursively() }
    }
    @Test fun failedProvidersAndEmptyInputLeaveNoPartialSnapshot() {
        val root = Files.createTempDirectory("rawlab-system-failure").toFile()
        try {
            assertThrows(IOException::class.java) { SystemPhotoStore.retain(root, ByteArrayInputStream(byteArrayOf()), "empty.png", "image/png") }
            val broken = object : InputStream() { override fun read(): Int = throw IOException("grant revoked") }
            assertThrows(IOException::class.java) { SystemPhotoStore.retain(root, broken, "photo.jpg", "image/jpeg") }
            assertEquals(0, root.listFiles()!!.size)
        } finally { root.deleteRecursively() }
    }

    @Test fun clearRetainedCopiesDeletesAllOwnedCopiesWithExactCountsWhilePreservingOtherFilesAndSubdirectories() {
        val workspace = Files.createTempDirectory("rawlab-system-clear").toFile()
        try {
            val store = File(workspace, "system-photos")
            val missing = File(workspace, "never-created")
            assertEquals(RetainedCopiesSummary(0, 0L), SystemPhotoStore.inspectRetainedCopies(missing))
            assertEquals(RetainedCopiesSummary(0, 0L), SystemPhotoStore.clearRetainedCopies(missing))
            assertFalse(missing.exists())

            val jpeg = SystemPhotoStore.retain(store, ByteArrayInputStream(byteArrayOf(-1, -40, -1, 10, 20, 30, 40)), "first.jpg", "image/jpeg")
            val png = SystemPhotoStore.retain(store, ByteArrayInputStream(byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10, 5, 6)), "second.png", "image/png")
            val x3f = SystemPhotoStore.retain(store, ByteArrayInputStream("FOVb-payload".toByteArray()), "third.x3f", "application/octet-stream")
            val raw = SystemPhotoStore.retain(store, ByteArrayInputStream("FUJIFILMCCD-RAW-payload".toByteArray()), "fourth.RAF", "application/octet-stream")
            val heicHeader = byteArrayOf(0, 0, 0, 16) + "ftypheic".toByteArray() + byteArrayOf(1, 2, 3, 4)
            val heic = SystemPhotoStore.retain(store, ByteArrayInputStream(heicHeader), "fifth.heic", "image/heic")
            val upperHash = "A1B2C3D4".repeat(8)
            val upperCopy = File(store, "$upperHash.jpg").apply { writeBytes(byteArrayOf(-1, -40, -1, 99)) }
            val upperName = File(store, "$upperHash.name").apply { writeText("upper.jpg") }

            val ownedFiles = listOf(
                jpeg, File(store, "${jpeg.nameWithoutExtension}.name"),
                png, File(store, "${png.nameWithoutExtension}.name"),
                x3f, File(store, "${x3f.nameWithoutExtension}.name"),
                raw, File(store, "${raw.nameWithoutExtension}.name"),
                heic, File(store, "${heic.nameWithoutExtension}.name"),
                upperCopy, upperName,
            )
            ownedFiles.forEach { assertTrue("expected owned file: ${it.name}", it.isFile) }
            val expectedBytes = ownedFiles.sumOf { it.length() }

            val keepTxt = File(store, "keep.txt").apply { writeText("unrelated note") }
            val rawTemp = File(store, "raw-staging.input").apply { writeText("staging") }
            val partPhoto = File(store, ".${"a".repeat(64)}.jpg.part").apply { writeText("partial-photo") }
            val partName = File(store, ".${"a".repeat(64)}.name.part").apply { writeText("partial-name") }
            val hexWrongExt = File(store, "${"b".repeat(64)}.txt").apply { writeText("not-a-photo-copy") }
            val shortHex = File(store, "${"c".repeat(63)}.jpg").apply { writeText("short-hash") }
            val externalTarget = File(workspace, "external.jpg").apply { writeText("outside-store") }
            val symlinkInStore = File(store, "${"d".repeat(64)}.jpg")
            Files.createSymbolicLink(symlinkInStore.toPath(), externalTarget.toPath())

            val nestedDir = File(store, "nested").apply { mkdirs() }
            val nestedCopyNamedFile = File(nestedDir, "${"e".repeat(64)}.jpg").apply { writeText("nested-file") }
            val nestedNameFile = File(nestedDir, "${"e".repeat(64)}.name").apply { writeText("nested.jpg") }
            val copyNamedSubdir = File(store, "${"f".repeat(64)}.jpg").apply { mkdirs() }
            val insideCopyNamedSubdir = File(copyNamedSubdir, "marker.txt").apply { writeText("dir-not-file") }

            assertEquals(RetainedCopiesSummary(ownedFiles.size, expectedBytes), SystemPhotoStore.inspectRetainedCopies(store))

            val cleared = SystemPhotoStore.clearRetainedCopies(store)
            assertEquals(RetainedCopiesSummary(ownedFiles.size, expectedBytes), cleared)
            ownedFiles.forEach { assertFalse("owned file should be deleted: ${it.name}", it.exists()) }
            assertTrue(store.isDirectory)

            assertTrue(keepTxt.isFile)
            assertTrue(rawTemp.isFile)
            assertTrue(partPhoto.isFile)
            assertTrue(partName.isFile)
            assertTrue(hexWrongExt.isFile)
            assertTrue(shortHex.isFile)
            assertTrue(Files.isSymbolicLink(symlinkInStore.toPath()))
            assertEquals("outside-store", externalTarget.readText())
            assertTrue(nestedDir.isDirectory)
            assertEquals("nested-file", nestedCopyNamedFile.readText())
            assertEquals("nested.jpg", nestedNameFile.readText())
            assertTrue(copyNamedSubdir.isDirectory)
            assertEquals("dir-not-file", insideCopyNamedSubdir.readText())

            assertEquals(RetainedCopiesSummary(0, 0L), SystemPhotoStore.inspectRetainedCopies(store))
            assertEquals(RetainedCopiesSummary(0, 0L), SystemPhotoStore.clearRetainedCopies(store))
        } finally {
            workspace.deleteRecursively()
        }
    }

    @Test fun invalidStoreTargetReportsFailureInsteadOfReturningZero() {
        val workspace = Files.createTempDirectory("rawlab-system-invalid-target").toFile()
        try {
            val notADirectory = File(workspace, "system-photos").apply { writeText("corrupt") }
            assertThrows(IOException::class.java) { SystemPhotoStore.inspectRetainedCopies(notADirectory) }
            assertThrows(IOException::class.java) { SystemPhotoStore.clearRetainedCopies(notADirectory) }
        } finally {
            workspace.deleteRecursively()
        }
    }
}
