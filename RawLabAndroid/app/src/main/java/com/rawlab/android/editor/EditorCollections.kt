package com.rawlab.android.editor

import android.net.Uri
import com.rawlab.android.batch.*
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.VersionedPhotoEdit
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.File

internal class EditorCollections(private val storage: PhotoStorage, parentScope: CoroutineScope,
    private val journalRoot: File, readRecord: (PhotoIdentity) -> VersionedPhotoEdit,
    private val captureActiveValidation: () -> (String) -> Unit,
    private val canRelease: (ImportedPhoto) -> Boolean,
) {
    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob(parentScope.coroutineContext[Job]))
    private val mutable = MutableStateFlow(BatchSelectionState())
    val state = mutable.asStateFlow()
    private val imported = java.util.concurrent.ConcurrentHashMap<String, ImportedPhoto>()
    private val deferredRelease = java.util.concurrent.ConcurrentHashMap<String, ImportedPhoto>()
    private data class SourceValidation(val stamp: () -> Unit, val content: () -> Unit)
    private val validators = java.util.concurrent.ConcurrentHashMap<String, SourceValidation>()
    private val exporter = BatchSelectionExport(journalRoot, readRecord, storage::lookPath, ::validate)

    fun close(onReleased: () -> Unit) {
        val job = scope.coroutineContext[Job]!!
        job.invokeOnCompletion { onReleased() }; job.cancel()
    }
    fun photo(id: String) = imported[id]
    fun owns(file: File) = imported.values.any { it.file == file } || deferredRelease.containsKey(file.absolutePath)
    fun releaseDeferred() {
        deferredRelease.entries.removeAll { (_, photo) ->
            if (imported.values.any { it.file == photo.file }) true
            else if (canRelease(photo)) { photo.file.delete(); true } else false
        }
    }
    fun select(id: String, selected: Boolean) { if (!mutable.value.busy) mutable.update { it.select(id, selected) } }
    fun selectAll(selected: Boolean) { if (!mutable.value.busy) mutable.update {
        it.copy(selected = if (selected) it.photos.mapTo(mutableSetOf()) { row -> row.id } else emptySet())
    } }
    fun remove(id: String) {
        if (mutable.value.busy) return
        imported.remove(id)?.let {
            if (canRelease(it)) it.file.delete() else deferredRelease[it.file.absolutePath] = it
        }
        validators.remove(id)
        mutable.update { it.remove(id) }
    }
    fun opened(id: String) { mutable.update { if (it.photos.any { photo -> photo.id == id }) it.beginEditing(id) else it.returnToCollection() } }
    fun returnToCollection() { mutable.update { it.returnToCollection() } }
    fun synchronized(id: java.util.UUID, changed: Boolean) { mutable.update { it.recordSynchronization(id, changed) } }
    fun failure(message: String?) { mutable.update { it.copy(error = message) } }
    fun validate(target: BatchTarget) = validate(target, content = true)
    fun validateForCommit(target: BatchTarget) = validate(target, content = false)
    private fun validate(target: BatchTarget, content: Boolean) {
        val retained = imported[target.id] ?: error("Photo source is unavailable")
        check(retained.file == target.sourceFile) { "Photo source changed" }
        val validation = validators.getValue(target.id)
        if (content) validation.content() else validation.stamp()
    }
    fun add(uris: List<Uri>, current: ImportedPhoto? = null) {
        if (mutable.value.busy) return
        mutable.update { it.copy(busy = true, error = null) }
        scope.launch {
            val additions = mutableListOf<BatchTarget>()
            val failures = mutableMapOf<String, String>()
            withContext(Dispatchers.IO) { synchronized(storage) {
                for (uri in uris.distinct()) {
                    try {
                        val id = uri.toString()
                        val photo = imported[id] ?: current?.takeIf { it.identity.value == id } ?: storage.import(uri)
                        val validate = validators[id] ?: run {
                            val stamp = EditorAdjustmentHistory.sourceValidation(photo)
                            val hash = BatchFrozenSettings.checksum(photo.file)
                            val checkSource: () -> Unit = { stamp(); check(BatchFrozenSettings.checksum(photo.file) == hash) { "Photo source changed" } }
                            SourceValidation(stamp, checkSource)
                        }
                        validate.content()
                        imported[id] = photo; validators[id] = validate
                        additions += BatchTarget(photo.identity, photo.file, photo.name, photo.uri.toString(), photo.inputKind,
                            sourceIsHDR = photo.isHDRSource)
                    } catch (error: Exception) {
                        val id = uri.toString()
                        failures[id] = error.message ?: error.javaClass.simpleName
                        // 保留失败 URI 的位置，恢复授权后可明确重试；该占位路径从不作为已验证输入。
                        val missing = File(journalRoot, "unavailable/${java.util.UUID.nameUUIDFromBytes(id.toByteArray())}")
                        additions += BatchTarget(PhotoIdentity(id), imported[id]?.file ?: missing,
                            imported[id]?.name ?: uri.lastPathSegment.orEmpty(), id,
                            imported[id]?.inputKind ?: com.rawlab.android.format.PhotoInputKind.RAW)
                    }
                }
            } }
            mutable.update { it.acceptImports(additions, failures).copy(busy = false) }
        }
    }
    fun refresh() {
        if (mutable.value.busy) return
        val photos = mutable.value.photos
        scope.launch {
            val failures = withContext(Dispatchers.IO) { photos.mapNotNull { target ->
                runCatching { validate(target) }.exceptionOrNull()?.let { target.id to (it.message ?: "Photo source unavailable") }
            }.toMap() }
            mutable.update { it.copy(failures = failures.filterKeys { id -> it.photos.any { photo -> photo.id == id } }) }
        }
    }
    fun prepare(skipping: Set<String>, format: ExportFormat, longEdge: Int?, destination: Uri?,
        completed: (CollectionExportReview?) -> Unit) {
        if (mutable.value.busy) { completed(null); return }
        val selection = mutable.value
        val validateActive = captureActiveValidation()
        mutable.update { it.copy(busy = true, error = null) }
        scope.launch {
            try {
                val review = withContext(Dispatchers.IO) { synchronized(storage) {
                    exporter.prepare(selection, skipping, format, longEdge, destination?.toString(), validateActive)
                } }
                completed(review)
            } catch (error: Exception) { failure(error.message); completed(null) }
            finally { mutable.update { it.copy(busy = false) } }
        }
    }
    fun freeze(review: CollectionExportReview, completed: (BatchJob?) -> Unit) {
        if (mutable.value.busy) { completed(null); return }
        val selection = mutable.value
        val validateActive = captureActiveValidation()
        mutable.update { it.copy(busy = true, error = null) }
        scope.launch {
            try {
                val job = withContext(Dispatchers.IO) { synchronized(storage) { exporter.freeze(selection, review, validateActive) } }
                completed(job)
            } catch (error: Exception) { failure(error.message); completed(null) }
            finally { mutable.update { it.copy(busy = false) } }
        }
    }
}

data class CollectionSynchronization(val sourceIdentity: String, val sourceName: String,
    val payload: com.rawlab.android.adjustments.AdjustmentPayload, val targets: List<Uri>)

// 纯模型保留可测试的错误信息；界面统一转换为应用当前语言。
internal fun collectionMessage(message: String): String {
    val resource = when (message) {
        "Invalid output size" -> com.rawlab.android.R.string.output_size_error
        "Photo look is unavailable" -> com.rawlab.android.R.string.collection_look_unavailable
        "Photo look changed" -> com.rawlab.android.R.string.collection_look_changed
        "Review the selected photos again" -> com.rawlab.android.R.string.collection_selection_changed
        "Photo source changed" -> com.rawlab.android.R.string.collection_source_changed
        "Photo source unavailable", "Photo source is unavailable", "Photo left the collection" -> com.rawlab.android.R.string.collection_source_unavailable
        "Cannot create batch inputs" -> com.rawlab.android.R.string.collection_storage_error
        "Apply, discard or skip this photo's draft" -> com.rawlab.android.R.string.collection_draft_error
        "Choose a source photo first" -> com.rawlab.android.R.string.collection_choose_source
        "No targets remain after excluding the source photo" -> com.rawlab.android.R.string.collection_no_sync_targets
        "Close the current export task first" -> com.rawlab.android.R.string.collection_existing_job
        "Photo adjustments changed after they were read" -> com.rawlab.android.R.string.transfer_conflict_message
        else -> return com.rawlab.android.i18n.AppStrings.text(com.rawlab.android.R.string.process_error) + "\n" + message
    }
    return com.rawlab.android.i18n.AppStrings.text(resource)
}
