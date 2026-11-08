package com.rawlab.android.engine

import com.rawlab.android.photo.HDRSourceInfo
import com.rawlab.android.settings.HDRSettings
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import android.graphics.Bitmap
import java.io.File
import com.rawlab.android.geometry.GeometrySettings

/** Strict gain-map probe; only NOT_HDR is represented as null. */
internal object NativeHDRBridge {
    init { System.loadLibrary("rawlab-jni") }

    fun probe(file: File): HDRSourceInfo? = nativeProbe(file.absolutePath)?.let(HDRSourceInfo::decode)
    fun probeLook(file: File): String = nativeProbeLook(file.absolutePath)
    fun probeCameraProfile(file: File): String = nativeProbeCameraProfile(file.absolutePath)
    fun probeCameraRaw(file: File): HDRSourceInfo? = nativeProbeCameraRaw(file.absolutePath)?.let {
        HDRSourceInfo.decode(it).copy(cameraStamp = HDRSourceInfo.CameraStamp(file.length(), file.lastModified()))
    }
    fun probeSource(file: File, raw: Boolean): HDRSourceInfo? = if (raw) probeCameraRaw(file)
        else if (HDRSourceInfo.mayContainGainMap(file)) probe(file) else null
    fun geometrySize(info: HDRSourceInfo, geometry: GeometrySettings): IntArray = nativeGeometry(
        if (info.orientation >= 5) info.height else info.width,
        if (info.orientation >= 5) info.width else info.height,
        HDRSettings(geometry = geometry).requestValues())

    fun decode(file: File, info: HDRSourceInfo, edge: Int): NativeHDRImage {
        if (edge == 0) HDRSourceCache.clear()
        val handle = nativeDecode(file.absolutePath, edge)
        if (handle == 0L) error("HDR decode returned an empty owner")
        try {
            require(nativeFingerprint(handle).contentEquals(info.fingerprint)) { "HDR source changed" }
            return NativeHDRImage(handle, info, nativeMetadata(handle))
        } catch (error: Throwable) {
            nativeRelease(handle)
            throw error
        }
    }

    fun decodeCameraRaw(processor: Long, file: File, info: HDRSourceInfo, edge: Int,
        cancellationGeneration: Long = -1L, camera: HDRCameraDevelopmentSettings = HDRCameraDevelopmentSettings(),
        profileDirectory: File? = null): NativeHDRImage {
        require(info.isCameraRaw) { "Camera RAW HDR decode requires a camera RAW source" }
        require(!info.isProRAW || camera.isDefault) { "Camera development requires an ordinary Bayer RAW" }
        require(edge in 0..65535)
        if (edge == 0) HDRSourceCache.clear()
        val flags = (if (camera.lensDistortion) 1 else 0) or (if (camera.lensTca) 2 else 0) or
            (if (camera.lensActive && camera.lensAutoCrop) 4 else 0)
        val handle = nativeDecodeCameraRaw(processor, file.absolutePath, edge, cancellationGeneration,
            info.isProRAW, requireNotNull(file.parentFile).absolutePath, camera.customWhiteBalance,
            camera.temperature, camera.tint, camera.sensorExposure, camera.fbddLevel, flags, camera.lensProfile,
            camera.cameraProfile?.requireAsset(profileDirectory)?.absolutePath, camera.cameraProfile?.sha256)
        if (handle == 0L) error("Camera RAW HDR decode returned an empty owner")
        try {
            info.cameraStamp?.let { expected ->
                require(expected == HDRSourceInfo.CameraStamp(file.length(), file.lastModified())) { "HDR source changed" }
            }
            return NativeHDRImage(handle, info, nativeMetadata(handle))
        } catch (error: Throwable) {
            nativeRelease(handle)
            throw error
        }
    }

    fun render(session: Long, source: NativeHDRImage, settings: HDRSettings, edge: Int, cancellationGeneration: Long,
        lookDirectory: File?): NativeHDRImage {
        require(settings.cameraSettings.isDefault || source.sourceInfo.isCameraRaw && !source.sourceInfo.isProRAW)
        val curve = settings.tone?.curve
        val handle = nativeRender(session, source.handle, settings.renderRequestValues(), curve?.mode?.nativeValue ?: 0,
            curve?.packed(), edge, cancellationGeneration, settings.look?.asset(lookDirectory)?.absolutePath, settings.look?.sha256)
        if (handle == 0L) error("HDR render returned an empty owner")
        try {
            return NativeHDRImage(handle, source.sourceInfo, nativeMetadata(handle))
        } catch (error: Throwable) {
            nativeRelease(handle)
            throw error
        }
    }

    fun plane(pair: NativeHDRImage, hdr: Boolean): FloatArray = nativePlane(pair.handle, hdr)
    fun estimateAutoExposure(session: Long, source: NativeHDRImage, settings: HDRSettings, cancellationGeneration: Long): Float =
        nativeEstimateAutoExposure(session, source.handle, settings.temperature, settings.tint, cancellationGeneration)
    fun sampleHsl(session: Long, source: NativeHDRImage, settings: HDRSettings, edge: Int,
        sourceRevision: Long, requestRevision: Long, probe: FloatArray, cancellationGeneration: Long, lookDirectory: File?) {
        val curve = settings.tone?.curve
        nativeSampleHsl(session, source.handle, settings.renderRequestValues(), curve?.mode?.nativeValue ?: 0,
            curve?.packed(), edge, sourceRevision, requestRevision, probe, cancellationGeneration,
            settings.look?.asset(lookDirectory)?.absolutePath, settings.look?.sha256)
    }
    fun sdrBitmap(pair: NativeHDRImage, bitmap: Bitmap) = nativeSdrBitmap(pair.handle, bitmap)
    fun release(pair: Long) = nativeRelease(pair)
    fun exportJpeg(pair: NativeHDRImage, source: File?, output: File, baseColor: Int = 2) =
        nativeExportJpeg(pair.handle, source?.absolutePath, output.absolutePath, baseColor)
    fun exportSdr(pair: NativeHDRImage, source: File?, output: File, format: Int) =
        nativeExportSdr(pair.handle, source?.absolutePath, output.absolutePath, format)

    fun exportProRAW(processor: Long, file: File, info: HDRSourceInfo, settings: HDRSettings,
        output: File, keepHDR: Boolean, edge: Int, cancellationGeneration: Long, lookDirectory: File?) {
        require(info.isProRAW && edge in 0..65535 && settings.cameraSettings.isDefault)
        info.cameraStamp?.let { require(it == HDRSourceInfo.CameraStamp(file.length(), file.lastModified())) { "HDR source changed" } }
        HDRSourceCache.clear()
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val bytes = ByteArray(1024 * 1024)
            while (true) { val count = input.read(bytes); if (count < 0) break; digest.update(bytes, 0, count) }
        }
        val curve = settings.tone?.curve
        nativeExportProRAW(processor, file.absolutePath, settings.renderRequestValues(), curve?.mode?.nativeValue ?: 0,
            curve?.packed(), edge, keepHDR,
            digest.digest(), requireNotNull(output.parentFile).absolutePath, output.absolutePath, cancellationGeneration,
            settings.look?.asset(lookDirectory)?.absolutePath, settings.look?.sha256)
    }

    @JvmStatic
    private external fun nativeProbe(path: String): ByteArray?
    @JvmStatic
    private external fun nativeProbeLook(path: String): String
    @JvmStatic
    private external fun nativeProbeCameraProfile(path: String): String
    @JvmStatic
    private external fun nativeProbeCameraRaw(path: String): ByteArray?
    @JvmStatic
    private external fun nativeGeometry(width: Int, height: Int, values: FloatArray): IntArray
    @JvmStatic
    private external fun nativeDecode(path: String, longEdge: Int): Long
    @JvmStatic
    private external fun nativeDecodeCameraRaw(session: Long, path: String, longEdge: Int, cancellationGeneration: Long,
        proRAW: Boolean, temporaryRoot: String, customWhiteBalance: Boolean, temperature: Float, tint: Float,
        sensorExposure: Boolean, fbddLevel: Int, lensFlags: Int, lensProfile: String?, profilePath: String?, profileDigest: String?): Long
    @JvmStatic
    private external fun nativeExportProRAW(session: Long, path: String, values: FloatArray, curveMode: Int, curvePoints: DoubleArray?, longEdge: Int,
        keepHDR: Boolean, fingerprint: ByteArray, temporaryRoot: String, output: String, cancellationGeneration: Long,
        lookPath: String?, lookSha256: String?)
    @JvmStatic
    private external fun nativeRender(session: Long, source: Long, values: FloatArray, curveMode: Int, curvePoints: DoubleArray?,
        longEdge: Int, cancellationGeneration: Long, lookPath: String?, lookSha256: String?): Long
    @JvmStatic
    private external fun nativeEstimateAutoExposure(session: Long, source: Long, temperature: Float, tint: Float, cancellationGeneration: Long): Float
    @JvmStatic
    private external fun nativeSampleHsl(session: Long, source: Long, values: FloatArray, curveMode: Int, curvePoints: DoubleArray?,
        longEdge: Int, sourceRevision: Long, requestRevision: Long, probe: FloatArray, cancellationGeneration: Long,
        lookPath: String?, lookSha256: String?)
    @JvmStatic
    private external fun nativeMetadata(pair: Long): FloatArray
    @JvmStatic
    private external fun nativeFingerprint(pair: Long): ByteArray
    @JvmStatic
    private external fun nativePlane(pair: Long, hdr: Boolean): FloatArray
    @JvmStatic
    private external fun nativeSdrBitmap(pair: Long, bitmap: Bitmap)
    @JvmStatic
    private external fun nativeRelease(pair: Long)
    @JvmStatic
    private external fun nativeExportJpeg(pair: Long, source: String?, output: String, baseColor: Int)
    @JvmStatic
    private external fun nativeExportSdr(pair: Long, source: String?, output: String, format: Int)
}

internal class NativeHDRImage internal constructor(
    internal val handle: Long,
    val sourceInfo: HDRSourceInfo,
    metadata: FloatArray,
) : AutoCloseable {
    val width = metadata[0].toInt()
    val height = metadata[1].toInt()
    val nativeWidth = metadata[2].toInt()
    val nativeHeight = metadata[3].toInt()
    val outputNativeWidth = metadata[4].toInt()
    val outputNativeHeight = metadata[5].toInt()
    val contentHeadroom = metadata[6]
    val sourceHeadroom = metadata[7]
    @Volatile private var closed = false

    fun hdrPlane(): FloatArray { check(!closed); return NativeHDRBridge.plane(this, true) }
    fun sdrPlane(): FloatArray { check(!closed); return NativeHDRBridge.plane(this, false) }

    fun snapshot(): com.rawlab.android.editor.render.HDRPreviewFrame {
        check(!closed)
        return com.rawlab.android.editor.render.HDRPreviewFrame(width, height, hdrPlane(), sdrPlane(), contentHeadroom, sourceHeadroom,
            outputNativeWidth, outputNativeHeight)
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

internal fun HDRSettings.requestValues(): FloatArray = floatArrayOf(
    exposure, temperature, tint, contrast, highlights, shadows, saturation,
    geometry.cropX, geometry.cropY, geometry.cropWidth, geometry.cropHeight, geometry.quarterTurns.toFloat(),
    if (geometry.flipHorizontal) 1f else 0f, if (geometry.flipVertical) 1f else 0f,
    geometry.straightenDegrees, geometry.perspectiveHorizontal, geometry.perspectiveVertical)

internal fun HDRSettings.renderRequestValues(): FloatArray {
    val base = requestValues()
    val tone = tone ?: return base
    val extended = base + floatArrayOf(tone.blackPoint, tone.whitePoint, tone.curveStrength)
    val color = color ?: return extended
    val grading = color.grading
    val colorValues = extended + color.vibrance + color.hsl.packed() + floatArrayOf(
        grading.shadows.hue, grading.shadows.saturation, grading.midtones.hue, grading.midtones.saturation,
        grading.highlights.hue, grading.highlights.saturation)
    val rendition = rendition ?: return colorValues
    val renditionValues = colorValues + floatArrayOf(rendition.peakLimitEV, rendition.sdrExposureEV, rendition.sdrContrast, rendition.sdrSaturation)
    val effects = effects ?: return renditionValues
    val effectValues = renditionValues + floatArrayOf(effects.vignetteAmount, effects.vignetteMidpoint, effects.vignetteRoundness,
        effects.vignetteFeather, effects.vignetteHighlights, effects.grainAmount, effects.grainSize, effects.grainRoughness)
    val detail = detail ?: return effectValues
    val detailValues = effectValues + floatArrayOf(detail.sharpening, detail.clarity, detail.dehaze, detail.denoise)
    return look?.let { detailValues + it.strength } ?: detailValues
}
