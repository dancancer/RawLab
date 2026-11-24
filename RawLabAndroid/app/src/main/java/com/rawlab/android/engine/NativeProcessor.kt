package com.rawlab.android.engine

import android.graphics.Bitmap
import com.rawlab.android.R
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.ExportMetadata
import com.rawlab.android.format.ExportSize
import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.format.PhotoFiles
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.looks.DcpCompilationException
import com.rawlab.android.looks.DcpFailureReason
import com.rawlab.android.raster.DecodedRaster
import com.rawlab.android.raster.RasterImageDecoder
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HDRSettings
import com.rawlab.android.settings.HslTargetAvailability
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.HslTargetSample
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.ProcessingMigrationOutcome
import com.rawlab.android.settings.X3fMode
import com.rawlab.android.settings.requireProRAWDecoder
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CancellationException

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

class NativeProcessingException @JvmOverloads constructor(
    val status: Int,
    message: String,
    val unsupportedReason: Int = UNSUPPORTED_NONE,
) : IOException(
    if (status == UNSUPPORTED && unsupportedReason == UNSUPPORTED_FORCE_GPU && AppStrings.isInitialized()) {
        AppStrings.text(R.string.force_gpu_unsupported)
    } else {
        message
    },
) {
    val isForceGpuUnsupported: Boolean
        get() = status == UNSUPPORTED && unsupportedReason == UNSUPPORTED_FORCE_GPU

    companion object {
        const val UNSUPPORTED = 2
        const val IO_ERROR = 3
        const val OUTPUT_IO_ERROR = 6
        const val CANCELLED = 7
        const val UNSUPPORTED_NONE = 0
        const val UNSUPPORTED_FORCE_GPU = 1
    }
}

class NativeFrame(
    val width: Int,
    val height: Int,
    private val backingBitmap: Bitmap,
    val temperature: Float,
    val tint: Float,
    val backend: Int,
    histogram: IntArray? = null,
) {
    val histogram: RgbHistogram? = RgbHistogram.fromNative(width, height, histogram)
    var lens: LensInfo? = null
        internal set
    var geometryWidth: Int = width
        internal set
    var geometryHeight: Int = height
        internal set
    fun bitmap(): Bitmap = backingBitmap
    val pixels: ByteArray by lazy(LazyThreadSafetyMode.NONE) {
        ByteArray(width * height * 4).also { out ->
            backingBitmap.copyPixelsToBuffer(ByteBuffer.wrap(out))
        }
    }

    internal companion object {
        @JvmStatic
        fun allocateBitmap(width: Int, height: Int, reusable: Bitmap? = null): Bitmap {
            if (reusable != null && reusable.isMutable && !reusable.isRecycled &&
                reusable.config == Bitmap.Config.ARGB_8888 &&
                reusable.width == width && reusable.height == height) {
                return reusable
            }
            return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        }
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
    internal fun supportsFastFullResGpu(
        input: File,
        settings: EditSettings,
        lut: File? = null,
        nativeWidth: Int = 0,
        nativeHeight: Int = 0,
        maxPixels: Int = 0,
        inputKind: PhotoInputKind = PhotoFiles.kind(input.name, null) ?: PhotoInputKind.RAW,
    ): Boolean {
        check(handle != 0L) { "Processor is closed" }
        if (settings.isHDREditing || inputKind != PhotoInputKind.RAW) return false
        val effective = settings.effectiveFor(inputKind)
        val json = effective.toSdrSessionStateJson(
            isRaster = false,
            lutPath = lut?.path,
            includeDenoise = true,
        )
        return nativeSupportsFastFullResGpu(
            handle,
            0,
            nativeWidth.coerceAtLeast(0),
            nativeHeight.coerceAtLeast(0),
            maxPixels.coerceAtLeast(0),
            input.path,
            json,
        )
    }

    @Synchronized
    fun preview(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean,
        inputKind: PhotoInputKind = PhotoFiles.kind(input.name, null) ?: PhotoInputKind.RAW,
        cancellationGeneration: Long = -1L, reusableBitmap: Bitmap? = null): NativeFrame {
        check(handle != 0L) { "Processor is closed" }
        val effective = settings.effectiveFor(inputKind)
        val pixels = rasterInput(input, inputKind, edge)
        configureDisplayLens(effective.lens)
        val json = effective.toSdrSessionStateJson(
            isRaster = pixels != null || inputKind != PhotoInputKind.RAW,
            lutPath = lut?.path,
            includeDenoise = true,
        )
        val frame = checkNotNull(nativeProcess(
            handle, json, input.path, pixels?.pixels, pixels?.width ?: 0, pixels?.height ?: 0,
            pixels?.pixelFormat ?: 0, null, ExportFormat.JPEG.nativeValue, edge, 0,
            interactive, edge > 0, reusableBitmap, cancellationGeneration, null,
        ))
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

    @Synchronized
    internal fun previewRoi(
        input: File,
        lut: File?,
        settings: EditSettings,
        x0: Float,
        y0: Float,
        x1: Float,
        y1: Float,
        maxOutputLongEdge: Int,
        inputKind: PhotoInputKind = PhotoFiles.kind(input.name, null) ?: PhotoInputKind.RAW,
        cancellationGeneration: Long = -1L,
    ): NativeRoiFrame {
        check(handle != 0L) { "Processor is closed" }
        val clampedEdge = maxOutputLongEdge.coerceIn(1, 2048)
        val effective = settings.effectiveFor(inputKind)
        val pixels = rasterInput(input, inputKind, 0)
        configureDisplayLens(effective.lens)
        val json = effective.toSdrSessionStateJson(
            isRaster = pixels != null || inputKind != PhotoInputKind.RAW,
            lutPath = lut?.path,
            includeDenoise = true,
        )
        val result = checkNotNull(nativeProcessRoi(
            handle, json, input.path, pixels?.pixels, pixels?.width ?: 0, pixels?.height ?: 0,
            pixels?.pixelFormat ?: 0, x0, y0, x1, y1, clampedEdge, cancellationGeneration,
        ))
        val b = result.bounds
        require(b.fullWidth > 0 && b.fullHeight > 0 && b.x1 > b.x0 && b.y1 > b.y0) { "Invalid native ROI bounds" }
        result.frame.geometryWidth = b.fullWidth
        result.frame.geometryHeight = b.fullHeight
        return result
    }

    // 仅供独立兼容预览实例使用，固定基础处理，不接触编辑器的调整或外观库。
    @Synchronized
    fun previewCompatibility(input: File, inputKind: PhotoInputKind, lut: File?, configuration: String?): NativeFrame {
        check(handle != 0L)
        val pixels = rasterInput(input, inputKind, 512)
        val isRaster = pixels != null || inputKind != PhotoInputKind.RAW
        val exposureMode = if (isRaster) "sensor" else "scene"
        val json = if (configuration != null || lut != null) {
            CanonicalEditRecipe.compatibilityPreviewStateJson(2, exposureMode, lut?.path, if (lut != null) 1.0 else 0.0)
        } else {
            CanonicalEditRecipe.processingSessionStateJson(2, exposureMode)
        }
        return checkNotNull(nativeCompatibilityPreview(
            handle, json, input.path, pixels?.pixels, pixels?.width ?: 0, pixels?.height ?: 0,
            pixels?.pixelFormat ?: 0, configuration,
        ))
    }

    @Synchronized
    internal fun migrateProcessing(input: File, lut: File?, settings: EditSettings, inputKind: PhotoInputKind,
        cancellationGeneration: Long): ProcessingMigrationOutcome {
        require(settings.processing.version in 1..2 && !settings.isHDREditing && settings.recipeID == null)
        check(handle != 0L) { "Processor is closed" }
        val effective = settings.effectiveFor(inputKind)
        val pixels = rasterInput(input, inputKind, 0)
        configureDisplayLens(effective.lens)
        val json = effective.toSdrSessionStateJson(
            isRaster = pixels != null || inputKind != PhotoInputKind.RAW,
            lutPath = lut?.path,
            includeDenoise = true,
        )
        val result = checkNotNull(nativeMigrateProcessing(
            handle, json, input.path, pixels?.pixels, pixels?.width ?: 0, pixels?.height ?: 0,
            pixels?.pixelFormat ?: 0, cancellationGeneration,
        ))
        return ProcessingMigrationOutcome.fromNative(settings, result)
    }

    internal enum class WbProbeAvailability { AVAILABLE, OVEREXPOSED, OUTSIDE, UNAVAILABLE }

    internal data class WbProbeSample(
        val availability: WbProbeAvailability,
        val temperature: Float,
        val tint: Float,
        val validPixelCount: Int,
        val rejectedOverexposedCount: Int,
    )

    @Synchronized
    internal fun sampleWhiteBalance(
        input: File,
        lut: File?,
        settings: EditSettings,
        edge: Int,
        inputKind: PhotoInputKind,
        x: Float,
        y: Float,
        windowSize: Int = 3,
        cancellationGeneration: Long = -1L,
    ): WbProbeSample {
        check(handle != 0L) { "Processor is closed" }
        if (!x.isFinite() || !y.isFinite() || x !in 0f..1f || y !in 0f..1f) {
            return WbProbeSample(WbProbeAvailability.OUTSIDE, 6500f, 0f, 0, 0)
        }
        val effective = settings.effectiveFor(inputKind)
        val pixels = rasterInput(input, inputKind, edge)
        configureDisplayLens(effective.lens)
        val json = effective.toSdrSessionStateJson(
            isRaster = pixels != null || inputKind != PhotoInputKind.RAW,
            lutPath = lut?.path,
            includeDenoise = true,
        )
        val result = checkNotNull(nativeSampleWbProbe(
            handle, json, input.path, pixels?.pixels, pixels?.width ?: 0, pixels?.height ?: 0,
            pixels?.pixelFormat ?: 0, edge, x, y, windowSize, cancellationGeneration,
        ))
        val availability = WbProbeAvailability.entries.getOrNull(result.availability) ?: WbProbeAvailability.UNAVAILABLE
        return WbProbeSample(availability, result.temperature, result.tint,
            result.validPixelCount, result.rejectedOverexposedCount)
    }

    @Synchronized
    fun sampleHsl(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean,
        inputKind: PhotoInputKind, revision: HslTargetRevision, x: Float, y: Float,
        cancellationGeneration: Long = -1L): HslTargetSample {
        check(handle != 0L) { "Processor is closed" }
        if (!x.isFinite() || !y.isFinite()) return HslTargetSample.unavailable(revision, HslTargetAvailability.NONFINITE)
        if (x !in 0f..1f || y !in 0f..1f) return HslTargetSample.unavailable(revision, HslTargetAvailability.OUTSIDE)
        val effective = settings.effectiveFor(inputKind)
        val pixels = rasterInput(input, inputKind, edge)
        configureDisplayLens(effective.lens)
        val json = effective.toSdrSessionStateJson(
            isRaster = pixels != null || inputKind != PhotoInputKind.RAW,
            lutPath = lut?.path,
            includeDenoise = true,
        )
        return checkNotNull(nativeSampleHsl(
            handle, json, input.path, pixels?.pixels, pixels?.width ?: 0, pixels?.height ?: 0,
            pixels?.pixelFormat ?: 0, edge, interactive, revision.source, revision.request, x, y, cancellationGeneration,
        )).toSample(revision)
    }

    @Synchronized
    internal fun sampleHDRHsl(source: NativeHDRImage, settings: HDRSettings, edge: Int,
        revision: HslTargetRevision, x: Float, y: Float, cancellationGeneration: Long, lookDirectory: File? = null): HslTargetSample {
        check(handle != 0L)
        if (!x.isFinite() || !y.isFinite()) return HslTargetSample.unavailable(revision, HslTargetAvailability.NONFINITE)
        if (x !in 0f..1f || y !in 0f..1f) return HslTargetSample.unavailable(revision, HslTargetAvailability.OUTSIDE)
        return NativeHDRBridge.sampleHsl(handle, source, settings, edge, revision.source, revision.request,
            x, y, cancellationGeneration, lookDirectory).toSample(revision)
    }

    private fun NativeHslProbeResult.toSample(revision: HslTargetRevision): HslTargetSample = HslTargetSample(
        revision = revision,
        availability = HslTargetAvailability.entries.getOrNull(availability) ?: HslTargetAvailability.FAILED,
        rgb = rgb.toList(),
        weights = weights.toList(),
        preview = previewQuality,
    )

    @Synchronized
    fun export(input: File, lut: File?, settings: EditSettings, output: File, format: ExportFormat, longEdge: Int? = null,
        inputKind: PhotoInputKind = PhotoFiles.kind(input.name, null) ?: PhotoInputKind.RAW,
        cancellationGeneration: Long = -1L,
        outputSharpening: OutputSharpening = OutputSharpening.OFF): Int {
        check(handle != 0L) { "Processor is closed" }
        require(format != ExportFormat.HDR_JPEG) { "HDR JPEG requires HDR editing" }
        require(input.canonicalPath != output.canonicalPath)
        require(ExportSize.isValid(longEdge)) { "Invalid output long edge" }
        val effectiveSharpening = if (format == ExportFormat.DNG) OutputSharpening.OFF else outputSharpening
        val generation = if (cancellationGeneration >= 0L) cancellationGeneration else -1L
        val cancelled = { generation >= 0L && cancellationGeneration() != generation }
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
                configureDisplayLens(effective.lens)
                val json = effective.toSdrSessionStateJson(
                    isRaster = pixels != null || inputKind != PhotoInputKind.RAW,
                    lutPath = lut?.path,
                    includeDenoise = true,
                    outputSharpening = effectiveSharpening,
                )
                val backend = intArrayOf(-1)
                nativeProcess(
                    handle, json, input.path, pixels?.pixels, pixels?.width ?: 0, pixels?.height ?: 0,
                    pixels?.pixelFormat ?: 0, staging.path, format.nativeValue, 0, longEdge ?: 0,
                    false, false, null, generation, backend,
                )
                check(backend[0] >= 0) { "Native export did not report a backend" }
                backend[0]
            },
            preserveMetadata = { staging ->
                if (format != ExportFormat.DNG) {
                    ExportMetadata.preserve(input, staging, allowUnreadableSource = PhotoFiles.isX3f(input))
                }
            },
        )
    }

    @Synchronized
    fun autoExposure(input: File, settings: EditSettings,
        inputKind: PhotoInputKind = PhotoFiles.kind(input.name, null) ?: PhotoInputKind.RAW): Float {
        check(handle != 0L) { "Processor is closed" }
        val effective = settings.effectiveFor(inputKind)
        val pixels = rasterInput(input, inputKind, 1280)
        configureDisplayLens(effective.lens)
        val json = effective.toSdrSessionStateJson(
            isRaster = pixels != null || inputKind != PhotoInputKind.RAW,
            lutPath = null,
            includeDenoise = false,
        )
        return nativeAutoExposure(handle, json, input.path, pixels?.pixels, pixels?.width ?: 0,
            pixels?.height ?: 0, pixels?.pixelFormat ?: 0)
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) { nativeDestroy(handle); handle = 0L }
        releaseRasterCache()
    }

    @Synchronized
    internal fun estimateHDRExposure(source: NativeHDRImage, settings: HDRSettings, cancellationGeneration: Long): Float {
        check(handle != 0L) { "Processor is closed" }
        return NativeHDRBridge.estimateAutoExposure(handle, source, settings, cancellationGeneration)
    }

    @Synchronized
    internal fun renderHDR(source: NativeHDRImage, settings: HDRSettings, edge: Int,
        cancellationGeneration: Long = -1L, lookDirectory: File? = null,
        progress: HDRProgressListener? = null,
        outputSharpening: OutputSharpening = OutputSharpening.OFF): NativeHDRImage {
        check(handle != 0L) { "Processor is closed" }
        require(edge in 0..65535)
        return NativeHDRBridge.render(handle, source, settings, edge, cancellationGeneration, lookDirectory, progress, outputSharpening)
    }

    @Synchronized
    internal fun renderHDRRoi(source: NativeHDRImage, settings: HDRSettings,
        x0: Float, y0: Float, x1: Float, y1: Float, maxOutputLongEdge: Int, baseContentHeadroom: Float,
        cancellationGeneration: Long = -1L, lookDirectory: File? = null): NativeHDRRoiImage {
        check(handle != 0L) { "Processor is closed" }
        return NativeHDRBridge.renderRoi(handle, source, settings, x0, y0, x1, y1,
            maxOutputLongEdge, baseContentHeadroom, cancellationGeneration, lookDirectory)
    }

    @Synchronized
    internal fun renderHDRCameraRawRoi(file: File, info: com.rawlab.android.photo.HDRSourceInfo,
        settings: HDRSettings, x0: Float, y0: Float, x1: Float, y1: Float,
        maxOutputLongEdge: Int, baseContentHeadroom: Float, cancellationGeneration: Long = -1L,
        lookDirectory: File? = null, profileDirectory: File? = null): NativeHDRRoiImage {
        check(handle != 0L) { "Processor is closed" }
        return NativeHDRBridge.renderCameraRawRoi(handle, file, info, settings, x0, y0, x1, y1,
            maxOutputLongEdge, baseContentHeadroom, cancellationGeneration, lookDirectory, profileDirectory)
    }

    @Synchronized
    internal fun renderHDRFileRoi(file: File, info: com.rawlab.android.photo.HDRSourceInfo,
        settings: HDRSettings, x0: Float, y0: Float, x1: Float, y1: Float,
        maxOutputLongEdge: Int, baseContentHeadroom: Float, cancellationGeneration: Long = -1L,
        lookDirectory: File? = null): NativeHDRRoiImage {
        check(handle != 0L) { "Processor is closed" }
        return NativeHDRBridge.renderFileRoi(handle, file, info, settings, x0, y0, x1, y1,
            maxOutputLongEdge, baseContentHeadroom, cancellationGeneration, lookDirectory)
    }

    @Synchronized
    internal fun clearHDRSessionCache() {
        if (handle != 0L) NativeHDRBridge.clearSessionCache(handle)
    }

    internal fun decodeHDRCamera(file: File, info: com.rawlab.android.photo.HDRSourceInfo, edge: Int,
        cancellationGeneration: Long = -1L,
        camera: com.rawlab.android.settings.HDRCameraDevelopmentSettings = com.rawlab.android.settings.HDRCameraDevelopmentSettings(),
        profileDirectory: File? = null,
        progress: HDRProgressListener? = null): NativeHDRImage {
        check(handle != 0L) { "Processor is closed" }
        return NativeHDRBridge.decodeCameraRaw(handle, file, info, edge, cancellationGeneration, camera, profileDirectory, progress)
    }

    internal fun exportProRAW(file: File, info: com.rawlab.android.photo.HDRSourceInfo,
        edits: EditSettings, output: File, keepHDR: Boolean, edge: Int, cancellationGeneration: Long = -1L,
        lookDirectory: File? = null, progress: HDRProgressListener? = null,
        outputSharpening: OutputSharpening = OutputSharpening.OFF) {
        check(handle != 0L) { "Processor is closed" }
        edits.requireProRAWDecoder()
        NativeHDRBridge.exportProRAW(handle, file, info, requireNotNull(edits.hdr).copy(geometry = edits.geometry),
            output, keepHDR, edge, cancellationGeneration, lookDirectory, progress, outputSharpening)
    }

    internal fun sessionHandle(): Long = handle

    // 取消不能等待 preview 的 Java monitor 或 native session 渲染锁。
    internal fun cancellationGeneration(): Long = nativeCancellationGeneration(handle)
    internal fun cancelPreview() { nativeCancelPreview(handle) }

    private external fun nativeCancellationGeneration(handle: Long): Long
    private external fun nativeCancelPreview(handle: Long)

    @Synchronized
    internal fun releaseRasterCache() {
        raster?.close(); raster = null; rasterKey = null; rasterHDRSource = null; rasterEdge = -1
        displayLensMetadata = null
        if (handle != 0L) {
            nativeSetDisplayLensMetadata(handle, null, floatArrayOf(0f, 0f, 0f), 1)
            NativeHDRBridge.clearSessionCache(handle)
        }
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
        if (raster == null || (hdr != null && rasterEdge != 0 && rasterEdge != edge)) {
            val decoded = if (hdr == null) RasterImageDecoder.decode(input) else {
                NativeHDRBridge.decode(input, hdr, edge).use { DecodedRaster(it.sdrBitmap()) }
            }
            raster?.close(); raster = decoded; rasterEdge = edge
        }
        return checkNotNull(raster)
    }

    private fun configureDisplayLens(settings: LensSettings) {
        displayLensMetadata?.let { source ->
            val metadata = source.copy(focalLength = settings.focalLength ?: source.focalLength,
                cropFactor = settings.cropFactor ?: source.cropFactor)
            nativeSetDisplayLensMetadata(handle, metadata.names, metadata.numbers, metadata.sourceOrientation)
        }
    }

    private fun readLens(input: File): LensInfo {
        val key = Triple(input.canonicalPath, input.length(), input.lastModified())
        if (key != catalogKey) {
            candidates = nativeLensProfiles(handle, if (displayLensMetadata == null) input.path else null).toList()
            catalogKey = key
        }
        val report = checkNotNull(nativeLensReport(handle))
        return LensInfo(report.state, report.detectedLens, report.selectedLens, report.appliedDistortion,
            report.appliedTca, report.cropScale, candidates,
            displayLensMetadata?.let { listOf(it.cameraMake, it.cameraModel).filter(String::isNotBlank).distinct().joinToString(" ") },
            displayLensMetadata?.focalLength?.takeIf { it > 0 },
            displayLensMetadata?.aperture?.takeIf { it > 0 },
            report.appliedVignetting)
    }

    @Synchronized
    internal fun inspectLens(input: File, settings: EditSettings, inputKind: PhotoInputKind): LensInfo {
        check(handle != 0L) { "Processor is closed" }
        val effective = settings.effectiveFor(inputKind)
        val metadata = if (inputKind == PhotoInputKind.RASTER) {
            DisplayLensMetadata.read(input).also {
                val configured = it.copy(
                    focalLength = effective.lens.focalLength ?: it.focalLength,
                    cropFactor = effective.lens.cropFactor ?: it.cropFactor,
                )
                nativeSetDisplayLensMetadata(handle, configured.names, configured.numbers, configured.sourceOrientation)
            }
        } else {
            nativeSetDisplayLensMetadata(handle, null, floatArrayOf(0f, 0f, 0f), 1)
            null
        }
        val json = effective.toSdrSessionStateJson(
            isRaster = inputKind != PhotoInputKind.RAW,
            includeDenoise = false,
        )
        val inspection = checkNotNull(nativeInspectLens(handle, json, if (metadata == null) input.path else null))
        return LensInfo(0, "", "", inspection.appliedDistortion, inspection.appliedTca, 1f, emptyList(),
            appliedVignetting = inspection.appliedVignetting)
    }

    @Synchronized
    internal fun resolveCameraWhiteBalance(
        input: File,
        settings: EditSettings,
        inputKind: PhotoInputKind = PhotoInputKind.RAW,
    ): Pair<Float, Float>? {
        check(handle != 0L) { "Processor is closed" }
        if (inputKind != PhotoInputKind.RAW) return null
        val effective = settings.effectiveFor(inputKind)
        val result = nativeResolveCameraWhiteBalance(
            handle,
            input.path,
            effective.processing.version,
            effective.x3fMode.nativeValue,
            effective.exposureMode,
        ) ?: return null
        if (!result.temperature.isFinite() || !result.tint.isFinite()) return null
        return result.temperature to result.tint
    }

    private external fun nativeCreate(mode: Int): Long
    private external fun nativeCompatibilityPreview(handle: Long, editStateJson: String, inputPath: String,
        pixels: Any?, width: Int, height: Int, pixelFormat: Int, configuration: String?): NativeFrame?
    private external fun nativeSetGpuMode(handle: Long, mode: Int)
    private external fun nativeSetLensDatabase(handle: Long, path: String)
    private external fun nativeSetDisplayLensMetadata(handle: Long, names: Array<String>?, numbers: FloatArray, orientation: Int)
    private external fun nativeGeometrySize(handle: Long): IntArray
    private external fun nativeLensProfiles(handle: Long, input: String?): Array<LensCandidate>
    private external fun nativeLensReport(handle: Long): NativeLensReport?
    private external fun nativeInspectLens(handle: Long, editStateJson: String?, input: String?): NativeLensInspection?
    private external fun nativeResolveCameraWhiteBalance(handle: Long, input: String, processingVersion: Int,
        x3fMode: Int, exposureMode: Int): NativeCameraWhiteBalance?
    private external fun nativeDestroy(handle: Long)
    private external fun nativeAutoExposure(handle: Long, editStateJson: String, inputPath: String,
        pixels: Any?, width: Int, height: Int, pixelFormat: Int): Float
    private external fun nativeProcess(handle: Long, editStateJson: String, inputPath: String,
        pixels: Any?, width: Int, height: Int, pixelFormat: Int, outputPath: String?, format: Int,
        edge: Int, longEdge: Int, interactive: Boolean, viewportPreview: Boolean,
        reusableBitmap: Bitmap?, cancellationGeneration: Long, backendOut: IntArray?): NativeFrame?
    private external fun nativeProcessRoi(handle: Long, editStateJson: String, inputPath: String,
        pixels: Any?, width: Int, height: Int, pixelFormat: Int, x0: Float, y0: Float, x1: Float, y1: Float,
        maxOutputLongEdge: Int, cancellationGeneration: Long): NativeRoiFrame?
    private external fun nativeSampleWbProbe(handle: Long, editStateJson: String, inputPath: String,
        pixels: Any?, width: Int, height: Int, pixelFormat: Int, edge: Int, x: Float, y: Float,
        windowSize: Int, cancellationGeneration: Long): NativeWbProbeResult?
    private external fun nativeSampleHsl(handle: Long, editStateJson: String, inputPath: String,
        pixels: Any?, width: Int, height: Int, pixelFormat: Int, edge: Int, interactive: Boolean,
        sourceRevision: Long, requestRevision: Long, x: Float, y: Float,
        cancellationGeneration: Long): NativeHslProbeResult?
    private external fun nativeMigrateProcessing(handle: Long, editStateJson: String, inputPath: String,
        pixels: Any?, width: Int, height: Int, pixelFormat: Int,
        cancellationGeneration: Long): NativeMigrationResult?
    private external fun nativeSupportsFastFullResGpu(handle: Long, inputType: Int, inputWidth: Int,
        inputHeight: Int, maxPixels: Int, inputPath: String?, editStateJson: String?): Boolean

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
            val result = checkNotNull(NativeLookBridge.validate(file.path))
            val format = when (result.format) {
                1 -> LookFormat.CUBE
                2 -> LookFormat.RLOOK
                3 -> LookFormat.VLT
                else -> LookFormat.UNKNOWN
            }
            if (format == LookFormat.UNKNOWN) throw IOException("Unsupported look format")
            return LookValidation(format, result.version, result.colorState)
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
    @JvmStatic external fun validate(path: String): NativeLookValidation?
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
        .also(com.rawlab.android.photo.WorkingCopyCleanup::protect)
    fun throwIfCancelled() {
        if (isCancelled()) throw NativeProcessingException(NativeProcessingException.CANCELLED, "Processing cancelled")
    }
    var committed = false
    var completed = false
    try {
        throwIfCancelled()
        val backend = renderToStaging(staging)
        committed = true
        preserveMetadata(staging)
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
            error is CancellationException || (!committed && isCancelled())
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
