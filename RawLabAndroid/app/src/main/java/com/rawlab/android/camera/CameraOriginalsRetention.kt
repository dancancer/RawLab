package com.rawlab.android.camera

import java.io.File
import java.io.IOException
import org.json.JSONObject

// ============================================================================
//  相机原件手动清理（Q6：相机原件不自动删、只提供手动清理入口）
//  Android 的相机原件字节发布进系统相册（MediaStore），应用私有目录
//  `camera-media-imports` 只保留每个导入任务的记录（<id>.json）。手动清理删除
//  「已导出」（COMPLETE 且 committed，相册字节已发布）任务的记录；照片不受影响。
//  保护规则与运行时读取方逐字对齐，保证宁漏删不误删：
//  · 最新的任务记录始终保留（历史与重复导入检测的锚点）；
//  · 每个增量格式保留最近一条含该格式检查点的已导出记录，与
//    committedIncrementalCheckpoints「按时间倒序、每格式取首个」的取值顺序一致
//    （listingOwner 每次连接都是新 UUID，按 owner 保护在生产是空转，必须按格式）；
//  · 联机运行（camera-tether-runs/*.json）batches[].id 引用的记录保留：
//    CameraTetherQueue.load 恢复会话时会回读这些批文件，删了会静默丢批次；
//    任一运行文件解析失败时不清理（引用集未知，宁漏删）；
//  · 未导出（非 COMPLETE 或未 committed）的任务记录一律保留供断点续传。
//  读不出的任务文件不计入、不删除，交给 CameraImportStore.load 的隔离逻辑；
//  目录整体不可读视为失败抛出，让 UI 能区分「没得清」与「清不了」。
// ============================================================================

// 数据类被 public 的 EditorScreen 引用，故公开；回收逻辑仍只在 internal object 内。
data class CameraOriginalsSummary(val fileCount: Int, val totalBytes: Long)

internal object CameraOriginalsRetention {
    private const val UUID_HEX = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private val JOB_PATTERN = Regex("^$UUID_HEX\\.json$")
    private val RUN_PATTERN = Regex("^$UUID_HEX\\.json$")
    // 与 CameraTetherJournal 的写入预算一致；异常大的运行文件按解析失败处理。
    private const val RUN_MAX_BYTES = 8L * 1024 * 1024

    /** 列目录：目录内直属任务记录文件的数量与占用字节，供设置页显示。 */
    fun inspect(directory: File): CameraOriginalsSummary {
        val files = listing(directory).filter { it.isFile && JOB_PATTERN.matches(it.name) }
        return CameraOriginalsSummary(files.size, files.sumOf { it.length() })
    }

    /** 预演手动清理：与 pruneExported 相同的保护规则，只统计将删除的数量与字节。 */
    fun pendingExported(directory: File, tetherRunsDirectory: File): CameraOriginalsSummary {
        val plan = plan(directory, tetherRunsDirectory)
        return CameraOriginalsSummary(plan.pruned.size, plan.pruned.sumOf { it.freedBytes })
    }

    /** 手动清理：删除已导出任务的记录，返回被删条目的数量与释放字节。 */
    fun pruneExported(directory: File, tetherRunsDirectory: File): CameraOriginalsSummary {
        val plan = plan(directory, tetherRunsDirectory)
        val freed = plan.pruned.filter { it.file.delete() }
        return CameraOriginalsSummary(freed.size, freed.sumOf { it.freedBytes })
    }

    private class Entry(val file: File, val json: JSONObject, val id: String, val time: Long, val freedBytes: Long)

    private class Plan(val pruned: List<Entry>)

    private fun plan(directory: File, tetherRunsDirectory: File): Plan {
        val entries = listing(directory).mapNotNull { file ->
            if (!file.isFile || !JOB_PATTERN.matches(file.name)) return@mapNotNull null
            val json = try { JSONObject(file.readText()) } catch (_: Exception) { return@mapNotNull null }
            Entry(file, json, file.nameWithoutExtension, json.optLong("time", file.lastModified()), file.length())
        }
        if (entries.isEmpty()) return Plan(emptyList())
        val batchIDs = tetherBatchIDs(tetherRunsDirectory) ?: return Plan(emptyList())
        // 时间相同按文件名倒序，保证「最新一条」与格式检查点锚点的选取可复现。
        val sorted = entries.sortedWith(compareByDescending<Entry> { it.time }.thenByDescending { it.id })
        val newestID = sorted.first().id
        // committedIncrementalCheckpoints 的镜像：按时间倒序，每个格式首个含检查点的已导出记录是该格式的锚点。
        val checkpointAnchors = mutableSetOf<String>()
        val seenKinds = mutableSetOf<String>()
        for (entry in sorted) {
            if (!isExported(entry.json)) continue
            val checkpoints = entry.json.optJSONObject("incremental")?.optJSONObject("checkpoints") ?: continue
            for (kind in checkpoints.keys()) if (seenKinds.add(kind)) checkpointAnchors.add(entry.id)
        }
        val pruned = entries.filter { entry ->
            isExported(entry.json) && entry.id != newestID && entry.id !in batchIDs &&
                entry.id !in checkpointAnchors
        }
        return Plan(pruned)
    }

    /** 联机运行引用的批次 id；null 表示存在解析不了的运行文件（引用集未知）。 */
    private fun tetherBatchIDs(runsDirectory: File): Set<String>? {
        val runs = runsDirectory.listFiles().orEmpty().filter { it.isFile && RUN_PATTERN.matches(it.name) }
        val ids = mutableSetOf<String>()
        for (run in runs) {
            if (run.length() > RUN_MAX_BYTES) return null
            val json = try { JSONObject(run.readText()) } catch (_: Exception) { return null }
            val batches = json.optJSONArray("batches") ?: continue
            for (index in 0 until batches.length()) {
                batches.optJSONObject(index)?.optString("id")?.takeIf { it.isNotEmpty() }?.let(ids::add)
            }
        }
        return ids
    }

    private fun listing(directory: File): List<File> =
        directory.listFiles()?.toList() ?: throw IOException("Cannot read ${directory.name}")

    private fun isExported(json: JSONObject): Boolean {
        val complete = json.optString("status") == "COMPLETE"
        // 与 CameraImportStore 解析一致：旧记录缺 committed 字段时 COMPLETE 即已发布。
        return complete && json.optBoolean("committed", true)
    }
}
