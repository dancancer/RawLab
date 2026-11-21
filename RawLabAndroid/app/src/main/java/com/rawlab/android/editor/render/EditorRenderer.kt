package com.rawlab.android.editor.render

import android.graphics.Bitmap
import android.system.Os
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.engine.HDRProgressListener
import com.rawlab.android.engine.NativeHDRBridge
import com.rawlab.android.photo.HDRSourceInfo
import com.rawlab.android.engine.NativeHDRImage
import com.rawlab.android.engine.HDRDisplayMath
import com.rawlab.android.engine.requireAsset
import com.rawlab.android.settings.HDRSettings
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.withHDRMode
import com.rawlab.android.settings.requireProRAWDecoder
import com.rawlab.android.settings.requireHDRDecodeVersion
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.engine.NativeFrame
import com.rawlab.android.engine.NativeRoiBounds
import com.rawlab.android.engine.NativeRoiFrame
import com.rawlab.android.engine.RgbHistogram
import com.rawlab.android.editor.canvas.NormalizedRect
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.HslTargetAvailability
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.HslTargetSample
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.PhotoEditState
import java.io.Closeable
import java.io.File
import java.util.IdentityHashMap

// ============================================================================
//  编辑器的渲染执行：只在渲染队列的线程上调用
//  缓存原图与几何对比图；原生处理器懒创建，队列释放时关闭
// ============================================================================

internal class EditorRenderer(
    private val storage: PhotoStorage,
    private val restore: (PhotoIdentity) -> PhotoEditState?,
    private val debuggable: Boolean,
    private val destinationDeleter: ExportDestinationDeleter = ExportDestinationDeleter { destination, original ->
        storage.deleteIncompleteDocument(destination, original)
    },
    private val engineFactory: () -> RenderEngine = { NativeRenderEngine(NativeProcessor(lensDatabase = storage.lensDatabase())) },
    private val hdrBridge: HdrRenderBridge = NativeHdrRenderBridge,
) {
    internal interface HdrImageHandle : Closeable {
        val sourceInfo: HDRSourceInfo
        val outputNativeWidth: Int
        val outputNativeHeight: Int
        fun snapshot(): HDRPreviewFrame
        fun snapshot(headroomOverride: Float): HDRPreviewFrame = snapshot()
        fun sdrBitmap(): Bitmap
    }

    internal class HdrRoiHandle(val image: HdrImageHandle, val bounds: NativeRoiBounds)

    internal interface RenderEngine : Closeable {
        fun setGpuMode(mode: Int)
        fun cancellationGeneration(): Long
        fun cancelPreview()
        fun releaseRasterCache()
        fun preview(
            input: File,
            lut: File?,
            settings: EditSettings,
            edge: Int,
            interactive: Boolean,
            inputKind: PhotoInputKind,
            cancellationGeneration: Long = -1L,
        ): NativeFrame
        fun previewRoi(
            input: File,
            lut: File?,
            settings: EditSettings,
            x0: Float,
            y0: Float,
            x1: Float,
            y1: Float,
            maxOutputLongEdge: Int,
            inputKind: PhotoInputKind,
            cancellationGeneration: Long = -1L,
        ): NativeRoiFrame = throw UnsupportedOperationException("previewRoi")
        fun sampleHsl(
            input: File,
            lut: File?,
            settings: EditSettings,
            edge: Int,
            interactive: Boolean,
            inputKind: PhotoInputKind,
            revision: HslTargetRevision,
            x: Float,
            y: Float,
            cancellationGeneration: Long = -1L,
        ): HslTargetSample
        fun export(
            input: File,
            lut: File?,
            settings: EditSettings,
            output: File,
            format: ExportFormat,
            longEdge: Int?,
            inputKind: PhotoInputKind,
            cancellationGeneration: Long = -1L,
        ): Int
        fun autoExposure(input: File, settings: EditSettings, inputKind: PhotoInputKind): Float
        fun decodeHDRCamera(
            file: File,
            info: HDRSourceInfo,
            edge: Int,
            cancellationGeneration: Long = -1L,
            camera: HDRCameraDevelopmentSettings = HDRCameraDevelopmentSettings(),
            profileDirectory: File? = null,
        ): HdrImageHandle
        fun decodeHDRCamera(
            file: File,
            info: HDRSourceInfo,
            edge: Int,
            cancellationGeneration: Long,
            camera: HDRCameraDevelopmentSettings,
            profileDirectory: File?,
            progress: HDRProgressListener?,
        ): HdrImageHandle = decodeHDRCamera(file, info, edge, cancellationGeneration, camera, profileDirectory)
        fun renderHDR(
            source: HdrImageHandle,
            settings: HDRSettings,
            edge: Int,
            cancellationGeneration: Long = -1L,
            lookDirectory: File? = null,
        ): HdrImageHandle
        fun renderHDR(
            source: HdrImageHandle,
            settings: HDRSettings,
            edge: Int,
            cancellationGeneration: Long,
            lookDirectory: File?,
            progress: HDRProgressListener?,
        ): HdrImageHandle = renderHDR(source, settings, edge, cancellationGeneration, lookDirectory)
        fun renderHDRRoi(
            source: HdrImageHandle,
            settings: HDRSettings,
            x0: Float,
            y0: Float,
            x1: Float,
            y1: Float,
            maxOutputLongEdge: Int,
            baseContentHeadroom: Float,
            cancellationGeneration: Long = -1L,
            lookDirectory: File? = null,
        ): HdrRoiHandle = throw UnsupportedOperationException("renderHDRRoi")
        fun renderHDRCameraRawRoi(
            file: File,
            info: HDRSourceInfo,
            settings: HDRSettings,
            x0: Float,
            y0: Float,
            x1: Float,
            y1: Float,
            maxOutputLongEdge: Int,
            baseContentHeadroom: Float,
            cancellationGeneration: Long = -1L,
            lookDirectory: File? = null,
            profileDirectory: File? = null,
        ): HdrRoiHandle = throw UnsupportedOperationException("renderHDRCameraRawRoi")
        fun renderHDRFileRoi(
            file: File,
            info: HDRSourceInfo,
            settings: HDRSettings,
            x0: Float,
            y0: Float,
            x1: Float,
            y1: Float,
            maxOutputLongEdge: Int,
            baseContentHeadroom: Float,
            cancellationGeneration: Long = -1L,
            lookDirectory: File? = null,
        ): HdrRoiHandle = throw UnsupportedOperationException("renderHDRFileRoi")
        fun clearHDRSessionCache() = Unit
        fun sampleHDRHsl(
            source: HdrImageHandle,
            settings: HDRSettings,
            edge: Int,
            revision: HslTargetRevision,
            x: Float,
            y: Float,
            cancellationGeneration: Long,
            lookDirectory: File? = null,
        ): HslTargetSample
        fun estimateHDRExposure(source: HdrImageHandle, settings: HDRSettings, cancellationGeneration: Long): Float
        fun exportProRAW(
            file: File,
            info: HDRSourceInfo,
            edits: EditSettings,
            output: File,
            keepHDR: Boolean,
            edge: Int,
            cancellationGeneration: Long = -1L,
            lookDirectory: File? = null,
        )
        fun exportProRAW(
            file: File,
            info: HDRSourceInfo,
            edits: EditSettings,
            output: File,
            keepHDR: Boolean,
            edge: Int,
            cancellationGeneration: Long,
            lookDirectory: File?,
            progress: HDRProgressListener?,
        ) = exportProRAW(file, info, edits, output, keepHDR, edge, cancellationGeneration, lookDirectory)
        fun sessionHandle(): Long = 0L
    }

    internal interface HdrSourceHandle : Closeable {
        val image: HdrImageHandle
    }

    internal interface HdrRenderBridge {
        fun cameraFraming(file: File, info: HDRSourceInfo, processingVersion: Int): HDRSourceInfo
        fun geometrySize(info: HDRSourceInfo, geometry: GeometrySettings): IntArray
        fun acquireCamera(
            file: File,
            info: HDRSourceInfo,
            edge: Int,
            camera: HDRCameraDevelopmentSettings?,
            lensDatabase: File?,
            decode: () -> HdrImageHandle,
        ): HdrSourceHandle
        fun acquireGainMap(file: File, info: HDRSourceInfo, edge: Int): HdrSourceHandle
        fun decodeGainMap(file: File, info: HDRSourceInfo, edge: Int): HdrImageHandle
        fun decodeGainMap(
            file: File,
            info: HDRSourceInfo,
            edge: Int,
            sessionHandle: Long,
            cancellationGeneration: Long,
            progress: HDRProgressListener?,
        ): HdrImageHandle = decodeGainMap(file, info, edge)
        fun exportJpeg(rendered: HdrImageHandle, metadataSource: File?, output: File)
        fun exportJpeg(
            rendered: HdrImageHandle,
            metadataSource: File?,
            output: File,
            sessionHandle: Long,
            cancellationGeneration: Long,
            progress: HDRProgressListener?,
        ) = exportJpeg(rendered, metadataSource, output)
        fun exportSdr(rendered: HdrImageHandle, metadataSource: File?, output: File, format: Int)
        fun exportSdr(
            rendered: HdrImageHandle,
            metadataSource: File?,
            output: File,
            format: Int,
            sessionHandle: Long,
            cancellationGeneration: Long,
            progress: HDRProgressListener?,
        ) = exportSdr(rendered, metadataSource, output, format)
        fun clearCache()
    }

    private class NativeHdrImageHandle(val underlying: NativeHDRImage) : HdrImageHandle {
        override val sourceInfo: HDRSourceInfo get() = underlying.sourceInfo
        override val outputNativeWidth: Int get() = underlying.outputNativeWidth
        override val outputNativeHeight: Int get() = underlying.outputNativeHeight
        override fun snapshot(): HDRPreviewFrame = underlying.snapshot(0f)
        override fun snapshot(headroomOverride: Float): HDRPreviewFrame = underlying.snapshot(headroomOverride)
        override fun sdrBitmap(): Bitmap = underlying.sdrBitmap()
        override fun close() = underlying.close()
    }

    private class NativeRenderEngine(private val native: NativeProcessor) : RenderEngine {
        override fun setGpuMode(mode: Int) = native.setGpuMode(mode)
        override fun cancellationGeneration(): Long = native.cancellationGeneration()
        override fun cancelPreview() = native.cancelPreview()
        override fun releaseRasterCache() = native.releaseRasterCache()
        override fun preview(
            input: File,
            lut: File?,
            settings: EditSettings,
            edge: Int,
            interactive: Boolean,
            inputKind: PhotoInputKind,
            cancellationGeneration: Long,
        ): NativeFrame = native.preview(input, lut, settings, edge, interactive, inputKind, cancellationGeneration)
        override fun previewRoi(
            input: File,
            lut: File?,
            settings: EditSettings,
            x0: Float,
            y0: Float,
            x1: Float,
            y1: Float,
            maxOutputLongEdge: Int,
            inputKind: PhotoInputKind,
            cancellationGeneration: Long,
        ): NativeRoiFrame = native.previewRoi(input, lut, settings, x0, y0, x1, y1, maxOutputLongEdge, inputKind, cancellationGeneration)
        override fun sampleHsl(
            input: File,
            lut: File?,
            settings: EditSettings,
            edge: Int,
            interactive: Boolean,
            inputKind: PhotoInputKind,
            revision: HslTargetRevision,
            x: Float,
            y: Float,
            cancellationGeneration: Long,
        ): HslTargetSample = native.sampleHsl(input, lut, settings, edge, interactive, inputKind, revision, x, y, cancellationGeneration)
        override fun export(
            input: File,
            lut: File?,
            settings: EditSettings,
            output: File,
            format: ExportFormat,
            longEdge: Int?,
            inputKind: PhotoInputKind,
            cancellationGeneration: Long,
        ): Int {
            return native.export(input, lut, settings, output, format, longEdge, inputKind, cancellationGeneration)
        }
        override fun autoExposure(input: File, settings: EditSettings, inputKind: PhotoInputKind): Float =
            native.autoExposure(input, settings, inputKind)
        override fun decodeHDRCamera(
            file: File,
            info: HDRSourceInfo,
            edge: Int,
            cancellationGeneration: Long,
            camera: HDRCameraDevelopmentSettings,
            profileDirectory: File?,
        ): HdrImageHandle = decodeHDRCamera(file, info, edge, cancellationGeneration, camera, profileDirectory, null)
        override fun decodeHDRCamera(
            file: File,
            info: HDRSourceInfo,
            edge: Int,
            cancellationGeneration: Long,
            camera: HDRCameraDevelopmentSettings,
            profileDirectory: File?,
            progress: HDRProgressListener?,
        ): HdrImageHandle = NativeHdrImageHandle(
            native.decodeHDRCamera(file, info, edge, cancellationGeneration, camera, profileDirectory, progress)
        )
        override fun renderHDR(
            source: HdrImageHandle,
            settings: HDRSettings,
            edge: Int,
            cancellationGeneration: Long,
            lookDirectory: File?,
        ): HdrImageHandle = renderHDR(source, settings, edge, cancellationGeneration, lookDirectory, null)
        override fun renderHDR(
            source: HdrImageHandle,
            settings: HDRSettings,
            edge: Int,
            cancellationGeneration: Long,
            lookDirectory: File?,
            progress: HDRProgressListener?,
        ): HdrImageHandle = NativeHdrImageHandle(
            native.renderHDR((source as NativeHdrImageHandle).underlying, settings, edge, cancellationGeneration, lookDirectory, progress)
        )
        override fun renderHDRRoi(
            source: HdrImageHandle,
            settings: HDRSettings,
            x0: Float,
            y0: Float,
            x1: Float,
            y1: Float,
            maxOutputLongEdge: Int,
            baseContentHeadroom: Float,
            cancellationGeneration: Long,
            lookDirectory: File?,
        ): HdrRoiHandle = native.renderHDRRoi(
            (source as NativeHdrImageHandle).underlying, settings, x0, y0, x1, y1,
            maxOutputLongEdge, baseContentHeadroom, cancellationGeneration, lookDirectory,
        ).let { HdrRoiHandle(NativeHdrImageHandle(it.image), it.bounds) }
        override fun renderHDRCameraRawRoi(
            file: File,
            info: HDRSourceInfo,
            settings: HDRSettings,
            x0: Float,
            y0: Float,
            x1: Float,
            y1: Float,
            maxOutputLongEdge: Int,
            baseContentHeadroom: Float,
            cancellationGeneration: Long,
            lookDirectory: File?,
            profileDirectory: File?,
        ): HdrRoiHandle = native.renderHDRCameraRawRoi(
            file, info, settings, x0, y0, x1, y1, maxOutputLongEdge, baseContentHeadroom,
            cancellationGeneration, lookDirectory, profileDirectory,
        ).let { HdrRoiHandle(NativeHdrImageHandle(it.image), it.bounds) }
        override fun renderHDRFileRoi(
            file: File,
            info: HDRSourceInfo,
            settings: HDRSettings,
            x0: Float,
            y0: Float,
            x1: Float,
            y1: Float,
            maxOutputLongEdge: Int,
            baseContentHeadroom: Float,
            cancellationGeneration: Long,
            lookDirectory: File?,
        ): HdrRoiHandle = native.renderHDRFileRoi(
            file, info, settings, x0, y0, x1, y1, maxOutputLongEdge, baseContentHeadroom,
            cancellationGeneration, lookDirectory,
        ).let { HdrRoiHandle(NativeHdrImageHandle(it.image), it.bounds) }
        override fun clearHDRSessionCache() = native.clearHDRSessionCache()
        override fun sampleHDRHsl(
            source: HdrImageHandle,
            settings: HDRSettings,
            edge: Int,
            revision: HslTargetRevision,
            x: Float,
            y: Float,
            cancellationGeneration: Long,
            lookDirectory: File?,
        ): HslTargetSample = native.sampleHDRHsl(
            (source as NativeHdrImageHandle).underlying, settings, edge, revision, x, y, cancellationGeneration, lookDirectory
        )
        override fun estimateHDRExposure(source: HdrImageHandle, settings: HDRSettings, cancellationGeneration: Long): Float =
            native.estimateHDRExposure((source as NativeHdrImageHandle).underlying, settings, cancellationGeneration)
        override fun exportProRAW(
            file: File,
            info: HDRSourceInfo,
            edits: EditSettings,
            output: File,
            keepHDR: Boolean,
            edge: Int,
            cancellationGeneration: Long,
            lookDirectory: File?,
        ) = exportProRAW(file, info, edits, output, keepHDR, edge, cancellationGeneration, lookDirectory, null)
        override fun exportProRAW(
            file: File,
            info: HDRSourceInfo,
            edits: EditSettings,
            output: File,
            keepHDR: Boolean,
            edge: Int,
            cancellationGeneration: Long,
            lookDirectory: File?,
            progress: HDRProgressListener?,
        ) = native.exportProRAW(file, info, edits, output, keepHDR, edge, cancellationGeneration, lookDirectory, progress)
        override fun sessionHandle(): Long = native.sessionHandle()
        override fun close() = native.close()
    }

    private object NativeHdrRenderBridge : HdrRenderBridge {
        override fun cameraFraming(file: File, info: HDRSourceInfo, processingVersion: Int): HDRSourceInfo =
            NativeHDRBridge.cameraFraming(file, info, processingVersion)
        override fun geometrySize(info: HDRSourceInfo, geometry: GeometrySettings): IntArray =
            NativeHDRBridge.geometrySize(info, geometry)
        override fun acquireCamera(
            file: File,
            info: HDRSourceInfo,
            edge: Int,
            camera: HDRCameraDevelopmentSettings?,
            lensDatabase: File?,
            decode: () -> HdrImageHandle,
        ): HdrSourceHandle {
            val lease = com.rawlab.android.engine.HDRSourceCache.acquire(file, info, edge, camera, lensDatabase) {
                (decode() as NativeHdrImageHandle).underlying
            }
            return object : HdrSourceHandle {
                override val image: HdrImageHandle = NativeHdrImageHandle(lease.image)
                override fun close() = lease.close()
            }
        }
        override fun acquireGainMap(file: File, info: HDRSourceInfo, edge: Int): HdrSourceHandle {
            val lease = com.rawlab.android.engine.HDRSourceCache.acquire(file, info, edge)
            return object : HdrSourceHandle {
                override val image: HdrImageHandle = NativeHdrImageHandle(lease.image)
                override fun close() = lease.close()
            }
        }
        override fun decodeGainMap(file: File, info: HDRSourceInfo, edge: Int): HdrImageHandle =
            decodeGainMap(file, info, edge, 0L, -1L, null)
        override fun decodeGainMap(
            file: File,
            info: HDRSourceInfo,
            edge: Int,
            sessionHandle: Long,
            cancellationGeneration: Long,
            progress: HDRProgressListener?,
        ): HdrImageHandle = NativeHdrImageHandle(
            NativeHDRBridge.decode(file, info, edge, sessionHandle, cancellationGeneration, progress)
        )
        override fun exportJpeg(rendered: HdrImageHandle, metadataSource: File?, output: File) =
            exportJpeg(rendered, metadataSource, output, 0L, -1L, null)
        override fun exportJpeg(
            rendered: HdrImageHandle,
            metadataSource: File?,
            output: File,
            sessionHandle: Long,
            cancellationGeneration: Long,
            progress: HDRProgressListener?,
        ) = NativeHDRBridge.exportJpeg(
            (rendered as NativeHdrImageHandle).underlying,
            metadataSource,
            output,
            session = sessionHandle,
            cancellationGeneration = cancellationGeneration,
            progress = progress,
        )
        override fun exportSdr(rendered: HdrImageHandle, metadataSource: File?, output: File, format: Int) =
            exportSdr(rendered, metadataSource, output, format, 0L, -1L, null)
        override fun exportSdr(
            rendered: HdrImageHandle,
            metadataSource: File?,
            output: File,
            format: Int,
            sessionHandle: Long,
            cancellationGeneration: Long,
            progress: HDRProgressListener?,
        ) = NativeHDRBridge.exportSdr(
            (rendered as NativeHdrImageHandle).underlying,
            metadataSource,
            output,
            format,
            session = sessionHandle,
            cancellationGeneration = cancellationGeneration,
            progress = progress,
        )
        override fun clearCache() = com.rawlab.android.engine.HDRSourceCache.clear()
    }

    internal var onExportProgress: (Work.Export, Float) -> Unit = { _, _ -> }

    private fun hdrProgressAdapter(
        work: Work.Export,
        startFraction: Float,
        endFraction: Float,
    ): HDRProgressListener {
        val span = endFraction - startFraction
        var lastPermille = -1
        return HDRProgressListener { permille ->
            if (permille == lastPermille) return@HDRProgressListener
            if (lastPermille >= 0 && permille < 1000 && permille - lastPermille < 5) return@HDRProgressListener
            lastPermille = permille
            val local = permille.coerceIn(0, 1000) / 1000f
            onExportProgress(work, (startFraction + local * span).coerceIn(0f, 1f))
        }
    }

    private var processor: RenderEngine? = null
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

    private data class HDRReference(val frame: HDRPreviewFrame, val bitmap: Bitmap)
    private val hdrReference = HDRReferenceCoordinator<FileStamp, HDRReference>()
    private var hdrSource: HdrImageHandle? = null
    private var hdrSourceLease: HdrSourceHandle? = null
    private var hdrSourceKey: Triple<String, Long, Long>? = null
    private var hdrSourceCamera: HDRCameraDevelopmentSettings? = null

    fun close() { releaseDecodedRaster(); hdrBridge.clearCache(); processor?.close() }
    private fun releaseHDRSource(clearReference: Boolean = true) {
        hdrSourceLease?.close(); hdrSourceLease=null; hdrSource=null; hdrSourceKey=null; hdrSourceCamera=null
        if (clearReference) hdrReference.clear()
    }
    fun releaseDecodedRaster() {
        previews.clear(); previewScope = null
        processor?.clearHDRSessionCache()
        processor?.releaseRasterCache(); releaseHDRSource()
    }

    private fun engine(): RenderEngine = processor ?: engineFactory().also { processor = it }

    fun perform(work: Work, cancellation: RenderCancellation): WorkResult = synchronized(storage) {
        runGuardedExportWork(work, destinationDeleter) {
            if (work !is Work.Preview && work !is Work.DetailPreview && work !is Work.HslProbe && work !is Work.Import &&
                work !is Work.CameraHDRPreflight && work !is Work.Export && work !is Work.AutoExposure)
                return@runGuardedExportWork perform(work)
            cancellation.check()
            val native = engine()
            val generation = native.cancellationGeneration()
            cancellation.onCancel(native::cancelPreview)
            try {
                cancellation.check()
                perform(work, generation)
            } finally { cancellation.onCancel(null) }
        }
    }

    // 托管文件从解析路径到 native 读取完成期间不能被另一队列删除。
    private fun perform(work: Work, generation: Long = -1L): WorkResult = synchronized(storage) { when (work) {
        is Work.Import -> {
            val photo = work.retained ?: storage.import(work.uri)
            val owned = work.retained == null || work.ownsRetained
            var canRetryLegacy = false
            var hadSavedRecord = false
            try {
                photo.validateOriginal?.invoke()
                val record = restore(photo.identity)
                hadSavedRecord = record?.settings != null
                var restored = record?.settings ?: photo.defaultEditSettings(work.x3fModeOverride)
                if (work.x3fModeOverride != null) restored = restored.copy(x3fMode = work.x3fModeOverride)
                if (hadSavedRecord && restored.isHDREditing && photo.hdrSource != null) {
                    restored.requireHDRDecodeVersion(photo.hdrSource.isProRAW)
                }
                canRetryLegacy = photo.isX3f && restored.x3fMode == com.rawlab.android.settings.X3fMode.NORMAL
                if (!restored.isHDREditing && runCatching { storage.lookPath(restored) }.isFailure) {
                    val native = engine()
                    native.setGpuMode(work.gpuMode)
                    val validation = native.preview(photo.file, null, restored.copy(film = "neutral", recipeID = null), 256, false, photo.inputKind, generation)
                    if (debuggable)
                        android.util.Log.i("RawLabImport", "missingLookValidationBackend=${validation.backend}")
                    WorkResult.MissingLook(photo, restored, record, work.x3fModeOverride != null, owned)
                } else perform(Work.Preview(photo, restored, false, work.gpuMode,
                    importing = true, restored = record?.settings != null, importedRecord = record,
                    persistOnImport = work.x3fModeOverride != null, ownsImportedInput = owned), generation)
            }
            catch (error: Throwable) {
                if (error is com.rawlab.android.settings.UnusableEditRecordException ||
                    (hadSavedRecord && error is com.rawlab.android.settings.HDRModeError.InvalidSettings)) {
                    WorkResult.UnusableEditImportFailure(work.copy(retained = photo, ownsRetained = owned), photo.identity, error)
                } else if (canRetryLegacy && error !is java.util.concurrent.CancellationException && error !is OutOfMemoryError)
                    WorkResult.X3fImportFailure(work.copy(retained = photo, ownsRetained = owned,
                        x3fModeOverride = com.rawlab.android.settings.X3fMode.LEGACY), error)
                else { if (owned) photo.file.delete(); throw error }
            }
        }
        is Work.Preview -> WorkResult.Preview(work, preview(work, generation))
        is Work.DetailPreview -> performDetail(work, generation)
        is Work.HslProbe -> {
            val preview = work.preview
            val sample = runCatching {
                if (preview.edits.isHDREditing) {
                    require(preview.gpuMode != NativeProcessor.FORCE)
                    if (preview.photo.hdrSource?.isProRAW == true) preview.edits.requireProRAWDecoder()
                    val native = engine()
                    native.setGpuMode(NativeProcessor.CPU)
                    val settings = requireNotNull(preview.edits.hdr).copy(geometry = preview.edits.geometry)
                    val info = hdrSourceInfo(preview.photo, preview.edits)
                    val source = cachedHDRSource(preview.photo, info, generation, settings.cameraSettings)
                    native.sampleHDRHsl(source, settings, hdrPreviewEdge(preview, info), work.revision, work.x, work.y, generation, storage.hdrLookDirectory)
                } else engine().sampleHsl(preview.photo.file, storage.lookPath(preview.edits), preview.edits,
                    preview.edge, preview.interactive, preview.photo.inputKind, work.revision, work.x, work.y, generation)
            }.getOrElse { HslTargetSample.unavailable(work.revision, HslTargetAvailability.FAILED) }
            WorkResult.HslProbe(work, sample)
        }
        is Work.CameraHDRPreflight -> performCameraHDRPreflight(work, generation)
        is Work.Export -> {
            if (work.photo.hdrSource != null && work.edits.isHDREditing) return performHDRExport(work, generation)
            val output = storage.temporaryOutput(work.format)
            val native = engine()
            try {
                native.setGpuMode(work.gpuMode)
                native.export(work.photo.file, storage.lookPath(work.edits), work.edits, output,
                    work.format, work.longEdge, work.photo.inputKind, generation)
                // Q12: native.export 正常返回即已过提交点（提交点前的取消在 export 内抛 CANCELLED）。
                // 提交点之后迟到的取消不删已渲染文件，继续入库/写文档并按「已完成」收尾。
                if (work.destination == null) storage.saveAlbum(output, work.format)
                else storage.saveDocument(output, work.destination, work.photo.uri)
            } finally { output.delete() }
            WorkResult.Export
        }
        is Work.AutoExposure -> {
            val native = engine()
            val exposure = if (work.edits.isHDREditing) {
                if (work.gpuMode == NativeProcessor.FORCE)
                    throw com.rawlab.android.engine.HDRProcessingException(2,13,6)
                val info = hdrSourceInfo(work.photo, work.edits)
                if (info.isProRAW) work.edits.requireProRAWDecoder()
                native.setGpuMode(NativeProcessor.CPU)
                val hdr = checkNotNull(work.edits.hdr)
                native.estimateHDRExposure(cachedHDRSource(work.photo, info, generation, hdr.cameraSettings), hdr, generation)
            } else native.autoExposure(work.photo.file, work.edits, work.photo.inputKind)
            WorkResult.AutoExposure(work, exposure)
        }
    } }

    private fun preview(work: Work.Preview, generation: Long): PreviewPair {
        val hdr = work.photo.hdrSource != null && work.edits.isHDREditing
        val lut = if (hdr) null else storage.lookPath(work.edits)
        val source = FileStamp.read(work.photo.file)
        val lutStamp = lut?.let { FileStamp.read(it) }
        // 拍摄白平衡的显示值会随首帧回填；配方的相对色调仍是渲染输入。
        val edits = if (work.edits.customWb) work.edits else work.edits.copy(temperature = 6500f,
            tint = if (work.edits.recipeID == null) 0f else work.edits.tint)
        val scope = if (work.interactive || work.draft || !work.includeNeutral || source == null || (lut != null && lutStamp == null)) null
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
        if (!work.includeNeutral) {
            val film = native.preview(work.photo.file, lut, work.edits, edge, work.interactive, work.photo.inputKind, generation)
            val resultBitmap = film.bitmap()
            val dimensions = comparisonDimensions(film.geometryWidth, film.geometryHeight)
            return PreviewPair(resultBitmap, resultBitmap, film.temperature, film.tint, film.lens,
                dimensions.first, dimensions.second, film.geometryWidth.toFloat() / film.geometryHeight,
                null, film.histogram,
                renderedGeometry = work.edits.geometry, nativeWidth = film.geometryWidth, nativeHeight = film.geometryHeight)
        }
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
            dimensions.first, dimensions.second, originalAspect, neutral.histogram, film.histogram,
            renderedGeometry = work.edits.geometry, nativeWidth = film.geometryWidth, nativeHeight = film.geometryHeight)
    }

    private fun hdrSourceInfo(photo: ImportedPhoto, edits: EditSettings): HDRSourceInfo {
        val info = checkNotNull(photo.hdrSource)
        val version = edits.processing.version
        val cached = hdrSource?.sourceInfo?.takeIf {
            info.isCameraRaw && hdrSourceKey?.first == photo.file.canonicalPath &&
                it.cameraStamp == info.cameraStamp && it.cameraProcessingVersion == version
        }
        return cached ?: hdrBridge.cameraFraming(photo.file, info, version)
    }

    private fun cachedHDRSource(photo: ImportedPhoto, info: HDRSourceInfo, generation: Long,
        camera: HDRCameraDevelopmentSettings = HDRCameraDevelopmentSettings()): HdrImageHandle {
        require(camera.isDefault || info.isCameraRaw && !info.isProRAW)
        camera.cameraProfile?.requireAsset(storage.hdrCameraProfileDirectory)
        val file = photo.file
        val key = Triple(file.canonicalPath, file.length(), file.lastModified())
        if (info.isCameraRaw) {
            val development = camera.takeUnless { it.isDefault }
            val sameSource = hdrSourceKey == key && hdrSource?.sourceInfo?.cameraStamp == info.cameraStamp &&
                hdrSource?.sourceInfo?.cameraProcessingVersion == info.cameraProcessingVersion
            if (!sameSource || hdrSourceCamera != development) {
                releaseHDRSource(clearReference = !sameSource)
                val database = if (camera.lensActive) storage.lensDatabase() else null
                hdrSourceLease = hdrBridge.acquireCamera(file, info, 1600, development, database) {
                    engine().decodeHDRCamera(file, info, 1600, generation, camera, storage.hdrCameraProfileDirectory)
                }
                hdrSource = hdrSourceLease!!.image
                hdrSourceKey = key
                hdrSourceCamera = development
            }
        } else {
            if (hdrSourceKey != key || hdrSource?.sourceInfo?.fingerprint?.contentEquals(info.fingerprint) != true) {
                releaseHDRSource()
                hdrSourceLease = hdrBridge.acquireGainMap(file, info, 1600)
                hdrSource = hdrSourceLease!!.image; hdrSourceKey = key
            }
        }
        return checkNotNull(hdrSource)
    }

    private fun hdrPreviewEdge(work: Work.Preview, info: HDRSourceInfo): Int {
        val canvas = hdrBridge.geometrySize(info, work.edits.geometry)
        return com.rawlab.android.engine.HDRPreviewBudget.edge(canvas[0], canvas[1], work.edge.coerceIn(1, 1600))
    }

    private fun performHDR(work: Work.Preview, stamp: FileStamp?, generation: Long): PreviewPair {
        if (work.gpuMode == NativeProcessor.FORCE)
            throw com.rawlab.android.engine.HDRProcessingException(2,13,6)
        val info = hdrSourceInfo(work.photo, work.edits)
        if (info.isProRAW) work.edits.requireProRAWDecoder()
        val native = engine()
        native.setGpuMode(NativeProcessor.CPU)
        val geometry = work.edits.geometry
        val edge = hdrPreviewEdge(work, info)
        val plan = buildHDRRenderPlan(stamp, work.photo, work.edits, geometry, edge, info.cameraProcessingVersion)
        val originalAspect = if (info.orientation >= 5) info.height.toFloat() / info.width else info.width.toFloat() / info.height
        if (!work.includeNeutral) {
            val source = cachedHDRSource(work.photo, info, generation, plan.resultCameraSettings)
            native.renderHDR(source, plan.resultSettings, edge, generation, storage.hdrLookDirectory).use { result ->
                val resultBitmap = result.sdrBitmap()
                val dimensions = comparisonDimensions(result.outputNativeWidth, result.outputNativeHeight)
                return PreviewPair(
                    resultBitmap, resultBitmap, Float.NaN, Float.NaN,
                    null, dimensions.first, dimensions.second,
                    originalAspect, null, null,
                    null, renderedGeometry = geometry,
                    nativeWidth = result.outputNativeWidth, nativeHeight = result.outputNativeHeight)
            }
        }
        val reference = hdrReference.resolveReference(plan) { neutralCamera, neutralSettings ->
            val source = cachedHDRSource(work.photo, info, generation, neutralCamera)
            native.renderHDR(source, neutralSettings, edge, generation).use { neutral ->
                HDRReference(neutral.snapshot(), neutral.sdrBitmap())
            }
        }
        val source = cachedHDRSource(work.photo, info, generation, plan.resultCameraSettings)
        native.renderHDR(source, plan.resultSettings, edge, generation, storage.hdrLookDirectory).use { result ->
            val resultFrame = result.snapshot()
            val resultBitmap = result.sdrBitmap()
            val dimensions = comparisonDimensions(resultFrame.nativeWidth, resultFrame.nativeHeight)
            return PreviewPair(
                reference.bitmap, resultBitmap, Float.NaN, Float.NaN,
                null, dimensions.first, dimensions.second,
                originalAspect, null, null,
                HDRPreview(reference.frame, resultFrame), renderedGeometry = geometry,
                nativeWidth = resultFrame.nativeWidth, nativeHeight = resultFrame.nativeHeight)
        }
    }

    private fun performCameraHDRPreflight(work: Work.CameraHDRPreflight, generation: Long): WorkResult {
        if (work.gpuMode == NativeProcessor.FORCE)
            throw com.rawlab.android.engine.HDRProcessingException(2,13,6)
        val info = hdrSourceInfo(work.photo, work.edits)
        require(info.isCameraRaw)
        if (info.isProRAW) work.edits.requireProRAWDecoder()
        val native = engine()
        native.setGpuMode(NativeProcessor.CPU)
        val canvas = hdrBridge.geometrySize(info, work.edits.geometry)
        val edge = com.rawlab.android.engine.HDRPreviewBudget.edge(canvas[0], canvas[1], work.edge.coerceIn(1, 1600))
        val settings = (work.edits.hdr ?: HDRSettings()).copy(geometry = work.edits.geometry)
        val source = native.decodeHDRCamera(work.photo.file, info, edge, generation, settings.cameraSettings, storage.hdrCameraProfileDirectory)
        try {
            native.renderHDR(source, settings, edge, generation, storage.hdrLookDirectory).close()
        } finally { source.close() }
        return WorkResult.CameraHDRPreflight(work)
    }

    private fun performHDRExport(work: Work.Export, generation: Long): WorkResult = synchronized(storage) {
        releaseDecodedRaster()
        if (work.gpuMode == NativeProcessor.FORCE)
            throw com.rawlab.android.engine.HDRProcessingException(2,13,6)
        val info = hdrSourceInfo(work.photo, work.edits)
        if (info.isProRAW) work.edits.requireProRAWDecoder()
        val native = engine()
        native.setGpuMode(NativeProcessor.CPU)
        val sessionHandle = native.sessionHandle()
        onExportProgress(work, 0f)
        if (info.isProRAW && work.format in setOf(ExportFormat.HDR_JPEG, ExportFormat.JPEG)) {
            hdrBridge.clearCache()
            val output = storage.temporaryOutput(work.format)
            try {
                native.exportProRAW(
                    work.photo.file,
                    info,
                    work.edits,
                    output,
                    work.format == ExportFormat.HDR_JPEG,
                    work.longEdge ?: 0,
                    generation,
                    storage.hdrLookDirectory,
                    hdrProgressAdapter(work, 0f, 0.96f),
                )
                onExportProgress(work, 0.96f)
                // Q12: exportProRAW 返回 ⇒ 输出文件已过提交点；迟到的取消不删文件，按「已完成」收尾。
                if (work.destination == null) storage.saveAlbum(output, work.format)
                else storage.saveDocument(output, work.destination, work.photo.uri)
                onExportProgress(work, 1f)
            } finally { output.delete() }
            return WorkResult.Export
        }
        val settings = (work.edits.hdr ?: HDRSettings(mode = com.rawlab.android.settings.HDRMode.SDR))
            .copy(geometry = work.edits.geometry)
        val decodeProgress = hdrProgressAdapter(work, 0f, 0.45f)
        val source = if (info.isCameraRaw) native.decodeHDRCamera(work.photo.file, info, 0, generation,
            settings.cameraSettings, storage.hdrCameraProfileDirectory, decodeProgress)
            else hdrBridge.decodeGainMap(work.photo.file, info, 0, sessionHandle, generation, decodeProgress)
        onExportProgress(work, 0.45f)
        val rendered = try {
            native.renderHDR(source, settings, work.longEdge ?: 0, generation, storage.hdrLookDirectory,
                hdrProgressAdapter(work, 0.45f, 0.72f))
        } finally { source.close() }
        onExportProgress(work, 0.72f)
        val output = storage.temporaryOutput(work.format)
        try {
            val metadataSource = work.photo.hdrSource?.takeUnless { it.isCameraRaw && !it.isProRAW }?.let { work.photo.file }
            val encodeProgress = hdrProgressAdapter(work, 0.72f, 0.96f)
            if (work.format == ExportFormat.HDR_JPEG)
                hdrBridge.exportJpeg(rendered, metadataSource, output, sessionHandle, generation, encodeProgress)
            else hdrBridge.exportSdr(rendered, metadataSource, output, work.format.nativeValue, sessionHandle, generation, encodeProgress)
            onExportProgress(work, 0.96f)
            // Q12: 输出文件写盘即已过提交点；迟到的取消不删文件，按「已完成」收尾。
            if (work.destination == null) storage.saveAlbum(output, work.format)
            else storage.saveDocument(output, work.destination, work.photo.uri)
            onExportProgress(work, 1f)
        } finally {
            rendered.close(); output.delete()
        }
        WorkResult.Export
    }

    private fun performDetail(work: Work.DetailPreview, generation: Long): WorkResult.DetailPreview {
        val overlay = try {
            val roi = work.roi.overscanRect
            val hdr = work.photo.hdrSource != null && work.edits.isHDREditing
            if (hdr) {
                if (work.gpuMode == NativeProcessor.FORCE) return WorkResult.DetailPreview(work, null)
                val info = hdrSourceInfo(work.photo, work.edits)
                if (info.isProRAW) {
                    work.edits.requireProRAWDecoder()
                    if (info.width.toLong() * info.height.toLong() > 16_000_000L) {
                        return WorkResult.DetailPreview(work, null)
                    }
                }
                val native = engine()
                native.setGpuMode(NativeProcessor.CPU)
                val edge = work.roi.maxOutputLongEdge.coerceIn(1, 1280)
                val plan = buildHDRRenderPlan(null, work.photo, work.edits, work.edits.geometry, edge, info.cameraProcessingVersion)
                fun renderHdrTile(settings: HDRSettings, headroom: Float): Pair<HDRPreviewFrame, NativeRoiBounds> {
                    val handle = when {
                        info.isProRAW -> native.decodeHDRCamera(
                            work.photo.file, info, 0, generation, settings.cameraSettings, storage.hdrCameraProfileDirectory,
                        ).use { source ->
                            native.renderHDRRoi(
                                source, settings, roi.x0, roi.y0, roi.x1, roi.y1, edge, headroom,
                                generation, storage.hdrLookDirectory,
                            )
                        }
                        info.isCameraRaw -> native.renderHDRCameraRawRoi(
                            work.photo.file, info, settings, roi.x0, roi.y0, roi.x1, roi.y1, edge, headroom,
                            generation, storage.hdrLookDirectory, storage.hdrCameraProfileDirectory,
                        )
                        else -> native.renderHDRFileRoi(
                            work.photo.file, info, settings, roi.x0, roi.y0, roi.x1, roi.y1, edge, headroom,
                            generation, storage.hdrLookDirectory,
                        )
                    }
                    handle.image.use { img ->
                        return img.snapshot(headroomOverride = headroom) to handle.bounds
                    }
                }
                val (afterFrame, bounds) = renderHdrTile(plan.resultSettings, work.baseResultHeadroom)
                val neutralFrame = if (plan.resultSettings == plan.neutralSettings) {
                    afterFrame
                } else if (work.includeNeutral) {
                    runCatching { renderHdrTile(plan.neutralSettings, work.baseNeutralHeadroom).first }.getOrNull()
                } else null
                PreviewDetailOverlay(
                    neutral = null,
                    result = null,
                    hdrNeutral = neutralFrame,
                    hdrResult = afterFrame,
                    normalizedRect = NormalizedRect(
                        bounds.x0.toFloat() / bounds.fullWidth,
                        bounds.y0.toFloat() / bounds.fullHeight,
                        bounds.x1.toFloat() / bounds.fullWidth,
                        bounds.y1.toFloat() / bounds.fullHeight,
                    ),
                    pixelWidth = afterFrame.width,
                    pixelHeight = afterFrame.height,
                    fullNativeWidth = bounds.fullWidth,
                    fullNativeHeight = bounds.fullHeight,
                    sourceRevision = work.sourceRevision,
                    editRevision = work.editRevision,
                    tileKey = work.tileKey,
                )
            } else {
                val native = engine()
                native.setGpuMode(work.gpuMode)
                val edge = work.roi.maxOutputLongEdge.coerceIn(1, 2048)
                val lut = storage.lookPath(work.edits)
                val afterRoi = native.previewRoi(
                    work.photo.file, lut, work.edits, roi.x0, roi.y0, roi.x1, roi.y1,
                    edge, work.photo.inputKind, generation,
                )
                val afterBitmap = afterRoi.frame.bitmap()
                val neutralSettings = EditSettings(
                    geometry = work.edits.geometry,
                    lens = work.edits.lens,
                    processing = work.edits.processing,
                    x3fMode = work.edits.x3fMode,
                )
                val neutralBitmap = if (work.edits == neutralSettings && lut == null) {
                    afterBitmap
                } else if (work.includeNeutral) {
                    runCatching {
                        native.previewRoi(
                            work.photo.file, null, neutralSettings, roi.x0, roi.y0, roi.x1, roi.y1,
                            edge, work.photo.inputKind, generation,
                        ).frame.bitmap()
                    }.getOrNull()
                } else null
                val bounds = afterRoi.bounds
                PreviewDetailOverlay(
                    neutral = neutralBitmap,
                    result = afterBitmap,
                    hdrNeutral = null,
                    hdrResult = null,
                    normalizedRect = NormalizedRect(
                        bounds.x0.toFloat() / bounds.fullWidth,
                        bounds.y0.toFloat() / bounds.fullHeight,
                        bounds.x1.toFloat() / bounds.fullWidth,
                        bounds.y1.toFloat() / bounds.fullHeight,
                    ),
                    pixelWidth = afterRoi.frame.width,
                    pixelHeight = afterRoi.frame.height,
                    fullNativeWidth = bounds.fullWidth,
                    fullNativeHeight = bounds.fullHeight,
                    sourceRevision = work.sourceRevision,
                    editRevision = work.editRevision,
                    tileKey = work.tileKey,
                )
            }
        } catch (_: Throwable) {
            null
        }
        return WorkResult.DetailPreview(work, overlay)
    }
}

internal inline fun runGuardedExportWork(
    work: Work,
    destinationDeleter: ExportDestinationDeleter,
    block: () -> WorkResult,
): WorkResult {
    try {
        return block()
    } catch (error: Throwable) {
        if (work is Work.Export && work.destination != null && work.destination != work.photo.uri) {
            destinationDeleter.deleteIncomplete(work.destination, work.photo.uri)
        }
        throw error
    }
}

internal fun isExportCancellation(error: Throwable): Boolean =
    error is java.util.concurrent.CancellationException ||
        (error is com.rawlab.android.engine.NativeProcessingException &&
            error.status == com.rawlab.android.engine.NativeProcessingException.CANCELLED)
