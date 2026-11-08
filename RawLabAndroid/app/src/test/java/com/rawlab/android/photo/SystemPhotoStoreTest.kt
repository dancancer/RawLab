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
}
