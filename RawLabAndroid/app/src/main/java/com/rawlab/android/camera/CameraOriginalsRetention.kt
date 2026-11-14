package com.rawlab.android.camera

import java.io.File
import org.json.JSONObject

// ============================================================================
//  相机原件手动清理（Q6：相机原件不自动删、只提供手动清理入口）
//  Android 的相机原件字节发布进系统相册（MediaStore），应用私有目录
//  `camera-media-imports` 只保留每个导入任务的记录（<id>.json）。手动清理删除
//  「已导出」（COMPLETE 且 committed）任务的记录；相册中的照片不受影响。
//  保护规则（测试证明不会删掉在用的记录）：
//  · 最新的任务记录始终保留（历史与重复导入检测的锚点）；
//  · 每个增量导入 owner（listingOwner 或 incremental.owner）最新一条 COMPLETE 记录保留，
//    它们提供 savedIncrementalKeys 去重键与检查点边界；
//  · 未导出（非 COMPLETE 或未 committed）的任务记录一律保留供断点续传。
//  读不出的记录文件不计入、不删除，交给 CameraImportStore.load 的隔离逻辑。
// ============================================================================

internal data class CameraOriginalsSummary(val fileCount: Int, val totalBytes: Long)

internal object CameraOriginalsRetention {
    private val UUID_HEX = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private val JOB_PATTERN = Regex("^$UUID_HEX\\.json$")

    /** 列目录：目录内直属任务记录文件的数量与占用字节，供设置页显示。 */
    fun inspect(directory: File): CameraOriginalsSummary {
        val files = directory.listFiles().orEmpty().filter { it.isFile && JOB_PATTERN.matches(it.name) }
        return CameraOriginalsSummary(files.size, files.sumOf { it.length() })
    }

    /** 手动清理：删除已导出任务的记录，返回被删条目的数量与释放字节。 */
    @Synchronized
    fun pruneExported(directory: File): CameraOriginalsSummary {
        data class Entry(val file: File, val json: JSONObject, val id: String, val time: Long, val freedBytes: Long)
        val entries = directory.listFiles().orEmpty().mapNotNull { file ->
            if (!file.isFile || !JOB_PATTERN.matches(file.name)) return@mapNotNull null
            val json = try { JSONObject(file.readText()) } catch (_: Exception) { return@mapNotNull null }
            Entry(file, json, file.nameWithoutExtension, json.optLong("time", file.lastModified()), file.length())
        }
        if (entries.isEmpty()) return CameraOriginalsSummary(0, 0)
        val newestID = entries.maxByOrNull { it.time }!!.id
        val newestOwnerComplete = mutableMapOf<String, Pair<String, Long>>()
        for (entry in entries) {
            if (!isExported(entry.json)) continue
            val owner = ownerSignature(entry.json) ?: continue
            val best = newestOwnerComplete[owner]
            if (best == null || entry.time >= best.second) newestOwnerComplete[owner] = entry.id to entry.time
        }
        val pruned = entries.filter { entry ->
            isExported(entry.json) && entry.id != newestID &&
                (ownerSignature(entry.json)?.let { newestOwnerComplete[it]?.first != entry.id } ?: true)
        }
        val freed = pruned.filter { it.file.delete() }
        return CameraOriginalsSummary(freed.size, freed.sumOf { it.freedBytes })
    }

    private fun isExported(json: JSONObject): Boolean =
        json.optString("status") == "COMPLETE" && json.optBoolean("committed")

    private fun ownerSignature(json: JSONObject): String? {
        val listingOwner = if (json.isNull("listingOwner")) null else json.optString("listingOwner")
        listingOwner?.takeIf { it.isNotEmpty() }?.let { return it }
        return json.optJSONObject("incremental")?.optString("owner")?.takeIf { it.isNotEmpty() }
    }
}
