package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class GeometrySettingsTest {
    @Test fun versionedRecordsAndResetPreserveLegacyIdentity() {
        val geometry = GeometrySettings(.2f, .1f, .8f, .7f, 3, true, true, -8.5f)
        assertTrue(GeometrySettings().isIdentity)
        assertFalse(geometry.isIdentity)
        assertEquals(geometry, GeometrySettings.decode(geometry.encode()))
        assertEquals(GeometrySettings(), GeometrySettings.decode(null))
        val settings = EditSettings(film = "velvia", geometry = geometry, exposureMode = 2)
        assertEquals(settings, SettingsCodec.decode(SettingsCodec.encode(settings)))
        assertEquals(GeometrySettings(), settings.reset().geometry)
        assertEquals("velvia", settings.reset().film)
        assertEquals(1, settings.reset().exposureMode)
    }

    @Test fun rejectsInvalidCropsFlagsVersionsAndAngles() {
        for (bad in listOf(Float.NaN, Float.POSITIVE_INFINITY, -.1f, 1f)) {
            assertThrows(IllegalArgumentException::class.java) { GeometrySettings(cropX = bad) }
        }
        for (bad in listOf(0f, -.1f, 1.01f, Float.NaN)) {
            assertThrows(IllegalArgumentException::class.java) { GeometrySettings(cropWidth = bad) }
        }
        assertThrows(IllegalArgumentException::class.java) { GeometrySettings(cropX = .5f, cropWidth = .6f) }
        assertThrows(IllegalArgumentException::class.java) { GeometrySettings(cropY = .5f, cropHeight = .6f) }
        assertThrows(IllegalArgumentException::class.java) { GeometrySettings(quarterTurns = 4) }
        assertThrows(IllegalArgumentException::class.java) { GeometrySettings(quarterTurns = -1) }
        for (bad in listOf(-45.01f, 45.01f, Float.NaN)) {
            assertThrows(IllegalArgumentException::class.java) { GeometrySettings(straightenDegrees = bad) }
        }
        for (record in listOf("2,0,0,1,1,0,0,0,0", "1,0,0,1,1,0,2,0,0", "1,0,0,1,1,0,0,false,0", "1,0,0")) {
            assertThrows(IllegalArgumentException::class.java) { GeometrySettings.decode(record) }
        }
        assertEquals(.8f, GeometrySettings(cropX = .2f, cropWidth = .8f).cropWidth)
        assertEquals(45f, GeometrySettings(straightenDegrees = 45f).straightenDegrees)
    }

    @Test fun quarterTurnsWrapWithoutChangingCropFlipsOrStraighten() {
        val geometry = GeometrySettings(.1f, .2f, .7f, .6f, 0, true, false, 4.2f)
        assertEquals(geometry, (1..4).fold(geometry) { state, _ -> state.rotated(true) })
        assertEquals(3, geometry.rotated(false).quarterTurns)
        assertEquals(geometry, geometry.rotated(true).rotated(false))
    }

    @Test fun comparisonKeySeparatesSourceGeometryLensAndPreviewDemand() {
        val key = ComparisonPreviewKey("source.raw", GeometrySettings(), LensSettings(), 800, false)
        assertNotEquals(key, key.copy(inputPath = "other.raw"))
        assertNotEquals(key, key.copy(geometry = GeometrySettings(quarterTurns = 1)))
        assertNotEquals(key, key.copy(lens = LensSettings(distortion = true)))
        assertNotEquals(key, key.copy(edge = 1600))
        assertNotEquals(key, key.copy(interactive = true))
        assertEquals(1600f to 1200f, comparisonDimensions(4000, 3000))
        assertEquals(1200f to 1600f, comparisonDimensions(3000, 4000))
        assertEquals(400f to 300f, comparisonDimensions(400, 300))
        val dimensions = comparisonDimensions(4000, 3000)
        val viewport = PhotoViewport(dimensions.first, dimensions.second, 800f, 600f)
        assertEquals(832, viewport.previewLongEdge(viewport.fitScale))
        assertEquals(1600, viewport.previewLongEdge(1f))
    }

    @Test fun batchRecoveryRetainsCompleteGeometrySnapshot() {
        val directory = Files.createTempDirectory("rawlab-geometry-batch").toFile()
        try {
            val geometry = GeometrySettings(.1f, .2f, .75f, .8f, 1, true, true, -12.2f)
            val settings = EditSettings(geometry = geometry)
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(directory, "source.raw"), settings)
            val job = BatchJob(source, listOf(BatchTarget(PhotoIdentity("target"), File(directory, "target.raw"), "target.raw")))
            BatchJournal(directory).save(job)
            val resumed = BatchJournal(directory).load(job.id)!!
            assertEquals(geometry, resumed.source.settings.geometry)
            var rendered: EditSettings? = null
            BatchRunner.run(resumed, render = { _, edits -> rendered = edits; byteArrayOf(1) }, write = { _, _, _ -> })
            assertEquals(geometry, rendered!!.geometry)
            assertEquals(settings, source.settings)
        } finally { directory.deleteRecursively() }
    }
}
