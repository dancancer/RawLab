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
//  · 按相机分桶（镜像 matchesCamera：hardwareIdentity 在场按机身、缺席按连接），桶内按
//    时间倒序每格式首个含检查点（checkpoints，真实字段）的已导出记录是锚点；未迁移的
//    incremental.boundary 只保护自身、不猜测格式集（migrateLegacyBoundary 的格式来自
//    saved/unavailable 条目且需合法 captureDateMillis，原始 JSON 无从复核，宁多留不误删）；
//    桶内最近的增量任务保留（读取方当前会话仍会查询它的去重键）。listingOwner 每次
//    连接都是新 UUID，按 owner 保护是空转；
//  · 联机运行（camera-tether-runs/*.json）batches[].id 引用的记录保留：
//    CameraTetherQueue.load 恢复会话时会回读这些批文件，删了会静默丢批次；
//    目录读不出、运行文件或 batches 结构损坏 → 引用集未知，本轮一条不删（B4 fail-closed）；
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
        // committedIncrementalCheckpoints + matchesCamera 的镜像（B2）：按相机分桶——
        // hardwareIdentity 在场按机身匹配，缺席按 cameraId(连接)隔离；桶内按时间倒序，
        // 每个格式首个含检查点的已导出记录是该格式的锚点。未迁移的 incremental.boundary
        // 按 migrateLegacyBoundary 语义回落成全格式检查点；桶内最近的增量任务保留——
        // 读取方在当前会话仍会查询它的去重键。listingOwner 每连接新 UUID，不作保护依据。
        val checkpointAnchors = mutableSetOf<String>()
        val seenKinds = HashMap<String, MutableSet<String>>()
        val seenBuckets = mutableSetOf<String>()
        for (entry in sorted) {
            if (!isExported(entry.json)) continue
            val incremental = entry.json.optJSONObject("incremental") ?: continue
            val checkpoints = incremental.optJSONObject("checkpoints")
            val kinds = mutableListOf<String>()
            if (checkpoints != null) {
                for (kind in checkpoints.keys()) kinds.add(kind)
            }
            // 未迁移 boundary 只保护自身、不猜测其供给的格式集：migrateLegacyBoundary
            // 要求 saved/unavailable 条目且合法 captureDateMillis，清理侧读的是原始
            // JSON 无从复核，故不把双格式塞进 seen（宁多留不误删，B4 同向）。
            val hasLegacyBoundary = kinds.isEmpty() && incremental.optJSONObject("boundary") != null
            val bucket = cameraBucket(entry.json)
            val seen = seenKinds.getOrPut(bucket) { mutableSetOf() }
            if (seenBuckets.add(bucket) || hasLegacyBoundary || kinds.any { it !in seen }) checkpointAnchors.add(entry.id)
            seen += kinds
        }
        val pruned = entries.filter { entry ->
            isExported(entry.json) && entry.id != newestID && entry.id !in batchIDs &&
                entry.id !in checkpointAnchors
        }
        return Plan(pruned)
    }

    private fun cameraBucket(json: JSONObject): String {
        // 与 CameraImportJob.matchesCamera 同构：hardwareIdentity==null 按 connectionId，否则按机身。
        val hardware = json.optJSONObject("hardwareIdentity")
        return if (hardware != null) "hw:" + hardware.optString("model") + "|" + hardware.optString("serial")
        else "cam:" + json.optString("camera")
    }

    /** 联机运行引用的批次 id；null 表示引用集未知（目录读不出、运行文件或 batches 结构损坏）。 */
    private fun tetherBatchIDs(runsDirectory: File): Set<String>? {
        if (!runsDirectory.exists()) return emptySet()  // 无运行历史 = 已知空引用集
        val runs = runsDirectory.listFiles()?.filter { it.isFile && RUN_PATTERN.matches(it.name) }
            ?: return null                               // 目录不可读/是文件 = 引用未知，B4 fail-closed
        val ids = mutableSetOf<String>()
        for (run in runs) {
            if (run.length() > RUN_MAX_BYTES) return null
            val json = try { JSONObject(run.readText()) } catch (_: Exception) { return null }
            if (!json.has("batches")) continue
            val batches = json.optJSONArray("batches") ?: return null   // 半截结构：宁可不删
            for (index in 0 until batches.length()) {
                val id = batches.optJSONObject(index)?.optString("id")?.takeIf { it.isNotEmpty() } ?: return null
                ids.add(id)
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
