package com.rawlab.android

import android.graphics.Bitmap
import java.io.IOException
import java.io.File
import java.nio.ByteBuffer

class NativeProcessingException(val status: Int, message: String) : IOException(message) {
    companion object {
        const val IO_ERROR = 3
        const val OUTPUT_IO_ERROR = 6
    }
}

class NativeFrame(val width: Int, val height: Int, val pixels: ByteArray, val temperature: Float, val tint: Float, val backend: Int) {
    var lens: LensInfo? = null
        internal set
    var geometryWidth: Int = width
        internal set
    var geometryHeight: Int = height
        internal set
    fun bitmap(): Bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
        it.copyPixelsFromBuffer(ByteBuffer.wrap(pixels))
    }
}

class NativeProcessor(mode: Int = AUTO, lensDatabase: File? = null) : AutoCloseable {
    private var handle = nativeCreate(mode).also { check(it != 0L) }
    private var catalogKey: Triple<String, Long, Long>? = null
    private var candidates: List<LensCandidate> = emptyList()
    init {
        try { if (lensDatabase != null) nativeSetLensDatabase(handle, lensDatabase.path) }
        catch (error: Throwable) { close(); throw error }
    }

    @Synchronized
    fun setGpuMode(mode: Int) {
        check(handle != 0L)
        require(mode in CPU..FORCE)
        nativeSetGpuMode(handle, mode)
    }

    @Synchronized
    fun preview(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean): NativeFrame {
        check(handle != 0L) { "Processor is closed" }
        configureLens(settings.lens)
        configureGeometry(settings.geometry)
        val frame = checkNotNull(nativeProcess(handle, input.path, lut?.path, null, settings.strength,
            settings.exposure, settings.customWb, settings.temperature, settings.tint,
            settings.highlights, settings.shadows, settings.contrast, settings.toneCurve,
            settings.saturation, settings.sharpening, edge, interactive, ExportFormat.JPEG.nativeValue, 0,
            settings.denoise.enabled, settings.denoise.luma, settings.denoise.chroma, settings.denoise.coarse,
            settings.displayChromaDenoise, settings.effects.vignetteAmount, settings.effects.vignetteMidpoint,
            settings.effects.vignetteRoundness, settings.effects.vignetteFeather, settings.effects.vignetteHighlights,
            settings.effects.grainAmount, settings.effects.grainSize, settings.effects.grainRoughness,
            settings.exposureMode, settings.renderHsl.packed(), settings.recipeID != null))
        val dimensions = nativeGeometrySize(handle)
        require(dimensions.size == 2 && dimensions.all { it > 0 }) { "Invalid native geometry size" }
        frame.geometryWidth = dimensions[0]
        frame.geometryHeight = dimensions[1]
        frame.lens = readLens(input)
        return frame
    }

    @Synchronized
    fun export(input: File, lut: File?, settings: EditSettings, output: File, format: ExportFormat, longEdge: Int? = null): Int {
        check(handle != 0L) { "Processor is closed" }
        require(input.canonicalPath != output.canonicalPath)
        require(ExportSize.isValid(longEdge)) { "Invalid output long edge" }
        configureLens(settings.lens)
        configureGeometry(settings.geometry)
        val backend = intArrayOf(-1)
        nativeProcess(handle, input.path, lut?.path, output.path, settings.strength,
            settings.exposure, settings.customWb, settings.temperature, settings.tint,
            settings.highlights, settings.shadows, settings.contrast, settings.toneCurve,
            settings.saturation, settings.sharpening, 0, false, format.nativeValue, longEdge ?: 0,
            settings.denoise.enabled, settings.denoise.luma, settings.denoise.chroma, settings.denoise.coarse,
            settings.displayChromaDenoise, settings.effects.vignetteAmount, settings.effects.vignetteMidpoint,
            settings.effects.vignetteRoundness, settings.effects.vignetteFeather, settings.effects.vignetteHighlights,
            settings.effects.grainAmount, settings.effects.grainSize, settings.effects.grainRoughness,
            settings.exposureMode, settings.renderHsl.packed(), settings.recipeID != null, backend)
        check(backend[0] >= 0) { "Native export did not report a backend" }
        if (format != ExportFormat.DNG) ExportMetadata.preserve(input, output)
        return backend[0]
    }

    @Synchronized
    fun autoExposure(input: File, settings: EditSettings): Float {
        check(handle != 0L) { "Processor is closed" }
        configureLens(settings.lens)
        configureGeometry(settings.geometry)
        return nativeAutoExposure(handle, input.path, settings.customWb, settings.temperature, settings.tint, settings.exposureMode, settings.recipeID != null, settings.strength)
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) { nativeDestroy(handle); handle = 0L }
    }

    private fun configureLens(settings: LensSettings) = nativeSetLensCorrection(handle,
        settings.distortion, settings.tca, settings.autoCrop, settings.coreProfileId.toByteArray(Charsets.UTF_8))

    private fun configureGeometry(settings: GeometrySettings) = nativeSetGeometry(handle,
        settings.cropX, settings.cropY, settings.cropWidth, settings.cropHeight, settings.quarterTurns,
        settings.flipHorizontal, settings.flipVertical, settings.straightenDegrees,
        settings.perspectiveHorizontal, settings.perspectiveVertical)

    private fun readLens(input: File): LensInfo {
        val key = Triple(input.canonicalPath, input.length(), input.lastModified())
        if (key != catalogKey) {
            val profiles = nativeLensProfiles(handle, input.path)
            require(profiles.size % 6 == 0) { "Invalid native lens catalog" }
            candidates = profiles.asList().chunked(6).map { LensCandidate(it[0], it[1], it[2], it[3] == "1", it[4] == "1", it[5] == "1") }
            catalogKey = key
        }
        val report = nativeLensReport(handle)
        require(report.size == 6) { "Invalid native lens report" }
        return LensInfo(report[0].toInt(), report[1], report[2], report[3] == "1", report[4] == "1", report[5].toFloat(), candidates)
    }

    private external fun nativeCreate(mode: Int): Long
    private external fun nativeSetGpuMode(handle: Long, mode: Int)
    private external fun nativeSetLensDatabase(handle: Long, path: String)
    private external fun nativeSetLensCorrection(handle: Long, distortion: Boolean, tca: Boolean, autoCrop: Boolean, profile: ByteArray)
    private external fun nativeSetGeometry(handle: Long, cropX: Float, cropY: Float, cropWidth: Float,
        cropHeight: Float, quarterTurns: Int, flipHorizontal: Boolean, flipVertical: Boolean, straightenDegrees: Float,
        perspectiveHorizontal: Float, perspectiveVertical: Float)
    private external fun nativeGeometrySize(handle: Long): IntArray
    private external fun nativeLensProfiles(handle: Long, input: String): Array<String>
    private external fun nativeLensReport(handle: Long): Array<String>
    private external fun nativeDestroy(handle: Long)
    private external fun nativeAutoExposure(handle: Long, input: String, customWb: Boolean,
        temperature: Float, tint: Float, exposureMode: Int, recipeActive: Boolean, strength: Float): Float
    private external fun nativeProcess(handle: Long, input: String, lut: String?, output: String?,
        strength: Float, exposure: Float, customWb: Boolean, temperature: Float, tint: Float,
        highlights: Float, shadows: Float, contrast: Float, toneCurve: Float, saturation: Float, sharpening: Float,
        edge: Int, interactive: Boolean, format: Int, longEdge: Int,
        denoiseEnabled: Boolean, luma: Float, chroma: Float, coarse: Float, displayChromaDenoise: Int,
        vignetteAmount: Float, vignetteMidpoint: Float, vignetteRoundness: Float, vignetteFeather: Float,
        vignetteHighlights: Float, grainAmount: Float, grainSize: Float, grainRoughness: Float,
        exposureMode: Int, hsl: FloatArray, recipeActive: Boolean, backend: IntArray? = null): NativeFrame?

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
