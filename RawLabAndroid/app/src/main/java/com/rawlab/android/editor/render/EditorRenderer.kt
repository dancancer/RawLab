package com.rawlab.android.editor.render

import android.graphics.Bitmap
import com.rawlab.android.engine.NativeProcessor
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

    fun close() { processor?.close() }
    fun releaseDecodedRaster() { processor?.releaseRasterCache() }

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
                val restored = record?.settings
                if (restored != null && runCatching { storage.lookPath(restored) }.isFailure) {
                    val native = engine()
                    native.setGpuMode(work.gpuMode)
                    val validation = native.preview(photo.file, null, restored.copy(film = "neutral", recipeID = null), 256, false, photo.inputKind, generation)
                    if (debuggable)
                        android.util.Log.i("RawLabImport", "missingLookValidationBackend=${validation.backend}")
                    WorkResult.MissingLook(photo, restored, record)
                } else perform(Work.Preview(photo, restored ?: EditSettings(), false, work.gpuMode,
                    importing = true, restored = restored != null, importedRecord = record), generation)
            }
            catch (error: Throwable) { if (work.retained == null) photo.file.delete(); throw error }
        }
        is Work.Preview -> {
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
            val output = storage.temporaryOutput(work.format)
            try {
                engine().setGpuMode(work.gpuMode)
                engine().export(work.photo.file, storage.lookPath(work.edits), work.edits, output, work.format, work.longEdge, work.photo.inputKind)
                if (work.destination == null) storage.saveAlbum(output, work.format)
                else storage.saveDocument(output, work.destination, work.photo.uri)
            } finally { output.delete() }
            WorkResult.Export
        }
        is Work.AutoExposure -> WorkResult.AutoExposure(work, engine().autoExposure(work.photo.file, work.edits, work.photo.inputKind))
    } }
}
