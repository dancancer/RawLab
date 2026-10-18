package com.rawlab.android.raster

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.IOException
import kotlin.math.max
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.applyRecipe
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslSettings
import com.rawlab.android.settings.PhotoEffectsSettings

@RunWith(AndroidJUnit4::class)
class RasterNativeInstrumentedTest {
    @Test
    fun sdrCicpPngPreservesNeutralPixelsAndFinalExport() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-cicp")
        val input = File(root, "sdr.png")
        val hdr = File(root, "hdr.png")
        val output = File(root, "output.png")
        writeCicpPng(input, byteArrayOf(1, 13, 0, 1))
        writeCicpPng(hdr, byteArrayOf(9, 16, 0, 1))
        try {
            assertTrue(RasterContainerValidator.inspect(input.readBytes()).isValid)
            assertTrue(!RasterContainerValidator.inspect(hdr.readBytes()).isValid)
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val preview = processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                val pixels = preview.bitmap()
                try {
                    assertEquals(2, pixels.width)
                    assertEquals(1, pixels.height)
                    assertEquals(0xFF336699.toInt(), pixels.getPixel(0, 0))
                    assertEquals(0xFFCC8040.toInt(), pixels.getPixel(1, 0))
                } finally {
                    pixels.recycle()
                }
                assertEquals(0, processor.export(input, null, EditSettings(), output, ExportFormat.PNG, null, PhotoInputKind.RASTER))
                val final = checkNotNull(BitmapFactory.decodeFile(output.path))
                try {
                    assertFrameMatchesBitmap(preview, final, 0)
                } finally {
                    final.recycle()
                }
                assertThrows(IOException::class.java) {
                    processor.preview(hdr, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun neutralRasterPreservesPixelsOrientationAndFullResolutionExport() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-native")
        val input = File(root, "source.png")
        val jpeg = File(root, "source.jpg")
        val output = File(root, "output.png")
        val bitmap = Bitmap.createBitmap(2, 1, Bitmap.Config.ARGB_8888).apply {
            setPixel(0, 0, 0xFFFF0000.toInt())
            setPixel(1, 0, 0xFF0000FF.toInt())
        }
        writeBitmap(input, bitmap, Bitmap.CompressFormat.PNG)
        bitmap.recycle()
        ExifInterface(input).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            saveAttributes()
        }
        val jpegBitmap = Bitmap.createBitmap(3, 2, Bitmap.Config.ARGB_8888).apply { eraseColor(0xFF336699.toInt()) }
        writeBitmap(jpeg, jpegBitmap, Bitmap.CompressFormat.JPEG)
        jpegBitmap.recycle()
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val preview = processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                assertEquals(1, preview.width)
                assertEquals(2, preview.height)
                assertEquals(0, preview.backend)
                val oriented = preview.bitmap()
                try {
                    assertEquals(0xFFFF0000.toInt(), oriented.getPixel(0, 0))
                    assertEquals(0xFF0000FF.toInt(), oriented.getPixel(0, 1))
                } finally {
                    oriented.recycle()
                }
                val jpegPreview = processor.preview(jpeg, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                assertEquals(3, jpegPreview.width)
                assertEquals(2, jpegPreview.height)
                assertEquals(0, processor.export(input, null, EditSettings(), output, ExportFormat.PNG, null, PhotoInputKind.RASTER))
            }
            val exported = checkNotNull(BitmapFactory.decodeFile(output.path))
            try {
                assertEquals(1, exported.width)
                assertEquals(2, exported.height)
            } finally {
                exported.recycle()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun masterRecipeIdentityAndStrengthChangeRasterPixels() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-recipe")
        val input = File(root, "source.png")
        writeGradient(input, 19, 13)
        try {
            PhotoStorage(context).use { storage ->
                val recipe = MasterRecipe.load(context).firstOrNull()
                assertNotNull(recipe)
                val actualRecipe = checkNotNull(recipe)
                assertTrue(actualRecipe.id.isNotBlank())
                val settings = EditSettings().applyRecipe(actualRecipe)
                assertEquals(actualRecipe.id, settings.recipeID)
                val look = checkNotNull(storage.lookPath(settings))
                NativeProcessor(NativeProcessor.CPU).use { processor ->
                    val neutral = processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                    val strengthFrames = listOf(0f, 1f, 2f).map { strength ->
                        processor.preview(input, look, settings.copy(strength = strength), 1600, false, PhotoInputKind.RASTER)
                    }
                    assertFramesClose(neutral, strengthFrames[0], 2)
                    assertTrue(
                        "strength 1 must change pixels from strength 0",
                        changedPixels(strengthFrames[0], strengthFrames[1], 3) > 8,
                    )
                    assertTrue(
                        "strength 2 must change pixels from strength 1",
                        changedPixels(strengthFrames[1], strengthFrames[2], 3) > 8,
                    )
                    assertTrue(
                        "a real master recipe must change pixels at strength 1",
                        changedPixels(neutral, strengthFrames[1], 3) > 8,
                    )
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun rasterForceGpuModeIsRejected() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-force-gpu")
        val input = File(root, "source.png")
        writeGradient(input, 9, 7)
        try {
            NativeProcessor(NativeProcessor.FORCE).use { processor ->
                assertThrows(IOException::class.java) {
                    processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun rasterStagesMatchFinalPngAndNativeExportDoesNotReusePreview() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-final")
        val smallInput = File(root, "small.png")
        val smallOutput = File(root, "small-final.png")
        val fullInput = File(root, "full.png")
        val fullOutput = File(root, "full-final.png")
        writeGradient(smallInput, 18, 14)
        writeGradient(fullInput, 47, 31)
        val settings = EditSettings(
            exposure = 0.55f,
            highlights = -0.25f,
            shadows = 0.3f,
            contrast = 0.28f,
            toneCurve = 0.2f,
            saturation = 0.22f,
            sharpening = 0.35f,
            denoise = DenoiseSettings(enabled = true, luma = 8f, chroma = 64f, coarse = 72f),
            displayChromaDenoise = 1,
            effects = PhotoEffectsSettings(
                vignetteAmount = -42f,
                vignetteMidpoint = 48f,
                vignetteRoundness = 20f,
                vignetteFeather = 64f,
                vignetteHighlights = 18f,
                grainAmount = 22f,
                grainSize = 35f,
                grainRoughness = 62f,
            ),
            hsl = HslSettings()
                .withValue(0, 0, 34f)
                .withValue(1, 2, -28f)
                .withValue(2, 4, 24f),
            geometry = GeometrySettings(
                cropX = 0.1f,
                cropY = 0.1f,
                cropWidth = 0.8f,
                cropHeight = 0.8f,
                quarterTurns = 1,
            ),
        )
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val probe = processor.preview(smallInput, null, settings, 1600, false, PhotoInputKind.RASTER)
                val preview = processor.preview(smallInput, null, settings,
                    max(probe.geometryWidth, probe.geometryHeight), false, PhotoInputKind.RASTER)
                processor.export(smallInput, null, settings, smallOutput, ExportFormat.PNG, null, PhotoInputKind.RASTER)
                val finalPng = checkNotNull(BitmapFactory.decodeFile(smallOutput.path))
                try {
                    assertEquals(preview.width, finalPng.width)
                    assertEquals(preview.height, finalPng.height)
                    assertFrameMatchesBitmap(preview, finalPng, 5)
                } finally {
                    finalPng.recycle()
                }

                val reduced = processor.preview(fullInput, null, EditSettings(), 9, false, PhotoInputKind.RASTER)
                assertTrue(max(reduced.width, reduced.height) <= 9)
                processor.export(fullInput, null, EditSettings(), fullOutput, ExportFormat.PNG, null, PhotoInputKind.RASTER)
                val nativePng = checkNotNull(BitmapFactory.decodeFile(fullOutput.path))
                try {
                    assertEquals(47, nativePng.width)
                    assertEquals(31, nativePng.height)
                    assertTrue(nativePng.width > reduced.width || nativePng.height > reduced.height)
                } finally {
                    nativePng.recycle()
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun rasterFinalDngHasTiffFloatPixelsAndGeometryAndMatchesPngAppearance() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-dng")
        val input = File(root, "source.png")
        val png = File(root, "final.png")
        val dng = File(root, "final.dng")
        writeGradient(input, 16, 12)
        val settings = EditSettings(
            exposure = 0.35f,
            saturation = 0.12f,
            geometry = GeometrySettings(cropX = 0.2f, cropY = 0.15f, cropWidth = 0.65f, cropHeight = 0.7f, quarterTurns = 1),
        )
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val preview = processor.preview(input, null, settings, 1600, false, PhotoInputKind.RASTER)
                processor.export(input, null, settings, png, ExportFormat.PNG, null, PhotoInputKind.RASTER)
                processor.export(input, null, settings, dng, ExportFormat.DNG, null, PhotoInputKind.RASTER)
                val renderedPng = checkNotNull(BitmapFactory.decodeFile(png.path))
                try {
                    val renderedDng = parseRenderedDng(dng.readBytes())
                    assertEquals(42, renderedDng.magic)
                    assertEquals(preview.geometryWidth, renderedDng.width)
                    assertEquals(preview.geometryHeight, renderedDng.height)
                    assertEquals(renderedPng.width, renderedDng.width)
                    assertEquals(renderedPng.height, renderedDng.height)
                    assertEquals(32, renderedDng.bitsPerSample)
                    assertEquals(1, renderedDng.compression)
                    assertEquals(3, renderedDng.samplesPerPixel)
                    assertEquals(34892, renderedDng.photometric)
                    assertTrue(renderedDng.sampleFormat.all { it == 3L })
                    assertDngAppearanceMatchesPng(renderedDng, renderedPng)
                } finally {
                    renderedPng.recycle()
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }
}
