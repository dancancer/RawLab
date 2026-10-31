package com.rawlab.android.engine

import com.rawlab.android.photo.HDRSourceInfo
import com.rawlab.android.settings.HDRSettings
import android.graphics.Bitmap
import java.io.File
import com.rawlab.android.geometry.GeometrySettings

/** Strict gain-map probe; only NOT_HDR is represented as null. */
internal object NativeHDRBridge {
    init { System.loadLibrary("rawlab-jni") }

    fun probe(file: File): HDRSourceInfo? = nativeProbe(file.absolutePath)?.let(HDRSourceInfo::decode)
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

    fun render(session: Long, source: NativeHDRImage, settings: HDRSettings, edge: Int, cancellationGeneration: Long = -1L): NativeHDRImage {
        val handle = nativeRender(session, source.handle, settings.requestValues(), edge, cancellationGeneration)
        if (handle == 0L) error("HDR render returned an empty owner")
        try {
            return NativeHDRImage(handle, source.sourceInfo, nativeMetadata(handle))
        } catch (error: Throwable) {
            nativeRelease(handle)
            throw error
        }
    }

    fun plane(pair: NativeHDRImage, hdr: Boolean): FloatArray = nativePlane(pair.handle, hdr)
    fun sdrBitmap(pair: NativeHDRImage, bitmap: Bitmap) = nativeSdrBitmap(pair.handle, bitmap)
    fun release(pair: Long) = nativeRelease(pair)
    fun exportJpeg(pair: NativeHDRImage, source: File, output: File, baseColor: Int = 2) =
        nativeExportJpeg(pair.handle, source.absolutePath, output.absolutePath, baseColor)
    fun exportSdr(pair: NativeHDRImage, source: File, output: File, format: Int) =
        nativeExportSdr(pair.handle, source.absolutePath, output.absolutePath, format)

    @JvmStatic
    private external fun nativeProbe(path: String): ByteArray?
    @JvmStatic
    private external fun nativeGeometry(width: Int, height: Int, values: FloatArray): IntArray
    @JvmStatic
    private external fun nativeDecode(path: String, longEdge: Int): Long
    @JvmStatic
    private external fun nativeRender(session: Long, source: Long, values: FloatArray, longEdge: Int, cancellationGeneration: Long): Long
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
    private external fun nativeExportJpeg(pair: Long, source: String, output: String, baseColor: Int)
    @JvmStatic
    private external fun nativeExportSdr(pair: Long, source: String, output: String, format: Int)
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
