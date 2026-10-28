package com.rawlab.android.engine

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class ToneCurveNativeTest {
    @Test fun customCurveSharesSamplingAndClearsReusedSession() {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "curve-${UUID.randomUUID()}").apply { mkdirs() }
        val input = File(root, "pattern.png")
        val bitmap = Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888)
        for (y in 0 until 64) for (x in 0 until 96) bitmap.setPixel(x, y, Color.rgb(24 + x * 2, 16 + y * 3, 31 + x + y))
        input.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        try {
            NativeProcessor(NativeProcessor.CPU).use { engine ->
                fun pixels(settings: EditSettings) = engine.preview(input, null, settings, 96, false).pixels
                val baseline = pixels(EditSettings())
                val legacySettings = EditSettings(toneCurve = .65f)
                val legacy = pixels(legacySettings)
                assertFalse(baseline.contentEquals(legacy))
                assertArrayEquals("Identity suppresses inactive legacy scalar exactly", baseline,
                    pixels(legacySettings.copy(curve = ToneCurveSettings.identity)))
                val curve = ToneCurveSettings.identity.inserting(.25, .4).inserting(.75, .9)
                val settings = legacySettings.copy(curve = curve)
                val changed = pixels(settings)
                assertFalse(changed.contentEquals(baseline)); assertFalse(changed.contentEquals(legacy))
                val samples = ToneCurveSampling.samples(curve, 256)
                val sample = engine.sampleHsl(input, null, settings, 96, false, PhotoInputKind.RASTER,
                    HslTargetRevision(1, 1), 0f, 0f)
                assertTrue(sample.usable)
                listOf(24, 16, 31).forEachIndexed { channel, value ->
                    assertEquals("Canvas evaluator agrees with native channel $channel", samples[value].y, sample.rgb[channel].toDouble(), .00001)
                }
                engine.preview(input, null, settings, 48, true)
                assertArrayEquals("FINAL curve survives interactive preview", changed, pixels(settings))
                val output = File(root, "output.png"); val reference = File(root, "reference.png")
                engine.export(input, null, settings, output, ExportFormat.PNG)
                NativeProcessor(NativeProcessor.CPU).use { it.export(input, null, settings, reference, ExportFormat.PNG) }
                assertArrayEquals("Export is independent of session history", reference.readBytes(), output.readBytes())
                assertArrayEquals("Legacy clears custom state", legacy, pixels(legacySettings))
                assertArrayEquals("Reset clears complete curve state", baseline, pixels(EditSettings()))
            }
        } finally { root.deleteRecursively() }
    }
}
