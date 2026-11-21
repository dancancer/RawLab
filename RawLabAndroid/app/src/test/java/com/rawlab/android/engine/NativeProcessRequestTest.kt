package com.rawlab.android.engine

import com.rawlab.android.format.ExportFormat
import com.rawlab.android.raster.DecodedRaster
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslSettings
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.PhotoEffectsSettings
import com.rawlab.android.settings.ProcessingIdentity
import com.rawlab.android.settings.X3fMode
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

class NativeProcessRequestTest {
    @Test fun rawPreviewMapsCoreUnitsWithoutJniProductSemantics() {
        val settings = EditSettings(
            strength = 0.8f,
            exposure = 1.5f,
            highlights = 0.4f,
            shadows = -0.25f,
            contrast = 0.3f,
            toneCurve = -0.2f,
            saturation = -0.15f,
            customWb = true,
            temperature = 5200f,
            tint = 14f,
            denoise = DenoiseSettings(enabled = true, luma = 12f, chroma = 50f, coarse = 60f),
            sharpening = 0.9f,
            effects = PhotoEffectsSettings(vignetteAmount = -30f, grainAmount = 20f),
            displayChromaDenoise = 2,
            exposureMode = 0,
            hsl = HslSettings().withValue(0, 2, 18f),
            processing = ProcessingIdentity.CURRENT,
            x3fMode = X3fMode.LEGACY,
        )
        val probe = FloatArray(13)
        val req = settings.toNativeProcessRequest(
            inputPath = "/tmp/sample.arw",
            pixels = null,
            lutPath = "/tmp/provia.cube",
            edge = 1200,
            interactive = true,
            revision = HslTargetRevision(7L, 9L),
            probe = probe,
            cancellationGeneration = 42L,
        )

        assertEquals("/tmp/sample.arw", req.input.path)
        assertNull(req.input.pixels)
        assertNull(req.output.path)
        assertEquals(1200, req.output.edge)
        assertEquals(0, req.output.longEdge)
        assertTrue(req.output.interactive)
        assertTrue(req.output.viewportPreview)
        assertEquals("/tmp/provia.cube", req.lutPath)
        assertEquals(0.8f, req.lutStrength, 0f)
        assertEquals(NativeProcessWhiteBalance(custom = true, temperature = 5200f, tint = 14f, recipeActive = false, recipeStrength = 0.8f), req.whiteBalance)
        assertEquals(1.5f, req.tone.exposureEv, 0f)
        assertEquals(1.3f, req.tone.contrast, 1e-6f)
        assertEquals(-0.4f, req.tone.highlights, 0f)
        assertEquals(-0.25f, req.tone.shadows, 0f)
        assertEquals(-0.2f, req.tone.toneCurve, 0f)
        assertEquals(0.85f, req.tone.saturation, 1e-6f)
        assertEquals(0.9f, req.tone.sharpening, 0f)
        assertEquals(NativeDenoiseConfig(enabled = true, luma = 12f, chroma = 50f, coarse = 60f, displayChroma = 2), req.denoise)
        assertEquals(settings.effects.toNativePhotoEffects(), req.effects)
        assertArrayEquals(settings.renderHsl.packed(), req.hsl, 0f)
        assertEquals(0, req.exposureMode)
        assertEquals(3, req.processingVersion)
        assertEquals(X3fMode.LEGACY.nativeValue, req.x3fMode)
        assertEquals(42L, req.cancellationGeneration)
        val target = requireNotNull(req.hslProbe)
        assertEquals(7L, target.sourceRevision)
        assertEquals(9L, target.requestRevision)
        assertSame(probe, target.output)
    }

    @Test fun recipeScalingAppliesInKotlinBeforeJniMarshalling() {
        val settings = EditSettings(
            recipeID = "hamada",
            strength = 2.0f,
            exposure = 1.5f,
            highlights = 0.3f,
            shadows = -0.2f,
            contrast = 0.4f,
            toneCurve = 0.25f,
            saturation = -0.3f,
            customWb = false,
            tint = 6f,
        )
        val req = settings.toNativeProcessRequest(
            inputPath = "/tmp/raw.dng",
            pixels = null,
            lutPath = null,
            edge = 800,
        )
        assertNull(req.lutPath)
        assertEquals(0f, req.lutStrength, 0f)
        assertTrue(req.whiteBalance.recipeActive)
        assertEquals(2.0f, req.whiteBalance.recipeStrength, 0f)
        assertEquals(3.0f, req.tone.exposureEv, 0f)
        assertEquals(1.8f, req.tone.contrast, 1e-6f)
        assertEquals(-0.6f, req.tone.highlights, 1e-6f)
        assertEquals(-0.4f, req.tone.shadows, 0f)
        assertEquals(0.4f, req.tone.saturation, 1e-6f)
    }

    @Test fun exportDisplayBufferAndMigrationFlagsConfigureOutputAndWhiteBalance() {
        val raster = DecodedRaster(ByteBuffer.allocateDirect(4 * 2 * 8), 2, 2)
        val backend = intArrayOf(-1)
        val exportReq = EditSettings(customWb = true, temperature = 4500f, tint = 10f, recipeID = "r").toNativeProcessRequest(
            inputPath = "/tmp/photo.png",
            pixels = raster,
            lutPath = "",
            outputPath = "/tmp/out.png",
            edge = 512,
            interactive = true,
            format = ExportFormat.PNG,
            longEdge = 2048,
            backendOut = backend,
        )
        assertEquals(2, exportReq.input.width)
        assertEquals(2, exportReq.input.pixelFormat)
        assertEquals("/tmp/out.png", exportReq.output.path)
        assertEquals(ExportFormat.PNG.nativeValue, exportReq.output.format)
        assertEquals(0, exportReq.output.edge)
        assertEquals(2048, exportReq.output.longEdge)
        assertFalse(exportReq.output.interactive)
        assertFalse(exportReq.output.viewportPreview)
        assertEquals(0f, exportReq.lutStrength, 0f)
        assertEquals(NativeProcessWhiteBalance(), exportReq.whiteBalance)
        assertSame(backend, exportReq.backendOut)

        val migration = FloatArray(20)
        val migrationReq = EditSettings().toNativeProcessRequest(
            inputPath = "/tmp/raw.dng",
            pixels = null,
            lutPath = null,
            edge = 600,
            migrationOut = migration,
        )
        assertEquals(0, migrationReq.output.edge)
        assertFalse(migrationReq.output.viewportPreview)
        assertSame(migration, migrationReq.migrationOut)
    }
}
