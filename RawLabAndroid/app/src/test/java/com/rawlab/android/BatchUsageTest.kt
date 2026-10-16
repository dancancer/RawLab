package com.rawlab.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BatchUsageTest {
    private val source = BatchSourceSnapshot(PhotoIdentity("source"), File("source.raw"), EditSettings())
    private val job = BatchJob(source, listOf(BatchTarget(PhotoIdentity("target"), File("target.raw"), "target.raw")))
    private val cancelled = job.withRows(job.rows.map { it.copy(status = BatchRowStatus.CANCELLED) })

    @Test fun backgroundAndLifecycleInterruptionDifferFromExplicitCancellation() {
        val cancellation = BatchCancellation()
        cancellation.request()
        assertTrue(cancellation.get())
        assertEquals(UsageBatchOutcome.Cancelled, cancellation.outcome(cancelled))
        cancellation.request(interrupted = true)
        assertEquals(UsageBatchOutcome.Cancelled, cancellation.outcome(cancelled))

        cancellation.reset()
        assertFalse(cancellation.get())
        cancellation.request(interrupted = true)
        assertEquals(UsageBatchOutcome.Interrupted, cancellation.outcome(cancelled))

        cancellation.reset()
        cancellation.request()
        assertEquals(UsageBatchOutcome.Cancelled, cancellation.outcome(cancelled))
    }

    @Test fun completedAndUncertainPublicationsKeepTheirOwnTerminalMeaning() {
        val cancellation = BatchCancellation()
        cancellation.request(interrupted = true)
        val success = job.withRows(job.rows.map { it.copy(status = BatchRowStatus.SUCCESS) })
        assertEquals(UsageBatchOutcome.Completed, cancellation.outcome(success))
        val failure = job.withRows(job.rows.map { it.copy(status = BatchRowStatus.FAILED) })
        assertEquals(UsageBatchOutcome.Partial, cancellation.outcome(failure))
        val uncertain = job.withRows(job.rows.map { it.copy(status = BatchRowStatus.NEEDS_CONFIRMATION) })
        assertEquals(UsageBatchOutcome.Interrupted, cancellation.outcome(uncertain))
        assertEquals(UsageBatchOutcome.Interrupted, cancellation.outcome(job.copy(globalError = "storage unavailable")))
    }
}
