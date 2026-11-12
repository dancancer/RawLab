package com.rawlab.android.engine

import com.rawlab.android.settings.requireProRAWDecoder
import com.rawlab.android.settings.ToneCurveSettings

import android.graphics.Bitmap
import android.os.CancellationSignal
import java.io.IOException
import java.io.File
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CancellationException
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
import com.rawlab.android.settings.HDRSettings
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.X3fMode
import com.rawlab.android.settings.ProcessingMigrationOutcome

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
    private var displayLensMetadata: DisplayLensMetadata? = null
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
        frame.lens = if (inputKind == PhotoInputKind.RAW || rasterHDRSource == null) readLens(input) else null
        return frame
    }

    // 仅供独立兼容预览实例使用，固定基础处理，不接触编辑器的调整或外观库。
    @Synchronized
    fun previewCompatibility(input: File, inputKind: PhotoInputKind, lut: File?, configuration: String?): NativeFrame {
        check(handle != 0L)
        val pixels = rasterInput(input, inputKind, 512)
        return nativeCompatibilityPreview(handle, input.path, pixels?.pixels, pixels?.width ?: 0,
            pixels?.height ?: 0, pixels?.pixelFormat ?: 0, lut?.path, configuration)
    }

    @Synchronized
    internal fun migrateProcessing(input: File, lut: File?, settings: EditSettings, inputKind: PhotoInputKind,
        cancellationGeneration: Long): ProcessingMigrationOutcome {
        require(settings.processing.version in 1..2 && !settings.isHDREditing && settings.recipeID == null)
        val result = FloatArray(20)
        previewRequest(input, lut, settings, 0, false, inputKind,
            cancellationGeneration = cancellationGeneration, migration = result)
        return ProcessingMigrationOutcome.decode(settings, result)
    }

    private fun previewRequest(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean,
        inputKind: PhotoInputKind, revision: HslTargetRevision? = null, probe: FloatArray? = null,
        cancellationGeneration: Long = -1L, migration: FloatArray? = null): NativeFrame? {
        check(handle != 0L) { "Processor is closed" }
        val effective = settings.effectiveFor(inputKind)
        val pixels = rasterInput(input, inputKind, edge)
        configureLens(effective.lens)
        configureGeometry(settings.geometry)
        setToneCurves(effective.renderCurve)
        nativeSetToneControls(handle, effective.renderBlackPoint / 100f, effective.renderWhitePoint / 100f, effective.renderVibrance / 100f)
        nativeSetAtmosphere(handle, effective.renderClarity / 100f, effective.renderDehaze / 100f)
        with(effective.renderColorGrading) { nativeSetColorGrading(handle, shadows.hue, shadows.saturation,
            midtones.hue, midtones.saturation, highlights.hue, highlights.saturation) }
        return nativeProcess(handle, input.path, pixels?.pixels, pixels?.width ?: 0,
            pixels?.height ?: 0, pixels?.pixelFormat ?: 0, lut?.path, null, effective.strength,
            effective.exposure, effective.customWb, effective.temperature, effective.tint,
            effective.highlights, effective.shadows, effective.contrast, effective.renderToneCurve,
            effective.saturation, effective.sharpening, edge, interactive, ExportFormat.JPEG.nativeValue, 0,
            effective.denoise.enabled, effective.denoise.luma, effective.denoise.chroma, effective.denoise.coarse,
            effective.displayChromaDenoise, effective.effects.vignetteAmount, effective.effects.vignetteMidpoint,
            effective.effects.vignetteRoundness, effective.effects.vignetteFeather, effective.effects.vignetteHighlights,
            effective.effects.grainAmount, effective.effects.grainSize, effective.effects.grainRoughness,
            effective.exposureMode, effective.renderHsl.packed(), effective.recipeID != null, effective.processing.version, effective.x3fMode.nativeValue, null,
            revision?.source ?: 0, revision?.request ?: 0, probe, cancellationGeneration, migration)
    }

    @Synchronized
    fun sampleHsl(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean,
        inputKind: PhotoInputKind, revision: HslTargetRevision, x: Float, y: Float,
        cancellationGeneration: Long = -1L): HslTargetSample {
        return sampleHsl(revision, x, y) {
            previewRequest(input, lut, settings, edge, interactive, inputKind, revision, it, cancellationGeneration)
        }
    }

    @Synchronized
    internal fun sampleHDRHsl(source: NativeHDRImage, settings: HDRSettings, edge: Int,
        revision: HslTargetRevision, x: Float, y: Float, cancellationGeneration: Long, lookDirectory: File? = null): HslTargetSample {
        check(handle != 0L)
        return sampleHsl(revision, x, y) {
            NativeHDRBridge.sampleHsl(handle, source, settings, edge, revision.source, revision.request, it, cancellationGeneration, lookDirectory)
        }
    }

    private fun sampleHsl(revision: HslTargetRevision, x: Float, y: Float, sample: (FloatArray) -> Unit): HslTargetSample {
        if (!x.isFinite() || !y.isFinite()) return HslTargetSample.unavailable(revision, HslTargetAvailability.NONFINITE)
        if (x !in 0f..1f || y !in 0f..1f) return HslTargetSample.unavailable(revision, HslTargetAvailability.OUTSIDE)
        val probe = FloatArray(13).also { it[0] = x; it[1] = y }
        sample(probe)
        return HslTargetSample(revision, HslTargetAvailability.entries.getOrNull(probe[0].toInt()) ?: HslTargetAvailability.FAILED,
            probe.slice(2..4), probe.slice(5..12), probe[1] == 1f)
    }

    @Synchronized
    fun export(input: File, lut: File?, settings: EditSettings, output: File, format: ExportFormat, longEdge: Int? = null,
        inputKind: PhotoInputKind = PhotoFiles.kind(input.name, null) ?: PhotoInputKind.RAW,
        cancellationGeneration: Long = -1L, cancellationSignal: CancellationSignal? = null): Int {
        check(handle != 0L) { "Processor is closed" }
        require(format != ExportFormat.HDR_JPEG) { "HDR JPEG requires HDR editing" }
        require(input.canonicalPath != output.canonicalPath)
        require(ExportSize.isValid(longEdge)) { "Invalid output long edge" }
        val generation = when {
            cancellationGeneration >= 0L -> cancellationGeneration
            cancellationSignal != null -> cancellationGeneration()
            else -> -1L
        }
        if (cancellationSignal != null) {
            cancellationSignal.setOnCancelListener { cancelPreview() }
            if (cancellationSignal.isCanceled) cancelPreview()
        }
        val cancelled = {
            (cancellationSignal?.isCanceled == true) ||
                (generation >= 0L && cancellationGeneration() != generation)
        }
        try {
            return executeExport(
                output = output,
                suffix = format.suffix,
                isCancelled = cancelled,
                renderToStaging = { staging ->
                    val effective = settings.effectiveFor(inputKind)
                    val pixels = rasterInput(input, inputKind)
                    if (cancelled()) {
                        throw NativeProcessingException(NativeProcessingException.CANCELLED, "Processing cancelled")
                    }
                    configureLens(effective.lens)
                    configureGeometry(settings.geometry)
                    setToneCurves(effective.renderCurve)
                    nativeSetToneControls(handle, effective.renderBlackPoint / 100f, effective.renderWhitePoint / 100f, effective.renderVibrance / 100f)
                    nativeSetAtmosphere(handle, effective.renderClarity / 100f, effective.renderDehaze / 100f)
                    with(effective.renderColorGrading) { nativeSetColorGrading(handle, shadows.hue, shadows.saturation,
                        midtones.hue, midtones.saturation, highlights.hue, highlights.saturation) }
                    val backend = intArrayOf(-1)
                    nativeProcess(handle, input.path, pixels?.pixels, pixels?.width ?: 0, pixels?.height ?: 0,
                        pixels?.pixelFormat ?: 0, lut?.path, staging.path, effective.strength,
                        effective.exposure, effective.customWb, effective.temperature, effective.tint,
                        effective.highlights, effective.shadows, effective.contrast, effective.renderToneCurve,
                        effective.saturation, effective.sharpening, 0, false, format.nativeValue, longEdge ?: 0,
                        effective.denoise.enabled, effective.denoise.luma, effective.denoise.chroma, effective.denoise.coarse,
                        effective.displayChromaDenoise, effective.effects.vignetteAmount, effective.effects.vignetteMidpoint,
                        effective.effects.vignetteRoundness, effective.effects.vignetteFeather, effective.effects.vignetteHighlights,
                        effective.effects.grainAmount, effective.effects.grainSize, effective.effects.grainRoughness,
                        effective.exposureMode, effective.renderHsl.packed(), effective.recipeID != null,
                        effective.processing.version, effective.x3fMode.nativeValue, backend,
                        0, 0, null, generation, null)
                    check(backend[0] >= 0) { "Native export did not report a backend" }
                    backend[0]
                },
                preserveMetadata = { staging ->
                    if (format != ExportFormat.DNG) {
                        ExportMetadata.preserve(input, staging, allowUnreadableSource = PhotoFiles.isX3f(input))
                    }
                },
            )
        } finally {
            cancellationSignal?.setOnCancelListener(null)
        }
    }

    @Synchronized
    fun autoExposure(input: File, settings: EditSettings,
        inputKind: PhotoInputKind = PhotoFiles.kind(input.name, null) ?: PhotoInputKind.RAW): Float {
        check(handle != 0L) { "Processor is closed" }
        val effective = settings.effectiveFor(inputKind)
        val pixels = rasterInput(input, inputKind, 1280)
        configureLens(effective.lens)
        configureGeometry(settings.geometry)
        setToneCurves(effective.renderCurve)
        nativeSetToneControls(handle, effective.renderBlackPoint / 100f, effective.renderWhitePoint / 100f, effective.renderVibrance / 100f)
        nativeSetAtmosphere(handle, effective.renderClarity / 100f, effective.renderDehaze / 100f)
        with(effective.renderColorGrading) { nativeSetColorGrading(handle, shadows.hue, shadows.saturation,
            midtones.hue, midtones.saturation, highlights.hue, highlights.saturation) }
        return nativeAutoExposure(handle, input.path, pixels?.pixels, pixels?.width ?: 0, pixels?.height ?: 0,
            pixels?.pixelFormat ?: 0, effective.customWb, effective.temperature, effective.tint,
            effective.exposureMode, effective.recipeID != null, effective.strength, effective.processing.version, effective.x3fMode.nativeValue)
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) { nativeDestroy(handle); handle = 0L }
        releaseRasterCache()
    }

    @Synchronized
    internal fun estimateHDRExposure(source: NativeHDRImage, settings: com.rawlab.android.settings.HDRSettings,
        cancellationGeneration: Long): Float {
        check(handle != 0L) { "Processor is closed" }
        return NativeHDRBridge.estimateAutoExposure(handle, source, settings, cancellationGeneration)
    }

    @Synchronized
    internal fun renderHDR(source: NativeHDRImage, settings: com.rawlab.android.settings.HDRSettings, edge: Int,
        cancellationGeneration: Long = -1L, lookDirectory: File? = null): NativeHDRImage {
        check(handle != 0L) { "Processor is closed" }
        require(edge in 0..65535)
        return NativeHDRBridge.render(handle, source, settings, edge, cancellationGeneration, lookDirectory)
    }

    internal fun decodeHDRCamera(file: File, info: com.rawlab.android.photo.HDRSourceInfo, edge: Int,
        cancellationGeneration: Long = -1L,
        camera: com.rawlab.android.settings.HDRCameraDevelopmentSettings = com.rawlab.android.settings.HDRCameraDevelopmentSettings(),
        profileDirectory: File? = null): NativeHDRImage {
        check(handle != 0L) { "Processor is closed" }
        return NativeHDRBridge.decodeCameraRaw(handle, file, info, edge, cancellationGeneration, camera, profileDirectory)
    }

    internal fun exportProRAW(file: File, info: com.rawlab.android.photo.HDRSourceInfo,
        edits: EditSettings, output: File, keepHDR: Boolean, edge: Int, cancellationGeneration: Long = -1L, lookDirectory: File? = null) {
        check(handle != 0L) { "Processor is closed" }
        edits.requireProRAWDecoder()
        NativeHDRBridge.exportProRAW(handle, file, info, requireNotNull(edits.hdr).copy(geometry = edits.geometry),
            output, keepHDR, edge, cancellationGeneration, lookDirectory)
    }

    // 取消不能等待 preview 的 Java monitor 或 native session 渲染锁。
    internal fun cancellationGeneration(): Long = nativeCancellationGeneration(handle)
    internal fun cancelPreview() { nativeCancelPreview(handle) }

    private external fun nativeCancellationGeneration(handle: Long): Long
    private external fun nativeCancelPreview(handle: Long)

    @Synchronized
    internal fun releaseRasterCache() {
        raster?.close(); raster = null; rasterKey = null; rasterHDRSource = null; rasterEdge = -1
        displayLensMetadata = null
        if (handle != 0L) nativeSetDisplayLensMetadata(handle, null, floatArrayOf(0f, 0f, 0f), 1)
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
            displayLensMetadata = DisplayLensMetadata.read(input)
            rasterKey = key
        }
        displayLensMetadata?.let { nativeSetDisplayLensMetadata(handle, it.names, it.numbers, it.sourceOrientation) }
        val hdr = rasterHDRSource
        if (raster == null || (hdr != null && rasterEdge != edge)) {
            val decoded = if (hdr == null) RasterImageDecoder.decode(input) else {
                NativeHDRBridge.decode(input, hdr, edge).use { DecodedRaster(it.sdrBitmap()) }
            }
            raster?.close(); raster = decoded; rasterEdge = edge
        }
        return checkNotNull(raster)
    }

    private fun configureLens(settings: LensSettings) {
        displayLensMetadata?.let { source ->
            val metadata = source.copy(focalLength = settings.focalLength ?: source.focalLength,
                cropFactor = settings.cropFactor ?: source.cropFactor)
            nativeSetDisplayLensMetadata(handle, metadata.names, metadata.numbers, metadata.sourceOrientation)
        }
        nativeSetLensCorrection(handle, settings.distortion, settings.tca, settings.autoCrop, settings.vignetting,
            settings.coreProfileId.toByteArray(Charsets.UTF_8))
    }

    private fun configureGeometry(settings: GeometrySettings) = nativeSetGeometry(handle,
        settings.cropX, settings.cropY, settings.cropWidth, settings.cropHeight, settings.quarterTurns,
        settings.flipHorizontal, settings.flipVertical, settings.straightenDegrees,
        settings.perspectiveHorizontal, settings.perspectiveVertical)

    private fun readLens(input: File): LensInfo {
        val key = Triple(input.canonicalPath, input.length(), input.lastModified())
        if (key != catalogKey) {
            val profiles = nativeLensProfiles(handle, if (displayLensMetadata == null) input.path else null)
            require(profiles.size % 7 == 0) { "Invalid native lens catalog" }
            candidates = profiles.asList().chunked(7).map { LensCandidate(it[0], it[1], it[2], it[3] == "1", it[4] == "1", it[5] == "1", it[6] == "1") }
            catalogKey = key
        }
        val report = nativeLensReport(handle)
        require(report.size == 7) { "Invalid native lens report" }
        return LensInfo(report[0].toInt(), report[1], report[2], report[3] == "1", report[4] == "1", report[5].toFloat(), candidates,
            displayLensMetadata?.let { listOf(it.cameraMake, it.cameraModel).filter(String::isNotBlank).distinct().joinToString(" ") },
            displayLensMetadata?.focalLength?.takeIf { it > 0 }, displayLensMetadata?.aperture?.takeIf { it > 0 }, report[6] == "1")
    }

    private external fun nativeCreate(mode: Int): Long
    private external fun nativeCompatibilityPreview(handle: Long, input: String, pixels: Any?, width: Int, height: Int,
        pixelFormat: Int, lut: String?, configuration: String?): NativeFrame
    private external fun nativeSetGpuMode(handle: Long, mode: Int)
    private external fun nativeSetLensDatabase(handle: Long, path: String)
    private external fun nativeSetLensCorrection(handle: Long, distortion: Boolean, tca: Boolean, autoCrop: Boolean, vignetting: Boolean, profile: ByteArray)
    private external fun nativeSetDisplayLensMetadata(handle: Long, names: Array<String>?, numbers: FloatArray, orientation: Int)
    private external fun nativeSetColorGrading(handle: Long, shadowsHue: Float, shadowsSaturation: Float,
        midtonesHue: Float, midtonesSaturation: Float, highlightsHue: Float, highlightsSaturation: Float)
    private external fun nativeSetAtmosphere(handle: Long, clarity: Float, dehaze: Float)
    private external fun nativeSetToneControls(handle: Long, blackPoint: Float, whitePoint: Float, vibrance: Float)
    private fun setToneCurves(curve: ToneCurveSettings) {
        nativeSetToneCurves(handle, curve.mode.nativeValue, curve.packed(),
            curve.channels.red.mode.nativeValue, curve.channels.red.packed(),
            curve.channels.green.mode.nativeValue, curve.channels.green.packed(),
            curve.channels.blue.mode.nativeValue, curve.channels.blue.packed())
    }
    private external fun nativeSetToneCurves(handle: Long, mode: Int, points: DoubleArray,
        redMode: Int, redPoints: DoubleArray, greenMode: Int, greenPoints: DoubleArray, blueMode: Int, bluePoints: DoubleArray)
    private external fun nativeSetGeometry(handle: Long, cropX: Float, cropY: Float, cropWidth: Float,
        cropHeight: Float, quarterTurns: Int, flipHorizontal: Boolean, flipVertical: Boolean, straightenDegrees: Float,
        perspectiveHorizontal: Float, perspectiveVertical: Float)
    private external fun nativeGeometrySize(handle: Long): IntArray
    private external fun nativeLensProfiles(handle: Long, input: String?): Array<String>
    private external fun nativeLensReport(handle: Long): Array<String>
    private external fun nativeDestroy(handle: Long)
    private external fun nativeAutoExposure(handle: Long, input: String, pixels: Any?, width: Int, height: Int,
        pixelFormat: Int, customWb: Boolean,
        temperature: Float, tint: Float, exposureMode: Int, recipeActive: Boolean, strength: Float, processingVersion: Int, x3fMode: Int): Float
    private external fun nativeProcess(handle: Long, input: String, pixels: Any?, width: Int, height: Int,
        pixelFormat: Int, lut: String?, output: String?,
        strength: Float, exposure: Float, customWb: Boolean, temperature: Float, tint: Float,
        highlights: Float, shadows: Float, contrast: Float, toneCurve: Float, saturation: Float, sharpening: Float,
        edge: Int, interactive: Boolean, format: Int, longEdge: Int,
        denoiseEnabled: Boolean, luma: Float, chroma: Float, coarse: Float, displayChromaDenoise: Int,
        vignetteAmount: Float, vignetteMidpoint: Float, vignetteRoundness: Float, vignetteFeather: Float,
        vignetteHighlights: Float, grainAmount: Float, grainSize: Float, grainRoughness: Float,
        exposureMode: Int, hsl: FloatArray, recipeActive: Boolean, processingVersion: Int, x3fMode: Int, backend: IntArray? = null,
        sourceRevision: Long = 0, requestRevision: Long = 0, hslProbe: FloatArray? = null,
        cancellationGeneration: Long = -1L, migration: FloatArray? = null): NativeFrame?

    companion object {
        @JvmStatic external fun nativeX3fAvailable(): Boolean
        @JvmStatic external fun nativeX3fDefaultMode(input: String): Int
        const val CPU = 0
        const val AUTO = 1
        const val FORCE = 2
        init { System.loadLibrary("rawlab-jni") }

        fun x3fDefaultMode(input: File): X3fMode = when (nativeX3fDefaultMode(input.path)) {
            X3fMode.LEGACY.nativeValue -> X3fMode.LEGACY
            X3fMode.NORMAL.nativeValue -> X3fMode.NORMAL
            else -> error("Invalid native X3F default mode")
        }

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

        fun compileDcp(source: ByteArray, sourceName: String, toneCurve: ByteArray? = null, omitAutomaticBlack: Boolean = false): ByteArray {
            if (source.size.toLong() > MAX_DCP_SOURCE_BYTES)
                throw DcpCompilationException(DcpFailureReason.TOO_LARGE)
            require(sourceName.isNotBlank()) { "Missing DCP source filename" }
            return NativeDcpBridge.compile(source, sourceName.toByteArray(Charsets.UTF_8), toneCurve, omitAutomaticBlack).also {
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
    @JvmStatic external fun compile(source: ByteArray, sourceNameUtf8: ByteArray, toneCurve: ByteArray?, omitAutomaticBlack: Boolean): ByteArray
}

internal fun exportStagingFile(
    parent: File,
    outputName: String,
    suffix: String,
    id: UUID = UUID.randomUUID(),
): File = File(parent, ".$outputName.$id.part$suffix")

internal fun executeExport(
    output: File,
    suffix: String = output.extension.takeIf { it.isNotEmpty() }?.let { ".$it" }.orEmpty(),
    isCancelled: () -> Boolean,
    renderToStaging: (File) -> Int,
    preserveMetadata: (File) -> Unit = {},
): Int {
    val emptyPlaceholder = output.exists() && output.length() == 0L
    val parent = output.absoluteFile.parentFile ?: File(".")
    val staging = exportStagingFile(parent, output.name, suffix)
    fun throwIfCancelled() {
        if (isCancelled()) throw NativeProcessingException(NativeProcessingException.CANCELLED, "Processing cancelled")
    }
    var completed = false
    try {
        throwIfCancelled()
        val backend = renderToStaging(staging)
        throwIfCancelled()
        preserveMetadata(staging)
        throwIfCancelled()
        try {
            Files.move(staging.toPath(), output.toPath(), StandardCopyOption.REPLACE_EXISTING)
        } catch (error: IOException) {
            throw NativeProcessingException(
                NativeProcessingException.OUTPUT_IO_ERROR,
                error.message ?: "Cannot write exported image",
            )
        }
        completed = true
        return backend
    } catch (error: Throwable) {
        val cancelled = (error is NativeProcessingException && error.status == NativeProcessingException.CANCELLED) ||
            error is CancellationException || isCancelled()
        if (cancelled && emptyPlaceholder && output.exists() && output.length() == 0L) {
            output.delete()
        }
        if (cancelled && (error !is NativeProcessingException || error.status != NativeProcessingException.CANCELLED)) {
            throw NativeProcessingException(NativeProcessingException.CANCELLED, error.message ?: "Processing cancelled")
        }
        throw error
    } finally {
        if (!completed) staging.delete()
    }
}
