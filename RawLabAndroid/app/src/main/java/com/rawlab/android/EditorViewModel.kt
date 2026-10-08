package com.rawlab.android

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

enum class Operation { NONE, IMPORT, IMPORT_LOOK, PICK_EXPORT, EXPORT }
data class PreviewPair(val neutral: Bitmap, val result: Bitmap, val temperature: Float, val tint: Float)
data class EditorState(
    val photo: ImportedPhoto? = null,
    val edits: EditSettings = EditSettings(),
    val looks: List<LookChoice> = LookChoice.builtIns,
    val preview: PreviewPair? = null,
    val operation: Operation = Operation.NONE,
    val rendering: Boolean = false,
    val exact: Boolean = false,
    val error: String? = null,
    val message: String? = null,
    val lookImportReport: String? = null,
    val gpuEnabled: Boolean = true,
) {
    val canExport get() = photo != null && preview != null && exact && !rendering && operation == Operation.NONE
    val controlsEnabled get() = photo != null && operation == Operation.NONE
}

private sealed interface Work {
    data class Import(val uri: Uri, val gpuMode: Int) : Work
    data class Preview(val photo: ImportedPhoto, val edits: EditSettings, val interactive: Boolean,
        val gpuMode: Int, val importing: Boolean = false) : Work
    data class Export(val photo: ImportedPhoto, val edits: EditSettings, val destination: Uri?, val png: Boolean, val gpuMode: Int) : Work
}
private sealed interface WorkResult {
    data class Preview(val request: Work.Preview, val pair: PreviewPair) : WorkResult
    data object Export : WorkResult
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
    private var processor: NativeProcessor? = null
    private var currentRevision = 0L
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
        lookRevision = lookQueue.submit(LookWork.Load)
    }

    private fun engine() = processor ?: NativeProcessor().also { processor = it }

    // 托管文件从解析路径到 native 读取完成期间不能被另一队列删除。
    private fun perform(work: Work): WorkResult = synchronized(storage) { when (work) {
        is Work.Import -> {
            val photo = storage.import(work.uri)
            try { perform(Work.Preview(photo, EditSettings(), false, work.gpuMode, importing = true)) }
            catch (error: Throwable) { photo.file.delete(); throw error }
        }
        is Work.Preview -> {
            val edge = if (work.interactive) 1000 else 1600
            val native = engine()
            native.setGpuMode(work.gpuMode)
            val neutral = native.preview(work.photo.file, null, work.edits, edge, work.interactive)
            val lut = storage.filmPath(work.edits.film)
            val film = if (lut == null || work.edits.strength == 0f) neutral
                else native.preview(work.photo.file, lut, work.edits, edge, work.interactive)
            val neutralBitmap = neutral.bitmap()
            WorkResult.Preview(work, PreviewPair(neutralBitmap,
                if (neutral === film) neutralBitmap else film.bitmap(), neutral.temperature, neutral.tint))
        }
        is Work.Export -> {
            val output = storage.temporaryOutput(work.png)
            try {
                engine().setGpuMode(work.gpuMode)
                engine().export(work.photo.file, storage.filmPath(work.edits.film), work.edits, output, work.png)
                if (work.destination == null) storage.saveAlbum(output, work.png)
                else storage.saveDocument(output, work.destination, work.photo.uri)
            } finally { output.delete() }
            WorkResult.Export
        }
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
                is WorkResult.Preview -> {
                    val request = value.request
                    if (request.importing) {
                        mutable.value.photo?.file?.takeIf { it != request.photo.file }?.delete()
                    }
                    val settings = if (!request.edits.customWb && value.pair.temperature.isFinite())
                        request.edits.copy(temperature = value.pair.temperature.coerceIn(2000f, 50000f), tint = value.pair.tint.coerceIn(-150f, 150f))
                    else request.edits
                    mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(
                        photo = request.photo, edits = settings, preview = value.pair,
                        exact = !request.interactive, error = null)
                }
                WorkResult.Export -> mutable.value = mutable.value.copy(operation = Operation.NONE, message = text(R.string.export_done))
            }
        }, { error ->
            mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(error = failure(error))
        })
    }

    private fun acceptLook(result: Result<LookResult>) {
        result.fold(::acceptLookValue, { error ->
            mutable.value = mutable.value.copy(operation = Operation.NONE,
                error = text(R.string.look_storage_error) + "\n" + (error.message ?: error.javaClass.simpleName))
        })
    }

    private fun acceptLookValue(result: LookResult) {
        when (result) {
            is LookResult.Loaded -> mutable.value = EditorStateReducer.looksLoaded(mutable.value, result.looks)
            is LookResult.Imported -> {
                val mutation = result.imported.lastOrNull()?.let { EditorStateReducer.lookImported(mutable.value, it) }
                    ?: EditorMutation(mutable.value.copy(operation = Operation.NONE), null)
                val report = if (result.failures.isEmpty()) null else
                    getApplication<Application>().getString(R.string.look_import_summary, result.imported.size, result.failures.size) +
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
        currentRevision = queue.submit(Work.Preview(photo, edits, false, gpuMode()))
    }

    fun importPhoto(uri: Uri?) {
        if (uri == null || mutable.value.operation != Operation.NONE) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT, rendering = true, error = null)
        currentRevision = queue.submit(Work.Import(uri, gpuMode()))
    }

    fun importLook(uri: Uri?) {
        if (uri != null) importLooks(listOf(uri))
    }

    fun importLooks(uris: List<Uri>) {
        if (uris.isEmpty() || mutable.value.operation != Operation.NONE) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null, lookImportReport = null)
        lookRevision = lookQueue.submit(LookWork.Import(uris.toList()))
    }

    fun dismissLookImportReport() { mutable.value = mutable.value.copy(lookImportReport = null) }

    fun renameLook(id: String, name: String) {
        if (mutable.value.operation != Operation.NONE) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null)
        lookRevision = lookQueue.submit(LookWork.Rename(id, name))
    }

    fun deleteLook(id: String) {
        if (mutable.value.operation != Operation.NONE) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null)
        lookRevision = lookQueue.submit(LookWork.Delete(id))
    }

    fun edit(edits: EditSettings, interactive: Boolean = false) {
        val current = mutable.value
        if (!current.controlsEnabled) return
        val look = current.looks.firstOrNull { it.id == edits.film }
        if (look?.managed == true && !look.available) {
            mutable.value = current.copy(error = text(R.string.look_unavailable))
            return
        }
        mutable.value = current.copy(edits = edits, rendering = true, exact = false, error = null)
        currentRevision = queue.submit(Work.Preview(current.photo!!, edits, interactive, gpuMode()))
    }

    fun retry() { edit(mutable.value.edits) }
    fun reset() { edit(mutable.value.edits.reset()) }

    private fun gpuMode() = if (mutable.value.gpuEnabled) NativeProcessor.AUTO else NativeProcessor.CPU
    fun setGpuEnabled(enabled: Boolean) {
        if (mutable.value.operation != Operation.NONE) return
        mutable.value = mutable.value.copy(gpuEnabled = enabled)
        if (mutable.value.photo != null) edit(mutable.value.edits)
    }

    fun beginExport(): Boolean {
        if (!mutable.value.canExport) return false
        mutable.value = mutable.value.copy(operation = Operation.PICK_EXPORT, error = null)
        return true
    }
    fun cancelExport() {
        if (mutable.value.operation == Operation.PICK_EXPORT) mutable.value = mutable.value.copy(operation = Operation.NONE)
    }
    fun export(destination: Uri?, png: Boolean) {
        val current = mutable.value
        if (current.operation != Operation.PICK_EXPORT || current.photo == null) return
        mutable.value = current.copy(operation = Operation.EXPORT)
        currentRevision = queue.submit(Work.Export(current.photo, current.edits, destination, png, gpuMode()))
    }
    fun dismissMessage() { mutable.value = mutable.value.copy(message = null) }
    private fun text(id: Int) = getApplication<Application>().getString(id)
    private fun failure(error: Throwable): String = if (error is OutOfMemoryError) text(R.string.memory_error)
        else text(R.string.process_error) + "\n" + (error.message ?: error.javaClass.simpleName)

    override fun onCleared() {
        disposed = true
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
