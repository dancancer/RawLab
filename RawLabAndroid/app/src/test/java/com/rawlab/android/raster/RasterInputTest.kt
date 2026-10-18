package com.rawlab.android.raster

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchJournal
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.format.PhotoFiles
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.PhotoIdentity

class RasterInputTest {
    @Test
    fun photoFilesAcceptsRawAndValidatedRasterContainers() {
        assertEquals(PhotoInputKind.RAW, PhotoFiles.kind("capture.ARW", "image/x-sony-arw"))
        assertEquals(PhotoInputKind.RASTER, PhotoFiles.kind("capture.jpg", "image/jpeg"))
        assertEquals(PhotoInputKind.RASTER, PhotoFiles.kind("capture.PNG", "image/png"))
        assertEquals(null, PhotoFiles.kind("capture.tif", "image/tiff"))
    }

    @Test
    fun photoFilesRejectsExplicitRawRasterConflicts() {
        assertEquals(null, PhotoFiles.kind("capture.arw", "image/jpeg"))
        assertEquals(null, PhotoFiles.kind("capture.jpg", "image/x-sony-arw"))
        assertEquals(PhotoInputKind.RAW, PhotoFiles.kind("capture.bin", "image/x-sony-arw"))
        assertEquals(PhotoInputKind.RASTER, PhotoFiles.kind("capture.bin", "image/png"))
    }

    @Test
    fun rasterSettingsDropCameraOnlyStateWithoutChangingStoredEdits() {
        val stored = EditSettings(customWb = true, temperature = 4200f, tint = 18f,
            exposureMode = 0, lens = LensSettings(distortion = true, tca = true),
            denoise = DenoiseSettings(enabled = true), recipeID = "recipe")
        val effective = stored.effectiveFor(PhotoInputKind.RASTER)
        assertEquals(2, effective.exposureMode)
        assertFalse(effective.customWb)
        assertEquals(6500f, effective.temperature)
        assertEquals(0f, effective.tint)
        assertEquals(LensSettings(), effective.lens)
        assertTrue(effective.denoise.enabled)
        assertEquals("recipe", effective.recipeID)
        assertTrue(stored.customWb)
        assertEquals(4200f, stored.temperature)
    }

    @Test
    fun mixedBatchPersistsKindsAndKeepsRawSourceSettings() {
        val root = java.nio.file.Files.createTempDirectory("rawlab-raster-batch").toFile()
        val stored = EditSettings(customWb = true, temperature = 4100f, tint = 15f,
            exposureMode = 0, lens = LensSettings(distortion = true))
        val source = BatchSourceSnapshot(PhotoIdentity("source"), java.io.File(root, "source.arw"), stored,
            inputKind = PhotoInputKind.RAW)
        val raster = BatchTarget(PhotoIdentity("raster"), java.io.File(root, "target.png"), "target.png",
            inputKind = PhotoInputKind.RASTER)
        val job = BatchJob(source, listOf(raster), id = "mixed")
        val journal = BatchJournal(root)
        journal.save(job)
        val restored = checkNotNull(journal.load("mixed"))
        assertEquals(PhotoInputKind.RASTER, restored.rows.single().target.inputKind)
        assertEquals(stored, restored.source.settings)
        assertEquals(LensSettings(), restored.rows.single().target.inputKind.let { stored.effectiveFor(it).lens })
        root.deleteRecursively()
    }

    @Test
    fun rasterContainerValidationRejectsAlphaAndSixteenBitPng() {
        assertTrue(RasterContainerValidator.inspect(pngHeader(2, 2, 8, 2, true)).isValid)
        assertTrue(RasterContainerValidator.inspect(pngHeader(2, 2, 8, 6, true)).isValid)
        assertFalse(RasterContainerValidator.inspect(pngHeader(2, 2, 8, 6, false)).isValid)
        assertFalse(RasterContainerValidator.inspect(pngHeader(2, 2, 16, 2, false)).isValid)
    }

    @Test
    fun rasterContainerValidationRejectsMpfJpegAndUnresolvedPngColorMetadata() {
        assertFalse(RasterContainerValidator.inspect(jpegWithMpf()).isValid)
        assertFalse(RasterContainerValidator.inspect(pngWithChunk("gAMA")).isValid)
        assertFalse(RasterContainerValidator.inspect(pngWithChunk("cICP")).isValid)
    }

    @Test
    fun pngColorMarkersAcceptOnlyExplicitSrgb() {
        assertTrue(RasterContainerValidator.inspect(pngWithChunk("cICP", byteArrayOf(1, 13, 0, 1))).isValid)
        for (payload in listOf(byteArrayOf(9, 16, 0, 1), byteArrayOf(1, 13, 1, 1), byteArrayOf(1, 13, 0))) {
            assertFalse(RasterContainerValidator.inspect(pngWithChunk("cICP", payload)).isValid)
        }
    }

    @Test
    fun pngSrgbChunkRequiresOneValidRenderingIntent() {
        for (intent in 0..3) {
            assertTrue(RasterContainerValidator.inspect(pngWithChunk("sRGB", byteArrayOf(intent.toByte()))).isValid)
        }
        for (payload in listOf(byteArrayOf(), byteArrayOf(4), byteArrayOf(0, 0))) {
            assertFalse(RasterContainerValidator.inspect(pngWithChunk("sRGB", payload)).isValid)
        }
    }

    @Test
    fun pngEndMustBeEmptyAndTerminateTheStream() {
        val prefix = pngHeader(2, 2, 8, 2, false)
        val complete = pngHeader(2, 2, 8, 2, true)
        assertFalse(RasterContainerValidator.inspect(prefix + pngChunk("IEND", byteArrayOf(1))).isValid)
        assertFalse(RasterContainerValidator.inspect(complete + byteArrayOf(0)).isValid)
        assertFalse(RasterContainerValidator.inspect(complete + complete).isValid)
    }

    @Test
    fun rasterContainerValidationAcceptsRealProgressiveJpegWithMultipleScans() {
        val jpeg = Base64.getDecoder().decode(PROGRESSIVE_JPEG_BASE64)
        val result = RasterContainerValidator.inspect(jpeg)
        assertTrue("progressive JPEG should be valid: ${result.error}", result.isValid)
        assertEquals("JPEG", result.info?.format)
        assertEquals(2, result.info?.width)
        assertEquals(2, result.info?.height)
    }

    @Test
    fun rasterContainerValidationRejectsConcatenatedJpegs() {
        val jpeg = Base64.getDecoder().decode(PROGRESSIVE_JPEG_BASE64)
        assertFalse(RasterContainerValidator.inspect(jpeg + jpeg).isValid)
    }

    private fun pngHeader(width: Int, height: Int, depth: Int, colorType: Int, includeIend: Boolean): ByteArray {
        val signature = byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10)
        val chunk = ByteArray(25)
        chunk[3] = 13
        chunk[4] = 'I'.code.toByte(); chunk[5] = 'H'.code.toByte(); chunk[6] = 'D'.code.toByte(); chunk[7] = 'R'.code.toByte()
        chunk[8] = (width ushr 24).toByte(); chunk[9] = (width ushr 16).toByte(); chunk[10] = (width ushr 8).toByte(); chunk[11] = width.toByte()
        chunk[12] = (height ushr 24).toByte(); chunk[13] = (height ushr 16).toByte(); chunk[14] = (height ushr 8).toByte(); chunk[15] = height.toByte()
        chunk[16] = depth.toByte(); chunk[17] = colorType.toByte()
        val iend = byteArrayOf(0, 0, 0, 0, 'I'.code.toByte(), 'E'.code.toByte(), 'N'.code.toByte(), 'D'.code.toByte(), 0, 0, 0, 0)
        return signature + chunk + if (includeIend) iend else ByteArray(0)
    }

    private fun pngWithChunk(type: String, data: ByteArray = byteArrayOf()): ByteArray =
        pngHeader(2, 2, 8, 2, false) + pngChunk(type, data) + pngChunk("IEND", byteArrayOf())

    private fun pngChunk(type: String, data: ByteArray): ByteArray =
        byteArrayOf((data.size ushr 24).toByte(), (data.size ushr 16).toByte(),
            (data.size ushr 8).toByte(), data.size.toByte()) + type.toByteArray(Charsets.US_ASCII) + data + ByteArray(4)

    private fun jpegWithMpf(): ByteArray {
        val mpf = byteArrayOf(0xFF.toByte(), 0xE2.toByte(), 0, 10, 'M'.code.toByte(), 'P'.code.toByte(), 'F'.code.toByte(), 0, 0, 0)
        val sof = byteArrayOf(0xFF.toByte(), 0xC0.toByte(), 0, 17, 8, 0, 1, 0, 1, 3, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1)
        val sos = byteArrayOf(0xFF.toByte(), 0xDA.toByte(), 0, 8, 3, 1, 0, 2, 0x11.toByte(), 3, 0x11.toByte(), 0)
        return byteArrayOf(0xFF.toByte(), 0xD8.toByte()) + mpf + sof + sos
    }

    private companion object {
        // Generated by libjpeg cjpeg -progressive from a 2x2 RGB PPM fixture.
        const val PROGRESSIVE_JPEG_BASE64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMU" +
            "FRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU" +
            "FBQUFBQUFBT/wgARCAACAAIDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAf/xAAUAQEAAAAAAAAAAAAAAAAAAAAG/9oA" +
            "DAMBAAIQAxAAAAG6gcA//8QAFhABAQEAAAAAAAAAAAAAAAAABAYD/9oACAEBAAEFApsBtJ7/xAAZEQABBQAAAAAAAAAAAAAAAAAA" +
            "AQIEM3H/2gAIAQMBAT8Bk3v1T//EABkRAAEFAAAAAAAAAAAAAAAAAAABAgMzcf/aAAgBAgEBPwGe1+qf/8QAGxAAAgIDAQAAAAAA" +
            "AAAAAAAAAQIDBAAFESL/2gAIAQEABj8C1bNXiZmqxEkoOnyM/8QAFhABAQEAAAAAAAAAAAAAAAAAAREA/9oACAEBAAE/IUb8PI2V" +
            "m//aAAwDAQACAAMAAAAQ9//EABcRAAMBAAAAAAAAAAAAAAAAAAABUfD/2gAIAQMBAT8Q1qz/xAAXEQADAQAAAAAAAAAAAAAAAAAA" +
            "AVHw/9oACAECAQE/ENis/8QAFxABAQEBAAAAAAAAAAAAAAAAAREAMf/aAAgBAQABPxBLxVstClVVXt3/2Q=="
    }
}
