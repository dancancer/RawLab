package com.rawlab.android.raster

import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test

class JpegMetadataInstrumentedTest {
    @Test fun metadataAndVideoTailsDoNotChangeTheDecodedPrimaryImage() {
        val root = testRoot(InstrumentationRegistry.getInstrumentation().targetContext, "jpeg-metadata")
        val source = File(root, "source.jpg")
        try {
            val bitmap = Bitmap.createBitmap(4, 3, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff336699.toInt()) }
            try { writeBitmap(source, bitmap, Bitmap.CompressFormat.JPEG) } finally { bitmap.recycle() }
            val jpeg = source.readBytes()
            val uuid = byteArrayOf(0x63, 0x32, 0x70, 0x61, 0, 0x11, 0, 0x10,
                0x80.toByte(), 0, 0, 0xaa.toByte(), 0, 0x38, 0x9b.toByte(), 0x71)
            val description = box("jumd", uuid + byteArrayOf(3) + "c2pa\u0000".toByteArray())
            val c2pa = segment(byteArrayOf(0x4a, 0x50, 0, 1, 0, 0, 0, 1) + box("jumb", description))
            val cases = listOf(jpeg + byteArrayOf(0, 0, 0, 24) + "ftypmp42".toByteArray(),
                jpeg + "SEFT".toByteArray(), jpeg.copyOfRange(0, 2) + c2pa + jpeg.copyOfRange(2, jpeg.size))
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                for ((index, bytes) in cases.withIndex()) {
                    val file = File(root, "case-$index.jpg").apply { writeBytes(bytes) }
                    val rendered = processor.preview(file, null, EditSettings(), 1600, false, PhotoInputKind.RASTER).bitmap()
                    try {
                        assertEquals(4, rendered.width); assertEquals(3, rendered.height)
                        assertPixelClose(0xff336699.toInt(), rendered.getPixel(0, 0), 2, "JPEG case $index")
                    } finally { rendered.recycle() }
                }
                for ((index, bytes) in listOf(jpeg + jpeg,
                    jpeg.copyOfRange(0, 2) + segment("JPEG XT".toByteArray()) + jpeg.copyOfRange(2, jpeg.size)).withIndex()) {
                    val rejected = File(root, "rejected-$index.jpg").apply { writeBytes(bytes) }
                    assertThrows(IOException::class.java) {
                        processor.preview(rejected, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                    }
                }
            }
        } finally { root.deleteRecursively() }
    }

    private fun box(type: String, body: ByteArray): ByteArray =
        ByteBuffer.allocate(4).putInt(body.size + 8).array() + type.toByteArray() + body
    private fun segment(body: ByteArray): ByteArray =
        byteArrayOf(-1, 0xeb.toByte(), ((body.size + 2) shr 8).toByte(), (body.size + 2).toByte()) + body
}
