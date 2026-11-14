package com.rawlab.android.photo

import java.io.File
import org.json.JSONObject

// ============================================================================
//  Q6 保留策略：常量集中定义
//  裁定（docs/architecture/remediation-plan-2026-11-13/g-product-decisions.md）：
//  「批量产物保留 30 天 / 100 条；相机原件不自动删、只提供手动清理入口；联机记录保留 90 天」
//  回收只在进程入口执行（RawLabApplication.onCreate，与 WorkingCopyCleanup 同一时机）：
//  此刻界面、批量任务与联机会话尚未启动，不引入后台任务框架也不会与写入方竞争。
//  相机原件因此没有自动回收函数，只有手动清理入口（CameraOriginalsRetention）。
// ============================================================================

internal object RetentionPolicy {
    /** 批量产物保留天数（双条件之一，超过即清退）。 */
    const val BATCH_ARTIFACT_MAX_AGE_MILLIS = 30L * 24 * 60 * 60 * 1000

    /** 批量产物保留条数（双条件之一，按时间排序超出最近 100 条的最旧条目先清）。 */
    const val BATCH_ARTIFACT_MAX_COUNT = 100

    /** 联机记录保留天数；相机原件不自动删（Q6），没有对应的自动回收常量。 */
    const val TETHER_RECORD_MAX_AGE_MILLIS = 90L * 24 * 60 * 60 * 1000

    private val UUID_HEX = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private val SNAPSHOT_PATTERN = Regex("^$UUID_HEX\\.properties$")
    private val RUN_PATTERN = Regex("^$UUID_HEX\\.json$")
    // 与 CameraTetherJournal 的写入预算一致；更大的文件异常，进程入口不解析（宁漏删）。
    private const val RUN_MAX_BYTES = 8L * 1024 * 1024
    private const val DAY_MILLIS = 24L * 60 * 60 * 1000

    /**
     * 批量产物 = 批量任务落在 journal 根目录的整套条目（快照 `.properties`、行日志 `.rows`
     * 与输入目录 `<id>/`）。双条件先到先清：距快照最后写入超过 30 天，或按写入时间排序
     * 已超出最近 100 条。同毫秒时按 id 倒序，保证边界条目的选取可复现。
     * 返回被清退条目的 id 列表。
     */
    @Synchronized
    fun reclaimBatchArtifacts(journalRoot: File, nowMillis: Long = System.currentTimeMillis(),
        maxAgeMillis: Long = BATCH_ARTIFACT_MAX_AGE_MILLIS, maxCount: Int = BATCH_ARTIFACT_MAX_COUNT): List<String> {
        val ordered = journalRoot.listFiles()?.filter { it.isFile && SNAPSHOT_PATTERN.matches(it.name) }
            .orEmpty().sortedWith(compareByDescending<File> { it.lastModified() }.thenByDescending { it.name })
        val reclaimed = mutableListOf<String>()
        ordered.forEachIndexed { index, snapshot ->
            if (nowMillis - snapshot.lastModified() <= maxAgeMillis && index < maxCount) return@forEachIndexed
            val id = snapshot.nameWithoutExtension
            snapshot.delete()
            File(journalRoot, "$id.rows").delete()
            File(journalRoot, id).deleteRecursively()
            reclaimed += id
        }
        return reclaimed
    }

    /**
     * 联机记录 = `camera-tether-runs` 里的运行日志。超过 90 天（按登记时间 `time` 字段，
     * 缺失时退回文件修改时间）的清退；状态 ACTIVE 的进行中运行不删（A2 验收）。
     * 读不出的半截文件原样保留，交给 [com.rawlab.android.camera.CameraTetherJournal] 的加载隔离。
     * 进程入口在主线程执行（Should 4 评估：正常运行文件数量少且已在 90 天窗口内清退，
     * 全量解析为亚秒级；仍先做名字/时间/体积三重预筛，只有老文件才解析）：
     * 文件名不是 UUID 或 mtime 距今不超过 maxAge 的一律跳过——刚写过的运行（例如超过
     * 90 天才 ENDED 的长会话）宁漏删不误删；超过写入预算的异常文件不解析、保留。
     * 返回被清退的记录数。
     */
    @Synchronized
    fun reclaimTetherRecords(runsDirectory: File, nowMillis: Long = System.currentTimeMillis(),
        maxAgeMillis: Long = TETHER_RECORD_MAX_AGE_MILLIS): Int {
        var reclaimed = 0
        for (file in runsDirectory.listFiles().orEmpty()) {
            if (!file.isFile || !RUN_PATTERN.matches(file.name)) continue
            if (nowMillis - file.lastModified() <= maxAgeMillis) continue
            if (file.length() > RUN_MAX_BYTES) continue
            val created: Long
            val active: Boolean
            try {
                val json = JSONObject(file.readText())
                created = json.optLong("time", -1L).takeIf { it > 0 } ?: file.lastModified()
                active = json.optString("status") == "ACTIVE"
            } catch (_: Exception) {
                continue
            }
            if (!active && nowMillis - created > maxAgeMillis && file.delete()) reclaimed += 1
        }
        return reclaimed
    }

    /** 测试与文案共用的天数换算。 */
    internal fun days(days: Long): Long = days * DAY_MILLIS
}
