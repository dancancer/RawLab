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

// 读不懂的条目：只隔离自己，身份尽力保留，原文逐字节留到可以删除为止（P2-16）。
data class UnreadablePreset(val id: String?, val name: String?, val raw: String)

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
    private data class Registry(val presets: List<AdjustmentPreset> = emptyList(), val retiredIDs: List<String> = emptyList(),
        val unreadable: List<UnreadablePreset> = emptyList())
    private val file = File(directory, "presets.json")
    private val processLock = locks.getOrPut(directory.canonicalPath) { ReentrantLock() }

    fun list(): List<AdjustmentPreset> = read().presets
    fun listUnreadable(): List<UnreadablePreset> = read().unreadable

    fun create(name: String, payload: AdjustmentPayload): AdjustmentPreset {
        val normalized = validatedName(name)
        payload.validate()
        return withWriteLock {
            val current = read()
            requireAvailableName(normalized, current)
            val id = (0 until 8).asSequence().map { makeID() }.firstOrNull { candidate ->
                canonicalID(candidate) && candidate !in current.retiredIDs &&
                    current.presets.none { it.id == candidate } && current.unreadable.none { it.id == candidate }
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
        // 坏条目仍占用的 ID 不登记 retired：retired ∩ 条目 ID 会让整库下次读取失效。
        val retire = if (current.unreadable.any { it.id == expected.id }) current.retiredIDs else current.retiredIDs + expected.id
        write(current.copy(presets = current.presets.filterIndexed { position, _ -> position != index }, retiredIDs = retire))
    }

    // 删除读不懂的条目：按 ID + 原文精确匹配，防止误删同名或同 ID 的另一条。
    fun delete(expected: UnreadablePreset) = withWriteLock {
        val current = read()
        val index = current.unreadable.indexOfFirst { it.id == expected.id && it.raw == expected.raw }
        if (index < 0) throw AdjustmentPresetException(PresetFailure.CHANGED)
        val removed = current.unreadable[index]
        val remaining = current.unreadable.filterIndexed { position, _ -> position != index }
        val stillUsed = current.presets.any { it.id == removed.id } || remaining.any { it.id == removed.id }
        val retire = if (removed.id != null && canonicalID(removed.id) && !stillUsed) current.retiredIDs + removed.id else current.retiredIDs
        write(current.copy(unreadable = remaining, retiredIDs = retire))
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
        // 坏条目的名字保留：宁可提示重名，也不悄悄造出两条同名预设。
        if (registry.unreadable.any { it.name == name }) throw AdjustmentPresetException(PresetFailure.DUPLICATE_NAME)
    }

    private fun read(): Registry {
        if (!file.exists()) return Registry()
        val text = file.readText(Charsets.UTF_8)
        val scanned = try { scanPresetJSON(text) }
            catch (_: PresetScanException) { throw AdjustmentPresetException(PresetFailure.CORRUPT_LIBRARY) }
        // 文件级失败（语法、根结构、版本、retired_ids、有效条目身份冲突）仍让整库不可用。
        val root = scanned as? JSONScan.Obj ?: throw AdjustmentPresetException(PresetFailure.CORRUPT_LIBRARY)
        val keys = root.members.map { it.first }.toSet()
        if (root.ownDuplicate || !keys.containsAll(setOf("registry_version", "presets")) ||
            !setOf("registry_version", "presets", "retired_ids").containsAll(keys)) {
            throw AdjustmentPresetException(PresetFailure.CORRUPT_LIBRARY)
        }
        val version = root.members.first { it.first == "registry_version" }.second as? JSONScan.Num
            ?: throw AdjustmentPresetException(PresetFailure.CORRUPT_LIBRARY)
        if (!isIntegerLiteral(version.literal)) throw AdjustmentPresetException(PresetFailure.CORRUPT_LIBRARY)
        val versionValue = version.literal.toLongOrNull() ?: throw AdjustmentPresetException(PresetFailure.CORRUPT_LIBRARY)
        if (versionValue != 1L) throw AdjustmentPresetException(PresetFailure.UNSUPPORTED_VERSION)
        val elements = (root.members.first { it.first == "presets" }.second as? JSONScan.Arr
            ?: throw AdjustmentPresetException(PresetFailure.CORRUPT_LIBRARY)).items
        val presets = mutableListOf<AdjustmentPreset>()
        val unreadable = mutableListOf<UnreadablePreset>()
        for (element in elements) {
            val raw = text.substring(element.start, element.end)
            val entry = decodeEntry(element, raw)
            if (entry == null) unreadable += UnreadablePreset(directString(element, "id"), directString(element, "name"), raw)
            else presets += entry
        }
        val retired = (root.members.firstOrNull { it.first == "retired_ids" }?.second as? JSONScan.Arr)?.items ?: emptyList()
        val retiredIDs = retired.map { id ->
            requirePreset(id is JSONScan.Str && canonicalID(id.value)); (id as JSONScan.Str).value
        }
        requirePreset(presets.map { it.id }.toSet().size == presets.size && presets.map { it.name }.toSet().size == presets.size &&
            retiredIDs.toSet().size == retiredIDs.size && presets.none { it.id in retiredIDs })
        return Registry(presets, retiredIDs, unreadable)
    }

    // 单条目损坏只降级这一条：任何解析失败都返回 null，由调用方保留原文。
    private fun decodeEntry(element: JSONScan, raw: String): AdjustmentPreset? {
        if (element !is JSONScan.Obj || element.subtreeDuplicate || !timestampsAreIntegers(element)) return null
        return try {
            val item = JSONObject(raw)
            requireKeys(item, setOf("id", "name", "created_at", "updated_at", "payload"))
            val id = item.get("id")
            val name = item.get("name")
            requirePreset(id is String && name is String)
            AdjustmentPreset(id as String, name as String, item.getLong("created_at"), item.getLong("updated_at"),
                AdjustmentPayload.decode(item.getJSONObject("payload").toString())).also { it.validate() }
        } catch (_: Exception) { null }
    }

    private fun write(registry: Registry) {
        // 有效条目按现行格式编码；坏条目以原文拼接在末尾，键序与空白逐字节保留。
        val pieces = registry.presets.map { preset ->
            preset.validate()
            JSONObject().put("id", preset.id).put("name", preset.name).put("created_at", preset.createdAt)
                .put("updated_at", preset.updatedAt).put("payload", JSONObject(preset.payload.encode())).toString()
        } + registry.unreadable.map { it.raw }
        val retired = JSONArray(registry.retiredIDs).toString().removeSurrounding("[", "]")
        val bytes = ("{\"registry_version\":1,\"presets\":[" + pieces.joinToString(",") +
            "],\"retired_ids\":[" + retired + "]}").toByteArray(Charsets.UTF_8)
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
