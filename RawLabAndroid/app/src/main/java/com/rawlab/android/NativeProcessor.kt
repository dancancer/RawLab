package com.rawlab.android

import android.graphics.Bitmap
import java.io.IOException
import java.io.File
import java.nio.ByteBuffer

class NativeFrame(val width: Int, val height: Int, val pixels: ByteArray, val temperature: Float, val tint: Float, val backend: Int) {
    fun bitmap(): Bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
        it.copyPixelsFromBuffer(ByteBuffer.wrap(pixels))
    }
}

class NativeProcessor(mode: Int = AUTO) : AutoCloseable {
    private var handle = nativeCreate(mode).also { check(it != 0L) }

    @Synchronized
    fun setGpuMode(mode: Int) {
        check(handle != 0L)
        require(mode in CPU..FORCE)
        nativeSetGpuMode(handle, mode)
    }

    @Synchronized
    fun preview(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean): NativeFrame {
        check(handle != 0L) { "Processor is closed" }
        return checkNotNull(nativeProcess(handle, input.path, lut?.path, null, settings.strength,
            settings.exposure, settings.customWb, settings.temperature, settings.tint,
            settings.highlights, settings.shadows, settings.contrast, settings.toneCurve,
            settings.saturation, settings.sharpening, edge, interactive, false,
            settings.denoise.enabled, settings.denoise.luma, settings.denoise.chroma, settings.denoise.coarse))
    }

    @Synchronized
    fun export(input: File, lut: File?, settings: EditSettings, output: File, png: Boolean) {
        check(handle != 0L) { "Processor is closed" }
        require(input.canonicalPath != output.canonicalPath)
        nativeProcess(handle, input.path, lut?.path, output.path, settings.strength,
            settings.exposure, settings.customWb, settings.temperature, settings.tint,
            settings.highlights, settings.shadows, settings.contrast, settings.toneCurve,
            settings.saturation, settings.sharpening, 0, false, png,
            settings.denoise.enabled, settings.denoise.luma, settings.denoise.chroma, settings.denoise.coarse)
        ExportMetadata.preserve(input, output)
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) { nativeDestroy(handle); handle = 0L }
    }

    private external fun nativeCreate(mode: Int): Long
    private external fun nativeSetGpuMode(handle: Long, mode: Int)
    private external fun nativeDestroy(handle: Long)
    private external fun nativeProcess(handle: Long, input: String, lut: String?, output: String?,
        strength: Float, exposure: Float, customWb: Boolean, temperature: Float, tint: Float,
        highlights: Float, shadows: Float, contrast: Float, toneCurve: Float, saturation: Float, sharpening: Float,
        edge: Int, interactive: Boolean, png: Boolean,
        denoiseEnabled: Boolean, luma: Float, chroma: Float, coarse: Float): NativeFrame?

    companion object {
        const val CPU = 0
        const val AUTO = 1
        const val FORCE = 2
        init { System.loadLibrary("rawlab-jni") }

        fun validateLook(file: File): LookValidation {
            val result = NativeLookBridge.validate(file.path)
            require(result.size >= 2) { "Native look validation returned no result" }
            val format = when (result[0]) {
                1 -> LookFormat.CUBE
                2 -> LookFormat.RLOOK
                else -> LookFormat.UNKNOWN
            }
            if (format == LookFormat.UNKNOWN) throw IOException("Unsupported look format")
            return LookValidation(format, result[1])
        }
    }
}

private object NativeLookBridge {
    @JvmStatic external fun validate(path: String): IntArray
}
