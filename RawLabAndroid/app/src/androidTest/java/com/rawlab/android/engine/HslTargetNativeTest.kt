package com.rawlab.android.engine

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class HslTargetNativeTest {
    @Test fun jniSampleUsesPreHslPixelsAndRejectsUnavailableInput() {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "hsl-target-${UUID.randomUUID()}").apply { mkdirs() }
        val source = File(root, "source.png")
        val bitmap = Bitmap.createBitmap(24, 16, Bitmap.Config.ARGB_8888).apply { eraseColor(0xffcc6633.toInt()) }
        source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        try {
            NativeProcessor(NativeProcessor.CPU).use { engine ->
                val revision = HslTargetRevision(3, 17)
                fun sample(settings: EditSettings, x: Float = .5f, y: Float = .5f) =
                    engine.sampleHsl(source, null, settings, 24, false, PhotoInputKind.RASTER, revision, x, y)
                val original = sample(EditSettings())
                assertTrue(original.usable); assertEquals(revision, original.revision)
                assertEquals(.8f, original.rgb[0], .01f); assertEquals(.4f, original.rgb[1], .01f)
                assertEquals(1f, original.weights.sum(), .00001f)
                val downstream = sample(EditSettings(hsl = HslSettings().withValue(0, 0, 80f),
                    colorGrading = ColorGradingSettings(shadows = ColorGradingWheel(230f, 70f)),
                    effects = PhotoEffectsSettings(grainAmount = 70f)))
                assertEquals(original.rgb, downstream.rgb); assertEquals(original.weights, downstream.weights)
                assertNotEquals(original.rgb, sample(EditSettings(exposure = .5f, vibrance = 60f)).rgb)
                assertEquals(HslTargetAvailability.OUTSIDE, sample(EditSettings(), -.01f).availability)
                assertEquals(HslTargetAvailability.NONFINITE, sample(EditSettings(), Float.NaN).availability)
                val gray = Bitmap.createBitmap(24, 16, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff808080.toInt()) }
                val grayFile = File(root, "gray.png")
                grayFile.outputStream().use { gray.compress(Bitmap.CompressFormat.PNG, 100, it) }; gray.recycle()
                val unavailable = engine.sampleHsl(grayFile, null, EditSettings(), 24, false, PhotoInputKind.RASTER, revision, .5f, .5f)
                assertEquals(HslTargetAvailability.NEAR_GRAY, unavailable.availability); assertFalse(unavailable.usable)
            }
        } finally { root.deleteRecursively() }
    }
}
