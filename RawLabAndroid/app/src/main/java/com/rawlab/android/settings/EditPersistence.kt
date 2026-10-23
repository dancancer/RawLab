package com.rawlab.android.settings

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Base64
import java.util.Properties
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import com.rawlab.android.geometry.GeometrySettings

/** Stable source identity. A picker URI is preferred; content:<digest> is used only when no URI exists. */
@JvmInline
value class PhotoIdentity(val value: String) {
    init { require(value.isNotBlank()) }
}

data class VersionedPhotoEdit(val identity: PhotoIdentity, val settings: EditSettings?, val revision: String?)
class EditPersistenceConflict : IOException("Photo adjustments changed after they were read")

class EditStore(private val directory: File,
    private val replaceFile: (File, File) -> Unit = ::replaceEditFileAtomically,
) {
    private val file = File(directory, "edits.properties")
    private val processLock = locks.getOrPut(directory.canonicalPath) { ReentrantLock() }
    @Volatile private var lastReadableRecords: Map<PhotoIdentity, EditSettings> = emptyMap()
    private data class Snapshot(val records: Map<PhotoIdentity, EditSettings>, val revisions: Map<PhotoIdentity, String>) {
        fun record(identity: PhotoIdentity) = VersionedPhotoEdit(identity, records[identity], revisions[identity])
    }

    init {
        if (directory.exists() && !directory.isDirectory) throw IOException("Edit store path is not a directory")
        if (!directory.exists() && !directory.mkdirs() && !directory.isDirectory) throw IOException("Cannot create edit store")
        withStoreLock { read() }
    }

    // 旧 UI 查询在存储暂不可读时保留最后可读值；提交和导入必须使用严格的 versionedState。
    fun load(identity: PhotoIdentity): EditSettings? = try { versionedState(identity).settings }
        catch (_: Exception) { lastReadableRecords[identity] }

    fun versionedState(identity: PhotoIdentity): VersionedPhotoEdit = withStoreLock { read().record(identity) }

    fun compareAndSave(expected: VersionedPhotoEdit, settings: EditSettings?): VersionedPhotoEdit = withStoreLock {
        val current = read()
        if (current.record(expected.identity) != expected) throw EditPersistenceConflict()
        commit(current, expected.identity, settings)
    }

    fun save(identity: PhotoIdentity, settings: EditSettings) = withStoreLock {
        commit(read(), identity, settings)
        Unit
    }

    fun reset(identity: PhotoIdentity) = withStoreLock {
        commit(read(), identity, null)
        Unit
    }

    private fun <T> withStoreLock(action: () -> T): T = processLock.withLock {
        if (!directory.isDirectory) throw IOException("Edit store path is not a directory")
        RandomAccessFile(File(directory, ".edits.lock"), "rw").use { lockFile ->
            lockFile.channel.lock().use { action() }
        }
    }

    private fun commit(current: Snapshot, identity: PhotoIdentity, settings: EditSettings?): VersionedPhotoEdit {
        if (current.records[identity] == settings) return current.record(identity)
        val records = current.records.toMutableMap()
        if (settings == null) records.remove(identity) else records[identity] = settings
        val revisions = current.revisions + (identity to UUID.randomUUID().toString())
        val updated = Snapshot(records, revisions)
        write(updated)
        lastReadableRecords = records.toMap()
        return updated.record(identity)
    }

    private fun read(): Snapshot {
        if (file.exists() && !file.isFile) throw IOException("Edit record path is not a file")
        if (!file.exists()) return Snapshot(emptyMap(), emptyMap()).also { lastReadableRecords = it.records }
        val properties = Properties()
        file.inputStream().use(properties::load)
        require(properties.getProperty("format.version") in setOf(null, "1")) { "Unsupported edit store version" }
        val records = linkedMapOf<PhotoIdentity, EditSettings>()
        val revisions = linkedMapOf<PhotoIdentity, String>()
        properties.stringPropertyNames().filter { it.startsWith("revision.") }.forEach { key ->
            val identity = decodeIdentity(key.removePrefix("revision."))
            val revision = properties.getProperty(key)
            require(revision.isNotBlank()) { "Missing record revision" }
            revisions[identity] = revision
        }
        properties.stringPropertyNames().filter { it.startsWith("record.") && it.endsWith(".values") }.forEach { key ->
            val encoded = key.removePrefix("record.").removeSuffix(".values")
            val identity = decodeIdentity(encoded)
            val storedFilm = properties.getProperty("record.${encoded}.film", "neutral")
            val film = runCatching { String(Base64.getUrlDecoder().decode(storedFilm), StandardCharsets.UTF_8) }
                .getOrDefault(storedFilm)
            records[identity] = decode(properties.getProperty(key), film).copy(
                recipeID = properties.getProperty("record.$encoded.recipe"),
                lens = LensSettings.decode(properties.getProperty("record.$encoded.lens")),
                geometry = GeometrySettings.decode(properties.getProperty("record.$encoded.geometry")),
                processing = ProcessingIdentity.decode(properties.getProperty("record.$encoded.processing")))
        }
        lastReadableRecords = records.toMap()
        return Snapshot(records, revisions)
    }

    private fun encodeIdentity(identity: PhotoIdentity) = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(identity.value.toByteArray(StandardCharsets.UTF_8))
    private fun decodeIdentity(encoded: String) = PhotoIdentity(String(Base64.getUrlDecoder().decode(encoded), StandardCharsets.UTF_8))

    private fun write(updated: Snapshot) {
        val properties = Properties()
        properties.setProperty("format.version", "1")
        updated.revisions.forEach { (identity, revision) ->
            properties.setProperty("revision.${encodeIdentity(identity)}", revision)
        }
        updated.records.forEach { (identity, settings) ->
            val encoded = encodeIdentity(identity)
            properties.setProperty("record.$encoded.values", encode(settings))
            settings.recipeID?.let { properties.setProperty("record.$encoded.recipe", it) }
            properties.setProperty("record.$encoded.lens", settings.lens.encode())
            properties.setProperty("record.$encoded.geometry", settings.geometry.encode())
            properties.setProperty("record.$encoded.processing", settings.processing.encode())
            properties.setProperty("record.$encoded.film", Base64.getUrlEncoder().withoutPadding()
                .encodeToString(settings.film.toByteArray(StandardCharsets.UTF_8)))
        }
        val temporary = File(directory, "edits-${System.nanoTime()}.tmp")
        try {
            temporary.outputStream().use { properties.store(it, null) }
            replaceFile(temporary, file)
        } catch (error: Throwable) {
            temporary.delete()
            throw if (error is IOException) error else IOException("Cannot save edit store", error)
        }
    }

    private fun encode(settings: EditSettings): String = listOf(
        settings.strength, settings.exposure, settings.highlights, settings.shadows,
        settings.contrast, settings.toneCurve, settings.saturation,
        if (settings.customWb) 1f else 0f, settings.temperature, settings.tint, settings.sharpening,
        if (settings.denoise.enabled) 1f else 0f, settings.denoise.luma, settings.denoise.chroma, settings.denoise.coarse,
        settings.displayChromaDenoise,
        settings.effects.vignetteAmount, settings.effects.vignetteMidpoint, settings.effects.vignetteRoundness,
        settings.effects.vignetteFeather, settings.effects.vignetteHighlights,
        settings.effects.grainAmount, settings.effects.grainSize, settings.effects.grainRoughness,
    ).plus(settings.exposureMode).plus(settings.hsl.packed().toList()).joinToString(",")

    private fun decode(values: String, film: String): EditSettings {
        val fields = values.split(',').map(String::toFloat)
        require(fields.size in listOf(11, 15, 24, 49))
        return EditSettings(film = film, strength = fields[0], exposure = fields[1],
            highlights = fields[2], shadows = fields[3], contrast = fields[4], toneCurve = fields[5],
            saturation = fields[6], customWb = fields[7] != 0f, temperature = fields[8], tint = fields[9],
            sharpening = fields[10], denoise = if (fields.size == 15)
                DenoiseSettings(fields[11] != 0f, fields[12], fields[13], fields[14])
            else if (fields.size >= 24)
                DenoiseSettings(fields[11] != 0f, fields[12], fields[13], fields[14])
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
