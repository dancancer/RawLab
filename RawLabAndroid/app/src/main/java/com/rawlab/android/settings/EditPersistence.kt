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
class AdjustmentOperationExpiredException : IllegalStateException("This adjustment operation is no longer current.")
class AdjustmentHistoryOrderException : IllegalStateException("Undo or redo the photo's edits in history order.")
class AdjustmentNotReadyException : IllegalStateException("The current adjustments are not committed")

class EditStore(private val directory: File,
    private val replaceFile: (File, File) -> Unit = ::replaceEditFileAtomically,
) {
    private val file = File(directory, "edits.properties")
    private val processLock = locks.getOrPut(directory.canonicalPath) { ReentrantLock() }
    @Volatile private var lastReadableRecords: Map<PhotoIdentity, EditSettings> = emptyMap()
    private data class Snapshot(val records: Map<PhotoIdentity, EditSettings>,
        val properties: Properties = Properties()) {
        fun record(identity: PhotoIdentity) = PhotoEditState(identity, records[identity])
    }

    private var cachedBytes: ByteArray? = null
    private var cachedSnapshot: Snapshot? = null

    init {
        if (directory.exists() && !directory.isDirectory) throw IOException("Edit store path is not a directory")
        if (!directory.exists() && !directory.mkdirs() && !directory.isDirectory) throw IOException("Cannot create edit store")
        withStoreLock { read() }
    }

    // 旧 UI 查询在存储暂不可读时保留最后可读值；提交和导入必须使用严格的 readState。
    fun load(identity: PhotoIdentity): EditSettings? = try { readState(identity).settings }
        catch (_: Exception) { lastReadableRecords[identity] }

    fun readState(identity: PhotoIdentity): PhotoEditState = withStoreLock { read().record(identity) }

    fun save(identity: PhotoIdentity, settings: EditSettings?): PhotoEditState = withStoreLock {
        commit(read(), identity, settings)
    }

    fun reset(identity: PhotoIdentity): PhotoEditState = save(identity, null)

    private fun <T> withStoreLock(action: () -> T): T = processLock.withLock {
        if (!directory.isDirectory) throw IOException("Edit store path is not a directory")
        RandomAccessFile(File(directory, ".edits.lock"), "rw").use { lockFile ->
            lockFile.channel.lock().use { action() }
        }
    }

    private fun commit(current: Snapshot, identity: PhotoIdentity, requested: EditSettings?): PhotoEditState {
        val settings = requested?.canonicalZeros()
        if (current.records[identity] == settings) return current.record(identity)
        val records = current.records.toMutableMap()
        if (settings == null) records.remove(identity) else records[identity] = settings
        val updated = Snapshot(records, current.properties)
        write(updated, identity)
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
        require(properties.getProperty("format.version") in setOf(null, "1")) { "Unsupported edit store version" }
        val recordSuffixes = setOf("values", "film", "recipe", "lens", "geometry", "processing")
        for (key in properties.stringPropertyNames().filter { it.startsWith("record.") }) {
            val parts = key.split('.')
            require(parts.size == 3 && parts[1].isNotEmpty() && parts[2] in recordSuffixes) { "Unknown edit record field" }
            val values = properties.getProperty("record.${parts[1]}.values")
            require(values != null) { "Missing edit record values" }
            require(!values.startsWith("v2:") || parts[2] == "values") { "Conflicting structured edit fields" }
        }
        val records = linkedMapOf<PhotoIdentity, EditSettings>()
        properties.stringPropertyNames().filter { it.startsWith("record.") && it.endsWith(".values") }.forEach { key ->
            val encoded = key.removePrefix("record.").removeSuffix(".values")
            val identity = decodeIdentity(encoded)
            val storedFilm = properties.getProperty("record.${encoded}.film", "neutral")
            val film = runCatching { String(Base64.getUrlDecoder().decode(storedFilm), StandardCharsets.UTF_8) }
                .getOrDefault(storedFilm)
            val encodedSettings = properties.getProperty(key)
            records[identity] = (if (encodedSettings.startsWith("v2:")) StructuredSettingsCodec.decode(encodedSettings, "photo_edit")
            else decode(encodedSettings, film).copy(
                recipeID = properties.getProperty("record.$encoded.recipe"),
                lens = LensSettings.decode(properties.getProperty("record.$encoded.lens")),
                geometry = GeometrySettings.decode(properties.getProperty("record.$encoded.geometry")),
                processing = ProcessingIdentity.decode(properties.getProperty("record.$encoded.processing")))).canonicalZeros()
        }
        lastReadableRecords = records.toMap()
        return Snapshot(records, properties = properties).also {
            cachedSnapshot = it
            cachedBytes = bytes
        }
    }

    private fun encodeIdentity(identity: PhotoIdentity) = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(identity.value.toByteArray(StandardCharsets.UTF_8))
    private fun decodeIdentity(encoded: String) = PhotoIdentity(String(Base64.getUrlDecoder().decode(encoded), StandardCharsets.UTF_8))

    private fun write(updated: Snapshot, identity: PhotoIdentity) {
        val properties = Properties().apply { putAll(updated.properties) }
        properties.setProperty("format.version", "1")
        val encoded = encodeIdentity(identity)
        // 旧文件中的 revision 只允许被读取，任何新写入都清理 revision 元数据。
        properties.stringPropertyNames().filter { it.startsWith("revision.") }.forEach(properties::remove)
        properties.stringPropertyNames().filter { it.startsWith("record.$encoded.") }.forEach(properties::remove)
        updated.records[identity]?.let { settings ->
            properties.setProperty("record.$encoded.values", StructuredSettingsCodec.encode(settings, "photo_edit"))
        }
        val temporary = File(directory, "edits-${System.nanoTime()}.tmp")
        try {
            val bytes = java.io.ByteArrayOutputStream().use { stream -> properties.store(stream, null); stream.toByteArray() }
            temporary.writeBytes(bytes)
            replaceFile(temporary, file)
            cachedSnapshot = updated.copy(properties = properties)
            cachedBytes = bytes
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
