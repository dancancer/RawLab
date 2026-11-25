package com.rawlab.android.engine

import android.graphics.Bitmap
import com.rawlab.android.editor.TestBitmaps
import org.junit.Assert.*
import org.junit.Test

class NativeFrameContractTest {
    @Test
    fun nativeFrameHoldsBackingBitmapDirectlyWithZeroCopyBitmapGetter() {
        val bitmap = TestBitmaps.stub()
        val frame = NativeFrame(
            width = 1600,
            height = 1200,
            backingBitmap = bitmap,
            temperature = 5400f,
            tint = 3f,
            backend = NativeProcessor.CPU,
            histogram = null,
        )
        assertSame(bitmap, frame.bitmap())
        assertSame(bitmap, frame.bitmap())

        val ctorParams = NativeFrame::class.java.constructors.filterNot { it.isSynthetic }.single().parameterTypes
        assertEquals(Bitmap::class.java, ctorParams[2])
        assertTrue(NativeFrame::class.java.declaredMethods.any { it.name == "allocateBitmap" })
        assertTrue(
            NativeProcessor::class.java.declaredMethods.any {
                it.name == "nativeProcess" && Bitmap::class.java in it.parameterTypes
            },
        )
    }
}
