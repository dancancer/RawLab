package com.rawlab.android

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
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.atomic.AtomicReference
import java.util.Properties
import java.util.UUID

class BatchGlobalFailure(message: String, cause: Throwable? = null) : IOException(message, cause)
class BatchPublicationUncertain(message: String, cause: Throwable? = null) : IOException(message, cause)

private fun String?.toInputKind(): PhotoInputKind = runCatching {
    PhotoInputKind.valueOf(this.orEmpty())
}.getOrDefault(PhotoInputKind.RAW)

internal fun asBatchOutputFailure(error: Throwable): Throwable =
    if (error is NativeProcessingException && error.status == NativeProcessingException.OUTPUT_IO_ERROR)
        BatchGlobalFailure(AppStrings.format(R.string.message_output_storage_failed, error.message.orEmpty()), error)
    else error

enum class BatchRowStatus { PENDING, PROCESSING, PUBLISHING, NEEDS_CONFIRMATION, SUCCESS, FAILED, CANCELLED }

data class BatchSourceSnapshot(
    val identity: PhotoIdentity,
    val sourceFile: File,
    val settings: EditSettings,
    val displayName: String = sourceFile.name,
    val lookFile: File? = null,
    val inputKind: PhotoInputKind = PhotoInputKind.RAW,
) {
    /** Resolve camera-only state for a target without mutating the frozen source edit. */
    fun settingsFor(targetKind: PhotoInputKind): EditSettings {
        if (inputKind != PhotoInputKind.RASTER || targetKind != PhotoInputKind.RAW) return settings
        return settings.copy(
            exposureMode = EditSettings().exposureMode,
            customWb = false,
            temperature = 6500f,
            tint = if (settings.recipeID == null) 0f else settings.tint,
            lens = LensSettings(),
        )
    }
}

data class BatchTarget(
    val identity: PhotoIdentity,
    val sourceFile: File,
    val displayName: String,
    val sourceUri: String? = null,
    val inputKind: PhotoInputKind = PhotoInputKind.RAW,
) {
    val id: String get() = identity.value
}

data class BatchRow(
    val target: BatchTarget,
    val status: BatchRowStatus = BatchRowStatus.PENDING,
    val error: String? = null,
    val outputName: String = "",
    val outputUri: String? = null,
    val outputReady: Boolean = false,
) {
    val id: String get() = target.identity.value
}

data class BatchJob(
    val source: BatchSourceSnapshot,
    val targets: List<BatchTarget>,
    val id: String = UUID.randomUUID().toString(),
    val outputFormat: ExportFormat = ExportFormat.JPEG,
    val outputLongEdge: Int? = null,
    val destination: String? = null,
    val rows: List<BatchRow> = uniqueRows(targets, outputFormat),
    val globalError: String? = null,
) {
    companion object {
        private fun uniqueRows(targets: List<BatchTarget>, format: ExportFormat): List<BatchRow> {
            val used = mutableSetOf<String>()
            return targets.filter { used.add(it.identity.value) }.map { target ->
                BatchRow(target = target, outputName = uniqueName(target.displayName, format, used = mutableSetOf()))
            }.let { rows ->
                val names = mutableSetOf<String>()
                rows.map { row -> row.copy(outputName = uniqueName(row.outputName, format, names)) }
            }
        }

        private fun uniqueName(displayName: String, format: ExportFormat, used: MutableSet<String>): String {
            val base = displayName.substringAfterLast('/').substringBeforeLast('.', "RawLab").ifBlank { "RawLab" }
            var name = "$base${format.suffix}"
            var suffix = 2
            while (!used.add(name.lowercase())) name = "$base-$suffix${format.suffix}".also { suffix++ }
            return name
        }
    }

    fun withRows(updated: List<BatchRow>, globalError: String? = this.globalError) = copy(rows = updated, globalError = globalError)
}

object BatchRunner {
    fun <T> run(
        job: BatchJob,
        render: (BatchTarget, EditSettings) -> T,
        write: (T, String, BatchTarget) -> Unit,
        shouldCancel: () -> Boolean = { false },
        journal: BatchJournal? = null,
        didUpdate: (BatchJob) -> Unit = {},
        publish: ((T, String, BatchTarget, (String) -> Unit) -> Unit)? = null,
        dispose: (T) -> Unit = {},
    ): BatchJob {
        var current = job.withRows(job.rows.map { if (it.status == BatchRowStatus.PROCESSING) it.copy(status = BatchRowStatus.PENDING) else it }, null)
        fun commit() { journal?.save(current); didUpdate(current) }
        commit()
        current.rows.indices.forEach { index ->
            if (current.rows[index].status in setOf(BatchRowStatus.SUCCESS, BatchRowStatus.NEEDS_CONFIRMATION, BatchRowStatus.PUBLISHING)) return@forEach
            if (shouldCancel()) {
                current = current.withRows(current.rows.mapIndexed { i, row ->
                    if (i >= index && row.status in setOf(BatchRowStatus.PENDING, BatchRowStatus.PROCESSING, BatchRowStatus.FAILED, BatchRowStatus.CANCELLED)) row.copy(status = BatchRowStatus.CANCELLED) else row
                })
                commit()
                return current
            }
            val processing = current.rows.toMutableList()
            processing[index] = processing[index].copy(status = BatchRowStatus.PROCESSING, error = null)
            current = current.withRows(processing)
            commit()
            try {
                val row = current.rows[index]
                val payload = render(row.target, current.source.settingsFor(row.target.inputKind))
                try {
                    current = current.withRows(current.rows.mapIndexed { i, item -> if (i == index) item.copy(status = BatchRowStatus.PUBLISHING) else item })
                    commit()
                    if (publish == null) write(payload, row.outputName, row.target)
                    else publish(payload, row.outputName, row.target) { uri ->
                        current = current.withRows(current.rows.mapIndexed { i, item -> if (i == index) item.copy(outputUri = uri, outputReady = false) else item })
                        commit()
                    }
                    current = current.withRows(current.rows.mapIndexed { i, item -> if (i == index) item.copy(outputReady = true) else item })
                    commit()
                    val done = current.rows.toMutableList()
                    done[index] = done[index].copy(status = BatchRowStatus.SUCCESS)
                    current = current.withRows(done)
                } finally { dispose(payload) }
            } catch (error: BatchGlobalFailure) {
                val failed = current.rows.map { row ->
                    if (row.status in setOf(BatchRowStatus.PROCESSING, BatchRowStatus.PUBLISHING)) row.copy(status = BatchRowStatus.FAILED, error = error.message) else row
                }
                current = current.withRows(failed, error.message)
                commit()
                return current
            } catch (error: Throwable) {
                val failed = current.rows.toMutableList()
                failed[index] = failed[index].copy(status = if (failed[index].status == BatchRowStatus.PUBLISHING) BatchRowStatus.NEEDS_CONFIRMATION else BatchRowStatus.FAILED,
                    error = error.message ?: error.javaClass.simpleName)
                current = current.withRows(failed)
            }
            commit()
        }
        return current
    }

    fun <T> retryFailed(
        job: BatchJob,
        render: (BatchTarget, EditSettings) -> T,
        write: (T, String, BatchTarget) -> Unit,
        shouldCancel: () -> Boolean = { false },
        journal: BatchJournal? = null,
        dispose: (T) -> Unit = {},
    ): BatchJob = run(job.withRows(job.rows.map { if (it.status == BatchRowStatus.FAILED) it.copy(status = BatchRowStatus.PENDING, error = null) else it }),
        render, write, shouldCancel, journal, dispose = dispose)
}

class BatchJournal(private val directory: File) {
    private companion object { const val JOURNAL_VERSION = 2 }

    init { if (!directory.exists() && !directory.mkdirs()) throw IOException("Cannot create batch journal") }

    @Synchronized
    fun save(job: BatchJob) {
        val properties = Properties()
        properties.setProperty("source.identity", job.source.identity.value)
        properties.setProperty("source.path", job.source.sourceFile.path)
        properties.setProperty("source.name", job.source.displayName)
        properties.setProperty("source.look", job.source.lookFile?.path.orEmpty())
        properties.setProperty("source.kind", job.source.inputKind.name)
        properties.setProperty("global.error", job.globalError.orEmpty())
        properties.setProperty("source.settings", SettingsCodec.encode(job.source.settings))
        properties.setProperty("journal.version", JOURNAL_VERSION.toString())
        properties.setProperty("output.format", job.outputFormat.name.lowercase())
        // Keep the old flag for clients that only know JPEG/PNG journals.
        properties.setProperty("output.png", (job.outputFormat == ExportFormat.PNG).toString())
        properties.setProperty("output.longEdge", job.outputLongEdge?.toString().orEmpty())
        properties.setProperty("output.destination", job.destination.orEmpty())
        properties.setProperty("row.count", job.rows.size.toString())
        job.rows.forEachIndexed { index, row ->
            val prefix = "row.${index}."
            properties.setProperty(prefix + "id", row.id)
            properties.setProperty(prefix + "path", row.target.sourceFile.path)
            properties.setProperty(prefix + "name", row.target.displayName)
            properties.setProperty(prefix + "uri", row.target.sourceUri.orEmpty())
            properties.setProperty(prefix + "kind", row.target.inputKind.name)
            properties.setProperty(prefix + "status", row.status.name)
            properties.setProperty(prefix + "error", row.error.orEmpty())
            properties.setProperty(prefix + "output", row.outputName)
            properties.setProperty(prefix + "output.uri", row.outputUri.orEmpty())
            properties.setProperty(prefix + "output.ready", row.outputReady.toString())
        }
        val file = File(directory, "${job.id}.properties")
        val temporary = File(directory, "${job.id}.${System.nanoTime()}.tmp")
        try {
            temporary.outputStream().use { properties.store(it, null) }
            try {
                Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally { temporary.delete() }
    }

    fun load(id: String): BatchJob? {
        val file = File(directory, "${id}.properties")
        if (!file.isFile) return null
        val properties = Properties().also { file.inputStream().use(it::load) }
        val source = BatchSourceSnapshot(PhotoIdentity(properties.getProperty("source.identity")),
            File(properties.getProperty("source.path")), SettingsCodec.decode(properties.getProperty("source.settings")),
            properties.getProperty("source.name"), properties.getProperty("source.look").orEmpty().takeIf { it.isNotEmpty() }?.let(::File),
            properties.getProperty("source.kind").toInputKind())
        val count = properties.getProperty("row.count", "0").toInt()
        val targets = (0 until count).map { index ->
            val prefix = "row.${index}."
            BatchTarget(PhotoIdentity(properties.getProperty(prefix + "id")), File(properties.getProperty(prefix + "path")),
                properties.getProperty(prefix + "name"), properties.getProperty(prefix + "uri").ifBlank { null },
                properties.getProperty(prefix + "kind").toInputKind())
        }
        val journalVersion = properties.getProperty("journal.version", "1").toIntOrNull() ?: 1
        if (journalVersion > JOURNAL_VERSION) throw IOException("Unsupported batch journal version: $journalVersion")
        val outputFormat = if (journalVersion >= JOURNAL_VERSION) {
            ExportFormat.fromPersisted(properties.getProperty("output.format"))
        } else if (properties.getProperty("output.png", "false").toBoolean()) {
            ExportFormat.PNG
        } else {
            ExportFormat.JPEG
        }
        val base = BatchJob(source, targets, id = id,
            outputFormat = outputFormat,
            outputLongEdge = properties.getProperty("output.longEdge").orEmpty().toIntOrNull()
                ?.takeIf { ExportSize.isValid(it) },
            destination = properties.getProperty("output.destination").orEmpty().ifBlank { null })
        return base.withRows(base.rows.map { row ->
            val prefix = "row.${base.rows.indexOf(row)}."
            val stored = properties.getProperty(prefix + "status")?.let(BatchRowStatus::valueOf) ?: row.status
            row.copy(status = when (stored) {
                BatchRowStatus.PROCESSING -> BatchRowStatus.PENDING
                BatchRowStatus.PUBLISHING -> BatchRowStatus.NEEDS_CONFIRMATION
                else -> stored
            },
                error = properties.getProperty(prefix + "error").orEmpty().ifBlank { null },
                outputUri = properties.getProperty(prefix + "output.uri").orEmpty().ifBlank { null },
                outputReady = properties.getProperty(prefix + "output.ready", "false").toBoolean(),
                outputName = properties.getProperty(prefix + "output", row.outputName))
        }, properties.getProperty("global.error").orEmpty().ifBlank { null })
    }

    fun pending(): List<String> = directory.listFiles().orEmpty()
        .filter { it.extension == "properties" }
        .mapNotNull { file -> load(file.nameWithoutExtension)?.let { job ->
            if (job.rows.isNotEmpty() && job.rows.all { it.status == BatchRowStatus.SUCCESS }) {
                discard(job.id)
                null
            } else job.takeIf { it.rows.isNotEmpty() }?.id
        } }

    fun discard(id: String) {
        File(directory, "${id}.properties").delete()
        File(directory, id).deleteRecursively()
    }
}

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
}

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
                mutable.value = mutable.value.copy(job = ready, stopping = false,
                    phase = if (initial == null) BatchPhase.SELECTING else BatchPhase.CANCELLED)
            } catch (error: Exception) {
                mutable.value = mutable.value.copy(phase = BatchPhase.FAILED, error = error.message)
            }
        }
    }

    fun addUris(uris: List<Uri>) {
        if (uris.isEmpty() || mutable.value.phase != BatchPhase.SELECTING) return
        cancelRequested.reset()
        mutable.value = mutable.value.copy(phase = BatchPhase.PREPARING)
        scope.launch {
            val failures = mutableListOf<String>()
            val additions = withContext(Dispatchers.IO) { uris.mapNotNull { uri ->
                if (cancelRequested.get()) null else try { copyTarget(uri) } catch (error: Exception) { failures += "${displayName(uri)}: ${error.message}"; null }
            } }
            val existing = mutable.value.job.rows.mapTo(mutableSetOf()) { it.id }
            val accepted = additions.filter { existing.add(it.identity.value) }
            val all = mutable.value.job.rows.map { it.target } + accepted
            mutable.value = mutable.value.copy(job = BatchJob(mutable.value.job.source, all,
                id = mutable.value.job.id, outputFormat = mutable.value.job.outputFormat,
                outputLongEdge = mutable.value.job.outputLongEdge, destination = mutable.value.job.destination),
                phase = BatchPhase.SELECTING, stopping = false,
                error = failures.takeIf { it.isNotEmpty() }?.joinToString("\n"))
        }
    }

    fun remove(id: String) {
        if (mutable.value.phase != BatchPhase.SELECTING) return
        val targets = mutable.value.job.rows.filterNot { it.id == id }.map { it.target }
        mutable.value = mutable.value.copy(job = BatchJob(mutable.value.job.source, targets,
            id = mutable.value.job.id, outputFormat = mutable.value.job.outputFormat,
            outputLongEdge = mutable.value.job.outputLongEdge, destination = mutable.value.job.destination))
    }

    fun start(format: ExportFormat, destination: Uri?, longEdge: Int? = null) {
        startInternal(format, destination, longEdge, retry = false)
    }

    private fun startInternal(format: ExportFormat, destination: Uri?, longEdge: Int?, retry: Boolean) {
        val current = mutable.value
        if (current.phase in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING) || current.job.rows.isEmpty()) return
        if (retry && current.unfinishedCount == 0) return
        val successBefore = current.successCount
        val attempted = mutableSetOf<String>()
        var terminalReported = false
        suspend fun reportTerminal(job: BatchJob, outcome: UsageBatchOutcome) {
            if (terminalReported) return
            terminalReported = true
            val succeeded = (job.rows.count { it.status == BatchRowStatus.SUCCESS } - successBefore).coerceAtLeast(0)
            val failed = job.rows.count { it.id in attempted && it.status == BatchRowStatus.FAILED }
            withContext(Dispatchers.Main) { onTerminal(succeeded, failed, outcome) }
        }
        if (!ExportSize.isValid(longEdge)) {
            mutable.value = current.copy(error = AppStrings.text(R.string.message_enter_a_pixel_count_between_1_and))
            return
        }
        if (destination == null && !format.allowsGallery) {
            mutable.value = current.copy(error = AppStrings.text(R.string.dng_file_only))
            return
        }
        val configured = current.job.copy(outputFormat = format, destination = destination?.toString(),
            outputLongEdge = longEdge,
            rows = current.job.rows.map { if (it.status == BatchRowStatus.SUCCESS) it else it.copy(outputName = it.outputName.substringBeforeLast('.') + format.suffix) })
        mutable.value = current.copy(job = configured, phase = BatchPhase.PREPARING, outputFormat = format, destination = destination, error = null, stopping = false)
        cancelRequested.reset()
        running = scope.launch(Dispatchers.IO) {
            try {
                val materialized = configured
                if (!materialized.source.sourceFile.isFile || ((materialized.source.settings.film != "neutral" || materialized.source.settings.recipeID != null) && materialized.source.lookFile?.isFile != true)) {
                    throw BatchGlobalFailure(AppStrings.text(R.string.message_the_task_source_or_look_file_is))
                }
                val journal = BatchJournal(journalRoot)
                val processor = processorFactory(gpuMode, storage.lensDatabase())
                val result = try {
                    val render: (BatchTarget, EditSettings) -> File = { target, settings ->
                        val temporary = File.createTempFile("render-", format.suffix, context.filesDir)
                        try {
                            val backend = processor.export(target.sourceFile, materialized.source.lookFile,
                                settings, temporary, format, materialized.outputLongEdge,
                                target.inputKind)
                            android.util.Log.i("RawLabBatch", "job=${materialized.id} exportBackend=$backend")
                            temporary
                        } catch (error: Throwable) {
                            temporary.delete()
                            throw asBatchOutputFailure(error)
                        }
                    }
                    val publish: (File, String, BatchTarget, (String) -> Unit) -> Unit = { rendered, outputName, _, checkpoint ->
                        try {
                            if (destination == null) {
                                if (android.os.Build.VERSION.SDK_INT < 29) throw BatchGlobalFailure(AppStrings.text(R.string.message_saving_to_the_photo_gallery_requires_android))
                                storage.saveAlbum(rendered, format, outputName) { checkpoint(it.toString()) }
                            } else {
                                saveDocumentChild(destination, rendered, outputName, format) { checkpoint(it.toString()) }
                            }
                        } catch (error: BatchPublicationUncertain) {
                            throw error
                        } catch (error: Exception) {
                            throw BatchGlobalFailure(AppStrings.format(R.string.message_output_storage_failed, error.message.orEmpty()), error)
                        }
                    }
                    mutable.value = mutable.value.copy(phase = BatchPhase.RUNNING)
                    BatchRunner.run(materialized, render, { _, _, _ -> }, cancelRequested::get, journal,
                        didUpdate = {
                            attempted.addAll(it.rows.filter { row -> row.status == BatchRowStatus.PROCESSING }.map { row -> row.id })
                            mutable.value = mutable.value.copy(job = it)
                        }, dispose = { it.delete() }, publish = publish)
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
                mutable.value = mutable.value.copy(phase = BatchPhase.FAILED,
                    error = error.message ?: error.javaClass.simpleName)
                reportTerminal(mutable.value.job, UsageBatchOutcome.Interrupted)
            }
        }
    }

    fun retryFailed() {
        if (mutable.value.phase == BatchPhase.RUNNING || mutable.value.unfinishedCount == 0) return
        startInternal(mutable.value.outputFormat, mutable.value.destination, mutable.value.job.outputLongEdge, retry = true)
    }

    fun cancel(forBackground: Boolean = false) {
        cancelRequested.request(interrupted = forBackground)
        if (mutable.value.phase in setOf(BatchPhase.RUNNING, BatchPhase.PREPARING)) mutable.value = mutable.value.copy(stopping = true)
    }

    private fun copyTarget(uri: Uri): BatchTarget {
        val identity = PhotoIdentity(uri.toString())
        val name = displayName(uri)
        val inputKind = PhotoFiles.kind(name, resolver.getType(uri))
            ?: throw IOException(AppStrings.text(R.string.message_not_a_supported_raw_file))
        val destination = inputFile(mutable.value.job.id, identity, name)
        if (!destination.exists()) {
            val input = resolver.openInputStream(uri) ?: throw IOException(AppStrings.text(R.string.message_unable_to_read_file))
            try { input.use { source -> destination.outputStream().use { source.copyTo(it) } }
                processorFactory(gpuMode, storage.lensDatabase()).use {
                    it.preview(destination, null, EditSettings(), 256, false, inputKind)
                }
            } catch (error: Exception) { destination.delete(); throw error }
        }
        return BatchTarget(identity, destination, name, uri.toString(), inputKind)
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

    private fun inputFile(jobID: String, identity: PhotoIdentity, name: String): File {
        val root = File(context.filesDir, "RawLab/BatchJobs/${jobID}/inputs")
        if (!root.exists()) root.mkdirs()
        val extension = name.substringAfterLast('.', "raw").replace(Regex("[^A-Za-z0-9]"), "")
        val safe = java.security.MessageDigest.getInstance("SHA-256").digest(identity.value.toByteArray()).joinToString("") { "%02x".format(it) }
        return File(root, "${safe}.${extension.ifBlank { "raw" }}")
    }

    private fun saveDocumentChild(tree: Uri, file: File, name: String, format: ExportFormat, onCreated: (Uri) -> Unit): Uri {
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val names = mutableSetOf<String>()
        resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) names += cursor.getString(0).lowercase()
        } ?: throw IOException(AppStrings.text(R.string.message_unable_to_read_output_directory))
        var candidate = name
        var suffix = 2
        while (candidate.lowercase() in names) candidate = "${name.substringBeforeLast('.')}-${suffix++}.${name.substringAfterLast('.')}"
        val child = DocumentsContract.createDocument(resolver, parent, format.mimeType, candidate)
            ?: throw IOException("Cannot create output document")
        try {
            onCreated(child)
            val output = resolver.openOutputStream(child, "wt") ?: throw IOException("Cannot open output document")
            output.use { destination -> file.inputStream().use { it.copyTo(destination) } }
            return child
        } catch (error: Exception) {
            if (!runCatching { DocumentsContract.deleteDocument(resolver, child) }.getOrDefault(false)) throw BatchPublicationUncertain(AppStrings.text(R.string.message_writing_was_incomplete_and_cleanup_failed_check), error)
            throw BatchGlobalFailure(AppStrings.format(R.string.message_unable_to_write_to_output_directory, error.message.toString()), error)
        }
    }

    suspend fun preview(target: BatchTarget): android.graphics.Bitmap = withContext(Dispatchers.IO) {
        // 取消对话框不能中断 JNI；所有预览仍由 model 持有，关闭后等它们退出再删输入。
        val work = scope.async(Dispatchers.IO) {
            val source = mutable.value.job.source
            // 效果查看先限长再降噪，最终导出仍保留完整质量。
            processorFactory(gpuMode, storage.lensDatabase()).use {
                it.preview(target.sourceFile, source.lookFile, source.settingsFor(target.inputKind), 1280, true, target.inputKind)
            }
        }
        try { work.await().bitmap() } finally { work.cancel() }
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
        val updated = mutable.value.job.withRows(mutable.value.job.rows.map {
            if (it.id == id && it.status == BatchRowStatus.NEEDS_CONFIRMATION) it.copy(status = if (saved) BatchRowStatus.SUCCESS else BatchRowStatus.PENDING, outputUri = null) else it
        })
        try { BatchJournal(journalRoot).save(updated); mutable.value = mutable.value.copy(job = updated) }
        catch (error: Exception) { mutable.value = mutable.value.copy(error = error.message) }
    }

    fun setDestination(destination: Uri?) { mutable.value = mutable.value.copy(destination = destination) }

    fun discardDraftOrCompleted(): Deferred<Unit>? {
        if (mutable.value.phase == BatchPhase.SELECTING || mutable.value.job.rows.all { it.status == BatchRowStatus.SUCCESS }) discardAfterWork()
        return discardCompletion
    }

    fun discard(): Boolean {
        if (mutable.value.phase in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING)) return false
        return try { discardAfterWork(); true }
        catch (error: Exception) { mutable.value = mutable.value.copy(error = error.message); false }
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

internal object SettingsCodec {
    fun encode(settings: EditSettings): String = listOf(
        settings.film, settings.strength, settings.exposure, settings.highlights, settings.shadows,
        settings.contrast, settings.toneCurve, settings.saturation, settings.customWb,
        settings.temperature, settings.tint, settings.sharpening,
        settings.denoise.enabled, settings.denoise.luma, settings.denoise.chroma, settings.denoise.coarse,
        settings.displayChromaDenoise,
        settings.effects.vignetteAmount, settings.effects.vignetteMidpoint, settings.effects.vignetteRoundness,
        settings.effects.vignetteFeather, settings.effects.vignetteHighlights,
        settings.effects.grainAmount, settings.effects.grainSize, settings.effects.grainRoughness,
    ).plus(settings.exposureMode).plus(settings.hsl.packed().toList()).plus(settings.recipeID ?: "")
        .plus(java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(settings.lens.encode().toByteArray(Charsets.UTF_8)))
        .plus(settings.geometry.encode())
        .joinToString("|")

    fun decode(value: String): EditSettings {
        val fields = value.split('|')
        require(fields.size in listOf(12, 16, 25, 50, 51, 52, 53))
        return EditSettings(film = fields[0], strength = fields[1].toFloat(), exposure = fields[2].toFloat(),
            highlights = fields[3].toFloat(), shadows = fields[4].toFloat(), contrast = fields[5].toFloat(),
            toneCurve = fields[6].toFloat(), saturation = fields[7].toFloat(), customWb = fields[8].toBoolean(),
            temperature = fields[9].toFloat(), tint = fields[10].toFloat(), sharpening = fields[11].toFloat(),
            denoise = if (fields.size == 16) DenoiseSettings(fields[12].toBoolean(), fields[13].toFloat(),
                fields[14].toFloat(), fields[15].toFloat())
            else if (fields.size >= 25) DenoiseSettings(fields[12].toBoolean(), fields[13].toFloat(),
                fields[14].toFloat(), fields[15].toFloat())
            else DenoiseSettings(),
            displayChromaDenoise = if (fields.size >= 25) parseChromaMode(fields[16]) else 0,
            exposureMode = if (fields.size >= 50) parseChromaMode(fields[25]) else 0,
            hsl = if (fields.size >= 50) HslSettings(fields.subList(26, 50).map(String::toFloat)) else HslSettings(),
            recipeID = if (fields.size >= 51) fields[50].ifEmpty { null } else null,
            lens = if (fields.size >= 52) LensSettings.decode(String(java.util.Base64.getUrlDecoder().decode(fields[51]), Charsets.UTF_8)) else LensSettings(),
            geometry = GeometrySettings.decode(fields.getOrNull(52)),
            effects = if (fields.size >= 25) PhotoEffectsSettings(
                vignetteAmount = fields[17].toFloat(), vignetteMidpoint = fields[18].toFloat(),
                vignetteRoundness = fields[19].toFloat(), vignetteFeather = fields[20].toFloat(),
                vignetteHighlights = fields[21].toFloat(), grainAmount = fields[22].toFloat(),
                grainSize = fields[23].toFloat(), grainRoughness = fields[24].toFloat(),
            ) else PhotoEffectsSettings())
    }

    private fun parseChromaMode(value: String): Int {
        val number = value.toFloat()
        require(number.isFinite() && number == number.toInt().toFloat())
        return number.toInt()
    }
}
