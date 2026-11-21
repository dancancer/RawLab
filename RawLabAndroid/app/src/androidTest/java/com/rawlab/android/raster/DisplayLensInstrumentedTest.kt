package com.rawlab.android.raster

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.engine.LensInfo
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LensSettings
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class DisplayLensInstrumentedTest {
    @Test fun jpegMetadataCorrectionMatchesExportAndDoesNotLeakAcrossSources() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "display-lens-${System.nanoTime()}").apply { mkdirs() }
        try {
            val database = File(root, "lenses").apply { mkdirs() }
            File(database, "test.xml").writeText("""<lensdatabase version="1">
                <mount><name>RawLab Test</name></mount>
                <camera><maker>RawLab</maker><model>Test Camera</model><mount>RawLab Test</mount><cropfactor>1</cropfactor></camera>
                <lens><maker>RawLab</maker><model>Test 24mm f/2.8</model><mount>RawLab Test</mount><cropfactor>1</cropfactor>
                <calibration><distortion model="poly3" focal="24" k1="-0.12"/><tca model="linear" focal="24" kr="1.015" kb="0.99"/><vignetting model="pa" focal="24" aperture="2.8" distance="1000" k1="-0.25" k2="0" k3="0"/></calibration></lens>
                </lensdatabase>""")
            val source = File(root, "oriented.jpg")
            val other = File(root, "without-metadata.jpg")
            val bitmap = Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888)
            try {
                for (y in 0 until 64) for (x in 0 until 96) bitmap.setPixel(x, y,
                    android.graphics.Color.rgb(x * 255 / 95, y * 255 / 63, if (x % 12 < 6) 50 else 200))
                source.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it)) }
                source.copyTo(other)
            } finally { bitmap.recycle() }
            ExifInterface(source).apply {
                setAttribute(ExifInterface.TAG_MAKE, "RawLab"); setAttribute(ExifInterface.TAG_MODEL, "Test Camera")
                setAttribute(ExifInterface.TAG_LENS_MODEL, "Test 24mm f/2.8")
                setAttribute(ExifInterface.TAG_FOCAL_LENGTH, "24/1"); setAttribute(ExifInterface.TAG_F_NUMBER, "28/10")
                setAttribute(ExifInterface.TAG_ORIENTATION, "6"); saveAttributes()
            }
            NativeProcessor(NativeProcessor.CPU, database).use { processor ->
                val off = processor.preview(source, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                assertEquals(64, off.width); assertEquals(96, off.height)
                assertEquals(24f, checkNotNull(off.lens?.focalLength), 0f)
                val vignette = processor.preview(source, null, EditSettings(lens = LensSettings(vignetting = true)), 1600, false, PhotoInputKind.RASTER)
                assertTrue(checkNotNull(vignette.lens).appliedVignetting)
                assertFalse(off.pixels.contentEquals(vignette.pixels))
                val settings = EditSettings(lens = LensSettings(distortion = true, tca = true, vignetting = true))
                val on = processor.preview(source, null, settings, 1600, false, PhotoInputKind.RASTER)
                assertTrue(checkNotNull(on.lens).appliedDistortion)
                assertTrue(checkNotNull(on.lens).appliedVignetting)
                assertFalse(off.pixels.contentEquals(on.pixels))
                val output = File(root, "corrected.png")
                processor.export(source, null, settings, output, ExportFormat.PNG, null, PhotoInputKind.RASTER)
                val rendered = checkNotNull(BitmapFactory.decodeFile(output.path))
                val preview = on.bitmap()
                try {
                    assertEquals(preview.width, rendered.width); assertEquals(preview.height, rendered.height)
                    val a = IntArray(preview.width * preview.height); val b = IntArray(a.size)
                    preview.getPixels(a, 0, preview.width, 0, 0, preview.width, preview.height)
                    rendered.getPixels(b, 0, rendered.width, 0, 0, rendered.width, rendered.height)
                    val maximum = a.indices.maxOf { i -> listOf(0, 8, 16).maxOf { shift ->
                        kotlin.math.abs((a[i] ushr shift and 255) - (b[i] ushr shift and 255)) } }
                    // PNG 最终输出保留 16-bit 精度，再转回 Android 8-bit bitmap 时允许一次量化差。
                    assertTrue("Preview and final export maximum channel error=$maximum", maximum <= 1)
                }
                finally { preview.recycle(); rendered.recycle() }
                val missing = processor.preview(other, null, settings, 1600, false, PhotoInputKind.RASTER)
                assertFalse(checkNotNull(missing.lens).appliedDistortion)
                assertNull(missing.lens?.focalLength)
                val profile = checkNotNull(off.lens).candidates.single { it.model == "Test 24mm f/2.8" }
                val manual = settings.copy(lens = settings.lens.copy(manual = true, profileId = profile.id, focalLength = 24f, cropFactor = 1f))
                val fixed = processor.preview(other, null, manual, 1600, false, PhotoInputKind.RASTER)
                assertEquals(LensInfo.STATE_APPLIED, checkNotNull(fixed.lens).state)
                assertTrue(checkNotNull(fixed.lens).appliedDistortion)
            }
        } finally { root.deleteRecursively() }
    }
}
