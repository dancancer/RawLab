package com.rawlab.android.batch

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.getAndUpdate
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicReference
import com.rawlab.android.R
import com.rawlab.android.analytics.UsageBatchOutcome
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.batch.publish.BatchOutputPublisher
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.ExportSize
import com.rawlab.android.format.PhotoFiles
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.photo.BatchGlobalFailure
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.EditStore
import com.rawlab.android.adjustments.AdjustmentTransferException

// ============================================================================
//  批量导出界面的状态与生命周期
// ============================================================================

enum class BatchPhase { SELECTING, PREPARING, RUNNING, CANCELLED, COMPLETE, FAILED }

data class BatchExportState(
    val job: BatchJob,
    val phase: BatchPhase = BatchPhase.SELECTING,
    val outputFormat: ExportFormat = ExportFormat.JPEG,
    val destination: Uri? = null,
    val error: String? = null,
    val stopping: Boolean = false,
) {
    val selectedCount: Int get() = job.rows.size
    val successCount: Int get() = job.rows.count { it.status == BatchRowStatus.SUCCESS }
    val failedCount: Int get() = job.rows.count { it.status == BatchRowStatus.FAILED }
    val confirmationCount: Int get() = job.rows.count { it.status == BatchRowStatus.NEEDS_CONFIRMATION }
    val completionFraction: Float get() = successCount.toFloat() / selectedCount.coerceAtLeast(1)
    val unfinishedCount: Int get() = job.rows.count { it.status !in setOf(BatchRowStatus.SUCCESS, BatchRowStatus.NEEDS_CONFIRMATION) }

    fun canStart(retry: Boolean) = phase !in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING) &&
        job.rows.isNotEmpty() && (!retry || failedCount > 0)

    fun configuredFor(format: ExportFormat, destination: Uri?, longEdge: Int?): BatchExportState {
        require(job.settingsMode != BatchSettingsMode.PER_TARGET_FROZEN ||
            (format == job.outputFormat && longEdge == job.outputLongEdge && destination?.toString() == job.destination)) {
            "Frozen export settings cannot be changed"
        }
        return copy(
        job = job.copy(outputFormat = format, destination = destination?.toString(), outputLongEdge = longEdge,
            rows = job.rows.map { if (it.status == BatchRowStatus.SUCCESS) it else it.copy(outputName = it.outputName.substringBeforeLast('.') + format.suffix) }),
        phase = BatchPhase.PREPARING, outputFormat = format, destination = destination, error = null, stopping = false)
    }
}

private fun BatchJob.confirmedOutput(id: String, saved: Boolean) = withRows(rows.map {
    if (it.id == id && it.status == BatchRowStatus.NEEDS_CONFIRMATION) it.copy(status = if (saved) BatchRowStatus.SUCCESS else BatchRowStatus.PENDING, outputUri = null) else it
})

internal class BatchCancellation {
    private val reason = AtomicReference<UsageBatchOutcome?>(null)

    fun get(): Boolean = reason.get() != null
    fun reset() { reason.set(null) }
    fun request(interrupted: Boolean = false) {
        reason.compareAndSet(null, if (interrupted) UsageBatchOutcome.Interrupted else UsageBatchOutcome.Cancelled)
    }

    fun outcome(job: BatchJob): UsageBatchOutcome = when {
        job.globalError != null || job.rows.any { it.status == BatchRowStatus.NEEDS_CONFIRMATION } -> UsageBatchOutcome.Interrupted
        job.rows.any { it.status == BatchRowStatus.CANCELLED } -> reason.get() ?: UsageBatchOutcome.Cancelled
        job.rows.any { it.status == BatchRowStatus.FAILED } -> UsageBatchOutcome.Partial
        else -> UsageBatchOutcome.Completed
    }
}

class BatchExportModel(
    private val context: Context,
    private val storage: PhotoStorage,
    source: BatchSourceSnapshot,
    initial: BatchJob? = null,
    private val gpuMode: Int = NativeProcessor.AUTO,
    private val processorFactory: (Int, File?) -> NativeProcessor = { mode, database -> NativeProcessor(mode, database) },
    private val onTerminal: (succeeded: Int, failed: Int, outcome: UsageBatchOutcome) -> Unit = { _, _, _ -> },
) : AutoCloseable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val resolver = context.contentResolver
    private val cancelRequested = BatchCancellation()
    private var running: Job? = null
    private var discardCompletion: CompletableDeferred<Unit>? = null
    private val journalRoot = File(context.filesDir, "RawLab/BatchJobs")
    private val initialJob = initial ?: BatchJob(source, emptyList())
    private val mutable = MutableStateFlow(BatchExportState(initialJob, phase = BatchPhase.PREPARING,
        outputFormat = initialJob.outputFormat, destination = initialJob.destination?.let(Uri::parse)))
    val state = mutable.asStateFlow()

    init {
        scope.launch {
            try {
                val ready = withContext(Dispatchers.IO) {
                    if (initial != null) reconcile(initial) else freeze(initialJob)
                }
                mutable.update { it.copy(job = ready, stopping = false,
                    phase = if (initial == null || (initial.settingsMode == BatchSettingsMode.PER_TARGET_FROZEN &&
                        ready.rows.all { it.status == BatchRowStatus.PENDING })) BatchPhase.SELECTING else BatchPhase.CANCELLED) }
            } catch (error: Exception) {
                mutable.update { it.copy(phase = BatchPhase.FAILED, error = error.message, stopping = false) }
            }
        }
    }

    fun addUris(uris: List<Uri>) {
        if (uris.isEmpty() || mutable.value.job.settingsMode != BatchSettingsMode.UNIFORM_FROZEN) return
        val previous = mutable.getAndUpdate {
            if (it.phase == BatchPhase.SELECTING) it.copy(phase = BatchPhase.PREPARING) else it
        }
        if (previous.phase != BatchPhase.SELECTING) return
        cancelRequested.reset()
        scope.launch {
            val failures = mutableListOf<String>()
            val additions = withContext(Dispatchers.IO) { uris.mapNotNull { uri ->
                if (cancelRequested.get()) null else try { copyTarget(uri) } catch (error: Exception) { failures += "${displayName(uri)}: ${error.message}"; null }
            } }
            val error = failures.takeIf { it.isNotEmpty() }?.joinToString("\n")
            mutable.update { current ->
                val existing = current.job.rows.mapTo(mutableSetOf()) { it.id }
                val accepted = additions.filter { existing.add(it.identity.value) }
                val all = current.job.rows.map { it.target } + accepted
                current.copy(job = BatchJob(current.job.source, all,
                    id = current.job.id, outputFormat = current.job.outputFormat,
                    outputLongEdge = current.job.outputLongEdge, destination = current.job.destination),
                    phase = BatchPhase.SELECTING, stopping = false, error = error)
            }
        }
    }

    fun remove(id: String) {
        mutable.update { current ->
            if (current.phase != BatchPhase.SELECTING || current.job.settingsMode != BatchSettingsMode.UNIFORM_FROZEN) current else {
                val targets = current.job.rows.filterNot { it.id == id }.map { it.target }
                current.copy(job = BatchJob(current.job.source, targets,
                    id = current.job.id, outputFormat = current.job.outputFormat,
                    outputLongEdge = current.job.outputLongEdge, destination = current.job.destination))
            }
        }
    }

    fun start(format: ExportFormat, destination: Uri?, longEdge: Int? = null) {
        startInternal(format, destination, longEdge, retry = false)
    }

    private fun startInternal(format: ExportFormat, destination: Uri?, longEdge: Int?, retry: Boolean) {
        val validationError = when {
            mutable.value.job.settingsMode == BatchSettingsMode.PER_TARGET_FROZEN &&
                (format != mutable.value.job.outputFormat || longEdge != mutable.value.job.outputLongEdge ||
                    destination?.toString() != mutable.value.job.destination) -> "Frozen export settings cannot be changed"
            !ExportSize.isValid(longEdge) -> AppStrings.text(R.string.message_enter_a_pixel_count_between_1_and)
            destination == null && !format.allowsGallery -> AppStrings.text(R.string.dng_file_only)
            else -> null
        }
        if (validationError != null) {
            mutable.update { if (it.canStart(retry)) it.copy(error = validationError) else it }
            return
        }
        val previous = mutable.getAndUpdate {
            if (it.canStart(retry)) it.configuredFor(format, destination, longEdge) else it
        }
        if (!previous.canStart(retry)) return
        val configured = previous.configuredFor(format, destination, longEdge).job
        val successBefore = previous.successCount
        val attempted = mutableSetOf<String>()
        var terminalReported = false
        suspend fun reportTerminal(job: BatchJob, outcome: UsageBatchOutcome) {
            if (terminalReported) return
            terminalReported = true
            val succeeded = (job.rows.count { it.status == BatchRowStatus.SUCCESS } - successBefore).coerceAtLeast(0)
            val failed = job.rows.count { it.id in attempted && it.status == BatchRowStatus.FAILED }
            withContext(Dispatchers.Main) { onTerminal(succeeded, failed, outcome) }
        }
        cancelRequested.reset()
        running = scope.launch(Dispatchers.IO) {
            try {
                val materialized = if(configured.settingsMode==BatchSettingsMode.UNIFORM_FROZEN && configured.source.settings.isHDREditing)
                    hdrPreparation(configured.source).freeze(configured,journalRoot,cancelRequested::get) else configured
                mutable.update { it.copy(job = materialized) }
                if (materialized.settingsMode == BatchSettingsMode.UNIFORM_FROZEN && !materialized.source.sourceFile.isFile) {
                    throw BatchGlobalFailure(AppStrings.text(R.string.message_task_source_unavailable))
                }
                if (materialized.settingsMode == BatchSettingsMode.UNIFORM_FROZEN && (materialized.source.settings.film != "neutral" || materialized.source.settings.recipeID != null) && materialized.source.lookFile?.isFile != true) {
                    throw BatchGlobalFailure(AppStrings.text(R.string.message_the_task_source_or_look_file_is))
                }
                val journal = BatchJournal(journalRoot)
                journal.save(materialized)
                val processor = processorFactory(gpuMode, storage.lensDatabase())
                val result = try {
                    val output = BatchOutputPublisher(context, storage, processor, materialized, destination, gpuMode)
                    mutable.update { it.copy(phase = BatchPhase.RUNNING) }
                    BatchRunner.run(materialized, output::render, { _, _, _ -> }, cancelRequested::get, journal,
                        didUpdate = {
                            attempted.addAll(it.rows.filter { row -> row.status == BatchRowStatus.PROCESSING }.map { row -> row.id })
                            mutable.update { current -> current.copy(job = it) }
                        }, dispose = { it.delete() }, publish = { rendered, name, _, checkpoint -> output.publish(rendered, name, checkpoint) },
                        onlyIDs = if (retry) materialized.rows.filter { it.status == BatchRowStatus.FAILED }.map { it.id }.toSet() else null)
                } finally { processor.close() }
                mutable.value = BatchExportState(result,
                    phase = when {
                        result.globalError != null -> BatchPhase.FAILED
                        result.rows.any { it.status in setOf(BatchRowStatus.CANCELLED, BatchRowStatus.NEEDS_CONFIRMATION) } -> BatchPhase.CANCELLED
                        result.rows.any { it.status == BatchRowStatus.FAILED } -> BatchPhase.FAILED
                        else -> BatchPhase.COMPLETE
                    }, outputFormat = format, destination = destination, error = result.globalError)
                reportTerminal(result, cancelRequested.outcome(result))
            } catch (error: Throwable) {
                mutable.update { it.copy(phase = if(it.job.settingsMode==BatchSettingsMode.UNIFORM_FROZEN && it.job.source.settings.isHDREditing)
                    BatchPhase.SELECTING else BatchPhase.FAILED, stopping = false,
                    error = if(error is AdjustmentTransferException) AppStrings.text(R.string.transfer_incompatible) else error.message ?: error.javaClass.simpleName) }
                reportTerminal(mutable.value.job, UsageBatchOutcome.Interrupted)
            }
        }
    }

    fun continueUnfinished() {
        val current = mutable.value
        startInternal(current.outputFormat, current.destination, current.job.outputLongEdge, retry = false)
    }

    fun retryFailed() {
        val current = mutable.value
        startInternal(current.outputFormat, current.destination, current.job.outputLongEdge, retry = true)
    }

    fun cancel(forBackground: Boolean = false) {
        cancelRequested.request(interrupted = forBackground)
        mutable.update {
            if (it.phase in setOf(BatchPhase.RUNNING, BatchPhase.PREPARING)) it.copy(stopping = true) else it
        }
    }

    private fun copyTarget(uri: Uri): BatchTarget {
        val identity = PhotoIdentity(uri.toString())
        val name = displayName(uri)
        val inputKind = PhotoFiles.kind(name, resolver.getType(uri))
            ?: throw IOException(AppStrings.text(R.string.message_not_a_supported_raw_file))
        val snapshot = mutable.value.job
        val destination = inputFile(snapshot.id, identity, name)
        if (!destination.exists()) {
            val input = resolver.openInputStream(uri) ?: throw IOException(AppStrings.text(R.string.message_unable_to_read_file))
            try { input.use { source -> destination.outputStream().use { source.copyTo(it) } }
                processorFactory(gpuMode, storage.lensDatabase()).use {
                    it.preview(destination, null, EditSettings(processing = snapshot.source.settings.processing), 256, false, inputKind)
                }
            } catch (error: Exception) { destination.delete(); throw error }
        }
        val hdr = com.rawlab.android.photo.HDRSourceInfo.mayContainGainMap(name, resolver.getType(uri)) &&
            com.rawlab.android.engine.NativeHDRBridge.probe(destination) != null
        return BatchTarget(identity, destination, name, uri.toString(), inputKind, sourceIsHDR = hdr)
    }

    private fun displayName(uri: Uri): String = runCatching {
        resolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    }.getOrNull() ?: uri.lastPathSegment?.substringAfterLast('/') ?: "RAW"

    private fun freeze(job: BatchJob): BatchJob {
        val sourceIdentity = job.source.identity
        val sourceCopy = inputFile(job.id, sourceIdentity, job.source.displayName)
        val look = synchronized(storage) {
            if (!sourceCopy.exists()) job.source.sourceFile.copyTo(sourceCopy)
            storage.lookPath(job.source.settings)?.let { original ->
                File(journalRoot, "${job.id}/look.${original.extension}").also { original.copyTo(it, overwrite = true) }
            }
        }
        return job.copy(source = job.source.copy(sourceFile = sourceCopy, lookFile = look))
    }

    private fun hdrPreparation(source: BatchSourceSnapshot): BatchHDRPreparation = BatchHDRPreparation(source,
        EditStore(File(context.filesDir,"edits"))::versionedState,storage::lookPath,
        { file -> com.rawlab.android.photo.HDRSourceInfo.mayContainGainMap(file) && com.rawlab.android.engine.NativeHDRBridge.probe(file)!=null })

    private fun inputFile(jobID: String, identity: PhotoIdentity, name: String): File {
        val root = File(context.filesDir, "RawLab/BatchJobs/${jobID}/inputs")
        if (!root.exists()) root.mkdirs()
        val extension = name.substringAfterLast('.', "raw").replace(Regex("[^A-Za-z0-9]"), "")
        val safe = java.security.MessageDigest.getInstance("SHA-256").digest(identity.value.toByteArray()).joinToString("") { "%02x".format(it) }
        return File(root, "${safe}.${extension.ifBlank { "raw" }}")
    }

    suspend fun preview(target: BatchTarget): android.graphics.Bitmap = withContext(Dispatchers.IO) {
        // 取消对话框不能中断 JNI；所有预览仍由 model 持有，关闭后等它们退出再删输入。
        val work = scope.async(Dispatchers.IO) {
            val snapshot = mutable.value.job
            snapshot.validate()
            if (snapshot.settingsMode == BatchSettingsMode.PER_TARGET_FROZEN) target.frozen!!.verifyFiles(target.sourceFile)
            // 效果查看先限长再降噪，最终导出仍保留完整质量。
            processorFactory(gpuMode, storage.lensDatabase()).use {
                val prepared=if(snapshot.settingsMode==BatchSettingsMode.UNIFORM_FROZEN && snapshot.source.settings.isHDREditing)
                    hdrPreparation(snapshot.source).prepare(target,0,snapshot.outputFormat,snapshot.outputLongEdge) else target.frozen
                val settings = prepared?.settings ?: snapshot.settingsFor(target)
                if (settings.isHDREditing) {
                    if (gpuMode == NativeProcessor.FORCE) throw com.rawlab.android.engine.HDRProcessingException(2,13,6)
                    val info = requireNotNull(com.rawlab.android.engine.NativeHDRBridge.probe(target.sourceFile))
                    com.rawlab.android.engine.NativeHDRBridge.decode(target.sourceFile, info, 1280).use { source ->
                        it.setGpuMode(NativeProcessor.CPU)
                        it.renderHDR(source, requireNotNull(settings.hdr).copy(geometry = settings.geometry), 1280).use { pair -> pair.sdrBitmap() }
                    }
                } else it.preview(target.sourceFile, if(prepared!=null)prepared.lookFile else snapshot.lookFor(target), settings, 1280, true, target.inputKind).bitmap()
            }
        }
        try { work.await() }
        catch(error: AdjustmentTransferException) {throw IOException(AppStrings.text(R.string.transfer_incompatible),error)}
        finally { work.cancel() }
    }

    private fun reconcile(job: BatchJob): BatchJob {
        val result = job.withRows(job.rows.map { row ->
            if (row.status != BatchRowStatus.NEEDS_CONFIRMATION || row.outputUri == null) row
            else if (!row.outputReady) {
                val uri = Uri.parse(row.outputUri)
                val deleted = runCatching {
                    if (DocumentsContract.isDocumentUri(context, uri)) DocumentsContract.deleteDocument(resolver, uri)
                    else resolver.delete(uri, null, null) == 1
                }.getOrDefault(false)
                if (deleted) row.copy(status = BatchRowStatus.PENDING, outputUri = null) else row
            }
            else if (runCatching { resolver.openInputStream(Uri.parse(row.outputUri))?.use { it.read() != -1 } == true }.getOrDefault(false)) row.copy(status = BatchRowStatus.SUCCESS)
            else row
        })
        BatchJournal(journalRoot).save(result)
        return result
    }

    fun confirmOutput(id: String, saved: Boolean) {
        val updated = mutable.value.job.confirmedOutput(id, saved)
        try { BatchJournal(journalRoot).save(updated); mutable.update { it.copy(job = it.job.confirmedOutput(id, saved)) } }
        catch (error: Exception) { mutable.update { it.copy(error = error.message) } }
    }

    fun setDestination(destination: Uri?) { mutable.update {
        if (it.job.settingsMode == BatchSettingsMode.PER_TARGET_FROZEN) it else it.copy(destination = destination)
    } }

    fun discardDraftOrCompleted(): Deferred<Unit>? {
        val job = mutable.value.job
        // 失败 phase 不代表已持久化；journal 决定副本是否需要保留。
        if (!BatchJournal(journalRoot).contains(job.id) || job.rows.all { it.status == BatchRowStatus.SUCCESS }) discardAfterWork()
        return discardCompletion
    }

    fun discard(): Boolean {
        if (mutable.value.phase in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING)) return false
        return try { discardAfterWork(); true }
        catch (error: Exception) { mutable.update { it.copy(error = error.message) }; false }
    }

    private fun discardAfterWork() {
        if (discardCompletion != null) return
        val completion = CompletableDeferred<Unit>().also { discardCompletion = it }
        scope.coroutineContext[Job]!!.invokeOnCompletion {
            try { BatchJournal(journalRoot).discard(initialJob.id); completion.complete(Unit) }
            catch (error: Exception) { completion.completeExceptionally(error) }
        }
        close()
    }

    override fun close() {
        cancelRequested.request(interrupted = true)
        val job = running
        if (job?.isActive == true) job.invokeOnCompletion { scope.coroutineContext[Job]?.cancel() }
        else scope.coroutineContext[Job]?.cancel()
    }
}
