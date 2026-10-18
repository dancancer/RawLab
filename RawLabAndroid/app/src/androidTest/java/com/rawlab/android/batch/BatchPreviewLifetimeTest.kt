package com.rawlab.android.batch

import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity

class BatchPreviewLifetimeTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test fun closingDraftKeepsInputsUntilCancelledPreviewActuallyExits() = blockedPreview(discard = false)

    @Test fun discardingDraftKeepsInputsUntilCancelledPreviewActuallyExits() = blockedPreview(discard = true)

    @Test fun discardingWaitsForEveryPreviewOwner() = blockedPreview(discard = true, owners = 2)

    @Test fun closeWithoutDiscardPreservesTheInputs() = blockedPreview(discard = false, preserve = true)

    private fun blockedPreview(discard: Boolean, owners: Int = 1, preserve: Boolean = false) = runBlocking {
        val root = File(context.cacheDir, "preview-lifetime-${UUID.randomUUID()}").apply { mkdirs() }
        val original = File(root, "source.raw").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val storage = PhotoStorage(context)
        val entered = CountDownLatch(owners)
        val release = List(owners) { CountDownLatch(1) }
        val exited = List(owners) { CountDownLatch(1) }
        val started = AtomicInteger()
        val reads = AtomicInteger()
        val caller = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        lateinit var model: BatchExportModel
        lateinit var frozen: File
        var created = false
        try {
            instrumentation.runOnMainSync {
                model = BatchExportModel(context, storage,
                    BatchSourceSnapshot(PhotoIdentity(original.path), original, EditSettings()),
                    gpuMode = NativeProcessor.CPU, processorFactory = { mode, _ ->
                        assertEquals(NativeProcessor.CPU, mode)
                        val index = started.getAndIncrement()
                        entered.countDown()
                        try {
                            check(release[index].await(10, TimeUnit.SECONDS))
                            assertArrayEquals(original.readBytes(), frozen.readBytes())
                            reads.incrementAndGet()
                            throw IOException("Controlled preview failure after the blocking read")
                        } finally { exited[index].countDown() }
                    })
            }
            created = true
            withTimeout(10_000) { while (model.state.value.phase == BatchPhase.PREPARING) delay(10) }
            assertEquals(BatchPhase.SELECTING, model.state.value.phase)
            frozen = model.state.value.job.source.sourceFile
            assertTrue(frozen.isFile)
            assertNotEquals(original.canonicalPath, frozen.canonicalPath)
            val previews = List(owners) { caller.async { model.preview(BatchTarget(PhotoIdentity("preview"), frozen, frozen.name)) } }
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            previews.forEach { it.cancel() }
            var cleanup: kotlinx.coroutines.Deferred<Unit>? = null
            instrumentation.runOnMainSync {
                if (!preserve) {
                    if (discard) assertTrue(model.discard())
                    cleanup = model.discardDraftOrCompleted()
                }
                model.close()
            }
            assertTrue(exited.all { it.count == 1L })
            assertTrue("Close must not delete a file still used by preview", frozen.isFile)
            if (!preserve) assertFalse(checkNotNull(cleanup).isCompleted)
            if (owners > 1) {
                release.first().countDown()
                assertTrue(exited.first().await(10, TimeUnit.SECONDS))
                assertFalse(checkNotNull(cleanup).isCompleted)
                assertTrue("Another preview still owns the input", frozen.isFile)
            }
            release.forEach { it.countDown() }
            exited.forEach { assertTrue(it.await(10, TimeUnit.SECONDS)) }
            withTimeout(10_000) {
                previews.forEach { it.join() }
                cleanup?.await()
            }
            assertEquals("Every blocked operation must finish its read before cleanup", owners, reads.get())
            assertEquals(preserve, frozen.exists())
            assertTrue("The original source is never deleted", original.isFile)
        } finally {
            release.forEach { it.countDown() }
            for (index in 0 until started.get()) assertTrue(exited[index].await(10, TimeUnit.SECONDS))
            caller.cancel()
            if (created) {
                instrumentation.runOnMainSync { model.close() }
                BatchJournal(File(context.filesDir, "RawLab/BatchJobs")).discard(model.state.value.job.id)
            }
            storage.close()
            root.deleteRecursively()
        }
    }

    @Test fun closedBatchRejectsNewPreviewBeforeItCanTouchInputs() = runBlocking {
        val root = File(context.cacheDir, "preview-closed-${UUID.randomUUID()}").apply { mkdirs() }
        val original = File(root, "source.raw").apply { writeBytes(byteArrayOf(4, 5, 6)) }
        val storage = PhotoStorage(context)
        val calls = AtomicInteger()
        lateinit var model: BatchExportModel
        var created = false
        try {
            instrumentation.runOnMainSync {
                model = BatchExportModel(context, storage,
                    BatchSourceSnapshot(PhotoIdentity(original.path), original, EditSettings()),
                    processorFactory = { _, _ -> calls.incrementAndGet(); throw IOException("Preview started after close") })
            }
            created = true
            withTimeout(10_000) { while (model.state.value.phase == BatchPhase.PREPARING) delay(10) }
            assertEquals(BatchPhase.SELECTING, model.state.value.phase)
            val source = model.state.value.job.source.sourceFile
            instrumentation.runOnMainSync { model.discardDraftOrCompleted(); model.close() }
            try {
                model.preview(BatchTarget(PhotoIdentity("closed"), source, source.name))
                fail("Closed batch must reject new previews")
            } catch (_: CancellationException) {
                assertEquals(0, calls.get())
            }
            assertFalse(source.exists())
            assertTrue(original.isFile)
        } finally {
            if (created) {
                instrumentation.runOnMainSync { model.close() }
                BatchJournal(File(context.filesDir, "RawLab/BatchJobs")).discard(model.state.value.job.id)
            }
            storage.close()
            root.deleteRecursively()
        }
    }
}
