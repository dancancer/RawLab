package com.rawlab.android.engine

import android.graphics.Bitmap
import java.io.IOException
import java.io.File
import java.nio.ByteBuffer
import java.util.Locale
import com.rawlab.android.looks.DcpCompilationException
import com.rawlab.android.looks.DcpFailureReason
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.ExportMetadata
import com.rawlab.android.format.ExportSize
import com.rawlab.android.format.PhotoFiles
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.raster.DecodedRaster
import com.rawlab.android.raster.RasterImageDecoder
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.HslTargetSample
import com.rawlab.android.settings.HslTargetAvailability
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LensSettings

// 原生层对外观文件的识别结果：格式与 RLOOK 版本
enum class LookFormat(val extension: String) {
    UNKNOWN(""), CUBE("cube"), RLOOK("rlook"), VLT("vlt");

    companion object {
        fun fromExtension(extension: String): LookFormat = when (extension.lowercase(Locale.ROOT)) {
            "cube" -> CUBE
            "rlook" -> RLOOK
            "vlt" -> VLT
            else -> UNKNOWN
        }
    }
}

data class LookValidation(val format: LookFormat, val version: Int, val colorState: Int = 5)
class LUTColorContractException(val reason: Int) : IllegalArgumentException("LUT color contract requires attention")

class NativeProcessingException(val status: Int, message: String) : IOException(message) {
    companion object {
        const val IO_ERROR = 3
        const val OUTPUT_IO_ERROR = 6
        const val CANCELLED = 7
    }
}

class NativeFrame(val width: Int, val height: Int, val pixels: ByteArray, val temperature: Float, val tint: Float, val backend: Int,
    histogram: IntArray? = null) {
    val histogram: RgbHistogram? = RgbHistogram.fromNative(width, height, histogram)
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
    @Volatile private var handle = nativeCreate(mode).also { check(it != 0L) }
    private var catalogKey: Triple<String, Long, Long>? = null
    private var candidates: List<LensCandidate> = emptyList()
    private var rasterKey: Triple<String, Long, Long>? = null
    private var raster: DecodedRaster? = null
    private var rasterEdge = -1
    private var rasterHDRSource: com.rawlab.android.photo.HDRSourceInfo? = null
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
    fun preview(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean,
        inputKind: PhotoInputKind = PhotoFiles.kind(input.name, null) ?: PhotoInputKind.RAW,
        cancellationGeneration: Long = -1L): NativeFrame {
        val frame = checkNotNull(previewRequest(input, lut, settings, edge, interactive, inputKind,
            cancellationGeneration = cancellationGeneration))
        val dimensions = nativeGeometrySize(handle)
        require(dimensions.size == 2 && dimensions.all { it > 0 }) { "Invalid native geometry size" }
        frame.geometryWidth = dimensions[0]
        frame.geometryHeight = dimensions[1]
        rasterHDRSource?.let { info ->
            val nativeSize = NativeHDRBridge.geometrySize(info, settings.geometry)
            frame.geometryWidth = nativeSize[0]; frame.geometryHeight = nativeSize[1]
        }
        frame.lens = if (inputKind == PhotoInputKind.RAW) readLens(input) else null
        return frame
    }

    // 仅供独立兼容预览实例使用，固定基础处理，不接触编辑器的调整或外观库。
    @Synchronized
    fun previewCompatibility(input: File, inputKind: PhotoInputKind, lut: File?, configuration: String?): NativeFrame {
        check(handle != 0L)
        val pixels = rasterInput(input, inputKind, 512)
        return nativeCompatibilityPreview(handle, input.path, pixels?.bitmap, pixels?.width ?: 0,
            pixels?.height ?: 0, lut?.path, configuration)
    }

    private fun previewRequest(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean,
        inputKind: PhotoInputKind, revision: HslTargetRevision? = null, probe: FloatArray? = null,
        cancellationGeneration: Long = -1L): NativeFrame? {
        check(handle != 0L) { "Processor is closed" }
        val effective = settings.effectiveFor(inputKind)
        val pixels = rasterInput(input, inputKind, edge)
        configureLens(effective.lens)
        configureGeometry(settings.geometry)
        nativeSetToneCurve(handle, effective.renderCurve.mode.nativeValue, effective.renderCurve.packed())
        nativeSetToneControls(handle, effective.renderBlackPoint / 100f, effective.renderWhitePoint / 100f, effective.renderVibrance / 100f)
        nativeSetAtmosphere(handle, effective.renderClarity / 100f, effective.renderDehaze / 100f)
        with(effective.renderColorGrading) { nativeSetColorGrading(handle, shadows.hue, shadows.saturation,
            midtones.hue, midtones.saturation, highlights.hue, highlights.saturation) }
        return nativeProcess(handle, input.path, pixels?.bitmap, pixels?.width ?: 0,
            pixels?.height ?: 0, if (pixels == null) 0 else 1, lut?.path, null, effective.strength,
            effective.exposure, effective.customWb, effective.temperature, effective.tint,
            effective.highlights, effective.shadows, effective.contrast, effective.renderToneCurve,
            effective.saturation, effective.sharpening, edge, interactive, ExportFormat.JPEG.nativeValue, 0,
            effective.denoise.enabled, effective.denoise.luma, effective.denoise.chroma, effective.denoise.coarse,
            effective.displayChromaDenoise, effective.effects.vignetteAmount, effective.effects.vignetteMidpoint,
            effective.effects.vignetteRoundness, effective.effects.vignetteFeather, effective.effects.vignetteHighlights,
            effective.effects.grainAmount, effective.effects.grainSize, effective.effects.grainRoughness,
            effective.exposureMode, effective.renderHsl.packed(), effective.recipeID != null, effective.processing.version, null,
            revision?.source ?: 0, revision?.request ?: 0, probe, cancellationGeneration)
    }

    @Synchronized
    fun sampleHsl(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean,
        inputKind: PhotoInputKind, revision: HslTargetRevision, x: Float, y: Float,
        cancellationGeneration: Long = -1L): HslTargetSample {
        if (!x.isFinite() || !y.isFinite())
            return HslTargetSample.unavailable(revision, HslTargetAvailability.NONFINITE)
        if (x !in 0f..1f || y !in 0f..1f)
            return HslTargetSample.unavailable(revision, HslTargetAvailability.OUTSIDE)
        val probe = FloatArray(13).also { it[0] = x; it[1] = y }
        previewRequest(input, lut, settings, edge, interactive, inputKind, revision, probe, cancellationGeneration)
        return HslTargetSample(revision, HslTargetAvailability.entries.getOrNull(probe[0].toInt()) ?: HslTargetAvailability.FAILED,
            probe.slice(2..4), probe.slice(5..12), probe[1] == 1f)
    }

    @Synchronized
    fun export(input: File, lut: File?, settings: EditSettings, output: File, format: ExportFormat, longEdge: Int? = null,
        inputKind: PhotoInputKind = PhotoFiles.kind(input.name, null) ?: PhotoInputKind.RAW): Int {
        check(handle != 0L) { "Processor is closed" }
        require(format != ExportFormat.HDR_JPEG) { "HDR JPEG requires HDR editing" }
        require(input.canonicalPath != output.canonicalPath)
        require(ExportSize.isValid(longEdge)) { "Invalid output long edge" }
        val effective = settings.effectiveFor(inputKind)
        val pixels = rasterInput(input, inputKind)
        configureLens(effective.lens)
        configureGeometry(settings.geometry)
        nativeSetToneCurve(handle, effective.renderCurve.mode.nativeValue, effective.renderCurve.packed())
        nativeSetToneControls(handle, effective.renderBlackPoint / 100f, effective.renderWhitePoint / 100f, effective.renderVibrance / 100f)
        nativeSetAtmosphere(handle, effective.renderClarity / 100f, effective.renderDehaze / 100f)
        with(effective.renderColorGrading) { nativeSetColorGrading(handle, shadows.hue, shadows.saturation,
            midtones.hue, midtones.saturation, highlights.hue, highlights.saturation) }
        val backend = intArrayOf(-1)
        nativeProcess(handle, input.path, pixels?.bitmap, pixels?.width ?: 0, pixels?.height ?: 0,
            if (pixels == null) 0 else 1, lut?.path, output.path, effective.strength,
            effective.exposure, effective.customWb, effective.temperature, effective.tint,
            effective.highlights, effective.shadows, effective.contrast, effective.renderToneCurve,
            effective.saturation, effective.sharpening, 0, false, format.nativeValue, longEdge ?: 0,
            effective.denoise.enabled, effective.denoise.luma, effective.denoise.chroma, effective.denoise.coarse,
            effective.displayChromaDenoise, effective.effects.vignetteAmount, effective.effects.vignetteMidpoint,
            effective.effects.vignetteRoundness, effective.effects.vignetteFeather, effective.effects.vignetteHighlights,
            effective.effects.grainAmount, effective.effects.grainSize, effective.effects.grainRoughness,
            effective.exposureMode, effective.renderHsl.packed(), effective.recipeID != null, effective.processing.version, backend)
        check(backend[0] >= 0) { "Native export did not report a backend" }
        if (format != ExportFormat.DNG) ExportMetadata.preserve(input, output)
        return backend[0]
    }

    @Synchronized
    fun autoExposure(input: File, settings: EditSettings,
        inputKind: PhotoInputKind = PhotoFiles.kind(input.name, null) ?: PhotoInputKind.RAW): Float {
        check(handle != 0L) { "Processor is closed" }
        val effective = settings.effectiveFor(inputKind)
        val pixels = rasterInput(input, inputKind, 1280)
        configureLens(effective.lens)
        configureGeometry(settings.geometry)
        nativeSetToneCurve(handle, effective.renderCurve.mode.nativeValue, effective.renderCurve.packed())
        nativeSetToneControls(handle, effective.renderBlackPoint / 100f, effective.renderWhitePoint / 100f, effective.renderVibrance / 100f)
        nativeSetAtmosphere(handle, effective.renderClarity / 100f, effective.renderDehaze / 100f)
        with(effective.renderColorGrading) { nativeSetColorGrading(handle, shadows.hue, shadows.saturation,
            midtones.hue, midtones.saturation, highlights.hue, highlights.saturation) }
        return nativeAutoExposure(handle, input.path, pixels?.bitmap, pixels?.width ?: 0, pixels?.height ?: 0,
            if (pixels == null) 0 else 1, effective.customWb, effective.temperature, effective.tint,
            effective.exposureMode, effective.recipeID != null, effective.strength, effective.processing.version)
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) { nativeDestroy(handle); handle = 0L }
        releaseRasterCache()
    }

    @Synchronized
    internal fun renderHDR(source: NativeHDRImage, settings: com.rawlab.android.settings.HDRSettings, edge: Int,
        cancellationGeneration: Long = -1L): NativeHDRImage {
        check(handle != 0L) { "Processor is closed" }
        require(edge in 0..65535)
        return NativeHDRBridge.render(handle, source, settings, edge, cancellationGeneration)
    }

    // 取消不能等待 preview 的 Java monitor 或 native session 渲染锁。
    internal fun cancellationGeneration(): Long = nativeCancellationGeneration(handle)
    internal fun cancelPreview() { nativeCancelPreview(handle) }

    private external fun nativeCancellationGeneration(handle: Long): Long
    private external fun nativeCancelPreview(handle: Long)

    @Synchronized
    internal fun releaseRasterCache() {
        raster?.close(); raster = null; rasterKey = null; rasterHDRSource = null; rasterEdge = -1
    }

    private fun rasterInput(input: File, kind: PhotoInputKind, edge: Int = 0): DecodedRaster? {
        if (kind != PhotoInputKind.RASTER) {
            releaseRasterCache()
            return null
        }
        val key = Triple(input.canonicalPath, input.length(), input.lastModified())
        if (key != rasterKey) {
            releaseRasterCache()
            rasterHDRSource = if (com.rawlab.android.photo.HDRSourceInfo.mayContainGainMap(input))
                NativeHDRBridge.probe(input) else null
            rasterKey = key
        }
        val hdr = rasterHDRSource
        if (raster == null || (hdr != null && rasterEdge != edge)) {
            val decoded = if (hdr == null) RasterImageDecoder.decode(input) else {
                NativeHDRBridge.decode(input, hdr, edge).use { DecodedRaster(it.sdrBitmap()) }
            }
            raster?.close(); raster = decoded; rasterEdge = edge
        }
        return checkNotNull(raster)
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
    private external fun nativeCompatibilityPreview(handle: Long, input: String, pixels: Bitmap?, width: Int, height: Int,
        lut: String?, configuration: String?): NativeFrame
    private external fun nativeSetGpuMode(handle: Long, mode: Int)
    private external fun nativeSetLensDatabase(handle: Long, path: String)
    private external fun nativeSetLensCorrection(handle: Long, distortion: Boolean, tca: Boolean, autoCrop: Boolean, profile: ByteArray)
    private external fun nativeSetColorGrading(handle: Long, shadowsHue: Float, shadowsSaturation: Float,
        midtonesHue: Float, midtonesSaturation: Float, highlightsHue: Float, highlightsSaturation: Float)
    private external fun nativeSetAtmosphere(handle: Long, clarity: Float, dehaze: Float)
    private external fun nativeSetToneControls(handle: Long, blackPoint: Float, whitePoint: Float, vibrance: Float)
    private external fun nativeSetToneCurve(handle: Long, mode: Int, points: DoubleArray)
    private external fun nativeSetGeometry(handle: Long, cropX: Float, cropY: Float, cropWidth: Float,
        cropHeight: Float, quarterTurns: Int, flipHorizontal: Boolean, flipVertical: Boolean, straightenDegrees: Float,
        perspectiveHorizontal: Float, perspectiveVertical: Float)
    private external fun nativeGeometrySize(handle: Long): IntArray
    private external fun nativeLensProfiles(handle: Long, input: String): Array<String>
    private external fun nativeLensReport(handle: Long): Array<String>
    private external fun nativeDestroy(handle: Long)
    private external fun nativeAutoExposure(handle: Long, input: String, pixels: Bitmap?, width: Int, height: Int,
        pixelFormat: Int, customWb: Boolean,
        temperature: Float, tint: Float, exposureMode: Int, recipeActive: Boolean, strength: Float, processingVersion: Int): Float
    private external fun nativeProcess(handle: Long, input: String, pixels: Bitmap?, width: Int, height: Int,
        pixelFormat: Int, lut: String?, output: String?,
        strength: Float, exposure: Float, customWb: Boolean, temperature: Float, tint: Float,
        highlights: Float, shadows: Float, contrast: Float, toneCurve: Float, saturation: Float, sharpening: Float,
        edge: Int, interactive: Boolean, format: Int, longEdge: Int,
        denoiseEnabled: Boolean, luma: Float, chroma: Float, coarse: Float, displayChromaDenoise: Int,
        vignetteAmount: Float, vignetteMidpoint: Float, vignetteRoundness: Float, vignetteFeather: Float,
        vignetteHighlights: Float, grainAmount: Float, grainSize: Float, grainRoughness: Float,
        exposureMode: Int, hsl: FloatArray, recipeActive: Boolean, processingVersion: Int, backend: IntArray? = null,
        sourceRevision: Long = 0, requestRevision: Long = 0, hslProbe: FloatArray? = null,
        cancellationGeneration: Long = -1L): NativeFrame?

    companion object {
        const val CPU = 0
        const val AUTO = 1
        const val FORCE = 2
        init { System.loadLibrary("rawlab-jni") }

        fun validateLook(file: File): LookValidation {
            val result = try { NativeLookBridge.validate(file.path) }
            catch (error: UnsupportedOperationException) {
                val reason = error.message?.takeIf { it.startsWith("rawlab-lut-color:") }?.substringAfter(':')?.toIntOrNull()
                if (reason != null && reason in 0..3) throw LUTColorContractException(reason)
                throw error
            }
            require(result.size >= 2) { "Native look validation returned no result" }
            val format = when (result[0]) {
                1 -> LookFormat.CUBE
                2 -> LookFormat.RLOOK
                3 -> LookFormat.VLT
                else -> LookFormat.UNKNOWN
            }
            if (format == LookFormat.UNKNOWN) throw IOException("Unsupported look format")
            return LookValidation(format, result[1], result.getOrElse(2) { 5 })
        }

        fun inspectLutCompatibility(file: File): String = NativeLookBridge.compatibility(file.path, null).toString(Charsets.UTF_8)
        fun prepareLutCompatibility(file: File, request: String): ByteArray =
            try { NativeLookBridge.compatibility(file.path, request) }
            catch (error: Exception) { throw LUTColorContractException(9) }
        fun compareLutPreviews(candidate: NativeFrame, reference: NativeFrame, conditions: String): String =
            NativeLookBridge.compare(candidate.pixels, candidate.width, candidate.height,
                reference.pixels, reference.width, reference.height, conditions).toString(Charsets.UTF_8)

        fun compileDcp(source: ByteArray, sourceName: String): ByteArray {
            if (source.size.toLong() > MAX_DCP_SOURCE_BYTES)
                throw DcpCompilationException(DcpFailureReason.TOO_LARGE)
            require(sourceName.isNotBlank()) { "Missing DCP source filename" }
            return NativeDcpBridge.compile(source, sourceName.toByteArray(Charsets.UTF_8)).also {
                if (it.size.toLong() > MAX_DCP_OUTPUT_BYTES)
                    throw DcpCompilationException(DcpFailureReason.TOO_LARGE)
            }
        }

        private const val MAX_DCP_SOURCE_BYTES = 128 * 1024 * 1024L
        private const val MAX_DCP_OUTPUT_BYTES = 64 * 1024 * 1024L
    }
}

private object NativeLookBridge {
    @JvmStatic external fun validate(path: String): IntArray
    @JvmStatic external fun compatibility(path: String, request: String?): ByteArray
    @JvmStatic external fun compare(candidate: ByteArray, width: Int, height: Int,
        reference: ByteArray, referenceWidth: Int, referenceHeight: Int, conditions: String): ByteArray
}

private object NativeDcpBridge {
    @JvmStatic external fun compile(source: ByteArray, sourceNameUtf8: ByteArray): ByteArray
}
