package com.rawlab.android.batch.workflow

import android.content.ContentValues
import android.provider.MediaStore
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.Properties
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchJournal
import com.rawlab.android.batch.BatchRowStatus
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.looks.LookLibrary
import com.rawlab.android.looks.LookValidator
import com.rawlab.android.looks.ManagedLook
import com.rawlab.android.looks.NativeLookValidator
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.testing.syntheticRlook

class BatchTestCleanupInstrumentedTest {
    @androidx.test.filters.SdkSuppress(minSdkVersion = 33)
    @Test fun deadOwnerRestoresLocaleCapturedBeforeTheLanguageRule() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val manager = context.getSystemService(android.app.LocaleManager::class.java)
        val previous = manager.applicationLocales
        val configuration = android.content.res.Configuration(context.resources.configuration)
        val cleanup = BatchTestCleanup(context)
        try {
            AppStrings.setPreference(context, "de")
            cleanup.apply(object : org.junit.runners.model.Statement() {
                override fun evaluate() {
                    AppStrings.setPreference(context, "zh-Hans")
                    cleanup.begin(UUID.randomUUID().toString())
                    val manifest = File(context.filesDir, "batch-gpu-test-cleanup.properties")
                    val owned = Properties().also { manifest.inputStream().use(it::load) }
                    assertEquals("de", owned.getProperty("originalLocales"))
                    check(!File("/proc/2147483647").exists())
                    owned.setProperty("pid", "2147483647")
                    manifest.outputStream().use { owned.store(it, null) }
                    cleanup.recover()
                    assertEquals("de", manager.applicationLocales.toLanguageTags())
                    assertFalse(manifest.exists())
                }
            }, org.junit.runner.Description.createTestDescription(javaClass, "locale-owner")).evaluate()
        } finally {
            if (File(context.filesDir, "batch-gpu-test-cleanup.properties").exists()) cleanup.finish(false, {}, {})
            manager.applicationLocales = previous
            @Suppress("DEPRECATION")
            context.resources.updateConfiguration(configuration, context.resources.displayMetrics)
        }
    }

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
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val manifest = File(context.filesDir, "batch-gpu-test-cleanup.properties")
        val previewProbe = InstrumentationRegistry.getArguments().getString("batchPreviewRecoveryProbe") == "true"
        val lookProbe = InstrumentationRegistry.getArguments().getString("batchLookStageRecoveryProbe") == "true"
        val partialProbe = InstrumentationRegistry.getArguments().getString("batchPartialRecoveryProbe")?.takeUnless { it == "none" }.orEmpty()
        var interruptedLookId: String? = null
        val previous = if (previewProbe || lookProbe || partialProbe.isNotEmpty()) {
            assertTrue("Failed work must defer cleanup to this new process", manifest.isFile)
            Properties().also { manifest.inputStream().use(it::load) }.also { properties ->
                val pid = properties.getProperty("pid").toInt()
                assertNotEquals(android.os.Process.myPid(), pid)
                assertFalse("Old preview process must exit before cleanup", File("/proc/$pid").exists())
                val root = File(context.filesDir, "RawLab/BatchJobs")
                val fixture = properties.getProperty("fixture")
                val job = properties.getProperty("job")
                if (previewProbe) {
                    assertNotEquals(fixture, job)
                    for (id in listOf(fixture, job)) {
                        assertEquals("Inputs must survive until the owner is dead", 2,
                            File(root, "$id/inputs").listFiles().orEmpty().count { it.isFile && it.length() > 0 })
                    }
                    instrumentation.sendStatus(2, android.os.Bundle().apply {
                        putString("stream", "Batch preview recovery oldPid=$pid newPid=${android.os.Process.myPid()} inputsPreserved=true fixture=$fixture job=$job\n")
                    })
                }
                if (lookProbe) {
                    val looks = File(context.filesDir, "looks")
                    val marker = looks.listFiles().orEmpty().filter { it.name.startsWith(".import-") && it.extension == "pending" }.single()
                    val importId = marker.name.removePrefix(".import-").removeSuffix(".pending")
                    UUID.fromString(importId)
                    interruptedLookId = importId
                    assertTrue(File(looks, ".$importId.stage.rlook").isFile)
                    assertFalse(File(looks, "$importId.rlook").exists())
                    instrumentation.sendStatus(2, android.os.Bundle().apply { putString("stream", "Batch look recovery oldPid=$pid stagePreserved=true id=$importId\n") })
                }
                if (partialProbe.isNotEmpty()) {
                    assertEquals(fixture, job)
                    assertTrue(File(root, "$fixture/inputs/source.dng").isFile)
                    assertEquals(partialProbe == "afterCheckpoint", File(root, "$job.properties").isFile)
                    @Suppress("DEPRECATION")
                    val images = MediaStore.setIncludePending(MediaStore.Images.Media.EXTERNAL_CONTENT_URI)
                    context.contentResolver.query(images, arrayOf(MediaStore.Images.Media.IS_PENDING),
                        "${MediaStore.Images.Media.DISPLAY_NAME} = ? AND ${MediaStore.Images.Media.RELATIVE_PATH} = ?",
                        arrayOf("batch-gpu-$fixture.jpg", "Pictures/RawLab/"), null)!!.use { cursor ->
                        assertEquals(1, cursor.count)
                        assertTrue(cursor.moveToFirst())
                        assertEquals(1, cursor.getInt(0))
                    }
                    instrumentation.sendStatus(2, android.os.Bundle().apply { putString("stream", "Batch partial recovery window=$partialProbe oldPid=$pid pendingPreserved=true fixture=$fixture\n") })
                }
            }
        } else null
        BatchTestCleanup(context).recover()
        assertFalse(manifest.exists())
        previous?.let { properties ->
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                properties.getProperty("originalLocales")?.let { expected ->
                    assertEquals(expected, context.getSystemService(android.app.LocaleManager::class.java).applicationLocales.toLanguageTags())
                }
            }
            val root = File(context.filesDir, "RawLab/BatchJobs")
            for (id in listOf(properties.getProperty("fixture"), properties.getProperty("job"))) {
                assertFalse(File(root, id).exists())
                assertFalse(File(root, "$id.properties").exists())
            }
            interruptedLookId?.let { id ->
                val looks = File(context.filesDir, "looks")
                for (name in listOf(".import-$id.pending", ".$id.stage", ".$id.stage.rlook", "$id.rlook")) assertFalse(File(looks, name).exists())
                val remaining = LookLibrary(looks).list().map { it.id }.toSet()
                assertFalse(id in remaining)
                assertTrue(properties.getProperty("existingLookIds", "").split(',').filter { it.isNotEmpty() }.all { it in remaining })
            }
        }
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

    @Test fun repeatedCleanupRemovesOnlyItsUnregisteredLookAfterInterruptedRemoval() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.filesDir, "looks")
        val cleanup = BatchTestCleanup(context)
        cleanup.recover()
        val id = UUID.randomUUID().toString()
        cleanup.begin(id)
        cleanup.trackLookImport("batch-gpu-$id.rlook")
        val library = LookLibrary(root, LookValidator { staged ->
            cleanup.trackLookStage(staged)
            NativeLookValidator.validate(staged)
        })
        val created = library.importLook(syntheticRlook().inputStream(), "batch-gpu-$id.rlook")
        val unrelated = File(root, "${UUID.randomUUID()}.rlook").apply { writeBytes(syntheticRlook()) }
        try {
            val bytes = created.file(root).readBytes()
            library.remove(created.id)
            // 重建 registry 已提交、文件尚未删除时的磁盘状态。
            created.file(root).writeBytes(bytes)
            cleanup.finish(active = false, cancel = {}, close = {})
            assertFalse(created.file(root).exists())
            assertTrue(unrelated.isFile)
        } finally {
            if (File(context.filesDir, "batch-gpu-test-cleanup.properties").exists()) cleanup.finish(false, {}, {})
            created.file(root).delete()
            unrelated.delete()
        }
    }

    @Test fun lookCleanupPreservesPreexistingSameNamedImport() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val cleanup = BatchTestCleanup(context)
        cleanup.recover()
        val id = UUID.randomUUID().toString()
        val library = LookLibrary(File(context.filesDir, "looks"))
        val name = "batch-gpu-$id.rlook"
        val previous = library.importLook(syntheticRlook().inputStream(), name)
        var independent: ManagedLook? = null
        try {
            cleanup.begin(id)
            cleanup.trackLookImport(name)
            val created = LookLibrary(File(context.filesDir, "looks"), LookValidator { staged ->
                cleanup.trackLookStage(staged)
                NativeLookValidator.validate(staged)
            }).importLook(syntheticRlook().inputStream(), name)
            independent = library.importLook(syntheticRlook().inputStream(), name)
            cleanup.finish(active = false, cancel = {}, close = {})
            assertTrue(library.list().any { it.id == previous.id })
            assertTrue(previous.file(File(context.filesDir, "looks")).isFile)
            assertFalse(library.list().any { it.id == created.id })
            assertFalse(created.file(File(context.filesDir, "looks")).exists())
            assertTrue(library.list().any { it.id == independent!!.id })
            assertTrue(independent!!.file(File(context.filesDir, "looks")).isFile)
        } finally {
            if (File(context.filesDir, "batch-gpu-test-cleanup.properties").exists()) cleanup.finish(false, {}, {})
            for (look in listOfNotNull(previous, independent)) {
                if (library.list().any { it.id == look.id }) library.remove(look.id)
            }
        }
    }
}
