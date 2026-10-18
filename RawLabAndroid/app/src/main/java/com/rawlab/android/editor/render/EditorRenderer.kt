package com.rawlab.android.editor.render

import android.graphics.Bitmap
import java.io.File
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity

// ============================================================================
//  编辑器的渲染执行：只在渲染队列的线程上调用
//  缓存原图与几何对比图；原生处理器懒创建，队列释放时关闭
// ============================================================================

internal class EditorRenderer(
    private val storage: PhotoStorage,
    private val restore: (PhotoIdentity) -> EditSettings?,
    private val debuggable: Boolean,
) {
    private var processor: NativeProcessor? = null
    private var original: Pair<File, Bitmap>? = null
    private var originalAspect = 1f
    private var transformedNeutral: Pair<ComparisonPreviewKey, Bitmap>? = null

    fun close() { processor?.close() }

    private fun engine() = processor ?: NativeProcessor(lensDatabase = storage.lensDatabase()).also { processor = it }

    // 托管文件从解析路径到 native 读取完成期间不能被另一队列删除。
    fun perform(work: Work): WorkResult = synchronized(storage) { when (work) {
        is Work.Import -> {
            val photo = storage.import(work.uri)
            val restored = restore(photo.identity)
            try {
                if (restored != null && runCatching { storage.lookPath(restored) }.isFailure) {
                    val native = engine()
                    native.setGpuMode(work.gpuMode)
                    val validation = native.preview(photo.file, null, restored.copy(film = "neutral", recipeID = null), 256, false, photo.inputKind)
                    if (debuggable)
                        android.util.Log.i("RawLabImport", "missingLookValidationBackend=${validation.backend}")
                    WorkResult.MissingLook(photo, restored)
                } else perform(Work.Preview(photo, restored ?: EditSettings(), false, work.gpuMode,
                    importing = true, restored = restored != null))
            }
            catch (error: Throwable) { photo.file.delete(); throw error }
        }
        is Work.Preview -> {
            val edge = work.edge
            val native = engine()
            native.setGpuMode(work.gpuMode)
            if (original?.first != work.photo.file) {
                original = null
                transformedNeutral = null
                val source = native.preview(work.photo.file, null, EditSettings(), 1600, false, work.photo.inputKind)
                originalAspect = source.geometryWidth.toFloat() / source.geometryHeight
                original = work.photo.file to source.bitmap()
            }
            val neutral = if (work.edits.geometry.isIdentity && !work.edits.lens.enabled) original!!.second else {
                val key = ComparisonPreviewKey(work.photo.file.path, work.edits.geometry, work.edits.lens, edge, work.interactive)
                if (transformedNeutral?.first != key) {
                    transformedNeutral = null
                    val comparison = EditSettings(geometry = work.edits.geometry, lens = work.edits.lens)
                    transformedNeutral = key to native.preview(work.photo.file, null, comparison, edge, work.interactive, work.photo.inputKind).bitmap()
                }
                transformedNeutral!!.second
            }
            val lut = storage.lookPath(work.edits)
            val film = native.preview(work.photo.file, lut, work.edits, edge, work.interactive, work.photo.inputKind)
            val dimensions = comparisonDimensions(film.geometryWidth, film.geometryHeight)
            WorkResult.Preview(work, PreviewPair(neutral, film.bitmap(), film.temperature, film.tint, film.lens,
                dimensions.first, dimensions.second, originalAspect))
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
