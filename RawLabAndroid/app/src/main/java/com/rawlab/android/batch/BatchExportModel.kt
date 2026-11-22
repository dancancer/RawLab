package com.rawlab.android.batch

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.getAndUpdate
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
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
import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.format.PhotoFiles
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.photo.BatchGlobalFailure
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.photo.WorkingCopy
import com.rawlab.android.photo.WorkingCopyStorageFull
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.requireProRAWDecoder
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.X3fMode
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

    fun configuredFor(
        format: ExportFormat,
        destination: Uri?,
        longEdge: Int?,
        outputSharpening: OutputSharpening = OutputSharpening.OFF,
    ): BatchExportState {
        val effectiveSharpening = if (format == ExportFormat.DNG) OutputSharpening.OFF else outputSharpening
        require(job.settingsMode != BatchSettingsMode.PER_TARGET_FROZEN ||
            (format == job.outputFormat && longEdge == job.outputLongEdge &&
                effectiveSharpening == job.effectiveOutputSharpening && destination?.toString() == job.destination)) {
            "Frozen export settings cannot be changed"
        }
        return copy(
        job = job.copy(outputFormat = format, destination = destination?.toString(), outputLongEdge = longEdge,
            outputSharpening = effectiveSharpening,
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

    // 预检尚未产生 CANCELLED 行，需要直接读取首次停止请求的原因。
    fun cancellationOutcome(): UsageBatchOutcome = reason.get() ?: UsageBatchOutcome.Interrupted

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
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val confirmations = BatchConfirmations(ioScope)
    private val resolver = context.contentResolver
    private val cancelRequested = BatchCancellation()
    private val activeProcessor = AtomicReference<NativeProcessor?>(null)
    @Volatile private var running: Job? = null
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
            val additions = withContext(Dispatchers.IO) {
                val snapshot = mutable.value.job
                val inputsRoot = File(context.filesDir, "RawLab/BatchJobs/${snapshot.id}/inputs")
                val spaceError = try {
                    preflightBatchInputsSpace(
                        uris = uris,
                        resolver = resolver,
                        inputsRoot = inputsRoot,
                        destinationFor = { uri ->
                            inputFile(snapshot.id, PhotoIdentity(uri.toString()), displayName(uri))
                        },
                    )
                    null
                } catch (_: WorkingCopyStorageFull) {
                    AppStrings.text(R.string.system_open_storage_full)
                }
                if (spaceError != null) {
                    failures += spaceError
                    return@withContext emptyList()
                }
                var batchProcessor: NativeProcessor? = null
                fun sharedProcessor(): NativeProcessor =
                    batchProcessor ?: processorFactory(gpuMode, storage.lensDatabase()).also { batchProcessor = it }
                try {
                    uris.mapNotNull { uri ->
                        if (cancelRequested.get()) null else try {
                            copyTarget(uri, ::sharedProcessor)
                        } catch (_: WorkingCopyStorageFull) {
                            failures += "${displayName(uri)}: ${AppStrings.text(R.string.system_open_storage_full)}"
                            null
                        } catch (error: Exception) {
                            failures += "${displayName(uri)}: ${error.message}"
                            null
                        }
                    }
                } finally {
                    batchProcessor?.close()
                }
            }
            val error = failures.takeIf { it.isNotEmpty() }?.joinToString("\n")
            mutable.update { current ->
                val existing = current.job.rows.mapTo(mutableSetOf()) { it.id }
                val accepted = additions.filter { existing.add(it.identity.value) }
                val all = current.job.rows.map { it.target } + accepted
                current.copy(job = BatchJob(current.job.source, all,
                    id = current.job.id, outputFormat = current.job.outputFormat,
                    outputLongEdge = current.job.outputLongEdge, destination = current.job.destination,
                    outputSharpening = current.job.outputSharpening),
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
                    outputLongEdge = current.job.outputLongEdge, destination = current.job.destination,
                    outputSharpening = current.job.outputSharpening))
            }
        }
    }

    fun start(
        format: ExportFormat,
        destination: Uri?,
        longEdge: Int? = null,
        outputSharpening: OutputSharpening = OutputSharpening.OFF,
    ) {
        startInternal(format, destination, longEdge, outputSharpening, retry = false)
    }

    private fun startInternal(
        format: ExportFormat,
        destination: Uri?,
        longEdge: Int?,
        outputSharpening: OutputSharpening,
        retry: Boolean,
    ) {
        val effectiveSharpening = if (format == ExportFormat.DNG) OutputSharpening.OFF else outputSharpening
        val validationError = when {
            mutable.value.job.settingsMode == BatchSettingsMode.PER_TARGET_FROZEN &&
                (format != mutable.value.job.outputFormat || longEdge != mutable.value.job.outputLongEdge ||
                    effectiveSharpening != mutable.value.job.effectiveOutputSharpening ||
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
            if (it.canStart(retry)) it.configuredFor(format, destination, longEdge, effectiveSharpening) else it
        }
        if (!previous.canStart(retry)) return
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
                val materialized = prepareBatchStart(confirmations, mutable, journalRoot) { configured ->
                    val ready = if (configured.settingsMode == BatchSettingsMode.UNIFORM_FROZEN && configured.source.settings.isHDREditing)
                        hdrPreparation(configured.source).freeze(configured, journalRoot, cancelRequested::get) else configured
                    if (ready.settingsMode == BatchSettingsMode.UNIFORM_FROZEN && !ready.source.sourceFile.isFile) {
                        throw BatchGlobalFailure(AppStrings.text(R.string.message_task_source_unavailable))
                    }
                    if (ready.settingsMode == BatchSettingsMode.UNIFORM_FROZEN && (ready.source.settings.film != "neutral" || ready.source.settings.recipeID != null) && ready.source.lookFile?.isFile != true) {
                        throw BatchGlobalFailure(AppStrings.text(R.string.message_the_task_source_or_look_file_is))
                    }
                    ready
                }
                val journal = BatchJournal(journalRoot)
                val processor = processorFactory(gpuMode, storage.lensDatabase())
                val cancellationGeneration = processor.cancellationGeneration()
                activeProcessor.set(processor)
                if (cancelRequested.get()) processor.cancelPreview()
                val result = try {
                    val output = BatchOutputPublisher(context, storage, processor, materialized, destination, gpuMode, cancellationGeneration)
                    mutable.update { it.copy(phase = BatchPhase.RUNNING) }
                    BatchRunner.run(materialized, output::render, { _, _, _ -> }, cancelRequested::get, journal,
                        didUpdate = {
                            attempted.addAll(it.rows.filter { row -> row.status == BatchRowStatus.PROCESSING }.map { row -> row.id })
                            mutable.update { current -> current.copy(job = it) }
                        }, dispose = { it.delete() }, publish = { rendered, name, _, checkpoint -> output.publish(rendered, name, checkpoint) },
                        onlyIDs = if (retry) materialized.rows.filter { it.status == BatchRowStatus.FAILED }.map { it.id }.toSet() else null,
                        resolveX3fMode = x3fModeResolver())
                } finally { activeProcessor.compareAndSet(processor, null); processor.close() }
                mutable.value = BatchExportState(result,
                    phase = when {
                        result.globalError != null -> BatchPhase.FAILED
                        result.rows.any { it.status in setOf(BatchRowStatus.CANCELLED, BatchRowStatus.NEEDS_CONFIRMATION) } -> BatchPhase.CANCELLED
                        result.rows.any { it.status == BatchRowStatus.FAILED } -> BatchPhase.FAILED
                        else -> BatchPhase.COMPLETE
                    }, outputFormat = format, destination = destination, error = result.globalError)
                reportTerminal(result, cancelRequested.outcome(result))
            } catch (error: CancellationException) {
                mutable.update { it.copy(phase = if(it.job.settingsMode==BatchSettingsMode.UNIFORM_FROZEN && it.job.source.settings.isHDREditing)
                    BatchPhase.SELECTING else BatchPhase.CANCELLED, stopping = false, error = null) }
                reportTerminal(mutable.value.job, cancelRequested.cancellationOutcome())
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
        startInternal(current.outputFormat, current.destination, current.job.outputLongEdge,
            current.job.effectiveOutputSharpening, retry = false)
    }

    fun retryFailed() {
        val current = mutable.value
        startInternal(current.outputFormat, current.destination, current.job.outputLongEdge,
            current.job.effectiveOutputSharpening, retry = true)
    }

    fun cancel(forBackground: Boolean = false) {
        cancelRequested.request(interrupted = forBackground)
        activeProcessor.get()?.cancelPreview()
        mutable.update {
            if (it.phase in setOf(BatchPhase.RUNNING, BatchPhase.PREPARING)) it.copy(stopping = true) else it
        }
    }

    private fun copyTarget(uri: Uri, obtainProcessor: () -> NativeProcessor): BatchTarget {
        val identity = PhotoIdentity(uri.toString())
        val name = displayName(uri)
        val inputKind = PhotoFiles.kind(name, resolver.getType(uri))
            ?: throw IOException(AppStrings.text(R.string.message_not_a_supported_raw_file))
        val snapshot = mutable.value.job
        val destination = inputFile(snapshot.id, identity, name)
        val candidate = BatchTarget(identity, destination, name, uri.toString(), inputKind)
        if (!destination.exists()) {
            val expectedBytes = WorkingCopy.declaredBytes(resolver, uri)
            val input = resolver.openInputStream(uri) ?: throw IOException(AppStrings.text(R.string.message_unable_to_read_file))
            try {
                WorkingCopy.copyTo(
                    destination = destination,
                    input = input,
                    expectedBytes = expectedBytes,
                    spaceDirectory = destination.parentFile ?: File("."),
                )
                val x3fMode = if (candidate.isX3f) x3fModeResolver()(candidate) else snapshot.source.settings.x3fMode
                obtainProcessor().preview(destination, null, EditSettings(processing = snapshot.source.settings.processing, x3fMode = x3fMode), 256, false, inputKind)
            } catch (error: Exception) { destination.delete(); throw error }
        }
        val hdrInfo = com.rawlab.android.engine.NativeHDRBridge.probeSource(destination, inputKind == PhotoInputKind.RAW)
        return candidate.copy(sourceIsHDR = hdrInfo != null)
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
            val lookSource = if (job.source.settings.isHDREditing) null else storage.lookPath(job.source.settings)
            val neededBytes = (if (!sourceCopy.exists()) job.source.sourceFile.length() else 0L) +
                (lookSource?.length() ?: 0L)
            WorkingCopy.requireTotalSpace(journalRoot, neededBytes)
            if (!sourceCopy.exists()) WorkingCopy.copyFile(job.source.sourceFile, sourceCopy, journalRoot)
            lookSource?.let { original ->
                File(journalRoot, "${job.id}/look.${original.extension}").also {
                    WorkingCopy.copyFile(original, it, journalRoot)
                }
            }
        }
        return job.copy(source = job.source.copy(sourceFile = sourceCopy, lookFile = look))
    }

    private fun hdrPreparation(source: BatchSourceSnapshot): BatchHDRPreparation = BatchHDRPreparation(source,
        EditStore(File(context.filesDir,"edits"))::readState,storage::lookPath,
        com.rawlab.android.engine.NativeHDRBridge::probeSource, storage.hdrLookDirectory, storage.hdrCameraProfileDirectory)

    private fun x3fModeResolver(): (BatchTarget) -> X3fMode =
        BatchJob.x3fModeResolver(EditStore(File(context.filesDir, "edits"))::readState)

    private fun inputFile(jobID: String, identity: PhotoIdentity, name: String): File {
        com.rawlab.android.photo.WorkingCopyCleanup.protect(File(journalRoot, jobID))
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
                    hdrPreparation(snapshot.source).prepare(target,0,snapshot.outputFormat,snapshot.outputLongEdge,snapshot.effectiveOutputSharpening) else target.frozen
                val settings = prepared?.settings ?: snapshot.settingsFor(target, x3fModeResolver())
                if (settings.isHDREditing) {
                    if (gpuMode == NativeProcessor.FORCE) throw com.rawlab.android.engine.HDRProcessingException(2,13,6)
                    val info = requireNotNull(com.rawlab.android.engine.NativeHDRBridge.probeSource(
                        target.sourceFile, target.inputKind == PhotoInputKind.RAW, settings.processing.version))
                    if (info.isProRAW) settings.requireProRAWDecoder()
                    val decoded = if (info.isCameraRaw) it.decodeHDRCamera(target.sourceFile, info, 1280,
                        camera = requireNotNull(settings.hdr).cameraSettings, profileDirectory = storage.hdrCameraProfileDirectory)
                        else com.rawlab.android.engine.NativeHDRBridge.decode(target.sourceFile, info, 1280)
                    decoded.use { source ->
                        it.setGpuMode(NativeProcessor.CPU)
                        it.renderHDR(source, requireNotNull(settings.hdr).copy(geometry = settings.geometry), 1280,
                            lookDirectory = storage.hdrLookDirectory).use { pair -> pair.sdrBitmap() }
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
        confirmations.launch {
            confirmBatchOutput(
                lock = confirmations.lock,
                journalRoot = journalRoot,
                id = id,
                saved = saved,
                currentJob = { mutable.value.job },
                updateJob = { mutable.update { it.copy(job = it.job.confirmedOutput(id, saved)) } },
                onError = { error -> mutable.update { it.copy(error = error.message) } },
            )
        }
    }

    fun setDestination(destination: Uri?) { mutable.update {
        if (it.job.settingsMode == BatchSettingsMode.PER_TARGET_FROZEN) it else it.copy(destination = destination)
    } }

    fun discardDraftOrCompleted(): Deferred<Unit>? {
        discardCompletion?.let { return it }
        return discardBatchDraftOrCompleted(
            currentJob = { mutable.value.job },
            initialJobId = initialJob.id,
            journalRoot = journalRoot,
            rootJob = scope.coroutineContext[Job]!!,
            ioScope = ioScope,
            confirmations = confirmations,
            onDiscarding = { discardCompletion = it },
            closeModel = ::close,
        )
    }

    fun discard(): Boolean {
        if (mutable.value.phase in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING)) return false
        return try { discardAfterWork(); true }
        catch (error: Exception) { mutable.update { it.copy(error = error.message) }; false }
    }

    private fun discardAfterWork() {
        if (discardCompletion != null) return
        discardCompletion = discardBatchAfterWork(
            initialJobId = initialJob.id,
            journalRoot = journalRoot,
            rootJob = scope.coroutineContext[Job]!!,
            ioScope = ioScope,
            confirmations = confirmations,
            closeModel = ::close,
        )
    }

    override fun close() {
        cancelRequested.request(interrupted = true)
        val job = running
        if (job?.isActive == true) job.invokeOnCompletion { scope.coroutineContext[Job]?.cancel() }
        else scope.coroutineContext[Job]?.cancel()
    }
}

internal fun preflightBatchInputsSpace(
    uris: Iterable<Uri>,
    resolver: ContentResolver,
    inputsRoot: File,
    destinationFor: (Uri) -> File,
    declaredBytes: (ContentResolver, Uri) -> Long = WorkingCopy::declaredBytes,
    requireSpace: (File, Long) -> Unit = WorkingCopy::requireTotalSpace,
) {
    var totalBytes = 0L
    for (uri in uris) {
        if (destinationFor(uri).exists()) continue
        val bytes = declaredBytes(resolver, uri)
        if (bytes > 0L) {
            totalBytes = if (Long.MAX_VALUE - totalBytes < bytes) Long.MAX_VALUE else totalBytes + bytes
        }
    }
    requireSpace(inputsRoot, totalBytes)
}

internal class BatchConfirmations(private val scope: CoroutineScope) {
    val lock = Mutex()
    private val pending = mutableSetOf<Job>()

    fun launch(block: suspend () -> Unit): Job {
        val job = scope.launch(start = CoroutineStart.LAZY) { block() }
        synchronized(pending) { pending.add(job) }
        job.invokeOnCompletion { synchronized(pending) { pending.remove(job) } }
        job.start()
        return job
    }

    suspend fun awaitPending() {
        val snapshot = synchronized(pending) { pending.toList() }
        snapshot.joinAll()
    }
}

internal suspend fun prepareBatchStart(
    confirmations: BatchConfirmations,
    state: MutableStateFlow<BatchExportState>,
    journalRoot: File,
    materialize: (BatchJob) -> BatchJob,
): BatchJob {
    // 确认任务也需要这把锁，必须先等全部已提交确认，再读取最新状态。
    confirmations.awaitPending()
    return confirmations.lock.withLock {
        val materialized = materialize(state.value.job)
        state.update { it.copy(job = materialized) }
        BatchJournal(journalRoot).save(materialized)
        materialized
    }
}

internal suspend fun confirmBatchOutput(
    lock: Mutex,
    journalRoot: File,
    id: String,
    saved: Boolean,
    currentJob: () -> BatchJob,
    updateJob: () -> Unit,
    onError: (Exception) -> Unit,
    ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    lock.withLock {
        withContext(NonCancellable) {
            val updated = currentJob().confirmedOutput(id, saved)
            try {
                withContext(ioDispatcher) { BatchJournal(journalRoot).save(updated) }
                updateJob()
            } catch (error: Exception) {
                onError(error)
            }
        }
    }
}

internal fun discardBatchAfterWork(
    initialJobId: String,
    journalRoot: File,
    rootJob: Job,
    ioScope: CoroutineScope,
    confirmations: BatchConfirmations = BatchConfirmations(ioScope),
    closeModel: () -> Unit,
): CompletableDeferred<Unit> {
    val completion = CompletableDeferred<Unit>()
    rootJob.invokeOnCompletion {
        ioScope.launch {
            try {
                confirmations.awaitPending()
                confirmations.lock.withLock { BatchJournal(journalRoot).discard(initialJobId) }
                completion.complete(Unit)
            } catch (error: Exception) {
                completion.completeExceptionally(error)
            }
        }
    }
    closeModel()
    return completion
}

internal fun discardBatchDraftOrCompleted(
    currentJob: () -> BatchJob,
    initialJobId: String,
    journalRoot: File,
    rootJob: Job,
    ioScope: CoroutineScope,
    confirmations: BatchConfirmations = BatchConfirmations(ioScope),
    onDiscarding: (CompletableDeferred<Unit>) -> Unit = {},
    closeModel: () -> Unit,
): CompletableDeferred<Unit> {
    // 失败 phase 不代表已持久化；journal 决定副本是否需要保留。
    // 仅在确实触发清理时通过 onDiscarding 缓存 completion，避免未完成持久化任务的空操作毒化后续 discard()。
    val completion = CompletableDeferred<Unit>()
    ioScope.launch {
        try {
            confirmations.awaitPending()
            val shouldDiscard = confirmations.lock.withLock {
                val job = currentJob()
                (job.rows.all { it.status == BatchRowStatus.SUCCESS } || !BatchJournal(journalRoot).contains(job.id)).also {
                    if (it) { onDiscarding(completion); closeModel() }
                }
            }
            if (shouldDiscard) {
                // running 可能还要拿确认锁，等模型退出时不能持锁。
                rootJob.join()
                confirmations.lock.withLock { BatchJournal(journalRoot).discard(initialJobId) }
            }
            completion.complete(Unit)
        } catch (error: Exception) {
            completion.completeExceptionally(error)
        }
    }
    return completion
}
