package com.rawlab.android

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import java.io.File

enum class Operation { NONE, IMPORT, IMPORT_LOOK, PICK_EXPORT, EXPORT }
enum class EditSaveState { NONE, RESTORED, SAVED, FAILED }
data class PreviewPair(val neutral: Bitmap, val result: Bitmap, val temperature: Float, val tint: Float,
    val lens: LensInfo? = null, val comparisonWidth: Float = neutral.width.toFloat(),
    val comparisonHeight: Float = neutral.height.toFloat())
data class EditorState(
    val photo: ImportedPhoto? = null,
    val edits: EditSettings = EditSettings(),
    val looks: List<LookChoice> = LookChoice.builtIns,
    val preview: PreviewPair? = null,
    val operation: Operation = Operation.NONE,
    val rendering: Boolean = false,
    val previewResizePending: Boolean = false,
    val exact: Boolean = false,
    val error: String? = null,
    val saveState: EditSaveState = EditSaveState.NONE,
    val message: String? = null,
    val lookImportReport: String? = null,
    val gpuEnabled: Boolean = true,
    val draft: AdjustmentDraft? = null,
) {
    val canExport get() = photo != null && preview != null && exact && !rendering && !previewResizePending &&
        operation == Operation.NONE && draft == null && saveState != EditSaveState.FAILED
    val controlsEnabled get() = photo != null && operation == Operation.NONE
    val visibleEdits get() = draft?.project(edits) ?: edits
    val canApplyDraft get() = draft != null && controlsEnabled && exact && !rendering && error == null
}

private sealed interface Work {
    data class Import(val uri: Uri, val gpuMode: Int) : Work
    data class Preview(val photo: ImportedPhoto, val edits: EditSettings, val interactive: Boolean,
        val gpuMode: Int, val importing: Boolean = false, val restored: Boolean = false,
        val edge: Int = 1600, val draft: Boolean = false) : Work
    data class Export(val photo: ImportedPhoto, val edits: EditSettings, val destination: Uri?, val format: ExportFormat,
        val longEdge: Int?, val gpuMode: Int) : Work
    data class AutoExposure(val photo: ImportedPhoto, val edits: EditSettings) : Work
}
private sealed interface WorkResult {
    data class Preview(val request: Work.Preview, val pair: PreviewPair) : WorkResult
    data class MissingLook(val photo: ImportedPhoto, val edits: EditSettings) : WorkResult
    data object Export : WorkResult
    data class AutoExposure(val request: Work.AutoExposure, val exposure: Float) : WorkResult
}
private sealed interface LookWork {
    data object Load : LookWork
    data class Import(val uris: List<Uri>) : LookWork
    data class Rename(val id: String, val name: String) : LookWork
    data class Delete(val id: String) : LookWork
}
private sealed interface LookResult {
    data class Loaded(val looks: List<LookChoice>) : LookResult
    data class Imported(val imported: List<ManagedLook>, val failures: List<String>, val looks: List<LookChoice>) : LookResult
    data class Renamed(val look: ManagedLook, val looks: List<LookChoice>) : LookResult
    data class Deleted(val id: String, val looks: List<LookChoice>) : LookResult
    data class Failed(val error: Throwable, val reload: Boolean) : LookResult
}

class EditorViewModel(application: Application) : AndroidViewModel(application) {
    val storage = PhotoStorage(application)
    private var editStore: EditStore? = runCatching { EditStore(File(application.filesDir, "edits")) }.getOrNull()
    private val mutableBatch = MutableStateFlow<BatchExportModel?>(null)
    val batch = mutableBatch.asStateFlow()
    private val mutablePendingBatch = MutableStateFlow<List<BatchJob>>(emptyList())
    val pendingBatch = mutablePendingBatch.asStateFlow()
    private var processor: NativeProcessor? = null
    private var original: Pair<java.io.File, Bitmap>? = null
    private var transformedNeutral: Pair<ComparisonPreviewKey, Bitmap>? = null
    private var currentRevision = 0L
    private var previewLongEdge = 1600
    private var requestedPreviewLongEdge = 1600
    private var previewResizeJob: Job? = null
    private var lookRevision = 0L
    private var releases = 0
    private val mutable = MutableStateFlow(EditorState())
    val state = mutable.asStateFlow()
    private var disposed = false
    private val queue = RenderQueue<Work, WorkResult>(::perform, { revision, result ->
        viewModelScope.launch {
            if (!disposed && revision == currentRevision) accept(result)
        }
    }, { processor?.close(); releaseStorage() })
    private val lookQueue = RenderQueue<LookWork, LookResult>(::performLook, { revision, result ->
        viewModelScope.launch {
            if (!disposed && revision == lookRevision) acceptLook(result)
        }
    }, ::releaseStorage)

    init {
        if (editStore == null) mutable.value = mutable.value.copy(saveState = EditSaveState.FAILED,
            error = text(R.string.edit_storage_error))
        lookRevision = lookQueue.submit(LookWork.Load)
        refreshPendingBatch()
    }

    private fun engine() = processor ?: NativeProcessor(lensDatabase = storage.lensDatabase()).also { processor = it }

    // 托管文件从解析路径到 native 读取完成期间不能被另一队列删除。
    private fun perform(work: Work): WorkResult = synchronized(storage) { when (work) {
        is Work.Import -> {
            val photo = storage.import(work.uri)
            val restored = editStore?.load(photo.identity)
            try {
                if (restored != null && runCatching { storage.lookPath(restored) }.isFailure) {
                    engine().preview(photo.file, null, restored.copy(film = "neutral", recipeID = null), 256, false)
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
                original = work.photo.file to native.preview(work.photo.file, null, EditSettings(), 1600, false).bitmap()
            }
            val neutral = if (work.edits.geometry.isIdentity && !work.edits.lens.enabled) original!!.second else {
                val key = ComparisonPreviewKey(work.photo.file.path, work.edits.geometry, work.edits.lens, edge, work.interactive)
                if (transformedNeutral?.first != key) {
                    transformedNeutral = null
                    val comparison = EditSettings(geometry = work.edits.geometry, lens = work.edits.lens)
                    transformedNeutral = key to native.preview(work.photo.file, null, comparison, edge, work.interactive).bitmap()
                }
                transformedNeutral!!.second
            }
            val lut = storage.lookPath(work.edits)
            val film = native.preview(work.photo.file, lut, work.edits, edge, work.interactive)
            val dimensions = if (work.edits.geometry.isIdentity && !work.edits.lens.enabled)
                original!!.second.width.toFloat() to original!!.second.height.toFloat()
            else comparisonDimensions(film.geometryWidth, film.geometryHeight)
            WorkResult.Preview(work, PreviewPair(neutral, film.bitmap(), film.temperature, film.tint, film.lens,
                dimensions.first, dimensions.second))
        }
        is Work.Export -> {
            val output = storage.temporaryOutput(work.format)
            try {
                engine().setGpuMode(work.gpuMode)
                engine().export(work.photo.file, storage.lookPath(work.edits), work.edits, output, work.format, work.longEdge)
                if (work.destination == null) storage.saveAlbum(output, work.format)
                else storage.saveDocument(output, work.destination, work.photo.uri)
            } finally { output.delete() }
            WorkResult.Export
        }
        is Work.AutoExposure -> WorkResult.AutoExposure(work, engine().autoExposure(work.photo.file, work.edits))
    } }

    private fun performLook(work: LookWork): LookResult = synchronized(storage) { try {
        when (work) {
            LookWork.Load -> LookResult.Loaded(storage.looks())
            is LookWork.Import -> {
                val imported = mutableListOf<ManagedLook>()
                val failures = mutableListOf<String>()
                for (uri in work.uris) {
                    try { imported += storage.importLook(uri) }
                    catch (error: Exception) { failures += error.message ?: error.javaClass.simpleName }
                }
                LookResult.Imported(imported, failures, storage.looks())
            }
            is LookWork.Rename -> {
                val look = storage.renameLook(work.id, work.name)
                LookResult.Renamed(look, storage.looks())
            }
            is LookWork.Delete -> {
                storage.deleteLook(work.id)
                LookResult.Deleted(work.id, storage.looks())
            }
        }
    } catch (error: Throwable) {
        LookResult.Failed(error, work != LookWork.Load)
    } }

    private fun accept(result: Result<WorkResult>) {
        result.fold({ value ->
            when (value) {
                is WorkResult.MissingLook -> {
                    mutable.value.photo?.file?.takeIf { it != value.photo.file }?.delete()
                    mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(photo = value.photo,
                        edits = value.edits, preview = null, exact = false,
                        saveState = EditSaveState.RESTORED, error = text(R.string.look_unavailable))
                }
                is WorkResult.Preview -> {
                    val request = value.request
                    if (request.draft) {
                        if (mutable.value.draft != null) mutable.value = EditorStateReducer.renderFinished(mutable.value)
                            .copy(preview = value.pair, exact = !request.interactive, error = null)
                        return@fold
                    }
                    if (request.importing) {
                        mutable.value.photo?.file?.takeIf { it != request.photo.file }?.delete()
                    }
                    val settings = if (!request.edits.customWb && value.pair.temperature.isFinite())
                        request.edits.copy(temperature = value.pair.temperature.coerceIn(2000f, 50000f),
                            tint = if (request.edits.recipeID == null) value.pair.tint.coerceIn(-150f, 150f) else request.edits.tint)
                    else request.edits
                    val saved = when {
                        request.importing -> if (editStore == null) EditSaveState.FAILED else if (request.restored) EditSaveState.RESTORED else EditSaveState.NONE
                        request.interactive -> mutable.value.saveState
                        else -> persist(request.photo, settings)
                    }
                    mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(
                        photo = request.photo, edits = settings, preview = value.pair,
                        exact = !request.interactive, error = null,
                        saveState = if (request.restored && saved == EditSaveState.SAVED) EditSaveState.RESTORED else saved)
                }
                WorkResult.Export -> mutable.value = mutable.value.copy(operation = Operation.NONE, message = text(R.string.export_done))
                is WorkResult.AutoExposure -> {
                    val current = mutable.value
                    if (current.photo?.identity == value.request.photo.identity && current.edits == value.request.edits) {
                        edit(current.edits.copy(exposure = value.exposure))
                    }
                }
            }
            fadeSaveNotice()
        }, { error ->
            mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(error = failure(error))
        })
        updatePreviewSize(requestedPreviewLongEdge)
    }

    private fun acceptLook(result: Result<LookResult>) {
        result.fold(::acceptLookValue, { error ->
            mutable.value = mutable.value.copy(operation = Operation.NONE,
                error = text(R.string.look_storage_error) + "\n" + (error.message ?: error.javaClass.simpleName))
        })
        updatePreviewSize(requestedPreviewLongEdge)
    }

    private fun acceptLookValue(result: LookResult) {
        when (result) {
            is LookResult.Loaded -> mutable.value = EditorStateReducer.looksLoaded(mutable.value, result.looks)
            is LookResult.Imported -> {
                val mutation = result.imported.lastOrNull()?.let { EditorStateReducer.lookImported(mutable.value, it) }
                    ?: EditorMutation(mutable.value.copy(operation = Operation.NONE), null)
                val report = if (result.failures.isEmpty()) null else
                    AppStrings.format(R.string.look_import_summary, result.imported.size, result.failures.size) +
                        "\n\n" + result.failures.joinToString("\n")
                mutable.value = mutation.state.copy(looks = result.looks, lookImportReport = report,
                    message = if (result.imported.isEmpty()) null else text(R.string.look_imported))
                scheduleLookPreview(mutation.preview)
            }
            is LookResult.Renamed -> {
                val mutation = EditorStateReducer.lookRenamed(mutable.value, result.look)
                mutable.value = mutation.state.copy(looks = result.looks)
            }
            is LookResult.Deleted -> {
                val mutation = EditorStateReducer.lookDeleted(mutable.value, result.id)
                mutable.value = mutation.state.copy(looks = result.looks)
                scheduleLookPreview(mutation.preview)
            }
            is LookResult.Failed -> {
                if (result.reload) lookRevision = lookQueue.submit(LookWork.Load)
                if (result.reload) {
                    val error = result.error
                    mutable.value = mutable.value.copy(operation = Operation.NONE,
                        error = text(R.string.look_error) + "\n" + (error.message ?: error.javaClass.simpleName))
                } else {
                    val error = result.error
                    mutable.value = mutable.value.copy(operation = Operation.NONE,
                        error = text(R.string.look_storage_error) + "\n" + (error.message ?: error.javaClass.simpleName))
                }
            }
        }
    }

    private fun scheduleLookPreview(edits: EditSettings?) {
        val photo = mutable.value.photo ?: return
        if (edits == null) return
        currentRevision = queue.submit(Work.Preview(photo, edits, false, gpuMode(), edge = previewLongEdge))
    }

    fun importPhoto(uri: Uri?) {
        if (uri == null || mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        val current = mutable.value
        if (current.photo != null && persist(current.photo, current.edits) == EditSaveState.FAILED) {
            mutable.value = current.copy(saveState = EditSaveState.FAILED, error = text(R.string.edit_storage_error))
            return
        }
        mutable.value = mutable.value.copy(operation = Operation.IMPORT, rendering = true, error = null)
        previewResizeJob?.cancel()
        previewResizeJob = null
        previewLongEdge = 1600
        requestedPreviewLongEdge = 1600
        mutable.value = mutable.value.copy(previewResizePending = false)
        currentRevision = queue.submit(Work.Import(uri, gpuMode()))
    }

    fun importLook(uri: Uri?) {
        if (uri != null) importLooks(listOf(uri))
    }

    fun importLooks(uris: List<Uri>) {
        if (uris.isEmpty() || mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null, lookImportReport = null)
        lookRevision = lookQueue.submit(LookWork.Import(uris.toList()))
    }

    fun dismissLookImportReport() { mutable.value = mutable.value.copy(lookImportReport = null) }

    fun renameLook(id: String, name: String) {
        if (mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null)
        lookRevision = lookQueue.submit(LookWork.Rename(id, name))
    }

    fun deleteLook(id: String) {
        if (mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null)
        lookRevision = lookQueue.submit(LookWork.Delete(id))
    }

    fun edit(edits: EditSettings, interactive: Boolean = false) {
        val current = mutable.value
        if (!current.controlsEnabled || current.draft != null) return
        val look = current.looks.firstOrNull { it.id == edits.film }
        if (look?.managed == true && !look.available) {
            mutable.value = current.copy(error = text(R.string.look_unavailable))
            return
        }
        if (!edits.denoise.enabled && previewResizeJob != null) {
            previewResizeJob?.cancel()
            previewResizeJob = null
            previewLongEdge = requestedPreviewLongEdge
        }
        val saved = if (interactive) current.saveState else persist(current.photo!!, edits)
        mutable.value = current.copy(edits = edits, rendering = true, exact = false, error = null, saveState = saved,
            previewResizePending = previewResizeJob != null)
        currentRevision = queue.submit(Work.Preview(current.photo!!, edits, interactive, gpuMode(), edge = previewLongEdge))
    }

    fun updatePreviewSize(edge: Int) {
        val current = mutable.value
        if (disposed || current.photo == null || current.draft != null || edge !in 1..1600 ||
            (edge == requestedPreviewLongEdge && (edge == previewLongEdge || previewResizeJob != null))) return
        requestedPreviewLongEdge = edge
        if (!current.controlsEnabled) return
        previewResizeJob?.cancel()
        previewResizeJob = null
        mutable.value = current.copy(previewResizePending = false)
        if (edge == previewLongEdge) return
        if (!current.edits.denoise.enabled) {
            previewLongEdge = edge
            edit(mutable.value.edits)
            return
        }
        mutable.value = mutable.value.copy(previewResizePending = true)
        previewResizeJob = viewModelScope.launch {
            delay(200)
            previewResizeJob = null
            mutable.value = mutable.value.copy(previewResizePending = false)
            if (!mutable.value.controlsEnabled) return@launch
            previewLongEdge = requestedPreviewLongEdge
            edit(mutable.value.edits)
        }
    }

    fun beginDraft(group: AdjustmentGroup) {
        val current = mutable.value
        if (!current.canExport) return
        previewResizeJob?.cancel()
        previewResizeJob = null
        mutable.value = current.copy(draft = AdjustmentDraft.begin(group, current.edits), previewResizePending = false, error = null)
        if (group == AdjustmentGroup.GEOMETRY && current.edits.geometry != current.edits.geometry.uncropped()) renderDraft(false)
    }

    fun changeDraft(edits: EditSettings, interactive: Boolean = false) {
        val current = mutable.value
        val previous = current.draft ?: return
        if (!current.controlsEnabled) return
        val next = previous.update(edits)
        mutable.value = current.copy(draft = next)
        // Crop-only edits are an overlay on the full transformed preview, not a RAW render.
        if (previous.group == AdjustmentGroup.GEOMETRY &&
            previous.value.geometry.uncropped() == next.value.geometry.uncropped() && (interactive || current.exact)) return
        renderDraft(interactive)
    }

    private fun renderDraft(interactive: Boolean) {
        val current = mutable.value
        val draft = current.draft ?: return
        val photo = current.photo ?: return
        val edits = draft.project(current.edits).let {
            if (draft.group == AdjustmentGroup.GEOMETRY) it.copy(geometry = it.geometry.uncropped()) else it
        }
        mutable.value = current.copy(rendering = true, exact = false, error = null)
        currentRevision = queue.submit(Work.Preview(photo, edits, interactive, gpuMode(), edge = 1600, draft = true))
    }

    fun applyDraft() {
        val current = mutable.value
        if (!current.canApplyDraft) return
        val edits = current.draft!!.project(current.edits)
        mutable.value = current.copy(draft = null)
        edit(edits)
    }

    fun discardDraft() {
        val current = mutable.value
        if (current.draft == null) return
        mutable.value = current.copy(draft = null)
        edit(current.edits)
    }

    fun retry() { if (mutable.value.draft != null) renderDraft(false) else edit(mutable.value.edits) }
    fun autoExposure() {
        val current = mutable.value
        if (!current.controlsEnabled || current.preview == null || current.rendering || current.draft != null) return
        mutable.value = current.copy(rendering = true, exact = false, error = null)
        currentRevision = queue.submit(Work.AutoExposure(current.photo!!, current.edits))
    }
    fun retrySave() {
        val photo = mutable.value.photo
        if (photo != null) mutable.value = mutable.value.copy(saveState = persist(photo, mutable.value.edits))
        else try {
            editStore = EditStore(File(getApplication<Application>().filesDir, "edits"))
            mutable.value = mutable.value.copy(saveState = EditSaveState.NONE, error = null)
        } catch (_: Exception) { mutable.value = mutable.value.copy(saveState = EditSaveState.FAILED) }
        fadeSaveNotice()
    }
    fun reset() { edit(mutable.value.edits.reset()) }

    private var saveNotice: kotlinx.coroutines.Job? = null
    private fun fadeSaveNotice() {
        saveNotice?.cancel()
        if (mutable.value.saveState !in setOf(EditSaveState.SAVED, EditSaveState.RESTORED)) return
        saveNotice = viewModelScope.launch {
            kotlinx.coroutines.delay(3000)
            if (mutable.value.saveState in setOf(EditSaveState.SAVED, EditSaveState.RESTORED)) mutable.value = mutable.value.copy(saveState = EditSaveState.NONE)
        }
    }

    private fun gpuMode() = if (mutable.value.gpuEnabled) NativeProcessor.AUTO else NativeProcessor.CPU

    private fun persist(photo: ImportedPhoto, edits: EditSettings): EditSaveState = try {
        if (editStore == null) editStore = EditStore(File(getApplication<Application>().filesDir, "edits"))
        editStore!!.save(photo.identity, edits)
        EditSaveState.SAVED
    } catch (_: Throwable) { EditSaveState.FAILED }
    fun setGpuEnabled(enabled: Boolean) {
        if (mutable.value.operation != Operation.NONE) return
        mutable.value = mutable.value.copy(gpuEnabled = enabled)
        if (mutable.value.draft != null) renderDraft(false)
        else if (mutable.value.photo != null) edit(mutable.value.edits)
    }

    fun beginExport(): Boolean {
        if (!mutable.value.canExport) return false
        val photo = mutable.value.photo ?: return false
        if (persist(photo, mutable.value.edits) == EditSaveState.FAILED) {
            mutable.value = mutable.value.copy(saveState = EditSaveState.FAILED)
            return false
        }
        mutable.value = mutable.value.copy(operation = Operation.PICK_EXPORT, error = null)
        return true
    }
    fun cancelExport() {
        if (mutable.value.operation == Operation.PICK_EXPORT) mutable.value = mutable.value.copy(operation = Operation.NONE)
        updatePreviewSize(requestedPreviewLongEdge)
    }
    fun export(destination: Uri?, format: ExportFormat, longEdge: Int? = null) {
        val current = mutable.value
        if (current.operation != Operation.PICK_EXPORT || current.photo == null) return
        if (destination == null && !format.allowsGallery) {
            mutable.value = current.copy(operation = Operation.NONE, error = text(R.string.dng_file_only))
            return
        }
        if (!ExportSize.isValid(longEdge)) {
            mutable.value = current.copy(operation = Operation.NONE, error = text(R.string.output_size_error))
            updatePreviewSize(requestedPreviewLongEdge)
            return
        }
        mutable.value = current.copy(operation = Operation.EXPORT)
        currentRevision = queue.submit(Work.Export(current.photo, current.edits, destination, format, longEdge, gpuMode()))
    }
    fun dismissMessage() { mutable.value = mutable.value.copy(message = null) }

    fun beginBatch() {
        val current = mutable.value
        if (!current.canExport || mutableBatch.value != null) return
        val photo = current.photo ?: return
        mutableBatch.value = BatchExportModel(getApplication(), storage,
            BatchSourceSnapshot(photo.identity, photo.file, current.edits, photo.name))
    }

    fun resumeBatch(job: BatchJob) {
        if (mutableBatch.value != null || mutable.value.draft != null || mutable.value.operation != Operation.NONE) return
        mutableBatch.value = BatchExportModel(getApplication(), storage, job.source, job)
    }

    fun closeBatch() {
        val model = mutableBatch.value ?: return
        if (model.state.value.phase in setOf(BatchPhase.RUNNING, BatchPhase.PREPARING)) return
        model.discardDraftOrCompleted()
        model.close()
        mutableBatch.value = null
        refreshPendingBatch()
    }

    private fun refreshPendingBatch() {
        viewModelScope.launch {
            try {
                mutablePendingBatch.value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    val journal = BatchJournal(File(getApplication<Application>().filesDir, "RawLab/BatchJobs"))
                    journal.pending().mapNotNull(journal::load)
                }
            } catch (error: Exception) { mutable.value = mutable.value.copy(error = AppStrings.format(R.string.message_unable_to_read_batch_task, error.message.toString())) }
        }
    }

    fun onBackground() {
        mutableBatch.value?.cancel()
        mutable.value.photo?.let { photo ->
            if (persist(photo, mutable.value.edits) == EditSaveState.FAILED) mutable.value = mutable.value.copy(saveState = EditSaveState.FAILED)
        }
    }
    private fun text(id: Int) = AppStrings.text(id)
    private fun failure(error: Throwable): String = if (error is OutOfMemoryError) text(R.string.memory_error)
        else text(R.string.process_error) + "\n" + (error.message ?: error.javaClass.simpleName)

    override fun onCleared() {
        disposed = true
        previewResizeJob?.cancel()
        mutableBatch.value?.close()
        lookQueue.close()
        queue.close()
    }

    private fun releaseStorage() {
        synchronized(this) {
            releases += 1
            if (releases == 2) storage.close()
        }
    }
}
