package com.rawlab.android.looks

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.rawlab.android.R
import com.rawlab.android.editor.PendingLookCompatibility
import com.rawlab.android.engine.NativeFrame
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoFiles
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.ImportedPhoto
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

internal data class LUTPreviewImage(val frame: NativeFrame, val bitmap: Bitmap = frame.bitmap())
internal data class LUTPreviewState(
    val sourceName: String? = null, val displayInput: Boolean = false, val loading: Boolean = false,
    val baseline: LUTPreviewImage? = null, val frames: Map<String, LUTPreviewImage> = emptyMap(),
    val errors: Map<String, String> = emptyMap(), val error: String? = null,
    val reference: LUTPreviewImage? = null, val referenceName: String? = null,
    val comparison: LUTPreviewComparison? = null, val comparisonError: String? = null,
)

// 每个对话框拥有独立的文件副本与串行 native 会话；不借用编辑器或外观库。
internal class LUTCompatibilityPreview(private val context: Context, private val pending: PendingLookCompatibility) : AutoCloseable {
    var state by mutableStateOf(LUTPreviewState())
        private set
    private val executor = Executors.newSingleThreadExecutor()
    private val dispatcher = executor.asCoroutineDispatcher()
    // 发布到主线程时会挂起；仍需保证源切换和参数预览作为完整操作串行执行。
    private val sourceWork = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val sourceGeneration = AtomicInteger()
    private val selectionGeneration = AtomicInteger()
    private val referenceGeneration = AtomicInteger()
    private val comparisonGeneration = AtomicInteger()
    private var closed = false
    private val directory = File(context.cacheDir, "lut-preview-${UUID.randomUUID()}").apply { check(mkdirs()) }
    private val processorOwner = lazy { NativeProcessor(NativeProcessor.CPU) }
    private val processor get() = processorOwner.value
    private var lut: File? = null
    private var source: File? = null
    private var sourceKind = PhotoInputKind.RAW

    private fun copyURI(uri: Uri, name: String, limit: Long): File {
        val suffix = name.substringAfterLast('.', "").lowercase().takeIf { it.matches(Regex("[a-z0-9]{1,12}")) }.orEmpty()
        val output = File(directory, "${UUID.randomUUID()}${if (suffix.isEmpty()) "" else ".$suffix"}")
        try {
            context.contentResolver.openInputStream(uri).use { input ->
                checkNotNull(input)
                output.outputStream().use { target ->
                    val bytes = ByteArray(64 * 1024); var total = 0L
                    while (true) { val count = input.read(bytes); if (count < 0) break; total += count; require(total <= limit); target.write(bytes, 0, count) }
                }
            }
        } catch (error: Throwable) { output.delete(); throw error }
        return output
    }
    private fun name(uri: Uri): String = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
        if (it.moveToFirst()) it.getString(0) else null
    } ?: uri.lastPathSegment.orEmpty()
    private fun ensureLut(): File = lut ?: copyURI(pending.uri, pending.name, 256L * 1024 * 1024).also { lut = it }
    fun loadInitial(photo: ImportedPhoto?) {
        if (photo == null) return
        loadSource {
            photo.validateOriginal?.invoke()
            val suffix = photo.name.substringAfterLast('.', "raw").lowercase().takeIf { it.matches(Regex("[a-z0-9]{1,12}")) } ?: "raw"
            val copy = File(directory, "${UUID.randomUUID()}.$suffix")
            try { photo.file.copyTo(copy) } catch (error: Throwable) { copy.delete(); throw error }
            Triple(copy, photo.name, photo.inputKind)
        }
    }
    fun loadPhoto(uri: Uri) = loadSource {
        val name = name(uri)
        val kind = requireNotNull(PhotoFiles.kind(name, context.contentResolver.getType(uri)))
        Triple(copyURI(uri, name, 1024L * 1024 * 1024), name, kind)
    }
    private fun loadSource(load: () -> Triple<File, String, PhotoInputKind>) {
        if (closed) return
        val generation = sourceGeneration.incrementAndGet()
        selectionGeneration.incrementAndGet(); referenceGeneration.incrementAndGet(); comparisonGeneration.incrementAndGet()
        state = state.copy(loading = true, baseline = null, frames = emptyMap(), errors = emptyMap(), error = null,
            reference = null, referenceName = null, comparison = null, comparisonError = null)
        scope.launch {
            try {
                withContext(dispatcher) { sourceWork.withLock {
                    ensureActive(); if (sourceGeneration.get() != generation) return@withLock
                    ensureLut()
                    val (file, name, kind) = load()
                    var committed = false
                    try {
                        ensureActive(); if (sourceGeneration.get() != generation) return@withLock
                        val baseline = LUTPreviewImage(processor.previewCompatibility(file, kind, null, null))
                        val previous = withContext(Dispatchers.Main) {
                            if (sourceGeneration.get() != generation) return@withContext null
                            val old = source
                            source = file; sourceKind = kind
                            state = state.copy(sourceName = name, displayInput = kind == PhotoInputKind.RASTER, baseline = baseline)
                            committed = true
                            old
                        }
                        if (!committed) return@withLock
                        if (previous != file) previous?.delete()
                        for (candidate in pending.draft.candidates) {
                            ensureActive(); if (sourceGeneration.get() != generation) break
                            val configured = pending.draft.applying(candidate, kind == PhotoInputKind.RASTER) ?: continue
                            try {
                                val frame = LUTPreviewImage(processor.previewCompatibility(file, kind, lut, configured.previewRequest()))
                                withContext(Dispatchers.Main) {
                                    if (sourceGeneration.get() == generation) state = state.copy(frames = state.frames + (configured.previewKey() to frame))
                                }
                            } catch (error: CancellationException) { throw error
                            } catch (_: Exception) {
                                withContext(Dispatchers.Main) {
                                    if (sourceGeneration.get() == generation) state = state.copy(errors = state.errors +
                                        (configured.previewKey() to context.getString(R.string.lut_preview_failed)))
                                }
                            }
                        }
                    } finally {
                        if (!committed) file.delete()
                    }
                } }
            } catch (error: CancellationException) { throw error
            } catch (_: Exception) { if (sourceGeneration.get() == generation) state = state.copy(error = context.getString(R.string.lut_preview_failed))
            } finally { if (sourceGeneration.get() == generation) state = state.copy(loading = false) }
        }
    }
    fun preview(draft: LUTCompatibility) {
        if (closed) return
        val selection = selectionGeneration.incrementAndGet(); val generation = sourceGeneration.get()
        clearComparison()
        if (!draft.hasCompleteContract || state.frames.containsKey(draft.previewKey())) return
        scope.launch {
            try {
                val frame = withContext(dispatcher) { sourceWork.withLock {
                    val file = source ?: return@withLock null
                    require(draft.supportsPreview(sourceKind == PhotoInputKind.RASTER))
                    LUTPreviewImage(processor.previewCompatibility(file, sourceKind, ensureLut(), draft.previewRequest()))
                } }
                if (frame != null && selectionGeneration.get() == selection && sourceGeneration.get() == generation)
                    state = state.copy(frames = state.frames + (draft.previewKey() to frame))
            } catch (error: CancellationException) { throw error
            } catch (_: Exception) {
                if (selectionGeneration.get() == selection && sourceGeneration.get() == generation)
                    state = state.copy(errors = state.errors + (draft.previewKey() to context.getString(R.string.lut_preview_failed)))
            }
        }
    }
    fun loadReference(uri: Uri) {
        if (closed) return
        val generation = referenceGeneration.incrementAndGet(); clearComparison()
        state = state.copy(reference = null, referenceName = null)
        scope.launch {
            try {
                val (name, image) = withContext(dispatcher) {
                    val name = name(uri); require(PhotoFiles.kind(name, context.contentResolver.getType(uri)) == PhotoInputKind.RASTER)
                    val file = copyURI(uri, name, 256L * 1024 * 1024)
                    try { name to NativeProcessor(NativeProcessor.CPU).use { LUTPreviewImage(it.previewCompatibility(file, PhotoInputKind.RASTER, null, null)) } }
                    finally { file.delete() }
                }
                if (referenceGeneration.get() == generation) state = state.copy(reference = image, referenceName = name)
            } catch (error: CancellationException) { throw error
            } catch (_: Exception) {
                if (referenceGeneration.get() == generation) state = state.copy(comparisonError = context.getString(R.string.lut_preview_failed))
            }
        }
    }
    fun clearComparison() { comparisonGeneration.incrementAndGet(); state = state.copy(comparison = null, comparisonError = null) }
    fun compare(draft: LUTCompatibility, conditions: LUTReferenceConditions) {
        clearComparison(); if (closed || !conditions.canCompare) return
        val a = state.frames[draft.previewKey()]?.frame ?: return
        val b = state.reference?.frame ?: return
        if (a.width != b.width || a.height != b.height) { state = state.copy(comparisonError = context.getString(R.string.lut_reference_dimensions)); return }
        val generation = comparisonGeneration.get()
        scope.launch {
            try {
                val result = withContext(dispatcher) { JSONObject(NativeProcessor.compareLutPreviews(a, b, conditions.json())) }
                if (comparisonGeneration.get() == generation) state = state.copy(comparison = LUTPreviewComparison(result.getDouble("mean_absolute_rgb"), result.getDouble("max_absolute_rgb"),
                    result.getDouble("candidate_boundary_fraction"), result.getDouble("reference_boundary_fraction")))
            } catch (error: CancellationException) { throw error
            } catch (_: Exception) { if (comparisonGeneration.get() == generation) state = state.copy(comparisonError = context.getString(R.string.lut_reference_conditions_required)) }
        }
    }
    override fun close() {
        if (closed) return
        closed = true; sourceGeneration.incrementAndGet(); selectionGeneration.incrementAndGet(); referenceGeneration.incrementAndGet(); comparisonGeneration.incrementAndGet()
        scope.cancel()
        executor.execute { try { if (processorOwner.isInitialized()) processor.close(); directory.deleteRecursively() } finally { dispatcher.close() } }
    }
}
