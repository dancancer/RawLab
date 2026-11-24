package com.rawlab.android.diagnostics

import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.annotation.StringRes
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rawlab.android.BuildConfig
import com.rawlab.android.R
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

data class DiagnosticEnvironmentInfo(
    val platform: String = "android",
    val appVersion: String,
    val build: String,
    val osVersion: String,
    val deviceModel: String,
)

data class DiagnosticBreadcrumbEntry(
    val timestamp: String,
    val seq: Int,
    val level: String,
    val category: String,
    val stage: String,
    val message: String,
    val context: Map<String, String> = emptyMap(),
)

data class DiagnosticErrorEntry(
    val timestamp: String,
    val operation: String,
    val stage: String,
    val errorType: String,
    val message: String,
    val context: Map<String, String> = emptyMap(),
)

data class DiagnosticReportPackage(
    val reportID: String,
    val manifestJSON: String,
    val breadcrumbsJSONL: String,
    val recentErrorsJSON: String,
    val readmeText: String,
    val breadcrumbCount: Int,
    val droppedBreadcrumbs: Int,
    val userNote: String?,
) {
    fun toZipBytes(): ByteArray {
        val out = ByteArrayOutputStream()
        writeZipTo(out)
        return out.toByteArray()
    }

    fun writeZipTo(stream: OutputStream) {
        ZipOutputStream(stream).use { zip ->
            fun put(name: String, content: String) {
                val entry = ZipEntry(name).apply { time = 315532800000L }
                zip.putNextEntry(entry)
                zip.write(content.toByteArray(StandardCharsets.UTF_8))
                zip.closeEntry()
            }
            put("manifest.json", manifestJSON)
            put("breadcrumbs.jsonl", breadcrumbsJSONL)
            put("recent-errors.json", recentErrorsJSON)
            put("README.txt", readmeText)
        }
    }

    val previewText: String
        get() {
            val truncated = if (breadcrumbsJSONL.length > 32_768) {
                breadcrumbsJSONL.take(32_768) + "\n... [preview truncated]"
            } else if (breadcrumbsJSONL.isEmpty()) {
                "(empty)"
            } else {
                breadcrumbsJSONL
            }
            return buildString {
                appendLine("=== manifest.json ===")
                appendLine(manifestJSON)
                appendLine("=== recent-errors.json ===")
                appendLine(recentErrorsJSON)
                appendLine("=== breadcrumbs.jsonl ($breadcrumbCount entries, dropped $droppedBreadcrumbs) ===")
                append(truncated)
            }
        }
}

enum class DiagnosticUploadFailure {
    EMPTY,
    PAYLOAD_TOO_LARGE,
    UNAVAILABLE,
}

class DiagnosticUploadException(val reason: DiagnosticUploadFailure) : Exception(reason.name)

fun interface DiagnosticCloudTransport {
    fun upload(endpoint: String, body: ByteArray)
}

object DiagnosticRedactor {
    private val allowedExtensions = setOf(
        "3fr", "arq", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "heic", "heif",
        "iiq", "jpeg", "jpg", "kdc", "mos", "mrw", "nef", "nrw", "orf", "pef", "png", "raf", "raw",
        "rw2", "rwl", "sr2", "srf", "srw", "tif", "tiff", "x3f",
    )
    private val fileUrlRegex = Regex("""(?i)(?:file|content)://[^\s"'<>()\[\]{}]+""")
    private val windowsPathRegex = Regex("""(?i)(?:[a-z]:[\\/]|\\\\)[^\s"'<>()\[\]{}]+""")
    private val posixPathRegex = Regex("""/(?:Users|home|private/var|var/mobile|var/folders|tmp|Volumes|data/user|data/data|storage/emulated|sdcard|mnt)/[^\s"'<>()\[\]{}]+""")
    private val identifierAllowed = Regex("""[^A-Za-z0-9._-]""")

    fun cleanText(input: String?, maxLength: Int = 512, extraPaths: List<Pair<String, String>> = emptyList()): String {
        if (input == null || input.isEmpty()) return ""
        var text: String = input
        for ((path, token) in extraPaths.sortedByDescending { it.first.length }) {
            if (path.length > 1) {
                text = text.replace(path, token, ignoreCase = true)
            }
        }
        text = fileUrlRegex.replace(text, "<uri>")
        text = windowsPathRegex.replace(text, "<path>")
        text = posixPathRegex.replace(text, "<path>")
        return if (text.length > maxLength) text.take(maxLength) + " [truncated]" else text
    }

    fun cleanUserNote(note: String?, extraPaths: List<Pair<String, String>> = emptyList()): String? {
        val trimmed = note?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        return cleanText(trimmed, maxLength = 200, extraPaths = extraPaths)
    }

    fun cleanIdentifier(raw: String?, fallback: String = "unknown"): String {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return fallback
        val cleaned = identifierAllowed.replace(trimmed.take(64), "_")
        return cleaned.ifEmpty { fallback }
    }

    fun cleanContext(raw: Map<String, String>, extraPaths: List<Pair<String, String>> = emptyList()): Map<String, String> {
        val result = linkedMapOf<String, String>()
        for (key in raw.keys.sorted().take(24)) {
            val value = raw[key] ?: continue
            val safeKey = cleanIdentifier(key, "key")
            if (safeKey == "extension") {
                val ext = value.trim().trimStart('.').lowercase(Locale.ROOT)
                result[safeKey] = if (ext in allowedExtensions) ext else "unknown"
            } else {
                result[safeKey] = cleanText(value, maxLength = 256, extraPaths = extraPaths)
            }
        }
        return result
    }
}

object DiagnosticReportIds {
    private val validPattern = Regex("""^RL-\d{8}-[0-9A-F]{8}$""")

    fun generate(nowMs: Long = System.currentTimeMillis()): String {
        val fmt = SimpleDateFormat("yyyyMMdd", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
        val hex = UUID.randomUUID().toString().replace("-", "").take(8).uppercase(Locale.US)
        return "RL-${fmt.format(Date(nowMs))}-$hex"
    }

    fun isValid(id: String?): Boolean = id != null && validPattern.matches(id)
}

object SLSDiagnosticWebTracking {
    const val PRODUCTION_URL =
        "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com/logstores/logstore-diagnostics/track"
    private const val MAX_CHUNK_BYTES = 200_000
    private const val MAX_BODY_BYTES = 950_000
    private val logstoreNameRegex = Regex("""^[a-z0-9][a-z0-9_-]{1,62}$""")

    fun validateEndpoint(raw: String, allowLoopback: Boolean = false): String {
        val uri = try {
            URI(raw)
        } catch (_: Exception) {
            throw DiagnosticUploadException(DiagnosticUploadFailure.UNAVAILABLE)
        }
        if (uri.userInfo != null || uri.rawQuery != null || uri.rawFragment != null) {
            throw DiagnosticUploadException(DiagnosticUploadFailure.UNAVAILABLE)
        }
        val host = uri.host?.lowercase(Locale.US)
            ?: throw DiagnosticUploadException(DiagnosticUploadFailure.UNAVAILABLE)
        val parts = (uri.path ?: "").split('/').filter { it.isNotEmpty() }
        if (parts.size != 3 || parts[0] != "logstores" || parts[2] != "track" || !logstoreNameRegex.matches(parts[1])) {
            throw DiagnosticUploadException(DiagnosticUploadFailure.UNAVAILABLE)
        }
        if (allowLoopback && uri.scheme == "http" && (host == "127.0.0.1" || host == "localhost")) {
            return uri.toString()
        }
        if (uri.scheme != "https" || (uri.port != -1 && uri.port != 443) ||
            !host.endsWith(".log.aliyuncs.com") || host.length <= ".log.aliyuncs.com".length
        ) {
            throw DiagnosticUploadException(DiagnosticUploadFailure.UNAVAILABLE)
        }
        return uri.toString()
    }

    fun buildPayload(report: DiagnosticReportPackage, environment: DiagnosticEnvironmentInfo): ByteArray {
        val chunks = splitLines(report.breadcrumbsJSONL, MAX_CHUNK_BYTES, 4).ifEmpty { listOf("") }
        val logsArray = JSONArray()
        chunks.forEachIndexed { index, chunk ->
            val obj = JSONObject().apply {
                put("report_id", report.reportID)
                put("schema_version", "1")
                put("platform", environment.platform)
                put("app_version", environment.appVersion)
                put("build", environment.build)
                put("os_version", environment.osVersion)
                put("device_model", environment.deviceModel)
                put("chunk_index", index.toString())
                put("chunk_count", chunks.size.toString())
                put("breadcrumbs_jsonl", chunk)
                if (index == 0) {
                    put("manifest_json", report.manifestJSON)
                    put("recent_errors_json", report.recentErrorsJSON)
                    if (!report.userNote.isNullOrEmpty()) {
                        put("user_note", report.userNote)
                    }
                }
            }
            logsArray.put(obj)
        }
        val envelope = JSONObject().apply {
            put("__topic__", "rawlab-diagnostic-v1")
            put("__source__", environment.platform)
            put("__tags__", JSONObject().apply {
                put("platform", environment.platform)
                put("app_version", environment.appVersion)
            })
            put("__logs__", logsArray)
        }
        val bytes = envelope.toString().toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > MAX_BODY_BYTES) {
            throw DiagnosticUploadException(DiagnosticUploadFailure.PAYLOAD_TOO_LARGE)
        }
        return bytes
    }

    val defaultHttpTransport = DiagnosticCloudTransport { endpoint, body ->
        val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15_000
            readTimeout = 20_000
            doOutput = true
            useCaches = false
            instanceFollowRedirects = false
            setRequestProperty("Content-Type", "application/json;charset=UTF-8")
            setRequestProperty("x-log-apiversion", "0.6.0")
            setRequestProperty("x-log-bodyrawsize", body.size.toString())
        }
        try {
            connection.outputStream.use { it.write(body) }
            val status = connection.responseCode
            if (status !in 200..299) {
                throw DiagnosticUploadException(DiagnosticUploadFailure.UNAVAILABLE)
            }
        } catch (error: DiagnosticUploadException) {
            throw error
        } catch (_: Exception) {
            throw DiagnosticUploadException(DiagnosticUploadFailure.UNAVAILABLE)
        } finally {
            connection.disconnect()
        }
    }

    private fun splitLines(text: String, maxBytes: Int, maxChunks: Int): List<String> {
        if (text.isEmpty()) return emptyList()
        val result = mutableListOf<String>()
        val current = mutableListOf<String>()
        var currentBytes = 0
        for (line in text.split('\n')) {
            val lineBytes = line.toByteArray(StandardCharsets.UTF_8).size + 1
            if (current.isNotEmpty() && currentBytes + lineBytes > maxBytes) {
                result += current.joinToString("\n")
                current.clear()
                currentBytes = 0
                if (result.size >= maxChunks) break
            }
            if (lineBytes <= maxBytes) {
                current += line
                currentBytes += lineBytes
            }
        }
        if (current.isNotEmpty() && result.size < maxChunks) {
            val tail = current.joinToString("\n")
            if (tail.isNotEmpty()) result += tail
        }
        return result
    }
}

class DiagnosticSessionStore(
    private val directory: File,
    val environment: DiagnosticEnvironmentInfo,
    private val extraRedactedPaths: List<Pair<String, String>> = emptyList(),
    private val leaseDurationMs: Long = DEFAULT_LEASE_MS,
    private val clockMs: () -> Long = { System.currentTimeMillis() },
) {
    companion object {
        const val DEFAULT_LEASE_MS = 30L * 60L * 1000L
        const val MAX_BREADCRUMBS = 500
        const val MAX_BREADCRUMB_BYTES = 450_000
        const val MAX_RECENT_ERRORS = 64
        private const val PRESERVED_HEAD_COUNT = 10
    }

    data class Snapshot(
        val isRecording: Boolean,
        val expiresAtMs: Long?,
        val sessionID: String?,
        val breadcrumbCount: Int,
        val recentErrorCount: Int,
        val recoveredPreviousSession: Boolean,
    ) {
        val hasExportableLogs: Boolean get() = breadcrumbCount > 0 || recentErrorCount > 0
    }

    private val lock = Any()
    private val fastActiveUntilMs = AtomicLong(0L)
    private val writerExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "rawlab-diagnostics-io").apply { isDaemon = true }
    }

    private var loaded = false
    private var sessionID: String? = null
    private var startedAtMs: Long? = null
    private var expiresAtMs: Long? = null
    private var remainingLaunches: Int = 0
    private var droppedBreadcrumbs: Int = 0
    private var nextSeq: Int = 1
    private var recoveredPreviousSession = false
    private val breadcrumbs = ArrayList<DiagnosticBreadcrumbEntry>()
    private val recentErrors = ArrayList<DiagnosticErrorEntry>()

    private val leaseFile get() = File(directory, "recording-lease.json")
    private val metaFile get() = File(directory, "session-meta.json")
    private val breadcrumbsFile get() = File(directory, "session-active.jsonl")
    private val errorsFile get() = File(directory, "errors.json")

    val isRecording: Boolean
        get() {
            val until = fastActiveUntilMs.get()
            return until > 0L && clockMs() < until
        }

    fun resumeOnLaunch(): Snapshot = synchronized(lock) {
        ensureLoadedLocked()
        val now = clockMs()
        val lease = readLeaseLocked()
        if (lease != null && now < lease.expiresAtMs && lease.remainingLaunches > 0) {
            sessionID = lease.sessionID
            startedAtMs = lease.startedAtMs
            expiresAtMs = lease.expiresAtMs
            remainingLaunches = lease.remainingLaunches - 1
            writeLeaseLocked(lease.copy(remainingLaunches = remainingLaunches))
            fastActiveUntilMs.set(lease.expiresAtMs)
            appendBreadcrumbLocked(
                level = "info",
                category = "lifecycle",
                stage = "relaunch",
                message = "Diagnostic recording resumed across launch",
                context = mapOf("remainingLaunches" to remainingLaunches.toString()),
                nowMs = now,
            )
        } else {
            if (lease != null) {
                leaseFile.delete()
                if (breadcrumbs.isNotEmpty()) recoveredPreviousSession = true
            } else if (breadcrumbs.isNotEmpty()) {
                recoveredPreviousSession = true
            }
            expiresAtMs = null
            remainingLaunches = 0
            fastActiveUntilMs.set(0L)
        }
        snapshotLocked(now)
    }

    fun setRecordingEnabled(enabled: Boolean): Snapshot = synchronized(lock) {
        ensureLoadedLocked()
        val now = clockMs()
        if (enabled) {
            val freshId = DiagnosticReportIds.generate(now)
            val until = now + leaseDurationMs
            sessionID = freshId
            startedAtMs = now
            expiresAtMs = until
            remainingLaunches = 1
            droppedBreadcrumbs = 0
            breadcrumbs.clear()
            nextSeq = 1
            recoveredPreviousSession = false
            writeLeaseLocked(LeaseRecord(freshId, now, until, 1))
            fastActiveUntilMs.set(until)
            appendBreadcrumbLocked(
                level = "info",
                category = "lifecycle",
                stage = "recordingStarted",
                message = "User enabled diagnostic recording",
                context = mapOf(
                    "platform" to environment.platform,
                    "appVersion" to environment.appVersion,
                    "build" to environment.build,
                    "osVersion" to environment.osVersion,
                    "deviceModel" to environment.deviceModel,
                ),
                nowMs = now,
            )
        } else {
            if (expiresAtMs != null) {
                appendBreadcrumbLocked(
                    level = "info",
                    category = "lifecycle",
                    stage = "recordingStopped",
                    message = "User stopped diagnostic recording",
                    context = emptyMap(),
                    nowMs = now,
                )
            }
            expiresAtMs = null
            remainingLaunches = 0
            fastActiveUntilMs.set(0L)
            leaseFile.delete()
        }
        snapshotLocked(now)
    }

    fun recordBreadcrumb(
        level: String = "info",
        category: String,
        stage: String,
        message: String,
        context: Map<String, String> = emptyMap(),
    ) {
        val until = fastActiveUntilMs.get()
        if (until <= 0L) return
        val now = clockMs()
        if (now >= until) {
            writerExecutor.execute { synchronized(lock) { ensureLoadedLocked(); expireIfNeededLocked(now) } }
            return
        }
        val safeCategory = DiagnosticRedactor.cleanIdentifier(category, "general")
        val safeStage = DiagnosticRedactor.cleanIdentifier(stage, "step")
        val safeMessage = DiagnosticRedactor.cleanText(message, 512, extraRedactedPaths)
        val safeContext = DiagnosticRedactor.cleanContext(context, extraRedactedPaths)
        writerExecutor.execute {
            synchronized(lock) {
                ensureLoadedLocked()
                expireIfNeededLocked(now)
                if (expiresAtMs == null) return@synchronized
                appendBreadcrumbLocked(level, safeCategory, safeStage, safeMessage, safeContext, now)
            }
        }
    }

    fun recordError(
        operation: String,
        stage: String,
        error: Throwable,
        context: Map<String, String> = emptyMap(),
    ) {
        val now = clockMs()
        val safeOp = DiagnosticRedactor.cleanIdentifier(operation, "editor")
        val safeStage = DiagnosticRedactor.cleanIdentifier(stage, "failure")
        val safeType = DiagnosticRedactor.cleanIdentifier(error.javaClass.name, "Exception")
        val safeMsg = DiagnosticRedactor.cleanText(error.message ?: error.javaClass.simpleName, 512, extraRedactedPaths)
        val safeCtx = DiagnosticRedactor.cleanContext(context, extraRedactedPaths)
        writerExecutor.execute {
            synchronized(lock) {
                ensureLoadedLocked()
                expireIfNeededLocked(now)
                recentErrors.add(
                    DiagnosticErrorEntry(
                        timestamp = formatIso(now),
                        operation = safeOp,
                        stage = safeStage,
                        errorType = safeType,
                        message = safeMsg,
                        context = safeCtx,
                    )
                )
                while (recentErrors.size > MAX_RECENT_ERRORS) {
                    recentErrors.removeAt(0)
                }
                persistErrorsLocked()
                if (expiresAtMs != null) {
                    appendBreadcrumbLocked(
                        level = "error",
                        category = safeOp,
                        stage = safeStage,
                        message = "$safeType: $safeMsg",
                        context = safeCtx,
                        nowMs = now,
                    )
                }
            }
        }
    }

    fun flushPendingWrites() {
        writerExecutor.submit {}.get()
    }

    fun stateSnapshot(): Snapshot {
        flushPendingWrites()
        return synchronized(lock) {
            ensureLoadedLocked()
            val now = clockMs()
            expireIfNeededLocked(now)
            snapshotLocked(now)
        }
    }

    fun buildReportPackage(userNote: String? = null, stopActiveRecording: Boolean = false): DiagnosticReportPackage {
        flushPendingWrites()
        return synchronized(lock) {
            ensureLoadedLocked()
            val now = clockMs()
            expireIfNeededLocked(now)
            if (stopActiveRecording && expiresAtMs != null) {
                appendBreadcrumbLocked(
                    level = "info",
                    category = "lifecycle",
                    stage = "recordingSealedForReport",
                    message = "Diagnostic recording sealed for export/upload",
                    context = emptyMap(),
                    nowMs = now,
                )
                expiresAtMs = null
                remainingLaunches = 0
                fastActiveUntilMs.set(0L)
                leaseFile.delete()
            }
            if (breadcrumbs.isEmpty() && recentErrors.isEmpty()) {
                throw DiagnosticUploadException(DiagnosticUploadFailure.EMPTY)
            }
            val reportID = sessionID?.takeIf(DiagnosticReportIds::isValid) ?: DiagnosticReportIds.generate(now)
            val cleanedNote = DiagnosticRedactor.cleanUserNote(userNote, extraRedactedPaths)
            val manifest = JSONObject().apply {
                put("schemaVersion", 1)
                put("reportID", reportID)
                put("createdAt", formatIso(now))
                put("environment", JSONObject().apply {
                    put("platform", environment.platform)
                    put("appVersion", environment.appVersion)
                    put("build", environment.build)
                    put("osVersion", environment.osVersion)
                    put("deviceModel", environment.deviceModel)
                })
                put("recordingActive", expiresAtMs != null)
                startedAtMs?.let { put("sessionStartedAt", formatIso(it)) }
                put("breadcrumbCount", breadcrumbs.size)
                put("droppedBreadcrumbs", droppedBreadcrumbs)
                put("recentErrorCount", recentErrors.size)
                if (!cleanedNote.isNullOrEmpty()) put("userNote", cleanedNote)
            }
            val recentErrorsJson = encodeErrorsLocked().toString(2)
            val breadcrumbsJsonl = encodeBreadcrumbsLocked()
            val readme = """
                RawLab Diagnostic Package ($reportID)
                ========================================
                Contents:
                - manifest.json: App/OS/device environment summary and report metadata.
                - breadcrumbs.jsonl: Redacted step-by-step runtime events recorded while diagnostic logging was enabled.
                - recent-errors.json: Bounded recent error codes and stages.

                Privacy Notice:
                Photo pixels, thumbnails, original file names, personal folder paths, EXIF GPS/serials, and AI prompts/keys are excluded.
            """.trimIndent() + "\n"
            DiagnosticReportPackage(
                reportID = reportID,
                manifestJSON = manifest.toString(2),
                breadcrumbsJSONL = breadcrumbsJsonl,
                recentErrorsJSON = recentErrorsJson,
                readmeText = readme,
                breadcrumbCount = breadcrumbs.size,
                droppedBreadcrumbs = droppedBreadcrumbs,
                userNote = cleanedNote,
            )
        }
    }

    fun clearAll(): Snapshot {
        flushPendingWrites()
        return synchronized(lock) {
            ensureLoadedLocked()
            sessionID = null
            startedAtMs = null
            expiresAtMs = null
            remainingLaunches = 0
            droppedBreadcrumbs = 0
            nextSeq = 1
            recoveredPreviousSession = false
            breadcrumbs.clear()
            recentErrors.clear()
            fastActiveUntilMs.set(0L)
            leaseFile.delete()
            metaFile.delete()
            breadcrumbsFile.delete()
            errorsFile.delete()
            snapshotLocked(clockMs())
        }
    }

    private data class LeaseRecord(
        val sessionID: String,
        val startedAtMs: Long,
        val expiresAtMs: Long,
        val remainingLaunches: Int,
    )

    private fun ensureLoadedLocked() {
        if (loaded) return
        loaded = true
        if (metaFile.isFile) {
            runCatching {
                val obj = JSONObject(metaFile.readText(StandardCharsets.UTF_8))
                if (obj.optInt("schemaVersion") == 1) {
                    sessionID = obj.optString("sessionID").takeIf { it.isNotEmpty() }
                    startedAtMs = obj.optLong("startedAtMs").takeIf { it > 0L }
                    droppedBreadcrumbs = obj.optInt("droppedBreadcrumbs", 0)
                }
            }
        }
        if (breadcrumbsFile.isFile) {
            runCatching {
                breadcrumbsFile.useLines(StandardCharsets.UTF_8) { lines ->
                    lines.forEach { line ->
                        if (line.isBlank()) return@forEach
                        val obj = JSONObject(line)
                        val ctxObj = obj.optJSONObject("context")
                        val ctx = linkedMapOf<String, String>()
                        ctxObj?.keys()?.forEach { key -> ctx[key] = ctxObj.optString(key) }
                        breadcrumbs.add(
                            DiagnosticBreadcrumbEntry(
                                timestamp = obj.getString("timestamp"),
                                seq = obj.getInt("seq"),
                                level = obj.getString("level"),
                                category = obj.getString("category"),
                                stage = obj.getString("stage"),
                                message = obj.getString("message"),
                                context = ctx,
                            )
                        )
                    }
                }
                nextSeq = (breadcrumbs.lastOrNull()?.seq ?: 0) + 1
            }
        }
        if (errorsFile.isFile) {
            runCatching {
                val root = JSONObject(errorsFile.readText(StandardCharsets.UTF_8))
                if (root.optInt("schemaVersion") == 1) {
                    val events = root.optJSONArray("events") ?: JSONArray()
                    for (i in 0 until events.length()) {
                        val item = events.getJSONObject(i)
                        val ctxObj = item.optJSONObject("context")
                        val ctx = linkedMapOf<String, String>()
                        ctxObj?.keys()?.forEach { k -> ctx[k] = ctxObj.optString(k) }
                        recentErrors.add(
                            DiagnosticErrorEntry(
                                timestamp = item.optString("timestamp"),
                                operation = item.optString("operation"),
                                stage = item.optString("stage"),
                                errorType = item.optString("errorType"),
                                message = item.optString("message"),
                                context = ctx,
                            )
                        )
                    }
                }
            }
        }
    }

    private fun expireIfNeededLocked(nowMs: Long) {
        val until = expiresAtMs ?: return
        if (nowMs >= until) {
            appendBreadcrumbLocked(
                level = "info",
                category = "lifecycle",
                stage = "leaseExpired",
                message = "Diagnostic recording automatically stopped after lease window",
                context = emptyMap(),
                nowMs = nowMs,
            )
            expiresAtMs = null
            remainingLaunches = 0
            fastActiveUntilMs.set(0L)
            leaseFile.delete()
        }
    }

    private fun appendBreadcrumbLocked(
        level: String,
        category: String,
        stage: String,
        message: String,
        context: Map<String, String>,
        nowMs: Long,
    ) {
        breadcrumbs.add(
            DiagnosticBreadcrumbEntry(
                timestamp = formatIso(nowMs),
                seq = nextSeq++,
                level = level,
                category = category,
                stage = stage,
                message = message,
                context = context,
            )
        )
        trimBreadcrumbsLocked()
        persistSessionLocked()
    }

    private fun trimBreadcrumbsLocked() {
        var dropped = 0
        while (breadcrumbs.size > MAX_BREADCRUMBS) {
            val removeIdx = minOf(PRESERVED_HEAD_COUNT, breadcrumbs.lastIndex)
            breadcrumbs.removeAt(removeIdx)
            dropped++
        }
        while (breadcrumbs.size > PRESERVED_HEAD_COUNT + 1 &&
            encodeBreadcrumbsLocked().toByteArray(StandardCharsets.UTF_8).size > MAX_BREADCRUMB_BYTES
        ) {
            breadcrumbs.removeAt(PRESERVED_HEAD_COUNT)
            dropped++
        }
        if (dropped > 0) droppedBreadcrumbs += dropped
    }

    private fun encodeBreadcrumbsLocked(): String {
        if (breadcrumbs.isEmpty()) return ""
        return buildString {
            for (entry in breadcrumbs) {
                val obj = JSONObject().apply {
                    put("timestamp", entry.timestamp)
                    put("seq", entry.seq)
                    put("level", entry.level)
                    put("category", entry.category)
                    put("stage", entry.stage)
                    put("message", entry.message)
                    put("context", JSONObject(entry.context))
                }
                append(obj.toString())
                append('\n')
            }
        }
    }

    private fun encodeErrorsLocked(): JSONObject {
        val arr = JSONArray()
        for (entry in recentErrors) {
            arr.put(JSONObject().apply {
                put("timestamp", entry.timestamp)
                put("operation", entry.operation)
                put("stage", entry.stage)
                put("errorType", entry.errorType)
                put("message", entry.message)
                put("context", JSONObject(entry.context))
            })
        }
        return JSONObject().apply {
            put("schemaVersion", 1)
            put("events", arr)
        }
    }

    private fun persistSessionLocked() {
        runCatching {
            directory.mkdirs()
            writeAtomic(breadcrumbsFile, encodeBreadcrumbsLocked())
            val meta = JSONObject().apply {
                put("schemaVersion", 1)
                sessionID?.let { put("sessionID", it) }
                startedAtMs?.let { put("startedAtMs", it) }
                put("droppedBreadcrumbs", droppedBreadcrumbs)
            }
            writeAtomic(metaFile, meta.toString())
        }
    }

    private fun persistErrorsLocked() {
        runCatching {
            directory.mkdirs()
            writeAtomic(errorsFile, encodeErrorsLocked().toString())
        }
    }

    private fun readLeaseLocked(): LeaseRecord? {
        if (!leaseFile.isFile) return null
        return runCatching {
            val obj = JSONObject(leaseFile.readText(StandardCharsets.UTF_8))
            if (obj.optInt("schemaVersion") != 1) return null
            LeaseRecord(
                sessionID = obj.getString("sessionID"),
                startedAtMs = obj.getLong("startedAtMs"),
                expiresAtMs = obj.getLong("expiresAtMs"),
                remainingLaunches = obj.getInt("remainingLaunches"),
            )
        }.getOrNull()
    }

    private fun writeLeaseLocked(lease: LeaseRecord) {
        runCatching {
            directory.mkdirs()
            val obj = JSONObject().apply {
                put("schemaVersion", 1)
                put("sessionID", lease.sessionID)
                put("startedAtMs", lease.startedAtMs)
                put("expiresAtMs", lease.expiresAtMs)
                put("remainingLaunches", lease.remainingLaunches)
            }
            writeAtomic(leaseFile, obj.toString())
        }
    }

    private fun writeAtomic(target: File, text: String) {
        val tmp = File(target.parentFile, "${target.name}.${UUID.randomUUID()}.tmp")
        try {
            tmp.writeText(text, StandardCharsets.UTF_8)
            if (!tmp.renameTo(target)) {
                target.writeText(text, StandardCharsets.UTF_8)
                tmp.delete()
            }
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }

    private fun snapshotLocked(nowMs: Long): Snapshot {
        val active = expiresAtMs?.let { nowMs < it } == true
        return Snapshot(
            isRecording = active,
            expiresAtMs = expiresAtMs,
            sessionID = sessionID,
            breadcrumbCount = breadcrumbs.size,
            recentErrorCount = recentErrors.size,
            recoveredPreviousSession = recoveredPreviousSession,
        )
    }

    private fun formatIso(epochMs: Long): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
        return fmt.format(Date(epochMs))
    }
}

object DiagnosticRegistry {
    @Volatile
    private var instance: DiagnosticSessionStore? = null

    fun get(context: Context): DiagnosticSessionStore {
        instance?.let { return it }
        return synchronized(this) {
            instance ?: create(context.applicationContext).also { instance = it }
        }
    }

    fun peek(): DiagnosticSessionStore? = instance

    private fun create(app: Context): DiagnosticSessionStore {
        val env = DiagnosticEnvironmentInfo(
            platform = "android",
            appVersion = BuildConfig.VERSION_NAME,
            build = BuildConfig.VERSION_CODE.toString(),
            osVersion = Build.VERSION.RELEASE ?: Build.VERSION.SDK_INT.toString(),
            deviceModel = DiagnosticRedactor.cleanIdentifier("${Build.MANUFACTURER}_${Build.MODEL}"),
        )
        val extraPaths = listOf(
            app.filesDir.absolutePath to "<files>",
            app.cacheDir.absolutePath to "<cache>",
        )
        return DiagnosticSessionStore(
            directory = File(app.filesDir, "RawLab/Diagnostics"),
            environment = env,
            extraRedactedPaths = extraPaths,
        )
    }
}

data class DiagnosticUiState(
    val isRecording: Boolean = false,
    val hasExportableLogs: Boolean = false,
    val recoveredPreviousSession: Boolean = false,
    val isUploading: Boolean = false,
    val lastUploadedReportID: String? = null,
    val userNote: String = "",
    val previewText: String? = null,
    val copiedCode: Boolean = false,
    @StringRes val feedbackRes: Int? = null,
    val feedbackIsError: Boolean = false,
) {
    @get:StringRes
    val statusRes: Int
        get() = when {
            isRecording -> R.string.diagnostics_status_recording
            recoveredPreviousSession && hasExportableLogs -> R.string.diagnostics_status_recovered
            hasExportableLogs -> R.string.diagnostics_status_ready
            else -> R.string.diagnostics_status_off
        }
}

class DiagnosticViewModel(
    application: Application,
    private val store: DiagnosticSessionStore,
    private val ioDispatcher: CoroutineDispatcher,
    private val transport: DiagnosticCloudTransport,
    private val uploadEndpointProvider: () -> String,
) : AndroidViewModel(application) {

    constructor(application: Application) : this(
        application = application,
        store = DiagnosticRegistry.get(application),
        ioDispatcher = Dispatchers.IO,
        transport = SLSDiagnosticWebTracking.defaultHttpTransport,
        uploadEndpointProvider = {
            System.getenv("RAWLAB_DIAGNOSTIC_UPLOAD_URL")
                ?.takeIf { it.isNotBlank() }
                ?.let { SLSDiagnosticWebTracking.validateEndpoint(it) }
                ?: SLSDiagnosticWebTracking.PRODUCTION_URL
        },
    )

    private val mutable = MutableStateFlow(DiagnosticUiState())
    val state: StateFlow<DiagnosticUiState> = mutable.asStateFlow()

    init {
        refresh()
    }

    fun beginSession() {
        viewModelScope.launch(ioDispatcher) {
            applySnapshot(store.resumeOnLaunch())
        }
    }

    fun refresh() {
        viewModelScope.launch(ioDispatcher) {
            applySnapshot(store.stateSnapshot())
        }
    }

    fun setRecordingEnabled(enabled: Boolean) {
        viewModelScope.launch(ioDispatcher) {
            val snap = store.setRecordingEnabled(enabled)
            mutable.update { current ->
                current.copy(
                    isRecording = snap.isRecording,
                    hasExportableLogs = snap.hasExportableLogs,
                    recoveredPreviousSession = snap.recoveredPreviousSession,
                    lastUploadedReportID = if (enabled) null else current.lastUploadedReportID,
                    copiedCode = false,
                    feedbackRes = null,
                    feedbackIsError = false,
                )
            }
        }
    }

    fun setUserNote(note: String) {
        mutable.update { it.copy(userNote = note.take(200)) }
    }

    fun markCodeCopied() {
        mutable.update { it.copy(copiedCode = true) }
    }

    fun togglePreview() {
        if (mutable.value.previewText != null) {
            mutable.update { it.copy(previewText = null) }
            return
        }
        val note = mutable.value.userNote
        viewModelScope.launch(ioDispatcher) {
            val text = runCatching { store.buildReportPackage(note).previewText }.getOrNull()
            mutable.update {
                if (text != null) it.copy(previewText = text)
                else it.copy(feedbackRes = R.string.diagnostics_empty, feedbackIsError = true)
            }
        }
    }

    fun saveZipToUri(context: Context, destination: Uri) {
        val note = mutable.value.userNote
        viewModelScope.launch(ioDispatcher) {
            val ok = runCatching {
                val report = store.buildReportPackage(userNote = note, stopActiveRecording = true)
                context.contentResolver.openOutputStream(destination)?.use { out ->
                    report.writeZipTo(out)
                } ?: error("Cannot open output stream")
            }.isSuccess
            val snap = store.stateSnapshot()
            mutable.update {
                it.copy(
                    isRecording = snap.isRecording,
                    hasExportableLogs = snap.hasExportableLogs,
                    recoveredPreviousSession = snap.recoveredPreviousSession,
                    feedbackRes = if (ok) R.string.diagnostics_saved_feedback else R.string.diagnostics_export_failed,
                    feedbackIsError = !ok,
                )
            }
        }
    }

    fun shareZip(context: Context) {
        val note = mutable.value.userNote
        viewModelScope.launch(ioDispatcher) {
            val shareIntent = runCatching {
                val report = store.buildReportPackage(userNote = note, stopActiveRecording = true)
                val shareDir = File(context.cacheDir, "diagnostics-share").apply {
                    mkdirs()
                    listFiles()?.forEach(File::delete)
                }
                val zipFile = File(shareDir, "RawLab-Diag-${report.reportID}.zip")
                zipFile.outputStream().use { report.writeZipTo(it) }
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.diagnostics", zipFile)
                Intent(Intent.ACTION_SEND).apply {
                    type = "application/zip"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            }.getOrNull()
            val snap = store.stateSnapshot()
            withContext(Dispatchers.Main) {
                if (shareIntent != null) {
                    runCatching {
                        context.startActivity(Intent.createChooser(shareIntent, null))
                    }
                    mutable.update {
                        it.copy(
                            isRecording = snap.isRecording,
                            hasExportableLogs = snap.hasExportableLogs,
                            recoveredPreviousSession = snap.recoveredPreviousSession,
                            feedbackRes = null,
                            feedbackIsError = false,
                        )
                    }
                } else {
                    mutable.update {
                        it.copy(
                            isRecording = snap.isRecording,
                            hasExportableLogs = snap.hasExportableLogs,
                            recoveredPreviousSession = snap.recoveredPreviousSession,
                            feedbackRes = R.string.diagnostics_export_failed,
                            feedbackIsError = true,
                        )
                    }
                }
            }
        }
    }

    fun uploadToCloud() {
        if (mutable.value.isUploading) return
        val note = mutable.value.userNote
        mutable.update { it.copy(isUploading = true, copiedCode = false, feedbackRes = null, feedbackIsError = false) }
        viewModelScope.launch(ioDispatcher) {
            try {
                val report = store.buildReportPackage(userNote = note, stopActiveRecording = true)
                val payload = SLSDiagnosticWebTracking.buildPayload(report, store.environment)
                val endpoint = uploadEndpointProvider()
                transport.upload(endpoint, payload)
                val snap = store.stateSnapshot()
                mutable.update {
                    it.copy(
                        isUploading = false,
                        isRecording = snap.isRecording,
                        hasExportableLogs = snap.hasExportableLogs,
                        recoveredPreviousSession = snap.recoveredPreviousSession,
                        lastUploadedReportID = report.reportID,
                        feedbackRes = R.string.diagnostics_upload_succeeded,
                        feedbackIsError = false,
                    )
                }
            } catch (error: DiagnosticUploadException) {
                val snap = store.stateSnapshot()
                val msg = when (error.reason) {
                    DiagnosticUploadFailure.EMPTY -> R.string.diagnostics_empty
                    DiagnosticUploadFailure.PAYLOAD_TOO_LARGE -> R.string.diagnostics_upload_too_large
                    DiagnosticUploadFailure.UNAVAILABLE -> R.string.diagnostics_upload_unavailable
                }
                mutable.update {
                    it.copy(
                        isUploading = false,
                        isRecording = snap.isRecording,
                        hasExportableLogs = snap.hasExportableLogs,
                        recoveredPreviousSession = snap.recoveredPreviousSession,
                        feedbackRes = msg,
                        feedbackIsError = true,
                    )
                }
            } catch (_: Exception) {
                val snap = store.stateSnapshot()
                mutable.update {
                    it.copy(
                        isUploading = false,
                        isRecording = snap.isRecording,
                        hasExportableLogs = snap.hasExportableLogs,
                        recoveredPreviousSession = snap.recoveredPreviousSession,
                        feedbackRes = R.string.diagnostics_upload_unavailable,
                        feedbackIsError = true,
                    )
                }
            }
        }
    }

    fun clearLogs() {
        viewModelScope.launch(ioDispatcher) {
            val snap = store.clearAll()
            mutable.update {
                it.copy(
                    isRecording = snap.isRecording,
                    hasExportableLogs = snap.hasExportableLogs,
                    recoveredPreviousSession = snap.recoveredPreviousSession,
                    lastUploadedReportID = null,
                    previewText = null,
                    copiedCode = false,
                    feedbackRes = R.string.diagnostics_cleared,
                    feedbackIsError = false,
                )
            }
        }
    }

    private fun applySnapshot(snap: DiagnosticSessionStore.Snapshot) {
        mutable.update {
            it.copy(
                isRecording = snap.isRecording,
                hasExportableLogs = snap.hasExportableLogs,
                recoveredPreviousSession = snap.recoveredPreviousSession,
            )
        }
    }
}
