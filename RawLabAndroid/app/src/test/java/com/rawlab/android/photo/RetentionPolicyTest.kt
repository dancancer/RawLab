package com.rawlab.android.photo

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

// Q6 保留策略的 JVM 回归：批量产物 30 天/100 条双条件先到先清；
// 联机记录 90 天且进行中（ACTIVE）不删（A2 验收）。
class RetentionPolicyTest {
    private val now = 1_763_000_000_000L
    private val day = RetentionPolicy.days(1)

    private fun batchEntry(root: File, ageMillis: Long): UUID {
        val id = UUID.randomUUID()
        File(root, "$id.properties").apply { writeText("snapshot"); setLastModified(now - ageMillis) }
        File(root, "$id.rows").apply { writeText("rows"); setLastModified(now - ageMillis) }
        File(root, id.toString()).apply { mkdirs(); resolve("inputs").mkdirs(); resolve("inputs/photo.raw").writeText("raw") }
        return id
    }

    @Test fun batchArtifactsReclaimAfterThirtyDaysAndKeepThirty() {
        val root = Files.createTempDirectory("rawlab-retention-age").toFile()
        try {
            val stale = batchEntry(root, RetentionPolicy.days(31))
            val boundary = batchEntry(root, RetentionPolicy.days(30))
            val fresh = batchEntry(root, day)
            val reclaimed = RetentionPolicy.reclaimBatchArtifacts(root, now)
            assertEquals(listOf(stale.toString()), reclaimed.map { it })
            assertFalse(File(root, "$stale.properties").exists())
            assertFalse(File(root, "$stale.rows").exists())
            assertFalse(File(root, stale.toString()).exists())
            assertTrue(File(root, "$boundary.properties").exists())
            assertTrue(File(root, "$fresh.rows").exists())
            assertTrue(File(root, fresh.toString()).resolve("inputs/photo.raw").exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun batchArtifactsReclaimOnlyTheOldestAtOneHundredAndOne() {
        val root = Files.createTempDirectory("rawlab-retention-count").toFile()
        try {
            val ids = (0..100).map { batchEntry(root, (it + 1).toLong() * 1_000L) }  // 最后一条最旧
            val reclaimed = RetentionPolicy.reclaimBatchArtifacts(root, now)
            assertEquals(listOf(ids.last().toString()), reclaimed)
            assertEquals(100, root.listFiles()!!.count { it.name.endsWith(".properties") })
            assertEquals(0, RetentionPolicy.reclaimBatchArtifacts(root, now).size)
        } finally { root.deleteRecursively() }
    }

    @Test fun exactlyOneHundredRecentBatchArtifactsAreNotTouched() {
        val root = Files.createTempDirectory("rawlab-retention-cap").toFile()
        try {
            repeat(100) { batchEntry(root, (it + 1).toLong() * 1_000L) }
            assertEquals(0, RetentionPolicy.reclaimBatchArtifacts(root, now).size)
        } finally { root.deleteRecursively() }
    }

    @Test fun bothConditionsSweepIndependentlyBelowTheCap() {
        val root = Files.createTempDirectory("rawlab-retention-mixed").toFile()
        try {
            val fresh = (0 until 95).map { batchEntry(root, (it + 1).toLong() * 1_000L) }
            val stale = (0 until 10).map { batchEntry(root, RetentionPolicy.days(35)) }
            val reclaimed = RetentionPolicy.reclaimBatchArtifacts(root, now)
            assertEquals(10, reclaimed.size)
            assertTrue(reclaimed.containsAll(stale.map { it.toString() }))
            assertEquals(95, root.listFiles()!!.count { it.name.endsWith(".properties") })
            assertTrue(fresh.all { File(root, "$it.properties").exists() })
        } finally { root.deleteRecursively() }
    }

    @Test fun unrelatedFilesInJournalRootAreNeverSwept() {
        val root = Files.createTempDirectory("rawlab-retention-strays").toFile()
        try {
            batchEntry(root, RetentionPolicy.days(40))
            val stray = File(root, "notes.txt").apply { writeText("x"); setLastModified(now - RetentionPolicy.days(400)) }
            val foreign = File(root, "${UUID.randomUUID()}.json").apply { writeText("{}"); setLastModified(now - RetentionPolicy.days(400)) }
            assertEquals(1, RetentionPolicy.reclaimBatchArtifacts(root, now).size)
            assertTrue(stray.exists() && foreign.exists())
        } finally { root.deleteRecursively() }
    }

    private fun tetherRun(root: File, createdAt: Long, status: String, body: String? = null): File =
        File(root, "${UUID.randomUUID()}.json").apply {
            writeText(body ?: JSONObject().put("version", 1).put("camera", "c").put("profile", "p")
                .put("time", createdAt).put("status", status).put("baseline", JSONArray()).put("batches", JSONArray()).toString())
            // 真实文件的 mtime ≈ 最后一次状态写入；测试与 createdAt 对齐以便通过主线程预筛。
            setLastModified(createdAt)
        }

    @Test fun tetherRecordsReclaimAfterNinetyDaysAndKeepNinety() {
        val root = Files.createTempDirectory("rawlab-tether-age").toFile()
        try {
            val stale = tetherRun(root, now - RetentionPolicy.days(91), "ENDED")
            val boundary = tetherRun(root, now - RetentionPolicy.days(90), "ENDED")
            assertEquals(1, RetentionPolicy.reclaimTetherRecords(root, now))
            assertFalse(stale.exists())
            assertTrue(boundary.exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun activeTetherRunsAreProtectedRegardlessOfAge() {
        val root = Files.createTempDirectory("rawlab-tether-active").toFile()
        try {
            val active = tetherRun(root, now - RetentionPolicy.days(400), "ACTIVE")
            val paused = tetherRun(root, now - RetentionPolicy.days(91), "PAUSED")
            val ended = tetherRun(root, now - RetentionPolicy.days(91), "ENDED")
            assertEquals(2, RetentionPolicy.reclaimTetherRecords(root, now))
            assertTrue(active.exists())
            assertFalse(paused.exists() || ended.exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun tetherRecordsFallBackToFileTimeAndKeepUnreadableFiles() {
        val root = Files.createTempDirectory("rawlab-tether-fallback").toFile()
        try {
            val noTime = File(root, "${UUID.randomUUID()}.json")
                .apply { writeText(JSONObject().put("status", "ENDED").toString()); setLastModified(now - RetentionPolicy.days(120)) }
            val broken = File(root, "${UUID.randomUUID()}.json").apply { writeText("{ half written"); setLastModified(now - RetentionPolicy.days(300)) }
            assertEquals(1, RetentionPolicy.reclaimTetherRecords(root, now))
            assertFalse(noTime.exists())
            assertTrue(broken.exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun recentlyRewrittenOldRunSurvivesMainThreadPrefilter() {
        val root = Files.createTempDirectory("rawlab-tether-prefilter").toFile()
        try {
            // Should 4：mtime 预筛在主线程跳过「刚写过」的文件——超过 90 天才 ENDED 的长会话
            // 宁可晚 90 天再清，也不在 onCreate 解析大 JSON、更不误删。
            val justEnded = tetherRun(root, now - RetentionPolicy.days(100), "ENDED")
            justEnded.setLastModified(now - day)
            assertEquals(0, RetentionPolicy.reclaimTetherRecords(root, now))
            assertTrue(justEnded.exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun nonUuidRunFilesAreNeverSwept() {
        val root = Files.createTempDirectory("rawlab-tether-strays").toFile()
        try {
            val stray = File(root, "manifest.json").apply {
                writeText(JSONObject().put("time", now - RetentionPolicy.days(120)).put("status", "ENDED").toString())
                setLastModified(now - RetentionPolicy.days(120))
            }
            assertEquals(0, RetentionPolicy.reclaimTetherRecords(root, now))
            assertTrue(stray.exists())
        } finally { root.deleteRecursively() }
    }
}
