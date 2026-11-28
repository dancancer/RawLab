package com.rawlab.android.batch

import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.ExportSize
import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.photo.WorkingCopy
import com.rawlab.android.settings.*
import java.io.File
import java.security.DigestInputStream
import java.security.MessageDigest
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
    fun supportsHDRExport(readRecord: (PhotoIdentity, Boolean) -> PhotoEditState, skipping: Set<String> = emptySet()): Boolean {
        val targets = selectedPhotos.filterNot { it.id in skipping }
        return targets.isNotEmpty() && targets.all { photo ->
            photo.sourceIsHDR && runCatching {
                (readRecord(photo.identity, photo.isX3f).settings ?: sourceDefaultSettings(photo.sourceIsHDR,
                    cameraRaw = photo.inputKind == com.rawlab.android.format.PhotoInputKind.RAW)).isHDREditing
            }.getOrDefault(false)
        }
    }
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
    val format: ExportFormat, val longEdge: Int?, val destination: String?,
    val outputSharpening: OutputSharpening = OutputSharpening.OFF) {
    data class Row(val target: BatchTarget, val record: PhotoEditState? = null,
        val settings: EditSettings? = null, val inputSHA256: String? = null,
        val look: File? = null, val lookSHA256: String? = null, val error: String? = null,
        val editGeneration: Long = 0L)
    val ready get() = rows.isNotEmpty() && rows.all { it.error == null && it.record != null && it.settings != null && it.inputSHA256 != null }
}

/** 预检冻结确认页的输入、外观与参数快照；确认前由本会话代次校验目标是否仍有效。 */
class BatchSelectionExport(private val directory: File,
    private val readRecord: (PhotoIdentity, Boolean) -> PhotoEditState,
    private val resolveLook: (EditSettings) -> File?,
    private val validateSource: (BatchTarget) -> Unit = {},
    private val validateHDRSource: (BatchTarget, EditSettings) -> Unit = { _, settings -> settings.requireProRAWDecoder() },
    private val editGeneration: (PhotoIdentity) -> Long = { 0L },
) {
    fun prepare(selection: BatchSelectionState, skipping: Set<String>, format: ExportFormat, longEdge: Int?,
        destination: String?, validateActive: (String) -> Unit): CollectionExportReview =
        prepare(selection, skipping, format, longEdge, destination, OutputSharpening.OFF, validateActive)

    fun prepare(selection: BatchSelectionState, skipping: Set<String>, format: ExportFormat, longEdge: Int?,
        destination: String?, outputSharpening: OutputSharpening,
        validateActive: (String) -> Unit): CollectionExportReview {
        require(ExportSize.isValid(longEdge)) { "Invalid output size" }
        val effectiveSharpening = if (format == ExportFormat.DNG) OutputSharpening.OFF else outputSharpening
        val rows = selection.selectedPhotos.filterNot { it.id in skipping }.map { photo ->
            try {
                validateActive(photo.id); validateSource(photo)
                val generation = editGeneration(photo.identity)
                val inputHash = BatchFrozenSettings.checksum(photo.sourceFile)
                val record = readRecord(photo.identity, photo.isX3f)
                val settings = record.settings ?: com.rawlab.android.photo.defaultEditSettingsFor(photo.sourceFile, photo.inputKind, photo.sourceIsHDR, cameraRaw = photo.inputKind == com.rawlab.android.format.PhotoInputKind.RAW)
                if (settings.isHDREditing && !photo.sourceIsHDR)
                    throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "hdr.source")
                if (settings.isHDREditing) validateHDRSource(photo, settings)
                require(format != ExportFormat.HDR_JPEG || settings.isHDREditing) { "HDR JPEG requires HDR editing" }
                val look = if (settings.isHDREditing) null else resolveLook(settings)
                check(settings.isHDREditing || (settings.film == "neutral" && settings.recipeID == null) || look != null) { "Photo look is unavailable" }
                CollectionExportReview.Row(photo, record, settings, inputHash, look, look?.let(BatchFrozenSettings::checksum),
                    editGeneration = generation)
            } catch (error: Exception) { CollectionExportReview.Row(photo, error = error.message ?: error.javaClass.simpleName) }
        }
        return CollectionExportReview(selection.selectedPhotos.map { it.id }, rows, format, longEdge, destination, effectiveSharpening)
    }

    fun freeze(selection: BatchSelectionState, review: CollectionExportReview, validateActive: (String) -> Unit): BatchJob {
        check(review.ready && selection.selectedPhotos.map { it.id } == review.selectionIDs) { "Review the selected photos again" }
        fun validateMetadata() {
            for (row in review.rows) {
                validateActive(row.target.id); validateSource(row.target)
                if (editGeneration(row.target.identity) != row.editGeneration)
                    throw AdjustmentOperationExpiredException()
            }
        }
        validateMetadata()
        val seenLooks = mutableSetOf<String>()
        var totalBytes = 0L
        for (row in review.rows) {
            val srcBytes = row.target.sourceFile.length()
            totalBytes = if (Long.MAX_VALUE - totalBytes < srcBytes) Long.MAX_VALUE else totalBytes + srcBytes
            val lookSha = row.lookSHA256
            val lookFile = row.look
            if (lookFile != null && lookSha != null && seenLooks.add(lookSha)) {
                val lookBytes = lookFile.length()
                totalBytes = if (Long.MAX_VALUE - totalBytes < lookBytes) Long.MAX_VALUE else totalBytes + lookBytes
            }
        }
        WorkingCopy.requireTotalSpace(directory, totalBytes)
        val id = UUID.randomUUID().toString()
        val folder = File(directory, id).also(com.rawlab.android.photo.WorkingCopyCleanup::protect)
        check(!folder.exists() && folder.mkdirs()) { "Cannot create batch inputs" }
        val journal = BatchJournal(directory)
        try {
            val targets = review.rows.mapIndexed { index, row ->
                val extension = row.target.displayName.substringAfterLast('.', "raw").replace(Regex("[^A-Za-z0-9]"), "").ifEmpty { "raw" }
                val input = File(folder, "input-$index.$extension")
                copyAndVerifySha256(row.target.sourceFile, input, row.inputSHA256!!, directory, "Photo source changed")
                val look = row.look?.let { source ->
                    File(folder, "${row.lookSHA256}.${source.extension}").also {
                        if (!it.exists()) {
                            copyAndVerifySha256(source, it, row.lookSHA256!!, directory, "Photo look changed")
                        }
                    }
                }
                val effectiveSharpening = if (review.format == ExportFormat.DNG) OutputSharpening.OFF else review.outputSharpening
                val frozen = BatchFrozenSettings(ordinal = index, settings = row.settings!!,
                    inputSHA256 = row.inputSHA256, lookFile = look, lookSHA256 = row.lookSHA256,
                    outputFormat = review.format, longEdge = review.longEdge,
                    outputSharpening = effectiveSharpening)
                row.target.copy(sourceFile = input, frozen = frozen)
            }
            validateMetadata()
            val first = targets.first()
            val source = BatchSourceSnapshot(first.identity, first.sourceFile, first.frozen!!.settings,
                first.displayName, inputKind = first.inputKind)
            val effectiveSharpening = if (review.format == ExportFormat.DNG) OutputSharpening.OFF else review.outputSharpening
            val job = BatchJob(source, targets, id = id, outputFormat = review.format, outputLongEdge = review.longEdge,
                destination = review.destination, settingsMode = BatchSettingsMode.PER_TARGET_FROZEN,
                outputSharpening = effectiveSharpening)
            job.validate(); journal.save(job)
            return job
        } catch (error: Throwable) { journal.discard(id); throw error }
    }

    private fun copyAndVerifySha256(
        source: File,
        destination: File,
        expectedSha256: String,
        spaceDirectory: File,
        changedMessage: String,
    ) {
        val digest = MessageDigest.getInstance("SHA-256")
        source.inputStream().use { raw ->
            WorkingCopy.copyTo(
                destination = destination,
                input = DigestInputStream(raw, digest),
                expectedBytes = source.length(),
                spaceDirectory = spaceDirectory,
            )
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        check(actual == expectedSha256) { changedMessage }
    }
}

internal suspend fun prepareCollectionReview(
    awaitPending: suspend () -> Unit = {},
    captureActiveValidation: () -> (String) -> Unit,
    runPrepare: suspend ((String) -> Unit) -> CollectionExportReview,
): CollectionExportReview {
    // 预检必须在已提交的编辑落盘后再捕获活动状态与读盘，避免读到旧/空记录。
    awaitPending()
    val validateActive = captureActiveValidation()
    return runPrepare(validateActive)
}
