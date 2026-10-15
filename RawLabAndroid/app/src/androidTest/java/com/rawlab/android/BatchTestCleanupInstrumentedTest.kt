package com.rawlab.android

import android.content.ContentValues
import android.provider.MediaStore
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.Properties

class BatchTestCleanupInstrumentedTest {
    @Test fun activePublisherKeepsItsOutputAndInputsUntilStopped() {
        for ((checkpointed, removed) in listOf(false to false, true to false, true to true)) {
            assertActivePublisher(checkpointed, removed)
        }
    }

    private fun assertActivePublisher(checkpointed: Boolean, alreadyRemoved: Boolean) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val cleanup = BatchTestCleanup(context)
        cleanup.recover()
        val id = UUID.randomUUID().toString()
        cleanup.begin(id)
        val root = File(context.filesDir, "RawLab/BatchJobs")
        val input = File(root, "$id/inputs/source.dng").apply { parentFile!!.mkdirs(); writeBytes(byteArrayOf(1)) }
        val resolver = context.contentResolver
        @Suppress("DEPRECATION")
        val images = MediaStore.setIncludePending(MediaStore.Images.Media.EXTERNAL_CONTENT_URI)
        val uri = requireNotNull(resolver.insert(images, ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, cleanup.targetName(id).substringBeforeLast('.') + ".png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RawLab")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }))
        if (checkpointed) {
            val target = BatchTarget(PhotoIdentity("publisher-probe"), input, input.name)
            val job = BatchJob(BatchSourceSnapshot(target.identity, input, EditSettings()), listOf(target), id = id)
            BatchJournal(root).save(job.withRows(job.rows.map { it.copy(status = BatchRowStatus.PUBLISHING, outputUri = uri.toString()) }))
        }
        var cancelled = false
        var closed = false
        try {
            resolver.openOutputStream(uri)!!.use { writer ->
                val liveOwner = assertThrows(IllegalStateException::class.java) { BatchTestCleanup(context).recover() }
                assertTrue(liveOwner.message.orEmpty().contains("still alive"))
                val abort = assertThrows(IllegalStateException::class.java) {
                    cleanup.finish(active = true, cancel = { cancelled = true }, close = { closed = true },
                        abort = { throw IllegalStateException("probe process boundary") })
                }
                assertEquals("probe process boundary", abort.message)
                assertTrue(cancelled)
                assertFalse("Cannot close/delete while publisher is active", closed)
                assertTrue(input.isFile)
                resolver.query(uri, arrayOf(MediaStore.Images.Media.IS_PENDING), null, null, null)!!.use {
                    assertTrue("Active output must not be deleted", it.moveToFirst())
                    assertEquals(1, it.getInt(0))
                }
                writer.write(byteArrayOf(7, 11, 19))
            }
        } finally {
            if (alreadyRemoved) resolver.delete(uri, null, null)
            cleanup.finish(active = false, cancel = {}, close = { closed = true })
        }
        try {
            assertTrue(closed)
            assertFalse(input.exists())
            resolver.query(images, arrayOf(MediaStore.Images.Media._ID),
                "${MediaStore.Images.Media._ID} = ?", arrayOf(uri.lastPathSegment), null)!!.use {
                assertFalse("Cleanup also finds outputs not yet checkpointed", it.moveToFirst())
            }
        } finally {
            val remains = resolver.query(images, arrayOf(MediaStore.Images.Media._ID),
                "${MediaStore.Images.Media._ID} = ?", arrayOf(uri.lastPathSegment), null)!!.use { it.moveToFirst() }
            if (remains) resolver.delete(uri, null, null)
        }
    }

    @Test fun recoversOnlyAfterPreviousOwnerProcessExited() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        BatchTestCleanup(context).recover()
        assertFalse(File(context.filesDir, "batch-gpu-test-cleanup.properties").exists())
    }

    @Test fun simulatedDeadOwnerCleansBothJobIdsAndOnlyNewRenderFiles() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val cleanup = BatchTestCleanup(context)
        cleanup.recover()
        val id = UUID.randomUUID().toString()
        val jobId = UUID.randomUUID().toString()
        val root = File(context.filesDir, "RawLab/BatchJobs")
        val preserved = File(context.filesDir, "render-preserved-$id.png").apply { writeBytes(byteArrayOf(1)) }
        val unrelated = File(root, "unrelated-$id/input").apply { parentFile!!.mkdirs(); writeBytes(byteArrayOf(2)) }
        try {
            cleanup.begin(id)
            cleanup.trackJob(jobId)
            val fixture = File(root, "$id/inputs/source.dng").apply { parentFile!!.mkdirs(); writeBytes(byteArrayOf(3)) }
            val frozen = File(root, "$jobId/inputs/source.dng").apply { parentFile!!.mkdirs(); fixture.copyTo(this) }
            BatchJournal(root).save(BatchJob(BatchSourceSnapshot(PhotoIdentity("fixture-probe"), fixture, EditSettings()), emptyList(), id = id))
            BatchJournal(root).save(BatchJob(BatchSourceSnapshot(PhotoIdentity("cleanup-probe"), frozen, EditSettings()), emptyList(), id = jobId))
            val checkpoint = File(root, "$jobId.1234.tmp").apply { writeBytes(byteArrayOf(5)) }
            val abandoned = File(context.filesDir, "render-abandoned-$id.png").apply { writeBytes(byteArrayOf(4)) }
            val manifest = File(context.filesDir, "batch-gpu-test-cleanup.properties")
            val properties = Properties().also { manifest.inputStream().use(it::load) }
            check(!File("/proc/2147483647").exists())
            properties.setProperty("pid", "2147483647")
            manifest.outputStream().use { properties.store(it, null) }
            cleanup.recover()
            assertFalse(fixture.exists())
            assertFalse(frozen.exists())
            assertNull(BatchJournal(root).load(jobId))
            assertFalse(checkpoint.exists())
            assertFalse(abandoned.exists())
            assertTrue(preserved.isFile)
            assertTrue(unrelated.isFile)
            assertFalse(manifest.exists())
        } finally {
            if (File(context.filesDir, "batch-gpu-test-cleanup.properties").exists()) {
                cleanup.finish(active = false, cancel = {}, close = {})
            }
            preserved.delete()
            unrelated.parentFile!!.deleteRecursively()
        }
    }
}
