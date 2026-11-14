package com.rawlab.android.camera

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

// Q6：相机原件不自动删，只提供手动清理入口。Android 的私有目录只存导入任务记录，
// 清理删除「已导出」（COMPLETE 且 committed，字节已发布进相册）的记录。保护规则按
// 运行时真实读取方建模（B2 评审）：最新锚点、按格式的增量检查点（与
// committedIncrementalCheckpoints 同构）、联机运行引用的批文件；listingOwner 每次
// 连接都是新 UUID，不再作为保护依据。
class CameraOriginalsRetentionTest {
    private val now = 1_763_000_000_000L
    private val day = 24L * 60 * 60 * 1_000

    private fun job(dir: File, ageMillis: Long, status: String = "COMPLETE", committed: Boolean? = true,
                    listingOwner: String? = null, sessionOwner: String? = null,
                    checkpoints: Set<String> = emptySet()): File {
        val json = JSONObject().put("version", 2).put("camera", "c").put("time", now - ageMillis)
            .put("status", status).put("items", JSONArray()).put("directory", "Download").put("grouping", "DAY")
        if (committed != null) json.put("committed", committed)
        if (listingOwner != null) json.put("listingOwner", listingOwner)
        if (sessionOwner != null || checkpoints.isNotEmpty()) {
            // 真实 CameraIncrementalPlan.json() 字段名是 sessionOwner；检查点在 checkpoints 对象里。
            val plan = JSONObject()
            if (sessionOwner != null) plan.put("sessionOwner", sessionOwner)
            if (checkpoints.isNotEmpty()) {
                val anchors = JSONObject()
                for (kind in checkpoints) anchors.put(kind, JSONObject().put("date", now - ageMillis))
                plan.put("checkpoints", anchors)
            }
            json.put("incremental", plan)
        }
        return File(dir, "${UUID.randomUUID()}.json").apply { writeText(json.toString()) }
    }

    private fun runDirWith(batchIDs: List<String>): File {
        val runs = Files.createTempDirectory("rawlab-originals-runs").toFile()
        if (batchIDs.isNotEmpty()) {
            val batches = JSONArray()
            for (id in batchIDs) batches.put(JSONObject().put("id", id).put("photos", JSONArray()))
            File(runs, "${UUID.randomUUID()}.json").writeText(JSONObject()
                .put("version", 1).put("time", now - day).put("status", "ENDED").put("batches", batches).toString())
        }
        return runs
    }

    @Test fun inspectCountsJournalFilesByPatternWithoutParsing() {
        val dir = Files.createTempDirectory("rawlab-originals-inspect").toFile()
        try {
            val first = job(dir, day); val second = job(dir, 2 * day)
            File(dir, "notes.json").writeText("[]")  // 非 UUID 记录名不计入
            File(dir, "sub").mkdirs()                // 目录不计入
            val summary = CameraOriginalsRetention.inspect(dir)
            assertEquals(2, summary.fileCount)
            assertEquals(first.length() + second.length(), summary.totalBytes)
            job(dir, 3 * day)
            assertEquals(3, CameraOriginalsRetention.inspect(dir).fileCount)
        } finally { dir.deleteRecursively() }
    }

    @Test fun pruneRemovesExportedJobsButKeepsAnchorsAndUnexportedJobs() {
        val dir = Files.createTempDirectory("rawlab-originals-prune").toFile()
        val runs = runDirWith(emptyList())
        try {
            val exportedOld = job(dir, 10 * day)
            val paused = job(dir, 5 * day, status = "ACTIVE")
            val notCommitted = job(dir, 4 * day, committed = false)
            val newest = job(dir, day)
            val freed = exportedOld.length()
            val pruned = CameraOriginalsRetention.pruneExported(dir, runs)
            assertEquals(1, pruned.fileCount)
            assertEquals(freed, pruned.totalBytes)
            assertFalse(exportedOld.exists())
            assertTrue(paused.exists() && notCommitted.exists() && newest.exists())
            assertEquals(0, CameraOriginalsRetention.pruneExported(dir, runs).fileCount)  // 幂等
        } finally { dir.deleteRecursively(); runs.deleteRecursively() }
    }

    @Test fun perConnectionListingOwnersDoNotIdleSpinThePrune() {
        // B2.1：生产里 listingOwner 每次连接都是新 UUID。按 owner 保留最新会导致
        // 每次清理释放 0（空转）；按格式建模后跨会话的已导出记录能真正清掉。
        val dir = Files.createTempDirectory("rawlab-originals-owners").toFile()
        val runs = runDirWith(emptyList())
        try {
            val old1 = job(dir, 30 * day, listingOwner = UUID.randomUUID().toString())
            val old2 = job(dir, 20 * day, listingOwner = UUID.randomUUID().toString())
            val newest = job(dir, day, listingOwner = UUID.randomUUID().toString())
            val pruned = CameraOriginalsRetention.pruneExported(dir, runs)
            assertEquals(2, pruned.fileCount)
            assertFalse(old1.exists()); assertFalse(old2.exists())
            assertTrue(newest.exists())
        } finally { dir.deleteRecursively(); runs.deleteRecursively() }
    }

    @Test fun manualJobDoesNotStealProtectionFromTheCheckpointAnchor() {
        // B2.1 同会话场景：增量任务（RAW 检查点）之后又手动导入一条 COMPLETE+committed。
        // 手动记录可以被清，但增量检查点锚点必须因 checkpoints 而保留，不能靠 owner 猜测。
        val dir = Files.createTempDirectory("rawlab-originals-steal").toFile()
        val runs = runDirWith(emptyList())
        try {
            val owner = UUID.randomUUID().toString()
            val anchor = job(dir, 10 * day, listingOwner = owner, sessionOwner = owner, checkpoints = setOf("RAW"))
            val manual = job(dir, 2 * day, listingOwner = owner)
            val newest = job(dir, day)
            val pruned = CameraOriginalsRetention.pruneExported(dir, runs)
            assertEquals(1, pruned.fileCount)
            assertFalse(manual.exists())
            assertTrue(anchor.exists() && newest.exists())
        } finally { dir.deleteRecursively(); runs.deleteRecursively() }
    }

    @Test fun checkpointAnchorsAreKeptPerFormatUntilCoveredByANewerJob() {
        val dir = Files.createTempDirectory("rawlab-originals-formats").toFile()
        val runs = runDirWith(emptyList())
        try {
            val raw = job(dir, 30 * day, sessionOwner = UUID.randomUUID().toString(), checkpoints = setOf("RAW"))
            val jpeg = job(dir, 20 * day, sessionOwner = UUID.randomUUID().toString(), checkpoints = setOf("JPEG"))
            val newest = job(dir, day)
            assertEquals(0, CameraOriginalsRetention.pruneExported(dir, runs).fileCount)
            // 新 RAW 增量覆盖检查点后，旧 RAW 锚点解锁；JPEG 锚点没有后继，继续保留。
            val cover = job(dir, 2 * day, sessionOwner = UUID.randomUUID().toString(), checkpoints = setOf("RAW"))
            val pruned = CameraOriginalsRetention.pruneExported(dir, runs)
            assertEquals(1, pruned.fileCount)
            assertFalse(raw.exists())
            assertTrue(jpeg.exists() && cover.exists() && newest.exists())
        } finally { dir.deleteRecursively(); runs.deleteRecursively() }
    }

    @Test fun tetherBatchReferencesProtectJobRecordsUntilTheRunFileGoes() {
        // B2.3：CameraTetherQueue.load 恢复会话时按 batches[].id 回读批文件。
        val dir = Files.createTempDirectory("rawlab-originals-tether").toFile()
        val exportedOld = java.util.UUID.randomUUID()
        File(dir, "$exportedOld.json").writeText(JSONObject().put("version", 2).put("camera", "c")
            .put("time", now - 40 * day).put("status", "COMPLETE").put("committed", true)
            .put("items", JSONArray()).toString())
        val runs = runDirWith(listOf(exportedOld.toString()))
        try {
            job(dir, day)
            assertEquals(0, CameraOriginalsRetention.pruneExported(dir, runs).fileCount)
            assertTrue(File(dir, "$exportedOld.json").exists())
            runs.listFiles()!!.first().delete()  // 运行记录已过 90 天窗口被回收
            assertEquals(1, CameraOriginalsRetention.pruneExported(dir, runs).fileCount)
            assertFalse(File(dir, "$exportedOld.json").exists())
        } finally { dir.deleteRecursively(); runs.deleteRecursively() }
    }

    @Test fun unparseableRunFileMakesThePruneConservativelySkip() {
        // 引用集未知（半截运行文件）时宁漏删：一个都不删。
        val dir = Files.createTempDirectory("rawlab-originals-brokenrun").toFile()
        val runs = Files.createTempDirectory("rawlab-originals-brokenrun-runs").toFile()
        try {
            job(dir, 30 * day)
            job(dir, day)
            File(runs, "${UUID.randomUUID()}.json").writeText("{ half written")
            assertEquals(0, CameraOriginalsRetention.pruneExported(dir, runs).fileCount)
            assertEquals(0, CameraOriginalsRetention.pendingExported(dir, runs).fileCount)
        } finally { dir.deleteRecursively(); runs.deleteRecursively() }
    }

    @Test fun legacyRecordsWithoutCommittedFieldCountAsExported() {
        // 与 CameraImportStore 解析一致：旧 COMPLETE 记录缺 committed 字段视为已发布。
        val dir = Files.createTempDirectory("rawlab-originals-legacy").toFile()
        val runs = runDirWith(emptyList())
        try {
            val legacy = job(dir, 30 * day, committed = null)
            job(dir, day)
            assertEquals(1, CameraOriginalsRetention.pruneExported(dir, runs).fileCount)
            assertFalse(legacy.exists())
        } finally { dir.deleteRecursively(); runs.deleteRecursively() }
    }

    @Test fun pendingExportedCountsTheDeletableSetWithoutDeleting() {
        // Should 5：确认框按「将要删除」条目计数，预演与实际清理口径一致。
        val dir = Files.createTempDirectory("rawlab-originals-pending").toFile()
        val runs = runDirWith(emptyList())
        try {
            val exportedOld = job(dir, 10 * day)
            job(dir, day)
            val pending = CameraOriginalsRetention.pendingExported(dir, runs)
            assertEquals(1, pending.fileCount)
            assertEquals(exportedOld.length(), pending.totalBytes)
            assertTrue(exportedOld.exists())
            assertEquals(1, CameraOriginalsRetention.pruneExported(dir, runs).fileCount)
            assertFalse(exportedOld.exists())
        } finally { dir.deleteRecursively(); runs.deleteRecursively() }
    }

    @Test fun unreadableRecordsAreNeitherCountedForPruningNorDeleted() {
        val dir = Files.createTempDirectory("rawlab-originals-broken").toFile()
        val runs = runDirWith(emptyList())
        try {
            val corrupt = File(dir, "${UUID.randomUUID()}.json").apply { writeText("{ half written") }
            val exportedOld = job(dir, 30 * day)
            job(dir, day)
            assertEquals(1, CameraOriginalsRetention.pruneExported(dir, runs).fileCount)
            assertTrue(corrupt.exists())
            assertFalse(exportedOld.exists())
        } finally { dir.deleteRecursively(); runs.deleteRecursively() }
    }
}
