package com.rawlab.android.settings

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Base64
import java.util.Properties
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import com.rawlab.android.geometry.GeometrySettings
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/** Stable source identity. A picker URI is preferred; content:<digest> is used only when no URI exists. */
@JvmInline
value class PhotoIdentity(val value: String) {

    init { require(value.isNotBlank()) }
}

/** 当前会话看到的照片调整；磁盘不再为调整记录生成 revision。 */
data class PhotoEditState(val identity: PhotoIdentity, val settings: EditSettings?) {
    fun sameAs(other: PhotoEditState?): Boolean = other != null && identity == other.identity && settings == other.settings
    fun copySettings(): PhotoEditState = copy(settings = settings?.copy())
}

class PhotoChangedException : IOException("The original photo changed. Select it again.")
class UnusableEditRecordException(message: String, cause: Throwable? = null) : IOException(message, cause)
class AdjustmentOperationExpiredException : IllegalStateException("This adjustment operation is no longer current.")
class AdjustmentHistoryOrderException : IllegalStateException("Undo or redo the photo's edits in history order.")
class AdjustmentNotReadyException : IllegalStateException("The current adjustments are not committed")

data class EditStoreChange(val directory: String, val state: PhotoEditState)

class EditStore(private val directory: File,
    private val replaceFile: (File, File) -> Unit = ::replaceEditFileAtomically,
) {
    private val file = File(directory, "edits.properties")
    private val directoryPath = directory.canonicalPath
    private val processLock = locks.getOrPut(directoryPath) { ReentrantLock() }
    @Volatile private var lastReadableRecords: Map<PhotoIdentity, EditSettings> = emptyMap()
    private data class Snapshot(val records: Map<PhotoIdentity, EditSettings>,
        val unusable: Map<PhotoIdentity, UnusableEditRecordException> = emptyMap(),
        val properties: Properties = Properties(),
        val rawLines: Map<String, String> = emptyMap()) {
        fun record(identity: PhotoIdentity): PhotoEditState {
            unusable[identity]?.let { throw it }
            return PhotoEditState(identity, records[identity])
        }
    }

    private var cachedBytes: ByteArray? = null
    private var cachedSnapshot: Snapshot? = null

    init {
        if (directory.exists() && !directory.isDirectory) throw IOException("Edit store path is not a directory")
        if (!directory.exists() && !directory.mkdirs() && !directory.isDirectory) throw IOException("Cannot create edit store")
        withStoreLock { read() }
    }

    // 旧 UI 查询在存储暂不可读时保留最后可读值；单条坏记录返回 null，提交和导入必须使用严格的 readState。
    fun load(identity: PhotoIdentity): EditSettings? = try { readState(identity).settings }
        catch (_: UnusableEditRecordException) { null }
        catch (_: Exception) { lastReadableRecords[identity] }

    fun readState(identity: PhotoIdentity): PhotoEditState = withStoreLock { read().record(identity) }
    fun readStates(identities: Collection<PhotoIdentity>): Map<PhotoIdentity, PhotoEditState> = withStoreLock {
        val snapshot = read()
        identities.associateWith { identity ->
            if (identity in snapshot.unusable) PhotoEditState(identity, null) else snapshot.record(identity)
        }
    }

    fun save(identity: PhotoIdentity, settings: EditSettings?, clearProcessingMigration: Boolean = false): PhotoEditState = withStoreLock {
        commit(read(), identity, settings, clearProcessingMigration)
    }

    fun reset(identity: PhotoIdentity): PhotoEditState = save(identity, null, clearProcessingMigration = true)

    fun resetToUnmodified(identity: PhotoIdentity): PhotoEditState = withStoreLock {
        val current = read()
        val encoded = encodeIdentity(identity)
        val hasRecordKeys = current.properties.stringPropertyNames().any { it.startsWith("record.$encoded.") }
        val hasMigration = current.properties.containsKey(migrationKey(identity))
        if (!hasRecordKeys && !hasMigration && identity !in current.records && identity !in current.unusable) {
            return@withStoreLock PhotoEditState(identity, null)
        }
        val records = current.records.toMutableMap().apply { remove(identity) }
        val unusable = current.unusable.toMutableMap().apply { remove(identity) }
        val updated = current.copy(records = records, unusable = unusable)
        write(updated, identity, clearProcessingMigration = true)
        lastReadableRecords = records.toMap()
        updated.record(identity)
    }

    fun processingMigration(identity: PhotoIdentity): ProcessingMigrationReceipt? = withStoreLock {
        read().properties.getProperty(migrationKey(identity))?.let { raw ->
            runCatching { ProcessingMigrationReceipt.decode(raw) }.getOrNull()
        }
    }

    fun commitProcessingMigration(expected: PhotoEditState, candidate: EditSettings?,
        quality: ProcessingMigrationQuality): PhotoEditState = withStoreLock {
        val current = read()
        if (!current.record(expected.identity).sameAs(expected)) throw AdjustmentOperationExpiredException()
        val before = requireNotNull(expected.settings)
        require(before.processing.version in 1..2 && quality.isValid)
        val previous = current.properties.getProperty(migrationKey(expected.identity))?.let { raw ->
            runCatching { ProcessingMigrationReceipt.decode(raw) }.getOrNull()
        }
        if (previous?.shouldAttempt(before, before.processing.version) == false) throw AdjustmentOperationExpiredException()
        if (candidate != null) require(candidate.processing == ProcessingIdentity.CURRENT && quality.passes)
        val records = current.records.toMutableMap()
        records[expected.identity] = (candidate ?: before).canonicalZeros()
        val updated = current.copy(records = records)
        write(updated, expected.identity, ProcessingMigrationReceipt(
            if (candidate == null) ProcessingMigrationStatus.KEPT else ProcessingMigrationStatus.MIGRATED, before, quality))
        lastReadableRecords = records.toMap()
        updated.record(expected.identity)
    }

    fun rollbackProcessingMigration(expected: PhotoEditState): PhotoEditState = withStoreLock {
        val current = read()
        if (!current.record(expected.identity).sameAs(expected)) throw AdjustmentOperationExpiredException()
        val receipt = current.properties.getProperty(migrationKey(expected.identity))?.let { raw ->
            runCatching { ProcessingMigrationReceipt.decode(raw) }.getOrNull()
        } ?: throw AdjustmentOperationExpiredException()
        if (receipt.status != ProcessingMigrationStatus.MIGRATED) throw AdjustmentOperationExpiredException()
        val records = current.records.toMutableMap()
        records[expected.identity] = receipt.original
        val updated = current.copy(records = records)
        write(updated, expected.identity, receipt.copy(status = ProcessingMigrationStatus.ROLLED_BACK))
        lastReadableRecords = records.toMap()
        updated.record(expected.identity)
    }

    private fun <T> withStoreLock(action: () -> T): T = processLock.withLock {
        if (!directory.isDirectory) throw IOException("Edit store path is not a directory")
        RandomAccessFile(File(directory, ".edits.lock"), "rw").use { lockFile ->
            lockFile.channel.lock().use { action() }
        }
    }

    private fun commit(current: Snapshot, identity: PhotoIdentity, requested: EditSettings?,
        clearProcessingMigration: Boolean = false): PhotoEditState {
        current.unusable[identity]?.let { throw it }
        val settings = requested?.canonicalZeros()
        val clearsMigration = clearProcessingMigration && current.properties.containsKey(migrationKey(identity))
        if (current.records[identity] == settings && !clearsMigration) return current.record(identity)
        val records = current.records.toMutableMap()
        if (settings == null) records.remove(identity) else records[identity] = settings
        val updated = current.copy(records = records)
        write(updated, identity, clearProcessingMigration = clearsMigration)
        lastReadableRecords = records.toMap()
        return updated.record(identity)
    }

    private fun read(): Snapshot {
        if (file.exists() && !file.isFile) throw IOException("Edit record path is not a file")
        if (!file.exists()) return Snapshot(emptyMap()).also { lastReadableRecords = it.records }
        // 部分文件系统的时间戳精度不足；内容未变时才复用解析结果。
        val bytes = file.readBytes()
        if (cachedBytes?.contentEquals(bytes) == true) cachedSnapshot?.let { return it }
        val properties = Properties()
        bytes.inputStream().use(properties::load)
        val rawLines = parseRawPropertyLines(bytes, properties)
        require(properties.getProperty("format.version") in setOf(null, "1")) { "Unsupported edit store version" }
        val recordSuffixes = setOf("values", "film", "recipe", "lens", "geometry", "processing")
        val recordKeysByPhoto = linkedMapOf<PhotoIdentity, MutableList<Pair<String, String>>>()
        for (key in properties.stringPropertyNames()) {
            when {
                key == "format.version" -> Unit
                key.startsWith("revision.") -> require(key.removePrefix("revision.").isNotEmpty()) { "Invalid revision key" }
                key.startsWith("migration.") -> {
                    val encoded = key.removePrefix("migration.")
                    require(encoded.isNotEmpty() && !encoded.contains('.')) { "Unknown migration field" }
                    decodeIdentity(encoded)
                }
                key.startsWith("record.") -> {
                    val rest = key.removePrefix("record.")
                    val dot = rest.indexOf('.')
                    require(dot > 0 && dot < rest.length - 1) { "Invalid edit record key" }
                    val encoded = rest.substring(0, dot)
                    val suffix = rest.substring(dot + 1)
                    val identity = decodeIdentity(encoded)
                    recordKeysByPhoto.getOrPut(identity) { mutableListOf() } += key to suffix
                }
                else -> throw IllegalArgumentException("Unknown edit store property")
            }
        }
        val records = linkedMapOf<PhotoIdentity, EditSettings>()
        val unusable = linkedMapOf<PhotoIdentity, UnusableEditRecordException>()
        for ((identity, entries) in recordKeysByPhoto) {
            val encoded = encodeIdentity(identity)
            try {
                for ((_, suffix) in entries) {
                    require(suffix in recordSuffixes) { "Unknown edit record field" }
                }
                val encodedSettings = properties.getProperty("record.$encoded.values")
                require(encodedSettings != null) { "Missing edit record values" }
                require(!encodedSettings.startsWith("v2:") || entries.all { it.second == "values" }) { "Conflicting structured edit fields" }
                val storedFilm = properties.getProperty("record.$encoded.film", "neutral")
                val film = runCatching { String(Base64.getUrlDecoder().decode(storedFilm), StandardCharsets.UTF_8) }
                    .getOrDefault(storedFilm)
                records[identity] = (if (encodedSettings.startsWith("v2:")) StructuredSettingsCodec.decode(encodedSettings, "photo_edit")
                else decode(encodedSettings, film).copy(
                    recipeID = properties.getProperty("record.$encoded.recipe"),
                    lens = LensSettings.decode(properties.getProperty("record.$encoded.lens")),
                    geometry = GeometrySettings.decode(properties.getProperty("record.$encoded.geometry")),
                    processing = ProcessingIdentity.decode(properties.getProperty("record.$encoded.processing")))).canonicalZeros()
            } catch (error: Exception) {
                unusable[identity] = UnusableEditRecordException(
                    error.message?.takeIf(String::isNotBlank) ?: error.javaClass.simpleName,
                    error,
                )
            }
        }
        lastReadableRecords = records.toMap()
        return Snapshot(records, unusable = unusable, properties = properties, rawLines = rawLines).also {
            cachedSnapshot = it
            cachedBytes = bytes
        }
    }

    private fun parseRawPropertyLines(bytes: ByteArray, expected: Properties): Map<String, String> {
        val text = String(bytes, StandardCharsets.ISO_8859_1)
        if (text.isEmpty()) return emptyMap()
        val lines = text.split(Regex("\\r\\n|\\n|\\r"))
        val rawLines = linkedMapOf<String, String>()
        var index = 0
        while (index < lines.size) {
            val first = lines[index]
            val trimmed = first.trimStart(' ', '\t', '\u000c')
            if (trimmed.isEmpty() || trimmed.startsWith('#') || trimmed.startsWith('!')) {
                index += 1
                continue
            }
            val chunkLines = mutableListOf(first)
            while (hasTrailingContinuation(chunkLines.last()) && index + 1 < lines.size) {
                index += 1
                chunkLines += lines[index]
            }
            val chunk = chunkLines.joinToString("\n")
            val single = Properties().apply { chunk.byteInputStream(StandardCharsets.ISO_8859_1).use(::load) }
            val key = single.stringPropertyNames().singleOrNull()
                ?: throw IllegalArgumentException("Malformed edit store property")
            require(rawLines.put(key, chunk) == null) { "Duplicate edit store key" }
            index += 1
        }
        require(rawLines.keys == expected.stringPropertyNames()) { "Corrupt edit store structure" }
        return rawLines
    }

    private fun hasTrailingContinuation(line: String): Boolean {
        var backslashes = 0
        var pos = line.length - 1
        while (pos >= 0 && line[pos] == '\\') {
            backslashes += 1
            pos -= 1
        }
        return backslashes % 2 == 1
    }

    private fun encodePropertyLine(key: String, value: String): String {
        val encoded = java.io.ByteArrayOutputStream().use { stream ->
            Properties().apply { setProperty(key, value) }.store(stream, null)
            String(stream.toByteArray(), StandardCharsets.ISO_8859_1)
        }
        return encoded.lineSequence()
            .map { it.trimEnd('\r') }
            .filter { it.isNotEmpty() && !it.startsWith('#') }
            .joinToString("\n")
    }

    private fun encodeIdentity(identity: PhotoIdentity) = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(identity.value.toByteArray(StandardCharsets.UTF_8))
    private fun decodeIdentity(encoded: String): PhotoIdentity {
        require(encoded.isNotEmpty() && '=' !in encoded) { "Invalid photo identity key" }
        val raw = Base64.getUrlDecoder().decode(encoded)
        val decoded = try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                .decode(java.nio.ByteBuffer.wrap(raw))
                .toString()
        } catch (error: java.nio.charset.CharacterCodingException) {
            throw IllegalArgumentException("Invalid UTF-8 photo identity key", error)
        }
        val identity = PhotoIdentity(decoded)
        require(encodeIdentity(identity) == encoded) { "Non-canonical photo identity key" }
        return identity
    }

    private fun migrationKey(identity: PhotoIdentity) = "migration.${encodeIdentity(identity)}"

    private fun write(updated: Snapshot, identity: PhotoIdentity, migration: ProcessingMigrationReceipt? = null,
        clearProcessingMigration: Boolean = false) {
        val properties = Properties().apply { putAll(updated.properties) }
        val rawLines = updated.rawLines.toMutableMap()
        if (properties.getProperty("format.version") != "1") {
            properties.setProperty("format.version", "1")
            rawLines.remove("format.version")
        }
        val migrationKey = migrationKey(identity)
        if (clearProcessingMigration) {
            properties.remove(migrationKey)
            rawLines.remove(migrationKey)
        }
        migration?.let {
            properties.setProperty(migrationKey, it.encode())
            rawLines.remove(migrationKey)
        }
        val encoded = encodeIdentity(identity)
        // 旧文件中的 revision 只允许被读取，任何新写入都清理 revision 元数据。
        properties.stringPropertyNames().filter { it.startsWith("revision.") }.forEach {
            properties.remove(it)
            rawLines.remove(it)
        }
        properties.stringPropertyNames().filter { it.startsWith("record.$encoded.") }.forEach {
            properties.remove(it)
            rawLines.remove(it)
        }
        updated.records[identity]?.let { settings ->
            properties.setProperty("record.$encoded.values", StructuredSettingsCodec.encode(settings, "photo_edit"))
        }
        for (key in properties.stringPropertyNames()) {
            if (key !in rawLines) rawLines[key] = encodePropertyLine(key, properties.getProperty(key))
        }
        rawLines.keys.retainAll(properties.stringPropertyNames())
        val temporary = File(directory, "edits-${System.nanoTime()}.tmp")
        try {
            val serialized = properties.stringPropertyNames().sorted()
                .joinToString("\n", postfix = if (properties.isEmpty) "" else "\n") { rawLines.getValue(it) }
            val bytes = serialized.toByteArray(StandardCharsets.ISO_8859_1)
            temporary.writeBytes(bytes)
            replaceFile(temporary, file)
            cachedSnapshot = updated.copy(properties = properties, rawLines = rawLines.toMap())
            cachedBytes = bytes
            changed.tryEmit(EditStoreChange(directoryPath, updated.record(identity)))
        } catch (error: Throwable) {
            cachedBytes = null; cachedSnapshot = null
            temporary.delete()
            throw if (error is IOException) error else IOException("Cannot save edit store", error)
        }
    }

    private fun decode(values: String, film: String): EditSettings {
        val fields = values.split(',').map(String::toFloat)
        require(fields.size in listOf(11, 15, 24, 49))
        return EditSettings(film = film, strength = fields[0], exposure = fields[1],
            x3fMode = X3fMode.LEGACY,
            highlights = fields[2], shadows = fields[3], contrast = fields[4], toneCurve = fields[5],
            saturation = fields[6], customWb = parseBoolean(fields[7]), temperature = fields[8], tint = fields[9],
            sharpening = fields[10], denoise = if (fields.size == 15)
                DenoiseSettings(parseBoolean(fields[11]), fields[12], fields[13], fields[14])
            else if (fields.size >= 24)
                DenoiseSettings(parseBoolean(fields[11]), fields[12], fields[13], fields[14])
            else DenoiseSettings(),
            displayChromaDenoise = if (fields.size >= 24) parseChromaMode(fields[15]) else 0,
            exposureMode = if (fields.size == 49) parseChromaMode(fields[24]) else 0,
            hsl = if (fields.size == 49) HslSettings(fields.drop(25)) else HslSettings(),
            effects = if (fields.size >= 24) PhotoEffectsSettings(
                vignetteAmount = fields[16], vignetteMidpoint = fields[17], vignetteRoundness = fields[18],
                vignetteFeather = fields[19], vignetteHighlights = fields[20], grainAmount = fields[21],
                grainSize = fields[22], grainRoughness = fields[23],
            ) else PhotoEffectsSettings())
    }

    private fun parseBoolean(value: Float): Boolean {
        require(value == 0f || value == 1f) { "Invalid legacy edit boolean" }
        return value == 1f
    }

    private fun parseChromaMode(value: Float): Int {
        require(value.isFinite() && value == value.toInt().toFloat())
        return value.toInt()
    }

    companion object {
        private val changed = MutableSharedFlow<EditStoreChange>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)
        val changes = changed.asSharedFlow()
        // JVM 内先串行，再取文件锁；否则同进程的不同 FileChannel 会直接抛 overlapping lock。
        private val locks = ConcurrentHashMap<String, ReentrantLock>()
    }
}

private fun replaceEditFileAtomically(from: File, to: File) {
    try {
        Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
        Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
    }
}
