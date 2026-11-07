package com.rawlab.android.editor.render

import android.graphics.Bitmap
import android.system.Os
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.engine.NativeHDRBridge
import com.rawlab.android.engine.HDRDisplayMath
import com.rawlab.android.settings.HDRSettings
import com.rawlab.android.settings.withHDRMode
import com.rawlab.android.settings.requireProRAWDecoder
import com.rawlab.android.format.ExportFormat
import kotlin.math.pow
import kotlin.math.roundToInt
import com.rawlab.android.engine.RgbHistogram
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.HslTargetAvailability
import com.rawlab.android.settings.HslTargetSample
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.VersionedPhotoEdit
import java.io.File
import java.util.IdentityHashMap

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
    private data class FileStamp(val path: String, val device: Long, val inode: Long, val size: Long, val modified: Long) {
        companion object {
            fun read(file: File): FileStamp? = runCatching {
                val path = file.canonicalPath
                val stat = Os.stat(path)
                FileStamp(path, stat.st_dev, stat.st_ino, stat.st_size, file.lastModified())
            }.getOrNull()
        }
    }
    private data class PreviewScope(val photo: ImportedPhoto, val source: FileStamp, val lut: FileStamp?,
        val edits: EditSettings, val gpuMode: Int)
    private var previewScope: PreviewScope? = null
    private val previews = LinkedHashMap<Int, PreviewPair>(3, .75f, true)
    private val heapLimit = Runtime.getRuntime().maxMemory()

    private data class HDRReferenceKey(val source: FileStamp, val photo: ImportedPhoto, val settings: HDRSettings,
        val edge: Int, val decodeVersion: Int?)
    private data class HDRReference(val frame: HDRPreviewFrame, val bitmap: Bitmap)
    private var hdrReference: Pair<HDRReferenceKey, HDRReference>? = null
    private var hdrSource: com.rawlab.android.engine.NativeHDRImage? = null
    private var hdrSourceLease: com.rawlab.android.engine.HDRSourceLease? = null
    private var hdrSourceKey: Triple<String, Long, Long>? = null

    fun close() { releaseDecodedRaster();com.rawlab.android.engine.HDRSourceCache.clear();processor?.close() }
    private fun releaseHDRSource() {hdrSourceLease?.close();hdrSourceLease=null;hdrSource=null;hdrSourceKey=null;hdrReference=null}
    fun releaseDecodedRaster() {
        previews.clear(); previewScope = null
        processor?.releaseRasterCache(); releaseHDRSource()
    }

    private fun engine() = processor ?: NativeProcessor(lensDatabase = storage.lensDatabase()).also { processor = it }

    fun perform(work: Work, cancellation: RenderCancellation): WorkResult = synchronized(storage) {
        if (work !is Work.Preview && work !is Work.HslProbe && work !is Work.Import && work !is Work.CameraHDRPreflight && work !is Work.Export)
            return@synchronized perform(work)
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
            val owned = work.retained == null || work.ownsRetained
            var canRetryLegacy = false
            try {
                photo.validateOriginal?.invoke()
                val record = restore(photo.identity)
                var restored = record?.settings ?: if (photo.hdrSource != null)
                    photo.defaultEditSettings() else null
                if (record == null && work.x3fModeOverride == null && photo.isX3f) {
                    val mode = NativeProcessor.x3fDefaultMode(photo.file)
                    if (mode == com.rawlab.android.settings.X3fMode.LEGACY)
                        restored = (restored ?: EditSettings()).copy(x3fMode = mode)
                }
                if (work.x3fModeOverride != null) restored = (restored ?: EditSettings()).copy(x3fMode = work.x3fModeOverride)
                canRetryLegacy = photo.isX3f && (restored ?: EditSettings()).x3fMode == com.rawlab.android.settings.X3fMode.NORMAL
                if (restored != null && !restored.isHDREditing && runCatching { storage.lookPath(restored) }.isFailure) {
                    val native = engine()
                    native.setGpuMode(work.gpuMode)
                    val validation = native.preview(photo.file, null, restored.copy(film = "neutral", recipeID = null), 256, false, photo.inputKind, generation)
                    if (debuggable)
                        android.util.Log.i("RawLabImport", "missingLookValidationBackend=${validation.backend}")
                    WorkResult.MissingLook(photo, restored, record, work.x3fModeOverride != null, owned)
                } else perform(Work.Preview(photo, restored ?: EditSettings(), false, work.gpuMode,
                    importing = true, restored = record?.settings != null, importedRecord = record,
                    persistOnImport = work.x3fModeOverride != null, ownsImportedInput = owned), generation)
            }
            catch (error: Throwable) {
                if (canRetryLegacy && error !is java.util.concurrent.CancellationException && error !is OutOfMemoryError)
                    WorkResult.X3fImportFailure(work.copy(retained = photo, ownsRetained = owned,
                        x3fModeOverride = com.rawlab.android.settings.X3fMode.LEGACY), error)
                else { if (owned) photo.file.delete(); throw error }
            }
        }
        is Work.Preview -> WorkResult.Preview(work, preview(work, generation))
        is Work.HslProbe -> {
            val preview = work.preview
            val sample = runCatching {
                engine().sampleHsl(preview.photo.file, storage.lookPath(preview.edits), preview.edits,
                    preview.edge, preview.interactive, preview.photo.inputKind, work.revision, work.x, work.y, generation)
            }.getOrElse { HslTargetSample.unavailable(work.revision, HslTargetAvailability.FAILED) }
            WorkResult.HslProbe(work, sample)
        }
        is Work.CameraHDRPreflight -> performCameraHDRPreflight(work, generation)
        is Work.Export -> {
            if (work.photo.hdrSource != null && work.edits.isHDREditing) return performHDRExport(work, generation)
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

    private fun preview(work: Work.Preview, generation: Long): PreviewPair {
        val hdr = work.photo.hdrSource != null && work.edits.isHDREditing
        val lut = if (hdr) null else storage.lookPath(work.edits)
        val source = FileStamp.read(work.photo.file)
        val lutStamp = lut?.let { FileStamp.read(it) }
        // 拍摄白平衡的显示值会随首帧回填；配方的相对色调仍是渲染输入。
        val edits = if (work.edits.customWb) work.edits else work.edits.copy(temperature = 6500f,
            tint = if (work.edits.recipeID == null) 0f else work.edits.tint)
        val scope = if (work.interactive || work.draft || source == null || (lut != null && lutStamp == null)) null
            else PreviewScope(work.photo, source, lutStamp, edits, work.gpuMode)
        if (previewScope != scope) {
            previews.clear()
            previewScope = scope
        }
        if (scope != null) previews[work.edge]?.let { return it }

        val pair = if (hdr) performHDR(work, source, generation) else performSDR(work, lut, generation)
        if (scope != null && (pair.hdr != null || pair.resultHistogram != null && pair.neutralHistogram != null)) {
            val previewBudget = if (pair.hdr != null) minOf(128L * 1024 * 1024, heapLimit / 3)
                else minOf(64L * 1024 * 1024, heapLimit / 8)
            if (previewBytes(listOf(pair)) <= previewBudget) {
                while (previews.size >= 3 || previewBytes(previews.values + pair) > previewBudget) {
                    previews.remove(previews.keys.first())
                }
                previews[work.edge] = pair
            }
        }
        return pair
    }

    private fun previewBytes(pairs: List<PreviewPair>): Long {
        val bitmaps = IdentityHashMap<Bitmap, Unit>()
        val planes = IdentityHashMap<FloatArray, Unit>()
        for (pair in pairs) {
            bitmaps[pair.neutral] = Unit
            bitmaps[pair.result] = Unit
            pair.hdr?.let {
                for (frame in listOf(it.neutral, it.result)) {
                    planes[frame.hdr] = Unit
                    planes[frame.sdr] = Unit
                }
            }
        }
        // 原图由现有参考缓存持有。其他共用的对照帧只计算一次实际分配。
        original?.second?.bitmap?.let(bitmaps::remove)
        return bitmaps.keys.sumOf { it.allocationByteCount.toLong() } +
            planes.keys.sumOf { it.size.toLong() * Float.SIZE_BYTES }
    }

    private fun performSDR(work: Work.Preview, lut: File?, generation: Long): PreviewPair {
        if (hdrSource != null) releaseHDRSource()
        val edge = work.edge
        val native = engine()
        native.setGpuMode(work.gpuMode)
        val sourceKey = NeutralSourceKey(work.photo.identity, work.photo.file.absolutePath, work.photo.inputKind, work.edits.processing, work.edits.x3fMode)
        if (original?.first != sourceKey) {
            original = null
            transformedNeutral = null
            val source = native.preview(work.photo.file, null, EditSettings(processing = work.edits.processing, x3fMode = work.edits.x3fMode), 1600, false, work.photo.inputKind, generation)
            originalAspect = source.geometryWidth.toFloat() / source.geometryHeight
            original = sourceKey to ReferenceFrame(source.bitmap(), source.histogram)
        }
        val neutral = if (work.edits.geometry.isIdentity && !work.edits.lens.enabled) original!!.second else {
            val key = ComparisonPreviewKey(work.photo.file.absolutePath, work.edits.geometry, work.edits.lens, edge, work.interactive,
                work.edits.processing, work.photo.identity, work.photo.inputKind, work.edits.x3fMode)
            if (transformedNeutral?.first != key) {
                transformedNeutral = null
                val comparison = EditSettings(geometry = work.edits.geometry, lens = work.edits.lens, processing = work.edits.processing, x3fMode = work.edits.x3fMode)
                val frame = native.preview(work.photo.file, null, comparison, edge, work.interactive, work.photo.inputKind, generation)
                transformedNeutral = key to ReferenceFrame(frame.bitmap(), frame.histogram)
            }
            transformedNeutral!!.second
        }
        val film = native.preview(work.photo.file, lut, work.edits, edge, work.interactive, work.photo.inputKind, generation)
        val dimensions = comparisonDimensions(film.geometryWidth, film.geometryHeight)
        return PreviewPair(neutral.bitmap, film.bitmap(), film.temperature, film.tint, film.lens,
            dimensions.first, dimensions.second, originalAspect, neutral.histogram, film.histogram)
    }

    private fun performHDR(work: Work.Preview, stamp: FileStamp?, generation: Long): PreviewPair {
        if (work.gpuMode == NativeProcessor.FORCE)
            throw com.rawlab.android.engine.HDRProcessingException(2,13,6)
        val info = checkNotNull(work.photo.hdrSource)
        if (info.isProRAW) work.edits.requireProRAWDecoder()
        val native = engine()
        native.setGpuMode(NativeProcessor.CPU)
        val key = Triple(work.photo.file.canonicalPath, work.photo.file.length(), work.photo.file.lastModified())
        val geometry = work.edits.geometry
        val canvas=NativeHDRBridge.geometrySize(info,geometry)
        val edge=com.rawlab.android.engine.HDRPreviewBudget.edge(canvas[0],canvas[1],work.edge.coerceIn(1,1600))
        val source = if (info.isCameraRaw) {
            if (hdrSourceKey != key || hdrSource?.sourceInfo?.cameraStamp != info.cameraStamp) {
                releaseHDRSource()
                hdrSourceLease = com.rawlab.android.engine.HDRSourceCache.acquire(work.photo.file, info, 1600) {
                    native.decodeHDRCamera(work.photo.file, info, 1600, generation)
                }
                hdrSource = hdrSourceLease!!.image
                hdrSourceKey = key
            }
            checkNotNull(hdrSource)
        } else {
            if (hdrSourceKey != key || hdrSource?.sourceInfo?.fingerprint?.contentEquals(info.fingerprint) != true) {
                releaseHDRSource()
                hdrSourceLease=com.rawlab.android.engine.HDRSourceCache.acquire(work.photo.file,info,1600)
                hdrSource=hdrSourceLease!!.image;hdrSourceKey=key
            }
            checkNotNull(hdrSource)
        }
        val neutralSettings = HDRSettings(mode = work.edits.hdr?.mode ?: com.rawlab.android.settings.HDRMode.SDR, geometry = geometry)
        val resultSettings = (work.edits.hdr ?: HDRSettings(mode = com.rawlab.android.settings.HDRMode.SDR)).copy(geometry = geometry)
        val referenceKey = stamp?.let { HDRReferenceKey(it, work.photo, neutralSettings, edge, work.edits.proRAWDecodeVersion) }
        val reference = hdrReference?.takeIf { it.first == referenceKey }?.second ?: run {
            native.renderHDR(source, neutralSettings, edge, generation).use { neutral ->
                val frame = neutral.snapshot()
                HDRReference(frame, sdrBitmap(frame)).also { hdrReference = referenceKey?.let { key -> key to it } }
            }
        }
        native.renderHDR(source, resultSettings, edge, generation).use { result ->
            val resultFrame = result.snapshot()
            val dimensions = comparisonDimensions(resultFrame.nativeWidth, resultFrame.nativeHeight)
            return PreviewPair(
                reference.bitmap, sdrBitmap(resultFrame), Float.NaN, Float.NaN,
                null, dimensions.first, dimensions.second,
                (if (info.orientation >= 5) info.height.toFloat() / info.width else info.width.toFloat() / info.height), null, null,
                HDRPreview(reference.frame, resultFrame))
        }
    }

    private fun performCameraHDRPreflight(work: Work.CameraHDRPreflight, generation: Long): WorkResult {
        if (work.gpuMode == NativeProcessor.FORCE)
            throw com.rawlab.android.engine.HDRProcessingException(2,13,6)
        val info = checkNotNull(work.photo.hdrSource?.takeIf { it.isCameraRaw })
        if (info.isProRAW) work.edits.requireProRAWDecoder()
        val native = engine()
        native.setGpuMode(NativeProcessor.CPU)
        val canvas = NativeHDRBridge.geometrySize(info, work.edits.geometry)
        val edge = com.rawlab.android.engine.HDRPreviewBudget.edge(canvas[0], canvas[1], work.edge.coerceIn(1, 1600))
        val source = native.decodeHDRCamera(work.photo.file, info, edge, generation)
        try {
            val settings = (work.edits.hdr ?: HDRSettings()).copy(geometry = work.edits.geometry)
            native.renderHDR(source, settings, edge, generation).close()
        } finally { source.close() }
        return WorkResult.CameraHDRPreflight(work)
    }

    private fun performHDRExport(work: Work.Export, generation: Long): WorkResult = synchronized(storage) {
        releaseDecodedRaster()
        if (work.gpuMode == NativeProcessor.FORCE)
            throw com.rawlab.android.engine.HDRProcessingException(2,13,6)
        val info = checkNotNull(work.photo.hdrSource)
        if (info.isProRAW) work.edits.requireProRAWDecoder()
        val native = engine()
        native.setGpuMode(NativeProcessor.CPU)
        if (info.isProRAW && work.format in setOf(ExportFormat.HDR_JPEG, ExportFormat.JPEG)) {
            com.rawlab.android.engine.HDRSourceCache.clear()
            val output = storage.temporaryOutput(work.format)
            try {
                native.exportProRAW(work.photo.file, info, work.edits, output,
                    work.format == ExportFormat.HDR_JPEG, work.longEdge ?: 0, generation)
                if (generation >= 0 && native.cancellationGeneration() != generation) throw java.util.concurrent.CancellationException()
                if (work.destination == null) storage.saveAlbum(output, work.format)
                else storage.saveDocument(output, work.destination, work.photo.uri)
            } finally { output.delete() }
            return WorkResult.Export
        }
        val source = if (info.isCameraRaw) native.decodeHDRCamera(work.photo.file, info, 0, generation) else
            NativeHDRBridge.decode(work.photo.file, info, 0)
        val settings = (work.edits.hdr ?: HDRSettings(mode = com.rawlab.android.settings.HDRMode.SDR))
            .copy(geometry = work.edits.geometry)
        val rendered = try { native.renderHDR(source, settings, work.longEdge ?: 0, generation) } finally { source.close() }
        val output = storage.temporaryOutput(work.format)
        try {
            val metadataSource = work.photo.hdrSource?.takeUnless { it.isCameraRaw && !it.isProRAW }?.let { work.photo.file }
            if (work.format == ExportFormat.HDR_JPEG)
                NativeHDRBridge.exportJpeg(rendered, metadataSource, output)
            else NativeHDRBridge.exportSdr(rendered, metadataSource, output, work.format.nativeValue)
            if (generation >= 0 && native.cancellationGeneration() != generation) throw java.util.concurrent.CancellationException()
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
