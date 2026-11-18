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
    fun probeCameraRaw(file: File, processingVersion: Int = 3): HDRSourceInfo? = nativeProbeCameraRaw(file.absolutePath, processingVersion)?.let {
        val info = HDRSourceInfo.decode(it)
        info.copy(cameraStamp = HDRSourceInfo.CameraStamp(file.length(), file.lastModified()),
            cameraProcessingVersion = if (info.isProRAW) 3 else processingVersion)
    }
    fun probeSource(file: File, raw: Boolean, processingVersion: Int = 3): HDRSourceInfo? = if (raw) probeCameraRaw(file, processingVersion)
        else if (HDRSourceInfo.mayContainGainMap(file)) probe(file) else null
    fun cameraFraming(file: File, info: HDRSourceInfo, processingVersion: Int): HDRSourceInfo {
        if (!info.isCameraRaw || info.isProRAW || info.cameraProcessingVersion == processingVersion) return info
        val result = requireNotNull(probeCameraRaw(file, processingVersion)) { "Camera RAW is unavailable" }
        require(!result.isProRAW && (info.cameraStamp == null || result.cameraStamp == info.cameraStamp)) { "HDR source changed" }
        return result
    }
    fun geometrySize(info: HDRSourceInfo, geometry: GeometrySettings): IntArray = geometrySize(
        if (info.orientation >= 5) info.height else info.width,
        if (info.orientation >= 5) info.width else info.height,
        geometry)
    fun geometrySize(width: Int, height: Int, geometry: GeometrySettings): IntArray =
        nativeGeometry(width, height, geometry.toNativeGeometry())

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
        val flags = (if (camera.lensDistortion) 1 else 0) or (if (camera.lensTca) 2 else 0) or (if (camera.lensVignetting) 8 else 0) or
            (if (camera.lensActive && camera.lensAutoCrop) 4 else 0)
        val handle = nativeDecodeCameraRaw(processor, file.absolutePath, edge, cancellationGeneration,
            info.isProRAW, requireNotNull(file.parentFile).absolutePath, camera.customWhiteBalance,
            camera.temperature, camera.tint, camera.sensorExposure, camera.fbddLevel, flags, camera.lensProfile,
            camera.cameraProfile?.requireAsset(profileDirectory)?.absolutePath, camera.cameraProfile?.sha256,
            info.cameraProcessingVersion)
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
        val handle = nativeRender(session, source.handle, settings.toNativeRequest(edge, lookDirectory), cancellationGeneration)
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
        nativeSampleHsl(session, source.handle, settings.toNativeRequest(edge, lookDirectory),
            sourceRevision, requestRevision, probe, cancellationGeneration)
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
        nativeExportProRAW(processor, file.absolutePath, settings.toNativeRequest(edge, lookDirectory), keepHDR,
            digest.digest(), requireNotNull(output.parentFile).absolutePath, output.absolutePath, cancellationGeneration)
    }

    @JvmStatic
    private external fun nativeProbe(path: String): ByteArray?
    @JvmStatic
    private external fun nativeProbeLook(path: String): String
    @JvmStatic
    private external fun nativeProbeCameraProfile(path: String): String
    @JvmStatic
    private external fun nativeProbeCameraRaw(path: String, processingVersion: Int): ByteArray?
    @JvmStatic
    private external fun nativeGeometry(width: Int, height: Int, geometry: NativeGeometry): IntArray
    @JvmStatic
    private external fun nativeDecode(path: String, longEdge: Int): Long
    @JvmStatic
    private external fun nativeDecodeCameraRaw(session: Long, path: String, longEdge: Int, cancellationGeneration: Long,
        proRAW: Boolean, temporaryRoot: String, customWhiteBalance: Boolean, temperature: Float, tint: Float,
        sensorExposure: Boolean, fbddLevel: Int, lensFlags: Int, lensProfile: String?, profilePath: String?, profileDigest: String?,
        processingVersion: Int): Long
    @JvmStatic
    private external fun nativeExportProRAW(session: Long, path: String, request: NativeHDRRenderRequest,
        keepHDR: Boolean, fingerprint: ByteArray, temporaryRoot: String, output: String, cancellationGeneration: Long)
    @JvmStatic
    private external fun nativeRender(session: Long, source: Long, request: NativeHDRRenderRequest,
        cancellationGeneration: Long): Long
    @JvmStatic
    private external fun nativeEstimateAutoExposure(session: Long, source: Long, temperature: Float, tint: Float, cancellationGeneration: Long): Float
    @JvmStatic
    private external fun nativeSampleHsl(session: Long, source: Long, request: NativeHDRRenderRequest,
        sourceRevision: Long, requestRevision: Long, probe: FloatArray, cancellationGeneration: Long)
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
