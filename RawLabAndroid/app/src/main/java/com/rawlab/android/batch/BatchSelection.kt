package com.rawlab.android.batch

import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.ExportSize
import com.rawlab.android.settings.*
import java.io.File
import java.util.UUID

/** 集合只持有会话选择；跳过项属于具体操作，不能回写这里。 */
data class BatchSelectionState(
    val photos: List<BatchTarget> = emptyList(),
    val selected: Set<String> = emptySet(),
    val currentID: String? = null,
    val returnPosition: Int = 0,
    val lastSynchronization: UUID? = null,
    val failures: Map<String, String> = emptyMap(),
    val busy: Boolean = false,
    val error: String? = null,
) {
    val selectedPhotos get() = photos.filter { it.id in selected }
    fun append(additions: List<BatchTarget>): BatchSelectionState {
        val known = photos.mapTo(mutableSetOf()) { it.id }
        val accepted = additions.filter { known.add(it.id) }
        return copy(photos = photos + accepted, selected = selected + accepted.map { it.id })
    }
    fun acceptImports(additions: List<BatchTarget>, errors: Map<String, String>): BatchSelectionState {
        val replacements = additions.associateBy { it.id }
        return copy(photos = photos.map { replacements[it.id] ?: it },
            failures = (failures - replacements.keys) + errors).append(additions)
    }
    fun select(id: String, value: Boolean) = if (photos.none { it.id == id }) this else
        copy(selected = if (value) selected + id else selected - id)
    fun remove(id: String) = copy(photos = photos.filterNot { it.id == id }, selected = selected - id,
        currentID = currentID?.takeUnless { it == id }, failures = failures - id)
    fun beginEditing(id: String): BatchSelectionState {
        val position = photos.indexOfFirst { it.id == id }
        return if (position < 0) this else copy(currentID = id, returnPosition = position)
    }
    fun returnToCollection() = copy(currentID = null)
    fun synchronizationTargets(sourceIdentity: String) = selectedPhotos.filterNot { it.id == sourceIdentity }
    fun recordSynchronization(id: UUID, changed: Boolean) = if (changed) copy(lastSynchronization = id) else this
}

data class CollectionExportReview(val selectionIDs: List<String>, val rows: List<Row>,
    val format: ExportFormat, val longEdge: Int?, val destination: String?) {
    data class Row(val target: BatchTarget, val record: VersionedPhotoEdit? = null,
        val settings: EditSettings? = null, val inputSHA256: String? = null,
        val look: File? = null, val lookSHA256: String? = null, val error: String? = null)
    val ready get() = rows.isNotEmpty() && rows.all { it.error == null && it.record != null && it.settings != null && it.inputSHA256 != null }
}

/** 预检和最终确认分别读取 revision；任务仅持有自己的输入、外观与参数快照。 */
class BatchSelectionExport(private val directory: File,
    private val readRecord: (PhotoIdentity) -> VersionedPhotoEdit,
    private val resolveLook: (EditSettings) -> File?,
    private val validateSource: (BatchTarget) -> Unit = {},
) {
    fun prepare(selection: BatchSelectionState, skipping: Set<String>, format: ExportFormat, longEdge: Int?,
        destination: String?, validateActive: (String) -> Unit): CollectionExportReview {
        require(ExportSize.isValid(longEdge)) { "Invalid output size" }
        val rows = selection.selectedPhotos.filterNot { it.id in skipping }.map { photo ->
            try {
                validateActive(photo.id); validateSource(photo)
                val inputHash = BatchFrozenSettings.checksum(photo.sourceFile)
                val record = readRecord(photo.identity)
                val settings = record.settings ?: EditSettings()
                val look = resolveLook(settings)
                check((settings.film == "neutral" && settings.recipeID == null) || look != null) { "Photo look is unavailable" }
                CollectionExportReview.Row(photo, record, settings, inputHash, look, look?.let(BatchFrozenSettings::checksum))
            } catch (error: Exception) { CollectionExportReview.Row(photo, error = error.message ?: error.javaClass.simpleName) }
        }
        return CollectionExportReview(selection.selectedPhotos.map { it.id }, rows, format, longEdge, destination)
    }

    fun freeze(selection: BatchSelectionState, review: CollectionExportReview, validateActive: (String) -> Unit): BatchJob {
        check(review.ready && selection.selectedPhotos.map { it.id } == review.selectionIDs) { "Review the selected photos again" }
        fun validate() {
            for (row in review.rows) {
                validateActive(row.target.id); validateSource(row.target)
                if (readRecord(row.target.identity) != row.record) throw EditPersistenceConflict()
                check(BatchFrozenSettings.checksum(row.target.sourceFile) == row.inputSHA256) { "Photo source changed" }
                check(row.look?.let(BatchFrozenSettings::checksum) == row.lookSHA256) { "Photo look changed" }
            }
        }
        validate()
        val id = UUID.randomUUID().toString()
        val folder = File(directory, id)
        check(!folder.exists() && folder.mkdirs()) { "Cannot create batch inputs" }
        val journal = BatchJournal(directory)
        try {
            val targets = review.rows.mapIndexed { index, row ->
                val extension = row.target.displayName.substringAfterLast('.', "raw").replace(Regex("[^A-Za-z0-9]"), "").ifEmpty { "raw" }
                val input = row.target.sourceFile.copyTo(File(folder, "input-$index.$extension"))
                val look = row.look?.copyTo(File(folder, "look-$index.${row.look.extension}"))
                val frozen = BatchFrozenSettings(ordinal = index, settings = row.settings!!,
                    inputSHA256 = row.inputSHA256!!, lookFile = look, lookSHA256 = row.lookSHA256,
                    outputFormat = review.format, longEdge = review.longEdge)
                frozen.verifyFiles(input)
                row.target.copy(sourceFile = input, frozen = frozen)
            }
            validate()
            val first = targets.first()
            val source = BatchSourceSnapshot(first.identity, first.sourceFile, first.frozen!!.settings,
                first.displayName, inputKind = first.inputKind)
            val job = BatchJob(source, targets, id = id, outputFormat = review.format, outputLongEdge = review.longEdge,
                destination = review.destination, settingsMode = BatchSettingsMode.PER_TARGET_FROZEN)
            job.validate(); journal.save(job)
            return job
        } catch (error: Throwable) { journal.discard(id); throw error }
    }
}
