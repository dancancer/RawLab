package com.rawlab.android.editor.render

import android.graphics.Bitmap
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.engine.NativeHDRBridge
import com.rawlab.android.engine.HDRDisplayMath
import com.rawlab.android.settings.HDRSettings
import com.rawlab.android.settings.withHDRMode
import com.rawlab.android.format.ExportFormat
import kotlin.math.pow
import kotlin.math.roundToInt
import com.rawlab.android.engine.RgbHistogram
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.HslTargetAvailability
import com.rawlab.android.settings.HslTargetSample
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.VersionedPhotoEdit

// ============================================================================
//  编辑器的渲染执行：只在渲染队列的线程上调用
//  缓存原图与几何对比图；原生处理器懒创建，队列释放时关闭
// ============================================================================

internal class EditorRenderer(
    private val storage: PhotoStorage,
    private val restore: (PhotoIdentity) -> VersionedPhotoEdit?,
    private val debuggable: Boolean,
) {
    private var processor: NativeProcessor? = null
    private data class ReferenceFrame(val bitmap: Bitmap, val histogram: RgbHistogram?)
    private var original: Pair<NeutralSourceKey, ReferenceFrame>? = null
    private var originalAspect = 1f
    private var transformedNeutral: Pair<ComparisonPreviewKey, ReferenceFrame>? = null
    private var hdrSource: com.rawlab.android.engine.NativeHDRImage? = null
    private var hdrSourceLease: com.rawlab.android.engine.HDRSourceLease? = null
    private var hdrSourceKey: Triple<String, Long, Long>? = null

    fun close() { releaseDecodedRaster();com.rawlab.android.engine.HDRSourceCache.clear();processor?.close() }
    private fun releaseHDRSource() {hdrSourceLease?.close();hdrSourceLease=null;hdrSource=null;hdrSourceKey=null}
    fun releaseDecodedRaster() { processor?.releaseRasterCache();releaseHDRSource() }

    private fun engine() = processor ?: NativeProcessor(lensDatabase = storage.lensDatabase()).also { processor = it }

    fun perform(work: Work, cancellation: RenderCancellation): WorkResult = synchronized(storage) {
        if (work !is Work.Preview && work !is Work.HslProbe && work !is Work.Import) return@synchronized perform(work)
        cancellation.check()
        val native = engine()
        val generation = native.cancellationGeneration()
        cancellation.onCancel(native::cancelPreview)
        try {
            cancellation.check()
            perform(work, generation)
        } finally { cancellation.onCancel(null) }
    }

    // 托管文件从解析路径到 native 读取完成期间不能被另一队列删除。
    private fun perform(work: Work, generation: Long = -1L): WorkResult = synchronized(storage) { when (work) {
        is Work.Import -> {
            val photo = work.retained ?: storage.import(work.uri)
            try {
                photo.validateOriginal?.invoke()
                val record = restore(photo.identity)
                val restored = record?.settings ?: if (photo.hdrSource != null)
                    com.rawlab.android.settings.sourceDefaultSettings(true) else null
                if (restored != null && runCatching { storage.lookPath(restored) }.isFailure) {
                    val native = engine()
                    native.setGpuMode(work.gpuMode)
                    val validation = native.preview(photo.file, null, restored.copy(film = "neutral", recipeID = null), 256, false, photo.inputKind, generation)
                    if (debuggable)
                        android.util.Log.i("RawLabImport", "missingLookValidationBackend=${validation.backend}")
                    WorkResult.MissingLook(photo, restored, record)
                } else perform(Work.Preview(photo, restored ?: EditSettings(), false, work.gpuMode,
                    importing = true, restored = record?.settings != null, importedRecord = record), generation)
            }
            catch (error: Throwable) { if (work.retained == null) photo.file.delete(); throw error }
        }
        is Work.Preview -> {
            if (work.photo.hdrSource != null && work.edits.isHDREditing) return performHDR(work, generation)
            if (hdrSource != null) releaseHDRSource()
            val edge = work.edge
            val native = engine()
            native.setGpuMode(work.gpuMode)
            val sourceKey = NeutralSourceKey(work.photo.identity, work.photo.file.absolutePath, work.photo.inputKind, work.edits.processing)
            if (original?.first != sourceKey) {
                original = null
                transformedNeutral = null
                val source = native.preview(work.photo.file, null, EditSettings(processing = work.edits.processing), 1600, false, work.photo.inputKind, generation)
                originalAspect = source.geometryWidth.toFloat() / source.geometryHeight
                original = sourceKey to ReferenceFrame(source.bitmap(), source.histogram)
            }
            val neutral = if (work.edits.geometry.isIdentity && !work.edits.lens.enabled) original!!.second else {
                val key = ComparisonPreviewKey(work.photo.file.absolutePath, work.edits.geometry, work.edits.lens, edge, work.interactive,
                    work.edits.processing, work.photo.identity, work.photo.inputKind)
                if (transformedNeutral?.first != key) {
                    transformedNeutral = null
                    val comparison = EditSettings(geometry = work.edits.geometry, lens = work.edits.lens, processing = work.edits.processing)
                    val frame = native.preview(work.photo.file, null, comparison, edge, work.interactive, work.photo.inputKind, generation)
                    transformedNeutral = key to ReferenceFrame(frame.bitmap(), frame.histogram)
                }
                transformedNeutral!!.second
            }
            val lut = storage.lookPath(work.edits)
            val film = native.preview(work.photo.file, lut, work.edits, edge, work.interactive, work.photo.inputKind, generation)
            val dimensions = comparisonDimensions(film.geometryWidth, film.geometryHeight)
            WorkResult.Preview(work, PreviewPair(neutral.bitmap, film.bitmap(), film.temperature, film.tint, film.lens,
                dimensions.first, dimensions.second, originalAspect, neutral.histogram, film.histogram))
        }
        is Work.HslProbe -> {
            val preview = work.preview
            val sample = runCatching {
                engine().sampleHsl(preview.photo.file, storage.lookPath(preview.edits), preview.edits,
                    preview.edge, preview.interactive, preview.photo.inputKind, work.revision, work.x, work.y, generation)
            }.getOrElse { HslTargetSample.unavailable(work.revision, HslTargetAvailability.FAILED) }
            WorkResult.HslProbe(work, sample)
        }
        is Work.Export -> {
            if (work.photo.hdrSource != null && work.edits.isHDREditing) return performHDRExport(work)
            val output = storage.temporaryOutput(work.format)
            try {
                engine().setGpuMode(work.gpuMode)
                engine().export(work.photo.file, storage.lookPath(work.edits), work.edits, output, work.format, work.longEdge, work.photo.inputKind)
                if (work.destination == null) storage.saveAlbum(output, work.format)
                else storage.saveDocument(output, work.destination, work.photo.uri)
            } finally { output.delete() }
            WorkResult.Export
        }
        is Work.AutoExposure -> WorkResult.AutoExposure(work,
            engine().autoExposure(work.photo.file, work.edits, work.photo.inputKind))
    } }

    private fun performHDR(work: Work.Preview, generation: Long): WorkResult = synchronized(storage) {
        if (work.gpuMode == NativeProcessor.FORCE)
            throw com.rawlab.android.engine.HDRProcessingException(2,13,6)
        val info = checkNotNull(work.photo.hdrSource)
        val native = engine()
        native.setGpuMode(NativeProcessor.CPU)
        val key = Triple(work.photo.file.canonicalPath, work.photo.file.length(), work.photo.file.lastModified())
        if (hdrSourceKey != key || hdrSource?.sourceInfo?.fingerprint?.contentEquals(info.fingerprint) != true) {
            releaseHDRSource()
            hdrSourceLease=com.rawlab.android.engine.HDRSourceCache.acquire(work.photo.file,info,1600)
            hdrSource=hdrSourceLease!!.image;hdrSourceKey=key
        }
        val source = checkNotNull(hdrSource)
        run {
            val geometry = work.edits.geometry
            val canvas=NativeHDRBridge.geometrySize(info,geometry)
            val edge=com.rawlab.android.engine.HDRPreviewBudget.edge(canvas[0],canvas[1],work.edge.coerceIn(1,1600))
            val neutralSettings = HDRSettings(mode = work.edits.hdr?.mode ?: com.rawlab.android.settings.HDRMode.SDR, geometry = geometry)
            val resultSettings = (work.edits.hdr ?: HDRSettings(mode = com.rawlab.android.settings.HDRMode.SDR)).copy(geometry = geometry)
            val neutral = native.renderHDR(source, neutralSettings, edge, generation)
            val result = try { native.renderHDR(source, resultSettings, edge, generation) }
            catch (error: Throwable) { neutral.close(); throw error }
            try {
                val neutralFrame = neutral.snapshot()
                val resultFrame = result.snapshot()
                val dimensions = comparisonDimensions(resultFrame.nativeWidth, resultFrame.nativeHeight)
                WorkResult.Preview(work, PreviewPair(
                    sdrBitmap(neutralFrame), sdrBitmap(resultFrame), Float.NaN, Float.NaN,
                    null, dimensions.first, dimensions.second,
                    (if (info.orientation >= 5) info.height.toFloat() / info.width else info.width.toFloat() / info.height), null, null,
                    HDRPreview(neutralFrame, resultFrame)))
            } finally {
                result.close(); neutral.close()
            }
        }
    }

    private fun performHDRExport(work: Work.Export): WorkResult = synchronized(storage) {
        releaseDecodedRaster()
        if (work.gpuMode == NativeProcessor.FORCE)
            throw com.rawlab.android.engine.HDRProcessingException(2,13,6)
        val info = checkNotNull(work.photo.hdrSource)
        val native = engine()
        native.setGpuMode(NativeProcessor.CPU)
        val source = NativeHDRBridge.decode(work.photo.file, info, 0)
        val settings = (work.edits.hdr ?: HDRSettings(mode = com.rawlab.android.settings.HDRMode.SDR))
            .copy(geometry = work.edits.geometry)
        val rendered = try { native.renderHDR(source, settings, work.longEdge ?: 0) } finally { source.close() }
        val output = storage.temporaryOutput(work.format)
        try {
            if (work.format == ExportFormat.HDR_JPEG)
                NativeHDRBridge.exportJpeg(rendered, work.photo.file, output)
            else NativeHDRBridge.exportSdr(rendered, work.photo.file, output, work.format.nativeValue)
            if (work.destination == null) storage.saveAlbum(output, work.format)
            else storage.saveDocument(output, work.destination, work.photo.uri)
        } finally {
            rendered.close(); output.delete()
        }
        WorkResult.Export
    }

    private fun sdrBitmap(frame: HDRPreviewFrame): Bitmap {
        val pixels = IntArray(frame.width * frame.height)
        for (index in pixels.indices) {
            val base = index * 3
            val r = encodeSrgb(frame.sdr[base]).times(255f).roundToInt().coerceIn(0, 255)
            val g = encodeSrgb(frame.sdr[base + 1]).times(255f).roundToInt().coerceIn(0, 255)
            val b = encodeSrgb(frame.sdr[base + 2]).times(255f).roundToInt().coerceIn(0, 255)
            pixels[index] = (255 shl 24) or (r shl 16) or (g shl 8) or b
        }
        return Bitmap.createBitmap(pixels, frame.width, frame.height, Bitmap.Config.ARGB_8888)
    }

    private fun encodeSrgb(value: Float): Float {
        val v = value.coerceIn(0f, 1f)
        return if (v <= .0031308f) 12.92f * v else 1.055f * v.toDouble().pow(1.0 / 2.4).toFloat() - .055f
    }
}
