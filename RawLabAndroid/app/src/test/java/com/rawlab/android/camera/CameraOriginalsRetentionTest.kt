package com.rawlab.android.camera

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

// Q6：相机原件不自动删，只提供手动清理入口。Android 的私有目录只存导入任务记录，
// 清理删除「已导出」（COMPLETE 且 committed）的记录并保护锚点记录（AGENTS：测试证明
// 不会删掉在用的记录）。
class CameraOriginalsRetentionTest {
    private val now = 1_763_000_000_000L
    private val day = 24L * 60 * 60 * 1_000

    private fun job(dir: File, ageMillis: Long, status: String = "COMPLETE", committed: Boolean = true,
                    owner: String? = null, listingOwner: String? = null): File {
        val json = JSONObject().put("version", 2).put("camera", "c").put("time", now - ageMillis)
            .put("status", status).put("items", JSONArray()).put("directory", "Download")
            .put("grouping", "DAY").put("committed", committed)
        if (listingOwner != null) json.put("listingOwner", listingOwner)
        if (owner != null) json.put("incremental", JSONObject().put("owner", owner))
        return File(dir, "${UUID.randomUUID()}.json").apply { writeText(json.toString()) }
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
        try {
            val exportedOld = job(dir, 10 * day)
            val paused = job(dir, 5 * day, status = "ACTIVE")
            val notCommitted = job(dir, 4 * day, committed = false)
            val newest = job(dir, day)
            val freed = exportedOld.length()
            val pruned = CameraOriginalsRetention.pruneExported(dir)
            assertEquals(1, pruned.fileCount)
            assertEquals(freed, pruned.totalBytes)
            assertFalse(exportedOld.exists())
            assertTrue(paused.exists() && notCommitted.exists() && newest.exists())
            assertEquals(0, CameraOriginalsRetention.pruneExported(dir).fileCount)  // 幂等
        } finally { dir.deleteRecursively() }
    }

    @Test fun newestCompleteRecordPerIncrementalOwnerIsAlwaysRetained() {
        val dir = Files.createTempDirectory("rawlab-originals-owner").toFile()
        try {
            val ownerA = UUID.randomUUID().toString(); val ownerB = UUID.randomUUID().toString()
            val anchor = job(dir, day)                                    // 最新任务（无 owner）
            val aOld = job(dir, 10 * day, owner = ownerA)
            val aNew = job(dir, 3 * day, owner = ownerA)
            val bOld = job(dir, 20 * day, owner = ownerB)
            val bOnly = job(dir, 8 * day, owner = ownerB)
            val pruned = CameraOriginalsRetention.pruneExported(dir)
            assertEquals(2, pruned.fileCount)
            assertFalse(aOld.exists()); assertFalse(bOld.exists())
            assertTrue(anchor.exists() && aNew.exists() && bOnly.exists())
        } finally { dir.deleteRecursively() }
    }

    @Test fun listingOwnerAnchorsTheSameWayAsIncrementalOwner() {
        val dir = Files.createTempDirectory("rawlab-originals-listing").toFile()
        try {
            val listing = UUID.randomUUID().toString()
            val old = job(dir, 12 * day, listingOwner = listing)
            val pending = job(dir, 2 * day, listingOwner = listing, committed = false)
            assertEquals(0, CameraOriginalsRetention.pruneExported(dir).fileCount)  // pending 未导出，old 仍是该 owner 最新 COMPLETE
            val exported = job(dir, 1_000L, listingOwner = listing)
            val pruned = CameraOriginalsRetention.pruneExported(dir)
            assertEquals(1, pruned.fileCount)  // exported 成为该 listing owner 最新 COMPLETE，old 可清
            assertFalse(old.exists())
            assertTrue(pending.exists() && exported.exists())
        } finally { dir.deleteRecursively() }
    }

    @Test fun unreadableRecordsAreNeitherCountedForPruningNorDeleted() {
        val dir = Files.createTempDirectory("rawlab-originals-broken").toFile()
        try {
            val corrupt = File(dir, "${UUID.randomUUID()}.json").apply { writeText("{ half written") }
            val exportedOld = job(dir, 30 * day)
            job(dir, day)
            assertEquals(1, CameraOriginalsRetention.pruneExported(dir).fileCount)
            assertTrue(corrupt.exists())
            assertFalse(exportedOld.exists())
        } finally { dir.deleteRecursively() }
    }
}
