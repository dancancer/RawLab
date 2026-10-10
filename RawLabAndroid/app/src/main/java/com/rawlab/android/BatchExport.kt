package com.rawlab.android

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.atomic.AtomicBoolean
import java.util.Properties
import java.util.UUID

class BatchGlobalFailure(message: String, cause: Throwable? = null) : IOException(message, cause)
class BatchPublicationUncertain(message: String, cause: Throwable? = null) : IOException(message, cause)

enum class BatchRowStatus { PENDING, PROCESSING, PUBLISHING, NEEDS_CONFIRMATION, SUCCESS, FAILED, CANCELLED }

data class BatchSourceSnapshot(
    val identity: PhotoIdentity,
    val sourceFile: File,
    val settings: EditSettings,
    val displayName: String = sourceFile.name,
    val lookFile: File? = null,
)

data class BatchTarget(
    val identity: PhotoIdentity,
    val sourceFile: File,
    val displayName: String,
    val sourceUri: String? = null,
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
    val outputPng: Boolean = false,
    val destination: String? = null,
    val rows: List<BatchRow> = uniqueRows(targets, outputPng),
    val globalError: String? = null,
) {
    companion object {
        private fun uniqueRows(targets: List<BatchTarget>, png: Boolean): List<BatchRow> {
            val used = mutableSetOf<String>()
            return targets.filter { used.add(it.identity.value) }.map { target ->
                BatchRow(target = target, outputName = uniqueName(target.displayName, png, used = mutableSetOf()))
            }.let { rows ->
                val names = mutableSetOf<String>()
                rows.map { row -> row.copy(outputName = uniqueName(row.outputName, png, names)) }
            }
        }

        private fun uniqueName(displayName: String, png: Boolean, used: MutableSet<String>): String {
            val base = displayName.substringAfterLast('/').substringBeforeLast('.', "RawLab").ifBlank { "RawLab" }
            val extension = if (png) "png" else "jpg"
            var name = "$base.$extension"
            var suffix = 2
            while (!used.add(name.lowercase())) name = "$base-$suffix.$extension".also { suffix++ }
            return name
        }
    }

    fun withRows(updated: List<BatchRow>, globalError: String? = this.globalError) = copy(rows = updated, globalError = globalError)
}

object BatchRunner {
    fun run(
        job: BatchJob,
        render: (BatchTarget, EditSettings) -> ByteArray,
        write: (ByteArray, String, BatchTarget) -> Unit,
        shouldCancel: () -> Boolean = { false },
        journal: BatchJournal? = null,
        didUpdate: (BatchJob) -> Unit = {},
        publish: ((ByteArray, String, BatchTarget, (String) -> Unit) -> Unit)? = null,
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
                val bytes = render(row.target, current.source.settings)
                current = current.withRows(current.rows.mapIndexed { i, item -> if (i == index) item.copy(status = BatchRowStatus.PUBLISHING) else item })
                commit()
                if (publish == null) write(bytes, row.outputName, row.target)
                else publish(bytes, row.outputName, row.target) { uri ->
                    current = current.withRows(current.rows.mapIndexed { i, item -> if (i == index) item.copy(outputUri = uri, outputReady = false) else item })
                    commit()
                }
                current = current.withRows(current.rows.mapIndexed { i, item -> if (i == index) item.copy(outputReady = true) else item })
                commit()
                val done = current.rows.toMutableList()
                done[index] = done[index].copy(status = BatchRowStatus.SUCCESS)
                current = current.withRows(done)
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

    fun retryFailed(
        job: BatchJob,
        render: (BatchTarget, EditSettings) -> ByteArray,
        write: (ByteArray, String, BatchTarget) -> Unit,
        shouldCancel: () -> Boolean = { false },
        journal: BatchJournal? = null,
    ): BatchJob = run(job.withRows(job.rows.map { if (it.status == BatchRowStatus.FAILED) it.copy(status = BatchRowStatus.PENDING, error = null) else it }),
        render, write, shouldCancel, journal)
}

class BatchJournal(private val directory: File) {
    init { if (!directory.exists() && !directory.mkdirs()) throw IOException("Cannot create batch journal") }

    @Synchronized
    fun save(job: BatchJob) {
        val properties = Properties()
        properties.setProperty("source.identity", job.source.identity.value)
        properties.setProperty("source.path", job.source.sourceFile.path)
        properties.setProperty("source.name", job.source.displayName)
        properties.setProperty("source.look", job.source.lookFile?.path.orEmpty())
        properties.setProperty("global.error", job.globalError.orEmpty())
        properties.setProperty("source.settings", SettingsCodec.encode(job.source.settings))
        properties.setProperty("output.png", job.outputPng.toString())
        properties.setProperty("output.destination", job.destination.orEmpty())
        properties.setProperty("row.count", job.rows.size.toString())
        job.rows.forEachIndexed { index, row ->
            val prefix = "row.$index."
            properties.setProperty(prefix + "id", row.id)
            properties.setProperty(prefix + "path", row.target.sourceFile.path)
            properties.setProperty(prefix + "name", row.target.displayName)
            properties.setProperty(prefix + "uri", row.target.sourceUri.orEmpty())
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
        val file = File(directory, "$id.properties")
        if (!file.isFile) return null
        val properties = Properties().also { file.inputStream().use(it::load) }
        val source = BatchSourceSnapshot(PhotoIdentity(properties.getProperty("source.identity")),
            File(properties.getProperty("source.path")), SettingsCodec.decode(properties.getProperty("source.settings")),
            properties.getProperty("source.name"), properties.getProperty("source.look").orEmpty().takeIf { it.isNotEmpty() }?.let(::File))
        val count = properties.getProperty("row.count", "0").toInt()
        val targets = (0 until count).map { index ->
            val prefix = "row.$index."
            BatchTarget(PhotoIdentity(properties.getProperty(prefix + "id")), File(properties.getProperty(prefix + "path")),
                properties.getProperty(prefix + "name"), properties.getProperty(prefix + "uri").ifBlank { null })
        }
        val base = BatchJob(source, targets, id = id,
            outputPng = properties.getProperty("output.png", "false").toBoolean(),
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
        File(directory, "$id.properties").delete()
        File(directory, id).deleteRecursively()
    }
}

enum class BatchPhase { SELECTING, PREPARING, RUNNING, CANCELLED, COMPLETE, FAILED }

data class BatchExportState(
    val job: BatchJob,
    val phase: BatchPhase = BatchPhase.SELECTING,
    val outputPng: Boolean = false,
    val destination: Uri? = null,
    val error: String? = null,
    val stopping: Boolean = false,
) {
    val selectedCount: Int get() = job.rows.size
    val successCount: Int get() = job.rows.count { it.status == BatchRowStatus.SUCCESS }
    val failedCount: Int get() = job.rows.count { it.status == BatchRowStatus.FAILED }
    val unfinishedCount: Int get() = job.rows.count { it.status !in setOf(BatchRowStatus.SUCCESS, BatchRowStatus.NEEDS_CONFIRMATION) }
}

class BatchExportModel(
    private val context: Context,
    private val storage: PhotoStorage,
    source: BatchSourceSnapshot,
    initial: BatchJob? = null,
) : AutoCloseable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val resolver = context.contentResolver
    private val cancelRequested = AtomicBoolean(false)
    private var running: Job? = null
    private val journalRoot = File(context.filesDir, "RawLab/BatchJobs")
    private val initialJob = initial ?: BatchJob(source, emptyList())
    private val mutable = MutableStateFlow(BatchExportState(initialJob, phase = BatchPhase.PREPARING,
        outputPng = initialJob.outputPng, destination = initialJob.destination?.let(Uri::parse)))
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
        cancelRequested.set(false)
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
                id = mutable.value.job.id), phase = BatchPhase.SELECTING, stopping = false,
                error = failures.takeIf { it.isNotEmpty() }?.joinToString("\n"))
        }
    }

    fun remove(id: String) {
        if (mutable.value.phase != BatchPhase.SELECTING) return
        val targets = mutable.value.job.rows.filterNot { it.id == id }.map { it.target }
        mutable.value = mutable.value.copy(job = BatchJob(mutable.value.job.source, targets,
            id = mutable.value.job.id))
    }

    fun start(png: Boolean, destination: Uri?) {
        startInternal(png, destination, retry = false)
    }

    private fun startInternal(png: Boolean, destination: Uri?, retry: Boolean) {
        val current = mutable.value
        if (current.phase in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING) || current.job.rows.isEmpty()) return
        if (retry && current.unfinishedCount == 0) return
        val configured = current.job.copy(outputPng = png, destination = destination?.toString(),
            rows = current.job.rows.map { if (it.status == BatchRowStatus.SUCCESS) it else it.copy(outputName = it.outputName.substringBeforeLast('.') + if (png) ".png" else ".jpg") })
        mutable.value = current.copy(job = configured, phase = BatchPhase.PREPARING, outputPng = png, destination = destination, error = null, stopping = false)
        cancelRequested.set(false)
        running = scope.launch(Dispatchers.IO) {
            try {
                val materialized = configured
                if (!materialized.source.sourceFile.isFile || (materialized.source.settings.film != "neutral" && materialized.source.lookFile?.isFile != true)) {
                    throw BatchGlobalFailure("任务来源或外观文件不可用，请重新创建批量任务。")
                }
                val journal = BatchJournal(journalRoot)
                val processor = NativeProcessor()
                val result = try {
                    val render: (BatchTarget, EditSettings) -> ByteArray = { target, settings ->
                        val temporary = File.createTempFile("render-", if (png) ".png" else ".jpg", context.filesDir)
                        try {
                            processor.export(target.sourceFile, materialized.source.lookFile, settings, temporary, png)
                            temporary.readBytes()
                        } finally { temporary.delete() }
                    }
                    val publish: (ByteArray, String, BatchTarget, (String) -> Unit) -> Unit = { bytes, outputName, _, checkpoint ->
                        val temporary = File.createTempFile("output-", if (png) ".png" else ".jpg", context.filesDir)
                        try {
                            temporary.writeBytes(bytes)
                            try { if (destination == null) {
                                if (android.os.Build.VERSION.SDK_INT < 29) throw BatchGlobalFailure("相册保存需要 Android 10 或更高版本")
                                storage.saveAlbum(temporary, png, outputName) { checkpoint(it.toString()) }
                            } else {
                                saveDocumentChild(destination, temporary, outputName, png) { checkpoint(it.toString()) }
                            } } catch (error: BatchPublicationUncertain) { throw error }
                            catch (error: Exception) { throw BatchGlobalFailure("输出存储失败：${error.message}", error) }
                        }
                        finally { temporary.delete() }
                    }
                    mutable.value = mutable.value.copy(phase = BatchPhase.RUNNING)
                    BatchRunner.run(materialized, render, { _, _, _ -> }, cancelRequested::get, journal,
                        didUpdate = { mutable.value = mutable.value.copy(job = it) }, publish = publish)
                } finally { processor.close() }
                mutable.value = BatchExportState(result,
                    phase = when {
                        result.globalError != null -> BatchPhase.FAILED
                        result.rows.any { it.status in setOf(BatchRowStatus.CANCELLED, BatchRowStatus.NEEDS_CONFIRMATION) } -> BatchPhase.CANCELLED
                        result.rows.any { it.status == BatchRowStatus.FAILED } -> BatchPhase.FAILED
                        else -> BatchPhase.COMPLETE
                    }, outputPng = png, destination = destination, error = result.globalError)
            } catch (error: Throwable) {
                mutable.value = mutable.value.copy(phase = BatchPhase.FAILED,
                    error = error.message ?: error.javaClass.simpleName)
            }
        }
    }

    fun retryFailed() {
        if (mutable.value.phase == BatchPhase.RUNNING || mutable.value.unfinishedCount == 0) return
        startInternal(mutable.value.outputPng, mutable.value.destination, retry = true)
    }

    fun cancel() {
        cancelRequested.set(true)
        if (mutable.value.phase in setOf(BatchPhase.RUNNING, BatchPhase.PREPARING)) mutable.value = mutable.value.copy(stopping = true)
    }

    private fun copyTarget(uri: Uri): BatchTarget {
        val identity = PhotoIdentity(uri.toString())
        val name = displayName(uri)
        if (!RawFiles.accepts(name, resolver.getType(uri))) throw IOException("不是受支持的 RAW 文件")
        val destination = inputFile(mutable.value.job.id, identity, name)
        if (!destination.exists()) {
            val input = resolver.openInputStream(uri) ?: throw IOException("无法读取文件")
            try { input.use { source -> destination.outputStream().use { source.copyTo(it) } }
                NativeProcessor().use { it.preview(destination, null, EditSettings(), 256, false) }
            } catch (error: Exception) { destination.delete(); throw error }
        }
        return BatchTarget(identity, destination, name, uri.toString())
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
            storage.filmPath(job.source.settings.film)?.let { original ->
                File(journalRoot, "${job.id}/look.${original.extension}").also { original.copyTo(it, overwrite = true) }
            }
        }
        return job.copy(source = job.source.copy(sourceFile = sourceCopy, lookFile = look))
    }

    private fun inputFile(jobID: String, identity: PhotoIdentity, name: String): File {
        val root = File(context.filesDir, "RawLab/BatchJobs/$jobID/inputs")
        if (!root.exists()) root.mkdirs()
        val extension = name.substringAfterLast('.', "raw").replace(Regex("[^A-Za-z0-9]"), "")
        val safe = java.security.MessageDigest.getInstance("SHA-256").digest(identity.value.toByteArray()).joinToString("") { "%02x".format(it) }
        return File(root, "$safe.${extension.ifBlank { "raw" }}")
    }

    private fun saveDocumentChild(tree: Uri, file: File, name: String, png: Boolean, onCreated: (Uri) -> Unit): Uri {
        val mime = if (png) "image/png" else "image/jpeg"
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val names = mutableSetOf<String>()
        resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) names += cursor.getString(0).lowercase()
        } ?: throw IOException("无法读取输出目录")
        var candidate = name
        var suffix = 2
        while (candidate.lowercase() in names) candidate = "${name.substringBeforeLast('.')}-${suffix++}.${name.substringAfterLast('.')}"
        val child = DocumentsContract.createDocument(resolver, parent, mime, candidate)
            ?: throw IOException("Cannot create output document")
        try {
            onCreated(child)
            val output = resolver.openOutputStream(child, "wt") ?: throw IOException("Cannot open output document")
            output.use { destination -> file.inputStream().use { it.copyTo(destination) } }
            return child
        } catch (error: Exception) {
            if (!runCatching { DocumentsContract.deleteDocument(resolver, child) }.getOrDefault(false)) throw BatchPublicationUncertain("写入未完成且无法清理，请核对输出目录", error)
            throw BatchGlobalFailure("无法写入输出目录：${error.message}", error)
        }
    }

    suspend fun preview(target: BatchTarget): android.graphics.Bitmap = withContext(Dispatchers.IO) {
        val source = mutable.value.job.source
        NativeProcessor().use { it.preview(target.sourceFile, source.lookFile, source.settings, 1280, false).bitmap() }
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

    fun discardDraftOrCompleted() {
        if (mutable.value.phase == BatchPhase.SELECTING || mutable.value.job.rows.all { it.status == BatchRowStatus.SUCCESS }) BatchJournal(journalRoot).discard(initialJob.id)
    }

    fun discard(): Boolean {
        if (mutable.value.phase in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING)) return false
        return try { BatchJournal(journalRoot).discard(initialJob.id); true }
        catch (error: Exception) { mutable.value = mutable.value.copy(error = error.message); false }
    }

    override fun close() {
        cancelRequested.set(true)
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
    ).joinToString("|")

    fun decode(value: String): EditSettings {
        val fields = value.split('|')
        require(fields.size == 12 || fields.size == 16)
        return EditSettings(film = fields[0], strength = fields[1].toFloat(), exposure = fields[2].toFloat(),
            highlights = fields[3].toFloat(), shadows = fields[4].toFloat(), contrast = fields[5].toFloat(),
            toneCurve = fields[6].toFloat(), saturation = fields[7].toFloat(), customWb = fields[8].toBoolean(),
            temperature = fields[9].toFloat(), tint = fields[10].toFloat(), sharpening = fields[11].toFloat(),
            denoise = if (fields.size == 16) DenoiseSettings(fields[12].toBoolean(), fields[13].toFloat(),
                fields[14].toFloat(), fields[15].toFloat()) else DenoiseSettings())
    }
}
