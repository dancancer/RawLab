package com.rawlab.android.engine

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.settings.EditSettings
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import kotlin.math.sin

@RunWith(AndroidJUnit4::class)
class AtmosphereNativeTest {
    @Test fun signedAtmosphereControlsClearSessionsAndPreserveFinalExports() {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "atmosphere-${UUID.randomUUID()}").apply { mkdirs() }
        val input = File(root, "pattern.png")
        val bitmap = Bitmap.createBitmap(320, 192, Bitmap.Config.ARGB_8888)
        for (y in 0 until 192) for (x in 0 until 320) {
            val wave = (25 * sin(x * Math.PI / 16)).toInt()
            bitmap.setPixel(x, y, Color.rgb(80 + x / 4 + wave, 60 + y / 2 + wave, 65 + x / 8 + y / 4 + wave))
        }
        input.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        try {
            NativeProcessor(NativeProcessor.CPU).use { engine ->
                fun pixels(settings: EditSettings) = engine.preview(input, null, settings, 320, false).pixels
                val baseline = pixels(EditSettings())
                for (settings in listOf(EditSettings(clarity = 75f), EditSettings(clarity = -75f),
                    EditSettings(dehaze = 75f), EditSettings(dehaze = -75f), EditSettings(clarity = 37.251234f, dehaze = -42.5f))) {
                    val changed = pixels(settings)
                    assertFalse("Each signed control changes pixels", changed.contentEquals(baseline))
                    engine.preview(input, null, settings, 73, true)
                    assertArrayEquals("Full-size atmosphere survives interactive preview", changed, pixels(settings))
                    val output = File(root, "output.png"); val reference = File(root, "reference.png")
                    engine.export(input, null, settings, output, ExportFormat.PNG)
                    NativeProcessor(NativeProcessor.CPU).use { it.export(input, null, settings, reference, ExportFormat.PNG) }
                    assertArrayEquals("FINAL export ignores preview history", reference.readBytes(), output.readBytes())
                    assertArrayEquals("Zero atmosphere clears reused session", baseline, pixels(EditSettings()))
                }
            }
        } finally { root.deleteRecursively() }
    }
}
