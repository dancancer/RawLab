package com.rawlab.android.presets

import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentTransferException
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.text.Normalizer
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

enum class PresetFailure { EMPTY_NAME, DUPLICATE_NAME, CHANGED, CORRUPT_LIBRARY, UNSUPPORTED_VERSION, IDENTITY_COLLISION }
class AdjustmentPresetException(val reason: PresetFailure, val existing: AdjustmentPreset? = null) : IOException(reason.name)

data class AdjustmentPreset(val id: String, val name: String, val createdAt: Long, val updatedAt: Long,
    val payload: AdjustmentPayload) {
    fun validate() {
        requirePreset(canonicalID(id) && name.isNotEmpty() && name == normalizedName(name) &&
            createdAt >= 0 && updatedAt >= createdAt && payload.source.identifier == "preset:$id")
        payload.validate()
    }

    companion object {
        fun normalizedName(name: String): String = Normalizer.normalize(name.trim { char ->
            char.code in 0x9..0xD || char.code in 0x2000..0x200B ||
                char.code in setOf(0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000)
        }, Normalizer.Form.NFC)
    }
}

class AdjustmentPresetStore(val directory: File,
    private val replaceFile: (File, File) -> Unit = ::replacePresetFile,
    private val makeID: () -> String = { UUID.randomUUID().toString() },
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private data class Registry(val presets: List<AdjustmentPreset> = emptyList(), val retiredIDs: List<String> = emptyList())
    private val file = File(directory, "presets.json")
    private val processLock = locks.getOrPut(directory.canonicalPath) { ReentrantLock() }

    fun list(): List<AdjustmentPreset> = read().presets

    fun create(name: String, payload: AdjustmentPayload): AdjustmentPreset {
        val normalized = validatedName(name)
        payload.validate()
        return withWriteLock {
            val current = read()
            requireAvailableName(normalized, current)
            val id = (0 until 8).asSequence().map { makeID() }.firstOrNull { candidate ->
                canonicalID(candidate) && candidate !in current.retiredIDs && current.presets.none { it.id == candidate }
            } ?: throw AdjustmentPresetException(PresetFailure.IDENTITY_COLLISION)
            val now = clock().coerceAtLeast(0)
            val created = AdjustmentPreset(id, normalized, now, now, independentPayload(payload, id))
            write(current.copy(presets = current.presets + created))
            created
        }
    }

    fun overwrite(expected: AdjustmentPreset, payload: AdjustmentPayload): AdjustmentPreset = update(expected, expected.name, payload)
    fun rename(expected: AdjustmentPreset, name: String): AdjustmentPreset = update(expected, validatedName(name), expected.payload)

    fun delete(expected: AdjustmentPreset) = withWriteLock {
        val current = read()
        val index = matchingIndex(expected, current)
        write(current.copy(presets = current.presets.filterIndexed { position, _ -> position != index },
            retiredIDs = current.retiredIDs + expected.id))
    }

    private fun update(expected: AdjustmentPreset, name: String, payload: AdjustmentPayload): AdjustmentPreset {
        val frozen = independentPayload(payload, expected.id)
        return withWriteLock {
            val current = read()
            val index = matchingIndex(expected, current)
            requireAvailableName(name, current, expected.id)
            if (name == expected.name && frozen == expected.payload) return@withWriteLock expected
            requirePreset(expected.updatedAt < Long.MAX_VALUE)
            val updated = expected.copy(name = name, payload = frozen, updatedAt = maxOf(clock(), expected.updatedAt + 1))
            write(current.copy(presets = current.presets.toMutableList().also { it[index] = updated }))
            updated
        }
    }

    private fun independentPayload(payload: AdjustmentPayload, id: String): AdjustmentPayload {
        payload.validate()
        return AdjustmentPayload(payload.source.copy(identifier = "preset:$id"), payload.values)
    }
    private fun matchingIndex(expected: AdjustmentPreset, registry: Registry): Int {
        val index = registry.presets.indexOfFirst { it.id == expected.id }
        if (index < 0 || registry.presets[index] != expected) throw AdjustmentPresetException(PresetFailure.CHANGED)
        return index
    }
    private fun validatedName(name: String): String = AdjustmentPreset.normalizedName(name).also {
        if (it.isEmpty()) throw AdjustmentPresetException(PresetFailure.EMPTY_NAME)
    }
    private fun requireAvailableName(name: String, registry: Registry, excluding: String? = null) {
        registry.presets.firstOrNull { it.id != excluding && it.name == name }?.let {
            throw AdjustmentPresetException(PresetFailure.DUPLICATE_NAME, it)
        }
    }

    private fun read(): Registry {
        if (!file.exists()) return Registry()
        val text = file.readText(Charsets.UTF_8)
        try {
            validatePresetJSON(text)
            val root = JSONObject(text)
            requireKeys(root, setOf("registry_version", "presets"), setOf("retired_ids"))
            if (root.getLong("registry_version") != 1L) throw AdjustmentPresetException(PresetFailure.UNSUPPORTED_VERSION)
            val entries = root.getJSONArray("presets")
            val presets = (0 until entries.length()).map { index ->
                val item = entries.getJSONObject(index)
                requireKeys(item, setOf("id", "name", "created_at", "updated_at", "payload"))
                val id = item.get("id")
                val name = item.get("name")
                requirePreset(id is String && name is String)
                AdjustmentPreset(id as String, name as String, item.getLong("created_at"), item.getLong("updated_at"),
                    AdjustmentPayload.decode(item.getJSONObject("payload").toString())).also { it.validate() }
            }
            val retired = if (root.has("retired_ids")) root.getJSONArray("retired_ids") else JSONArray()
            val retiredIDs = (0 until retired.length()).map { index ->
                val id = retired.get(index); requirePreset(id is String && canonicalID(id)); id as String
            }
            requirePreset(presets.map { it.id }.toSet().size == presets.size && presets.map { it.name }.toSet().size == presets.size &&
                retiredIDs.toSet().size == retiredIDs.size && presets.none { it.id in retiredIDs })
            return Registry(presets, retiredIDs)
        } catch (error: AdjustmentPresetException) { throw error }
          catch (error: AdjustmentTransferException) {
            throw AdjustmentPresetException(if (error.reason == AdjustmentFailure.UNSUPPORTED_VERSION)
                PresetFailure.UNSUPPORTED_VERSION else PresetFailure.CORRUPT_LIBRARY)
        } catch (_: Exception) { throw AdjustmentPresetException(PresetFailure.CORRUPT_LIBRARY) }
    }

    private fun write(registry: Registry) {
        val entries = JSONArray()
        registry.presets.forEach { preset ->
            preset.validate()
            entries.put(JSONObject().put("id", preset.id).put("name", preset.name).put("created_at", preset.createdAt)
                .put("updated_at", preset.updatedAt).put("payload", JSONObject(preset.payload.encode())))
        }
        val bytes = JSONObject().put("registry_version", 1).put("presets", entries)
            .put("retired_ids", JSONArray(registry.retiredIDs)).toString().toByteArray(Charsets.UTF_8)
        val temporary = File(directory, ".presets-${UUID.randomUUID()}.tmp")
        try {
            FileOutputStream(temporary).use { it.write(bytes); it.fd.sync() }
            replaceFile(temporary, file)
        } finally { temporary.delete() }
    }

    private fun <T> withWriteLock(action: () -> T): T = processLock.withLock {
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Cannot create preset directory")
        RandomAccessFile(File(directory, ".presets.lock"), "rw").use { lockFile ->
            lockFile.channel.lock().use { action() }
        }
    }

    companion object { private val locks = ConcurrentHashMap<String, ReentrantLock>() }
}

private fun canonicalID(id: String): Boolean = runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)
private fun requirePreset(value: Boolean) {
    if (!value) throw AdjustmentPresetException(PresetFailure.CORRUPT_LIBRARY)
}
private fun requireKeys(json: JSONObject, required: Set<String>, optional: Set<String> = emptySet()) {
    val keys = json.keys().asSequence().toSet()
    requirePreset(keys.containsAll(required) && (required + optional).containsAll(keys))
}

private fun replacePresetFile(from: File, to: File) {
    // 不支持原子替换时报告失败，不降级为可能丢失旧文件的普通移动。
    Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
}
