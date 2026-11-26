package com.rawlab.android.engine

import android.graphics.Bitmap
import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.photo.HDRSourceInfo
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.HDRSettings
import java.io.File

internal fun interface HDRProgressListener {
    fun onProgress(permille: Int)
}

/** Strict gain-map probe; only NOT_HDR is represented as null. */
internal object NativeHDRBridge {
    init { System.loadLibrary("rawlab-jni") }

    fun probe(file: File): HDRSourceInfo? = nativeProbe(file.absolutePath)
    fun probeLook(file: File): String = nativeProbeLook(file.absolutePath)
    fun probeCameraProfile(file: File): String = nativeProbeCameraProfile(file.absolutePath)
    fun probeCameraRaw(file: File, processingVersion: Int = 3): HDRSourceInfo? =
        nativeProbeCameraRaw(file.absolutePath, processingVersion)?.copy(
            cameraStamp = HDRSourceInfo.CameraStamp(file.length(), file.lastModified()),
        )

    fun probeSource(file: File, raw: Boolean, processingVersion: Int = 3): HDRSourceInfo? = if (raw) {
        probeCameraRaw(file, processingVersion)
    } else if (HDRSourceInfo.mayContainGainMap(file)) {
        probe(file)
    } else {
        null
    }

    fun cameraFraming(file: File, info: HDRSourceInfo, processingVersion: Int): HDRSourceInfo {
        if (!info.isCameraRaw || info.isProRAW || info.cameraProcessingVersion == processingVersion) return info
        val result = requireNotNull(probeCameraRaw(file, processingVersion)) { "Camera RAW is unavailable" }
        require(!result.isProRAW && (info.cameraStamp == null || result.cameraStamp == info.cameraStamp)) { "HDR source changed" }
        return result
    }

    fun geometrySize(info: HDRSourceInfo, geometry: GeometrySettings): IntArray = geometrySize(
        if (info.orientation >= 5) info.height else info.width,
        if (info.orientation >= 5) info.width else info.height,
        geometry,
    )

    fun geometrySize(width: Int, height: Int, geometry: GeometrySettings): IntArray =
        nativeGeometry(width, height, HDRSettings(geometry = geometry).toHdrSessionStateJson())

    fun decode(file: File, info: HDRSourceInfo, edge: Int, session: Long = 0L, cancellationGeneration: Long = -1L,
        progress: HDRProgressListener? = null): NativeHDRImage {
        if (edge == 0) HDRSourceCache.clear()
        val handle = nativeDecode(session, file.absolutePath, edge, cancellationGeneration, progress)
        if (handle == 0L) error("HDR decode returned an empty owner")
        try {
            require(nativeFingerprint(handle).contentEquals(info.fingerprint)) { "HDR source changed" }
            return NativeHDRImage(handle, info, checkNotNull(nativeMetadata(handle)))
        } catch (error: Throwable) {
            nativeRelease(handle)
            throw error
        }
    }

    private fun wrapRoiPair(info: HDRSourceInfo, pair: NativeHDRRoiPair): NativeHDRRoiImage {
        if (pair.handle == 0L) error("HDR ROI render returned an empty owner")
        try {
            val bounds = pair.bounds
            require(bounds.fullWidth > 0 && bounds.fullHeight > 0 && bounds.x1 > bounds.x0 && bounds.y1 > bounds.y0) {
                "Invalid HDR ROI bounds"
            }
            return NativeHDRRoiImage(
                NativeHDRImage(pair.handle, info, checkNotNull(nativeMetadata(pair.handle))),
                bounds,
            )
        } catch (error: Throwable) {
            nativeRelease(pair.handle)
            throw error
        }
    }

    fun decodeCameraRaw(processor: Long, file: File, info: HDRSourceInfo, edge: Int,
        cancellationGeneration: Long = -1L, camera: HDRCameraDevelopmentSettings = HDRCameraDevelopmentSettings(),
        profileDirectory: File? = null, progress: HDRProgressListener? = null): NativeHDRImage {
        require(info.isCameraRaw) { "Camera RAW HDR decode requires a camera RAW source" }
        require(!info.isProRAW || camera.isDefault) { "Camera development requires an ordinary Bayer RAW" }
        require(edge in 0..65535)
        if (edge == 0) HDRSourceCache.clear()
        val editStateJson = if (info.isProRAW) null else camera.toCameraDevelopmentJson(
            processingVersion = info.cameraProcessingVersion,
            profileDirectory = profileDirectory,
        )
        val handle = nativeDecodeCameraRaw(processor, file.absolutePath, edge, cancellationGeneration,
            info.isProRAW, requireNotNull(file.parentFile).absolutePath, editStateJson, progress)
        if (handle == 0L) error("Camera RAW HDR decode returned an empty owner")
        try {
            info.cameraStamp?.let { expected ->
                require(expected == HDRSourceInfo.CameraStamp(file.length(), file.lastModified())) { "HDR source changed" }
            }
            return NativeHDRImage(handle, info, checkNotNull(nativeMetadata(handle)))
        } catch (error: Throwable) {
            nativeRelease(handle)
            throw error
        }
    }

    fun render(session: Long, source: NativeHDRImage, settings: HDRSettings, edge: Int, cancellationGeneration: Long,
        lookDirectory: File?, progress: HDRProgressListener? = null,
        outputSharpening: OutputSharpening = OutputSharpening.OFF): NativeHDRImage {
        require(settings.cameraSettings.isDefault || source.sourceInfo.isCameraRaw && !source.sourceInfo.isProRAW)
        val json = settings.toHdrSessionStateJson(lookDirectory = lookDirectory, outputSharpening = outputSharpening)
        val handle = nativeRender(session, source.handle, json, edge, cancellationGeneration, progress)
        if (handle == 0L) error("HDR render returned an empty owner")
        try {
            return NativeHDRImage(handle, source.sourceInfo, checkNotNull(nativeMetadata(handle)))
        } catch (error: Throwable) {
            nativeRelease(handle)
            throw error
        }
    }

    fun renderRoi(session: Long, source: NativeHDRImage, settings: HDRSettings,
        x0: Float, y0: Float, x1: Float, y1: Float, maxOutputLongEdge: Int, baseContentHeadroom: Float,
        cancellationGeneration: Long, lookDirectory: File?): NativeHDRRoiImage {
        require(settings.cameraSettings.isDefault || source.sourceInfo.isCameraRaw && !source.sourceInfo.isProRAW)
        val clampedEdge = maxOutputLongEdge.coerceIn(1, 1280)
        val json = settings.toHdrSessionStateJson(lookDirectory = lookDirectory)
        val pair = checkNotNull(nativeRenderRoi(session, source.handle, json, clampedEdge,
            x0, y0, x1, y1, clampedEdge, baseContentHeadroom, cancellationGeneration))
        return wrapRoiPair(source.sourceInfo, pair)
    }

    fun renderCameraRawRoi(session: Long, file: File, info: HDRSourceInfo, settings: HDRSettings,
        x0: Float, y0: Float, x1: Float, y1: Float, maxOutputLongEdge: Int, baseContentHeadroom: Float,
        cancellationGeneration: Long, lookDirectory: File?, profileDirectory: File?): NativeHDRRoiImage {
        require(info.isCameraRaw && !info.isProRAW) { "Camera RAW HDR ROI requires a Bayer RAW source" }
        val clampedEdge = maxOutputLongEdge.coerceIn(1, 1280)
        val json = settings.toHdrSessionStateJson(
            lookDirectory = lookDirectory,
            camera = settings.cameraSettings,
            profileDirectory = profileDirectory,
            cameraProcessingVersion = info.cameraProcessingVersion,
        )
        val pair = checkNotNull(nativeRenderCameraRawRoi(session, file.absolutePath, json, clampedEdge,
            x0, y0, x1, y1, clampedEdge, baseContentHeadroom, cancellationGeneration))
        try {
            info.cameraStamp?.let { expected ->
                require(expected == HDRSourceInfo.CameraStamp(file.length(), file.lastModified())) { "HDR source changed" }
            }
            return wrapRoiPair(info, pair)
        } catch (error: Throwable) {
            if (pair.handle != 0L) nativeRelease(pair.handle)
            throw error
        }
    }

    fun renderFileRoi(session: Long, file: File, info: HDRSourceInfo, settings: HDRSettings,
        x0: Float, y0: Float, x1: Float, y1: Float, maxOutputLongEdge: Int, baseContentHeadroom: Float,
        cancellationGeneration: Long, lookDirectory: File?): NativeHDRRoiImage {
        require(!info.isCameraRaw) { "File HDR ROI requires a gain-map file source" }
        val clampedEdge = maxOutputLongEdge.coerceIn(1, 1280)
        val json = settings.toHdrSessionStateJson(lookDirectory = lookDirectory)
        val pair = checkNotNull(nativeRenderFileRoi(session, file.absolutePath, info.fingerprint, json,
            clampedEdge, x0, y0, x1, y1, clampedEdge, baseContentHeadroom, cancellationGeneration))
        return wrapRoiPair(info, pair)
    }

    fun clearSessionCache(session: Long) = nativeClearHdrSessionCache(session)

    fun plane(pair: NativeHDRImage, hdr: Boolean): FloatArray = nativePlane(pair.handle, hdr)
    fun analyzeLuminance(values: FloatArray, width: Int, height: Int, stride: Int, bins: IntArray, peak: FloatArray): Int =
        nativeAnalyzeLuminance(values, width, height, stride, bins, peak)

    /** 把紧密排列的 HDR/SDR 平面 [firstRow, firstRow + rowCount) 行映射为 RGBA16F；超出半精度范围时返回 false。 */
    fun displayRows(hdr: FloatArray, sdr: FloatArray, width: Int, height: Int, firstRow: Int, rowCount: Int,
        displayHeadroom: Float, contentHeadroom: Float, flags: Int, output: ShortArray): Boolean =
        nativeDisplayRows(hdr, sdr, width, height, firstRow, rowCount, displayHeadroom, contentHeadroom, flags, output)
    fun estimateAutoExposure(session: Long, source: NativeHDRImage, settings: HDRSettings, cancellationGeneration: Long): Float =
        nativeEstimateAutoExposure(session, source.handle, settings.temperature, settings.tint, cancellationGeneration)

    fun sampleHsl(session: Long, source: NativeHDRImage, settings: HDRSettings, edge: Int,
        sourceRevision: Long, requestRevision: Long, x: Float, y: Float, cancellationGeneration: Long,
        lookDirectory: File?): NativeHslProbeResult = checkNotNull(
        nativeSampleHsl(session, source.handle, settings.toHdrSessionStateJson(lookDirectory = lookDirectory),
            edge, sourceRevision, requestRevision, x, y, cancellationGeneration),
    )

    fun sdrBitmap(pair: NativeHDRImage, bitmap: Bitmap) = nativeSdrBitmap(pair.handle, bitmap)
    fun release(pair: Long) = nativeRelease(pair)
    fun exportJpeg(pair: NativeHDRImage, source: File?, output: File, baseColor: Int = 2,
        session: Long = 0L, cancellationGeneration: Long = -1L, progress: HDRProgressListener? = null) =
        nativeExportJpeg(pair.handle, session, source?.absolutePath, output.absolutePath, baseColor,
            cancellationGeneration, progress)

    fun exportSdr(pair: NativeHDRImage, source: File?, output: File, format: Int,
        session: Long = 0L, cancellationGeneration: Long = -1L, progress: HDRProgressListener? = null) =
        nativeExportSdr(pair.handle, session, source?.absolutePath, output.absolutePath, format,
            cancellationGeneration, progress)

    fun exportProRAW(processor: Long, file: File, info: HDRSourceInfo, settings: HDRSettings,
        output: File, keepHDR: Boolean, edge: Int, cancellationGeneration: Long, lookDirectory: File?,
        progress: HDRProgressListener? = null, outputSharpening: OutputSharpening = OutputSharpening.OFF) {
        require(info.isProRAW && edge in 0..65535 && settings.cameraSettings.isDefault)
        info.cameraStamp?.let { require(it == HDRSourceInfo.CameraStamp(file.length(), file.lastModified())) { "HDR source changed" } }
        HDRSourceCache.clear()
        val json = settings.toHdrSessionStateJson(lookDirectory = lookDirectory, outputSharpening = outputSharpening)
        // 全零 source_sha256：导出内部在 validateStreamSource 单次读取时自采冻结摘要，避免前置全盘扫读。
        nativeExportProRAW(processor, file.absolutePath, json, edge, keepHDR, ByteArray(32),
            requireNotNull(output.parentFile).absolutePath, output.absolutePath, cancellationGeneration, progress)
    }

    @JvmStatic
    private external fun nativeProbe(path: String): HDRSourceInfo?
    @JvmStatic
    private external fun nativeProbeLook(path: String): String
    @JvmStatic
    private external fun nativeProbeCameraProfile(path: String): String
    @JvmStatic
    private external fun nativeProbeCameraRaw(path: String, processingVersion: Int): HDRSourceInfo?
    @JvmStatic
    private external fun nativeGeometry(width: Int, height: Int, editStateJson: String): IntArray
    @JvmStatic
    private external fun nativeDecode(session: Long, path: String, longEdge: Int, cancellationGeneration: Long,
        progress: HDRProgressListener?): Long
    @JvmStatic
    private external fun nativeDecodeCameraRaw(session: Long, path: String, longEdge: Int, cancellationGeneration: Long,
        proRAW: Boolean, temporaryRoot: String, editStateJson: String?, progress: HDRProgressListener?): Long
    @JvmStatic
    private external fun nativeExportProRAW(session: Long, path: String, editStateJson: String, edge: Int,
        keepHDR: Boolean, fingerprint: ByteArray, temporaryRoot: String, output: String,
        cancellationGeneration: Long, progress: HDRProgressListener?)
    @JvmStatic
    private external fun nativeRender(session: Long, source: Long, editStateJson: String, edge: Int,
        cancellationGeneration: Long, progress: HDRProgressListener?): Long
    @JvmStatic
    private external fun nativeRenderRoi(session: Long, source: Long, editStateJson: String, edge: Int,
        x0: Float, y0: Float, x1: Float, y1: Float, maxOutputLongEdge: Int, baseContentHeadroom: Float,
        cancellationGeneration: Long): NativeHDRRoiPair?
    @JvmStatic
    private external fun nativeRenderCameraRawRoi(session: Long, path: String, editStateJson: String, edge: Int,
        x0: Float, y0: Float, x1: Float, y1: Float, maxOutputLongEdge: Int, baseContentHeadroom: Float,
        cancellationGeneration: Long): NativeHDRRoiPair?
    @JvmStatic
    private external fun nativeRenderFileRoi(session: Long, path: String, expectedFingerprint: ByteArray,
        editStateJson: String, edge: Int, x0: Float, y0: Float, x1: Float, y1: Float,
        maxOutputLongEdge: Int, baseContentHeadroom: Float, cancellationGeneration: Long): NativeHDRRoiPair?
    @JvmStatic
    private external fun nativeClearHdrSessionCache(session: Long)
    @JvmStatic
    private external fun nativeEstimateAutoExposure(session: Long, source: Long, temperature: Float, tint: Float,
        cancellationGeneration: Long): Float
    @JvmStatic
    private external fun nativeSampleHsl(session: Long, source: Long, editStateJson: String, edge: Int,
        sourceRevision: Long, requestRevision: Long, x: Float, y: Float, cancellationGeneration: Long): NativeHslProbeResult?
    @JvmStatic
    private external fun nativeMetadata(pair: Long): NativeHDRPairInfo?
    @JvmStatic
    private external fun nativeFingerprint(pair: Long): ByteArray
    @JvmStatic
    private external fun nativePlane(pair: Long, hdr: Boolean): FloatArray
    @JvmStatic
    private external fun nativeAnalyzeLuminance(values: FloatArray, width: Int, height: Int, stride: Int,
        bins: IntArray, peak: FloatArray): Int
    @JvmStatic
    private external fun nativeDisplayRows(hdr: FloatArray, sdr: FloatArray, width: Int, height: Int, firstRow: Int,
        rowCount: Int, displayHeadroom: Float, contentHeadroom: Float, flags: Int, output: ShortArray): Boolean
    @JvmStatic
    private external fun nativeSdrBitmap(pair: Long, bitmap: Bitmap)
    @JvmStatic
    private external fun nativeRelease(pair: Long)
    @JvmStatic
    private external fun nativeExportJpeg(pair: Long, session: Long, source: String?, output: String, baseColor: Int,
        cancellationGeneration: Long, progress: HDRProgressListener?)
    @JvmStatic
    private external fun nativeExportSdr(pair: Long, session: Long, source: String?, output: String, format: Int,
        cancellationGeneration: Long, progress: HDRProgressListener?)
}

internal class NativeHDRImage internal constructor(
    internal val handle: Long,
    val sourceInfo: HDRSourceInfo,
    metadata: NativeHDRPairInfo,
) : AutoCloseable {
    val width = metadata.width
    val height = metadata.height
    val nativeWidth = metadata.nativeWidth
    val nativeHeight = metadata.nativeHeight
    val outputNativeWidth = metadata.outputNativeWidth
    val outputNativeHeight = metadata.outputNativeHeight
    val contentHeadroom = metadata.contentHeadroom
    val sourceHeadroom = metadata.sourceHeadroom
    @Volatile private var closed = false

    fun hdrPlane(): FloatArray { check(!closed); return NativeHDRBridge.plane(this, true) }
    fun sdrPlane(): FloatArray { check(!closed); return NativeHDRBridge.plane(this, false) }

    fun snapshot(headroomOverride: Float = 0f): com.rawlab.android.editor.render.HDRPreviewFrame {
        check(!closed)
        val hdr = hdrPlane()
        val sdr = sdrPlane()
        val resolvedHeadroom = if (headroomOverride.isFinite() && headroomOverride > 1f) headroomOverride else contentHeadroom
        val measured = HDRStatistics.analyze(hdr, width, height, width * 3)
        val statistics = if (headroomOverride.isFinite() && headroomOverride > 1f) {
            measured.copy(headroom = headroomOverride)
        } else {
            measured
        }
        return com.rawlab.android.editor.render.HDRPreviewFrame(
            width, height, hdr, sdr, resolvedHeadroom, sourceHeadroom,
            outputNativeWidth, outputNativeHeight, statistics,
        )
    }

    fun sdrBitmap(): Bitmap {
        check(!closed)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            NativeHDRBridge.sdrBitmap(this, bitmap)
            return bitmap
        } catch (error: Throwable) {
            bitmap.recycle()
            throw error
        }
    }

    override fun close() {
        if (!closed) {
            closed = true
            NativeHDRBridge.release(handle)
        }
    }
}

internal class NativeHDRRoiImage(
    val image: NativeHDRImage,
    val bounds: NativeRoiBounds,
) : AutoCloseable {
    override fun close() = image.close()
}
