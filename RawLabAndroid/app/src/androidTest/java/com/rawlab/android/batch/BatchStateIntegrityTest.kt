package com.rawlab.android.batch

import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class BatchStateIntegrityTest {
    @Test fun staleCancelCannotOverwriteCompleteAndPageCloses() = terminalRace(BatchPhase.COMPLETE)

    @Test fun staleCancelCannotOverwriteCancelledAndPageCloses() = terminalRace(BatchPhase.CANCELLED)

    @Test fun staleCancelCannotOverwriteFailedAndPageCloses() = terminalRace(BatchPhase.FAILED)

    private fun terminalRace(terminal: BatchPhase) {
        BatchStateTestFixture().use { fixture ->
            fixture.addTargets(if (terminal == BatchPhase.CANCELLED) 2 else 1)
            if (terminal == BatchPhase.FAILED) fixture.model.state.value.job.rows[0].target.sourceFile.writeText("invalid PNG")
            val workerEntered = CountDownLatch(1)
            val workerRelease = CountDownLatch(1)
            val cancelEntered = CountDownLatch(1)
            val cancelRelease = CountDownLatch(1)
            val terminalWritten = CountDownLatch(1)
            val cancelDone = CountDownLatch(1)
            val blockWorker = AtomicBoolean(true)
            val blockCancel = AtomicBoolean(true)
            var result: BatchExportState? = null
            fixture.gate(before = { next ->
                if (next.job.rows.any { it.status == BatchRowStatus.PROCESSING } && !next.stopping && blockWorker.compareAndSet(true, false)) {
                    workerEntered.countDown(); workerRelease.awaitBatch()
                }
                if (next.stopping && blockCancel.compareAndSet(true, false)) {
                    cancelEntered.countDown(); cancelRelease.awaitBatch()
                }
            }, after = { next ->
                if (next.phase == terminal) { result = next; terminalWritten.countDown() }
            })
            try {
                fixture.main { fixture.model.start(ExportFormat.JPEG, null) }
                workerEntered.awaitBatch()
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    try { fixture.model.cancel() } finally { cancelDone.countDown() }
                }
                cancelEntered.awaitBatch()
                workerRelease.countDown()
                terminalWritten.awaitBatch()
                cancelRelease.countDown()
                cancelDone.awaitBatch()
                fixture.joinWorker()
                assertEquals("Stale cancel must not regress a terminal state", terminal, fixture.model.state.value.phase)
                assertFalse(fixture.model.state.value.stopping)
                val job = checkNotNull(result).job
                val expected = when (terminal) {
                    BatchPhase.COMPLETE -> listOf(BatchRowStatus.SUCCESS)
                    BatchPhase.CANCELLED -> listOf(BatchRowStatus.SUCCESS, BatchRowStatus.CANCELLED)
                    else -> listOf(BatchRowStatus.FAILED)
                }
                assertEquals(expected, fixture.journal.load(job.id)!!.rows.map { it.status })
                assertEquals(job, fixture.model.state.value.job)
                fixture.assertOutputs(job, if (terminal == BatchPhase.FAILED) 0 else 1)
                fixture.closePage()
                assertEquals(terminal != BatchPhase.COMPLETE, fixture.journal.pending().contains(job.id))
                fixture.assertOutputs(job, if (terminal == BatchPhase.FAILED) 0 else 1)
                fixture.assertOriginals()
            } finally {
                workerRelease.countDown(); cancelRelease.countDown()
            }
        }
    }

    @Test fun workerRowUpdateCannotLoseStoppingAndRetryStillWorks() {
        val initializations = AtomicInteger()
        BatchStateTestFixture(factory = { mode, _ ->
            initializations.incrementAndGet()
            NativeProcessor(mode)
        }).use { fixture ->
            fixture.addTargets(2)
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val written = CountDownLatch(1)
            val finish = CountDownLatch(1)
            val armed = AtomicBoolean(true)
            val processingWrite = AtomicBoolean(false)
            fixture.gate(before = { next ->
                if (next.job.rows.any { it.status == BatchRowStatus.PROCESSING } && armed.compareAndSet(true, false)) {
                    entered.countDown(); release.awaitBatch(); processingWrite.set(true)
                }
            }, after = {
                if (processingWrite.compareAndSet(true, false)) { written.countDown(); finish.awaitBatch() }
            })
            try {
                fixture.main { fixture.model.start(ExportFormat.JPEG, null) }
                entered.awaitBatch()
                fixture.main { fixture.model.cancel() }
                assertTrue(fixture.model.state.value.stopping)
                release.countDown()
                written.awaitBatch()
                assertTrue("Worker row update must preserve the stop request", fixture.model.state.value.stopping)
            } finally { release.countDown(); finish.countDown() }
            fixture.joinWorker()
            assertEquals(BatchPhase.CANCELLED, fixture.model.state.value.phase)
            val first = fixture.model.state.value.job.rows.first()
            fixture.main { fixture.model.retryFailed() }
            fixture.joinWorker()
            assertEquals(BatchPhase.COMPLETE, fixture.model.state.value.phase)
            assertEquals(first, fixture.model.state.value.job.rows.first())
            fixture.assertOutputs(fixture.model.state.value.job, 2)
            val beforeRestart = initializations.get()
            fixture.main { fixture.model.start(ExportFormat.JPEG, null) }
            fixture.joinWorker()
            assertEquals(beforeRestart + 1, initializations.get())
            assertEquals(BatchPhase.COMPLETE, fixture.model.state.value.phase)
            assertEquals(first, fixture.model.state.value.job.rows.first())
            fixture.assertOutputs(fixture.model.state.value.job, 2)
            fixture.main { fixture.model.cancel() }
            assertEquals(BatchPhase.COMPLETE, fixture.model.state.value.phase)
            assertFalse(fixture.model.state.value.stopping)
            fixture.closePage()
            fixture.assertOriginals()
        }
    }
}
