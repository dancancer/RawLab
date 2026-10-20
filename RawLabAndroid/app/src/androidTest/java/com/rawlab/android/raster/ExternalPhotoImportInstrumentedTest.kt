package com.rawlab.android.raster

import android.graphics.BitmapFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ExternalPhotoImportInstrumentedTest {
    @Test
    fun suppliedIccExifJpegPreviewsAndExports() = verifyPhoto("sample.jpg", PhotoInputKind.RASTER)

    @Test
    fun suppliedSonyArw6PreviewsAndExports() = verifyPhoto("sony-arw6.ARW", PhotoInputKind.RAW)

    @Test
    fun jpegCompressedDngPreviewsAndExports() = verifyPhoto("jpeg-lossy.dng", PhotoInputKind.RAW, 32, 32..32)

    private fun verifyPhoto(asset: String, kind: PhotoInputKind, width: Int = 512, heights: IntRange = 341..342) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val assets = instrumentation.context.assets
        val present = assets.list("")?.contains(asset) == true
        if (asset == "jpeg-lossy.dng") assertTrue("Required synthetic DNG fixture must be packaged", present)
        else assumeTrue("Supply rawlabTestSonyArw6/rawlabTestRaster for external photo checks", present)
        val root = testRoot(instrumentation.targetContext, "external-photo-import")
        val input = File(root, asset)
        val output = File(root, "developed.png")
        assets.open(asset).use { source -> input.outputStream().use(source::copyTo) }
        val original = input.readBytes()
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val frame = processor.preview(input, null, EditSettings(), 512, false, kind)
                assertEquals(width, frame.width)
                assertTrue("Preview must retain the photo aspect ratio", frame.height in heights)
                val preview = frame.bitmap()
                try {
                    assertTrue("Preview must contain photo detail",
                        preview.getPixel(frame.width / 4, frame.height / 4) !=
                            preview.getPixel(frame.width * 3 / 4, frame.height * 3 / 4))
                } finally {
                    preview.recycle()
                }
                assertEquals(0, processor.export(input, null, EditSettings(), output,
                    ExportFormat.PNG, 512, kind))
                val exported = checkNotNull(BitmapFactory.decodeFile(output.path))
                try {
                    assertEquals(width, exported.width)
                    assertTrue("Export must retain the photo aspect ratio", exported.height in heights)
                } finally {
                    exported.recycle()
                }
                assertTrue("Import/export must preserve the input photo", original.contentEquals(input.readBytes()))
            }
        } finally {
            root.deleteRecursively()
        }
    }
}
