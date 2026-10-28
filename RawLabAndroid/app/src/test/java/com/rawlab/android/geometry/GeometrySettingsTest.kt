package com.rawlab.android.geometry

import com.rawlab.android.settings.legacyPipeSettings
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.batch.BatchRunner
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.editor.canvas.PhotoViewport
import com.rawlab.android.editor.render.ComparisonPreviewKey
import com.rawlab.android.editor.render.comparisonDimensions
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.SettingsCodec

class GeometrySettingsTest {
    @Test fun perspectiveV2RecordRoundTripsWithoutLosingAxes() {
        val record = "2,0.1,0.2,0.7,0.6,1,1,0,4.0,0.25,-0.4"
        assertEquals(record, GeometrySettings.decode(record).encode())
    }

    @Test fun legacyV1RecordUpgradesWithZeroPerspective() {
        val old = "1,0.1,0.2,0.7,0.6,1,1,0,4.0"
        assertEquals("2,0.1,0.2,0.7,0.6,1,1,0,4.0,0.0,0.0", GeometrySettings.decode(old).encode())
    }

    @Test fun versionedRecordsAndResetPreserveLegacyIdentity() {
        val geometry = GeometrySettings(.2f, .1f, .8f, .7f, 3, true, true, -8.5f, .35f, -.25f)
        assertTrue(GeometrySettings().isIdentity)
        assertFalse(geometry.isIdentity)
        assertEquals(geometry, GeometrySettings.decode(geometry.encode()))
        assertEquals(11, geometry.encode().split(',').size)
        assertEquals("2", geometry.encode().substringBefore(','))
        assertEquals(GeometrySettings(), GeometrySettings.decode(null))
        assertFalse(GeometrySettings(perspectiveHorizontal = .01f).isIdentity)
        assertFalse(GeometrySettings(perspectiveVertical = -.01f).isIdentity)
        val settings = EditSettings(film = "velvia", geometry = geometry, exposureMode = 2)
        assertEquals(settings, SettingsCodec.decode(SettingsCodec.encode(settings)))
        assertEquals(GeometrySettings(), settings.reset().geometry)
        assertEquals("velvia", settings.reset().film)
        assertEquals(1, settings.reset().exposureMode)
    }

    @Test fun oldGeometryRecordsPreserveTheirCanvasAndDefaultPerspective() {
        val record = "1,0.2,0.1,0.8,0.7,3,1,1,-8.5"
        val expected = GeometrySettings(.2f, .1f, .8f, .7f, 3, true, true, -8.5f)
        assertEquals(expected, GeometrySettings.decode(record))
        val settings = EditSettings(geometry = expected, exposureMode = 2)
        val oldSnapshot = legacyPipeSettings(settings).split('|').toMutableList().also { it[52] = record }
        assertEquals(settings, SettingsCodec.decode(oldSnapshot.joinToString("|")))
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
        for (bad in listOf(-1.001f, 1.001f, Float.NaN, Float.NEGATIVE_INFINITY, Float.POSITIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { GeometrySettings(perspectiveHorizontal = bad) }
            assertThrows(IllegalArgumentException::class.java) { GeometrySettings(perspectiveVertical = bad) }
        }
        for (record in listOf("2,0,0,1,1,0,0,0,0", "1,0,0,1,1,0,2,0,0", "1,0,0,1,1,0,0,false,0", "1,0,0",
            "1,0,0,1,1,0,0,0,0,0,0", "3,0,0,1,1,0,0,0,0,0,0", "2,0,0,1,1,0,0,0,0,0",
            "2,0,0,1,1,0,0,0,0,0,0,0", "2,0,0,1,1,0,0,0,0,NaN,0", "2,0,0,1,1,0,0,0,0,0,1.01")) {
            assertThrows(IllegalArgumentException::class.java) { GeometrySettings.decode(record) }
        }
        assertEquals(.8f, GeometrySettings(cropX = .2f, cropWidth = .8f).cropWidth)
        assertEquals(45f, GeometrySettings(straightenDegrees = 45f).straightenDegrees)
        assertEquals(-1f, GeometrySettings(perspectiveHorizontal = -1f).perspectiveHorizontal)
        assertEquals(1f, GeometrySettings(perspectiveVertical = 1f).perspectiveVertical)
    }

    @Test fun quarterTurnsWrapWithoutChangingCropFlipsOrStraighten() {
        val geometry = GeometrySettings(.1f, .2f, .7f, .6f, 0, true, false, 4.2f, -.4f, .6f)
        assertEquals(geometry, (1..4).fold(geometry) { state, _ -> state.rotated(true) })
        assertEquals(3, geometry.rotated(false).quarterTurns)
        assertEquals(geometry, geometry.rotated(true).rotated(false))
    }

    @Test fun comparisonKeySeparatesLogicalSourceAndInputKindEvenAtTheSamePath() {
        val first = ComparisonPreviewKey("source", GeometrySettings(), LensSettings(), 800, false,
            sourceIdentity = com.rawlab.android.settings.PhotoIdentity("first"), inputKind = com.rawlab.android.format.PhotoInputKind.RAW)
        assertNotEquals(first, first.copy(sourceIdentity = com.rawlab.android.settings.PhotoIdentity("second")))
        assertNotEquals(first, first.copy(inputKind = com.rawlab.android.format.PhotoInputKind.RASTER))
        assertNotEquals(first, first.copy(processing = com.rawlab.android.settings.ProcessingIdentity.LEGACY))
    }

    @Test fun comparisonKeySeparatesSourceGeometryLensAndPreviewDemand() {
        val key = ComparisonPreviewKey("source.raw", GeometrySettings(), LensSettings(), 800, false)
        assertNotEquals(key, key.copy(inputPath = "other.raw"))
        assertNotEquals(key, key.copy(geometry = GeometrySettings(quarterTurns = 1)))
        assertNotEquals(key, key.copy(geometry = GeometrySettings(perspectiveHorizontal = .3f)))
        assertNotEquals(key, key.copy(geometry = GeometrySettings(perspectiveVertical = -.3f)))
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
            val geometry = GeometrySettings(.1f, .2f, .75f, .8f, 1, true, true, -12.2f, .45f, -.55f)
            var settings = EditSettings(geometry = geometry)
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(directory, "source.raw"), settings)
            val job = BatchJob(source, listOf(BatchTarget(PhotoIdentity("target"), File(directory, "target.raw"), "target.raw")))
            BatchJournal(directory).save(job)
            settings = settings.copy(geometry = GeometrySettings(perspectiveHorizontal = -1f))
            val resumed = BatchJournal(directory).load(job.id)!!
            assertEquals(geometry, resumed.source.settings.geometry)
            var rendered: EditSettings? = null
            BatchRunner.run(resumed, render = { _, edits -> rendered = edits; byteArrayOf(1) }, write = { _, _, _ -> })
            assertEquals(geometry, rendered!!.geometry)
            assertEquals(geometry, source.settings.geometry)
            assertNotEquals(settings.geometry, source.settings.geometry)
        } finally { directory.deleteRecursively() }
    }

    @Test fun oldBatchJournalRecoversBasicGeometryWithZeroPerspective() {
        val directory = Files.createTempDirectory("rawlab-geometry-legacy-batch").toFile()
        try {
            val geometry = GeometrySettings(.1f, .2f, .75f, .8f, 1, true, true, -12.2f)
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(directory, "source.raw"), EditSettings(geometry = geometry))
            val job = BatchJob(source, listOf(BatchTarget(PhotoIdentity("target"), File(directory, "target.raw"), "target.raw")))
            val journal = BatchJournal(directory)
            journal.save(job)
            val file = File(directory, "${job.id}.properties")
            val properties = java.util.Properties().also { file.inputStream().use(it::load) }
            val fields = legacyPipeSettings(source.settings).split('|').toMutableList()
            fields[52] = "1,0.1,0.2,0.75,0.8,1,1,1,-12.2"
            properties.setProperty("source.settings", fields.joinToString("|"))
            file.outputStream().use { properties.store(it, null) }
            assertEquals(geometry, journal.load(job.id)!!.source.settings.geometry)
        } finally { directory.deleteRecursively() }
    }
}
