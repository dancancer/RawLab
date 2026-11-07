package com.rawlab.android.photo

import java.io.ByteArrayInputStream
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
            val raw = SystemPhotoStore.retain(root, ByteArrayInputStream("camera data".toByteArray()), "camera.NEF", "application/octet-stream")
            assertEquals("raw", raw.extension)
            for (name in listOf("animation.gif", "scan.tiff")) assertThrows(IOException::class.java) {
                SystemPhotoStore.retain(root, ByteArrayInputStream("unsupported".toByteArray()), name, "application/octet-stream")
            }
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
