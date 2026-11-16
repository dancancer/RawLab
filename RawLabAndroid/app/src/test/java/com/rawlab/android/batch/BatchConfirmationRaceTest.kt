package com.rawlab.android.batch

import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.CoroutineContext

class BatchConfirmationRaceTest {
    @Test fun r1_a4_confirmLastRowThenImmediateCloseDoesNotLoseConfirmationOrLeaveOrphan() = withFixture(1) { f ->
        val saveEntered = CountDownLatch(1)
        val releaseSave = CountDownLatch(1)
        val saveDispatcher = f.gatedSave(saveEntered, releaseSave)
        val confirm = f.confirmations.launch { f.confirm("row-1", ioDispatcher = saveDispatcher) }
        try {
            saveEntered.awaitChecked()
            // 真正取消正在确认的 Job；只取消无关 panelScope 不能验证 NonCancellable。
            confirm.cancel()
            val cleanup = f.closeAfter()
            assertFalse("Cleanup must wait for the in-flight save", cleanup.completionLatch().await(200, TimeUnit.MILLISECONDS))
            releaseSave.countDown()
            runBlocking { withTimeout(5_000) { cleanup.await(); confirm.join() } }
            assertNull(f.error.get())
            assertEquals(BatchRowStatus.SUCCESS, f.state.value.job.rows.single().status)
            f.assertDiscarded()
        } finally { releaseSave.countDown() }
    }

    @Test fun r2_a4_3_closeWaitsForEveryConfirmationWhenLaterRowFinishesFirst() = withFixture(2) { f ->
        f.finishLaterConfirmationFirst { f.closeAfter() }
        assertEquals(listOf(BatchRowStatus.SUCCESS, BatchRowStatus.SUCCESS), f.state.value.job.rows.map { it.status })
        f.assertDiscarded()
    }

    @Test fun r2_a4_3_discardDoesNotDeleteInputsBeforeOlderConfirmationSaves() = withFixture(2) { f ->
        f.finishLaterConfirmationFirst {
            discardBatchAfterWork(f.initial.id, f.journalRoot, f.rootJob, f.scope, confirmations = f.confirmations,
                closeModel = { f.rootJob.cancel() })
        }
        f.assertDiscarded()
    }

    @Test fun r2_a4_1_continueWaitsOutsideLockForQueuedConfirmation() = withFixture(1) { f ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        f.confirmations.launch {
            entered.countDown()
            release.awaitChecked()
            f.confirm("row-1", saved = false)
        }
        try {
            entered.awaitChecked()
            val state = f.state
            val preparation = f.scope.async(start = CoroutineStart.UNDISPATCHED) {
                prepareBatchStart(f.confirmations, state, f.journalRoot) { it }
            }
            release.countDown()
            val prepared = runBlocking { withTimeout(1_000) { preparation.await() } }
            assertEquals(BatchRowStatus.PENDING, prepared.rows.single().status)
            assertEquals(BatchRowStatus.PENDING, f.journal.load(f.initial.id)!!.rows.single().status)
        } finally { release.countDown() }
    }

    @Test fun r2_a4_2_continueMaterializesLatestUnsavedDecisionAndRendersRow() = withFixture(1) { f ->
        val saveEntered = CountDownLatch(1)
        val releaseSave = CountDownLatch(1)
        val confirm = f.confirmations.launch {
            f.confirm("row-1", saved = false, ioDispatcher = f.gatedSave(saveEntered, releaseSave))
        }
        try {
            saveEntered.awaitChecked()
            val preparation = f.scope.async(start = CoroutineStart.UNDISPATCHED) {
                prepareBatchStart(f.confirmations, f.state, f.journalRoot) { job ->
                    assertEquals("Materialization must see the committed unsaved decision", BatchRowStatus.PENDING, job.rows.single().status)
                    job
                }
            }
            releaseSave.countDown()
            val prepared = runBlocking { withTimeout(5_000) { preparation.await(); confirm.join(); preparation.await() } }
            assertEquals(BatchRowStatus.PENDING, f.state.value.job.rows.single().status)
            assertEquals(BatchRowStatus.PENDING, f.journal.load(f.initial.id)!!.rows.single().status)
            val rendered = mutableListOf<String>()
            val result = BatchRunner.run(prepared, render = { target, _ -> rendered += target.id }, write = { _, _, _ -> })
            assertEquals(listOf("row-1"), rendered)
            assertEquals(BatchRowStatus.SUCCESS, result.rows.single().status)
        } finally { releaseSave.countDown() }
    }

    @Test fun r2_a4_confirmationCommitsReadLatestJobUnderSharedLock() = withFixture(2) { f ->
        val saveEntered = CountDownLatch(1)
        val releaseSave = CountDownLatch(1)
        val first = f.confirmations.launch { f.confirm("row-1", ioDispatcher = f.gatedSave(saveEntered, releaseSave)) }
        try {
            saveEntered.awaitChecked()
            val secondEntered = CountDownLatch(1)
            val second = f.confirmations.launch {
                secondEntered.countDown()
                f.confirm("row-2")
            }
            secondEntered.awaitChecked()
            val secondFinished = CountDownLatch(1).also { latch -> second.invokeOnCompletion { latch.countDown() } }
            assertFalse("Second confirmation must not snapshot an in-flight commit", secondFinished.await(200, TimeUnit.MILLISECONDS))
            releaseSave.countDown()
            runBlocking { withTimeout(5_000) { first.join(); second.join() } }
            assertNull(f.error.get())
            assertEquals(listOf(BatchRowStatus.SUCCESS, BatchRowStatus.SUCCESS), f.journal.load(f.initial.id)!!.rows.map { it.status })
        } finally { releaseSave.countDown() }
    }

    private fun Fixture.finishLaterConfirmationFirst(cleanup: () -> Deferred<Unit>) {
        val firstEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val first = confirmations.launch {
            firstEntered.countDown()
            releaseFirst.awaitChecked()
            confirm("row-1")
        }
        try {
            firstEntered.awaitChecked()
            val last = confirmations.launch { confirm("row-2") }
            runBlocking { withTimeout(5_000) { last.join() } }
            assertEquals(listOf(BatchRowStatus.NEEDS_CONFIRMATION, BatchRowStatus.SUCCESS), state.value.job.rows.map { it.status })
            val completion = cleanup()
            assertFalse("Cleanup must include the older pending confirmation", completion.completionLatch().await(200, TimeUnit.MILLISECONDS))
            assertTrue("Working inputs must survive pending confirmation", input.isFile)
            releaseFirst.countDown()
            runBlocking { withTimeout(5_000) { first.join(); completion.await() } }
            assertNull(error.get())
        } finally {
            releaseFirst.countDown()
            runBlocking { withTimeout(5_000) { first.join() } }
        }
    }

    private class Fixture(count: Int) : AutoCloseable {
        val directory = Files.createTempDirectory("rawlab-a4-races").toFile()
        val journalRoot = File(directory, "jobs")
        val input = File(journalRoot, "a4-job/inputs/source.raw").apply { parentFile!!.mkdirs(); writeText("original") }
        val initial = BatchJob(BatchSourceSnapshot(PhotoIdentity("source"), input, EditSettings()),
            (1..count).map { BatchTarget(PhotoIdentity("row-$it"), input, "out-$it.raw") }, id = "a4-job").let { job ->
            job.withRows(job.rows.map { it.copy(status = BatchRowStatus.NEEDS_CONFIRMATION,
                outputUri = "content://test/${it.id}", outputReady = true) })
        }
        val journal = BatchJournal(journalRoot).also { it.save(initial) }
        val state = MutableStateFlow(BatchExportState(initial, phase = BatchPhase.PREPARING))
        val error = AtomicReference<Exception?>(null)
        val executor = Executors.newFixedThreadPool(4)
        val dispatcher = executor.asCoroutineDispatcher()
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val rootJob = Job()
        val confirmations = BatchConfirmations(scope)

        fun gatedSave(entered: CountDownLatch, release: CountDownLatch) = object : CoroutineDispatcher() {
            override fun dispatch(context: CoroutineContext, block: Runnable) {
                executor.execute {
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS)) { "Save gate timed out" }
                    block.run()
                }
            }
        }

        suspend fun confirm(id: String, saved: Boolean = true, ioDispatcher: CoroutineDispatcher = Dispatchers.IO) {
            confirmBatchOutput(confirmations.lock, journalRoot, id, saved, { state.value.job }, updateJob = {
                state.value = state.value.copy(job = state.value.job.let { job -> job.withRows(job.rows.map {
                    if (it.id == id && it.status == BatchRowStatus.NEEDS_CONFIRMATION)
                        it.copy(status = if (saved) BatchRowStatus.SUCCESS else BatchRowStatus.PENDING, outputUri = null)
                    else it
                }) })
            }, onError = error::set, ioDispatcher = ioDispatcher)
        }

        fun closeAfter() = discardBatchDraftOrCompleted({ state.value.job }, initial.id, journalRoot, rootJob, scope,
            confirmations = confirmations, closeModel = { rootJob.cancel() })

        fun assertDiscarded() {
            assertFalse("No orphan properties", File(journalRoot, "${initial.id}.properties").exists())
            assertFalse("No orphan row log", File(journalRoot, "${initial.id}.rows").exists())
            assertFalse("Working copy removed after all confirmations", input.parentFile!!.parentFile!!.exists())
        }

        override fun close() {
            scope.cancel()
            rootJob.cancel()
            dispatcher.close()
            assertTrue("Test workers terminated", executor.awaitTermination(5, TimeUnit.SECONDS))
            directory.deleteRecursively()
        }
    }

    private fun CountDownLatch.awaitChecked() = assertTrue("Latch timed out", await(5, TimeUnit.SECONDS))
    private fun Deferred<Unit>.completionLatch() = CountDownLatch(1).also { latch -> invokeOnCompletion { latch.countDown() } }
    private fun withFixture(count: Int, test: (Fixture) -> Unit) = Fixture(count).use(test)
}
