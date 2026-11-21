package com.rawlab.android.camera

import android.graphics.Bitmap
import androidx.exifinterface.media.ExifInterface
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class CameraPreviewTest {
    @Test fun jpegPreviewHonorsOrientationAndPixelBudget() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File.createTempFile("camera-preview-", ".jpg", context.cacheDir)
        try {
            val original = Bitmap.createBitmap(1200, 800, Bitmap.Config.ARGB_8888)
            original.eraseColor(android.graphics.Color.BLUE)
            file.outputStream().use { original.compress(Bitmap.CompressFormat.JPEG, 95, it) }
            original.recycle()
            ExifInterface(file).apply { setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString()); saveAttributes() }
            val thumbnail = checkNotNull(decodeCameraPreview(file.readBytes(), false))
            assertEquals(267, thumbnail.width)
            assertEquals(400, thumbnail.height)
            thumbnail.recycle()
            val large = checkNotNull(decodeCameraPreview(file.readBytes(), true))
            assertEquals(800, large.width)
            assertEquals(1200, large.height)
            large.recycle()
            assertNull(decodeCameraPreview(file.readBytes().copyOf(30), false))
        } finally { file.delete() }
    }
}
