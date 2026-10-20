package com.rawlab.android.raster

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MpfThumbnailInstrumentedTest {
    @Test fun cameraThumbnailDoesNotReplaceThePrimaryImageInPreviewOrExport() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "mpf-thumbnail")
        val source = File(root, "primary.jpg")
        val input = File(root, "camera.jpg")
        val output = File(root, "output.png")
        val primary = jpeg(48, 32, 0xff336699.toInt())
        source.writeBytes(primary)
        input.writeBytes(withThumbnail(primary, jpeg(12, 8, 0xffcc3300.toInt())))
        try {
            for (mode in listOf(NativeProcessor.CPU, NativeProcessor.AUTO)) {
                NativeProcessor(mode).use { processor ->
                    val reference = processor.preview(source, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                    val frame = processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                    assertEquals(48, frame.width)
                    assertEquals(32, frame.height)
                    assertEquals(0, frame.backend)
                    assertArrayEquals(reference.pixels, frame.pixels)
                    assertEquals(0, processor.export(input, null, EditSettings(), output,
                        ExportFormat.PNG, null, PhotoInputKind.RASTER))
                    val exported = checkNotNull(BitmapFactory.decodeFile(output.path))
                    val expected = reference.bitmap()
                    try {
                        assertEquals(48, exported.width)
                        assertEquals(32, exported.height)
                        val originalPixels = IntArray(48 * 32)
                        val exportedPixels = IntArray(48 * 32)
                        expected.getPixels(originalPixels, 0, 48, 0, 0, 48, 32)
                        exported.getPixels(exportedPixels, 0, 48, 0, 0, 48, 32)
                        assertArrayEquals(originalPixels, exportedPixels)
                    }
                    finally { expected.recycle(); exported.recycle() }
                }
            }
        } finally { root.deleteRecursively() }
    }

    private fun jpeg(width: Int, height: Int, color: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        return try {
            bitmap.eraseColor(color)
            ByteArrayOutputStream().use { output ->
                check(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, output))
                output.toByteArray()
            }
        } finally { bitmap.recycle() }
    }

    private fun withThumbnail(primary: ByteArray, thumbnail: ByteArray): ByteArray {
        val payload = ByteArray(86)
        "MPF\u0000II".toByteArray().copyInto(payload)
        val buffer = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putShort(6, 42); buffer.putInt(8, 8); buffer.putShort(12, 3)
        buffer.putShort(14, 0xb000.toShort()); buffer.putShort(16, 7); buffer.putInt(18, 4)
        "0100".toByteArray().copyInto(payload, 22)
        buffer.putShort(26, 0xb001.toShort()); buffer.putShort(28, 4); buffer.putInt(30, 1); buffer.putInt(34, 2)
        buffer.putShort(38, 0xb002.toShort()); buffer.putShort(40, 7); buffer.putInt(42, 32); buffer.putInt(46, 50)
        val primaryEnd = primary.size + payload.size + 4
        buffer.putInt(54, 0xa0030000.toInt()); buffer.putInt(58, primaryEnd); buffer.putShort(66, 2)
        buffer.putInt(70, 0x40010002); buffer.putInt(74, thumbnail.size); buffer.putInt(78, primaryEnd + 17 - 10)
        val segment = byteArrayOf(-1, -30, 0, 88) + payload
        return primary.copyOfRange(0, 2) + segment + primary.copyOfRange(2, primary.size) + ByteArray(17) + thumbnail
    }
}
