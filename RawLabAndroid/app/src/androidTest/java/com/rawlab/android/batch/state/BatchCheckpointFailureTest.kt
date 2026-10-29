package com.rawlab.android.batch.state

import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchPhase
import com.rawlab.android.batch.BatchRowStatus
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.settings.EditSettings
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class BatchCheckpointFailureTest {
    @Test fun continueInitFailureKeepsPublishedOutputAndUnfinishedRowsRecoverable() {
        val fail = AtomicBoolean(false)
        BatchStateTestFixture(factory = { mode, _ ->
            if (fail.get()) throw IOException("Controlled continuation initialization failure")
            NativeProcessor(mode)
        }).use { fixture ->
            fixture.addTargets(2)
            val stop = AtomicBoolean(true)
            fixture.gate(after = { next ->
                if (next.job.rows.first().status == BatchRowStatus.SUCCESS && stop.compareAndSet(true, false)) {
                    fixture.main { fixture.model.cancel() }
                }
            })
            fixture.main { fixture.model.start(ExportFormat.JPEG, null) }
            fixture.joinWorker()
            assertEquals(BatchPhase.CANCELLED, fixture.model.state.value.phase)
            val stopped = fixture.model.state.value.job
            fixture.assertOutputs(stopped, 1)
            fail.set(true)
            fixture.main { fixture.model.retryFailed() }
            fixture.joinWorker()
            assertEquals(BatchPhase.CANCELLED, fixture.model.state.value.phase)
            assertEquals(stopped, fixture.model.state.value.job)
            assertNull(fixture.model.state.value.error)
            fixture.main { fixture.model.continueUnfinished() }
            fixture.joinWorker()
            assertEquals(BatchPhase.FAILED, fixture.model.state.value.phase)
            assertEquals("Controlled continuation initialization failure", fixture.model.state.value.error)
            val persisted = fixture.journal.load(stopped.id)!!
            assertEquals(listOf(BatchRowStatus.SUCCESS, BatchRowStatus.CANCELLED), persisted.rows.map { it.status })
            assertEquals(stopped.rows.first(), persisted.rows.first())
            fixture.closePage()
            assertTrue(fixture.journal.pending().contains(stopped.id))
            fixture.assertOutputs(persisted, 1)
            fixture.assertOriginals()
        }
    }

    @Test fun initFailureIsCheckpointedBeforeFactoryAndRetainedOnClose() {
        val fail = AtomicBoolean(false)
        var checkpointAtInit: BatchJob? = null
        lateinit var fixture: BatchStateTestFixture
        fixture = BatchStateTestFixture(factory = { mode, _ ->
            if (fail.get()) {
                val id = fixture.model.state.value.job.id
                checkpointAtInit = fixture.journal.load(id)
                throw IOException("Controlled processor initialization failure")
            }
            NativeProcessor(mode)
        })
        fixture.use {
            fixture.addTargets()
            val job = fixture.model.state.value.job
            fail.set(true)
            fixture.main { fixture.model.start(ExportFormat.JPEG, null) }
            fixture.joinWorker()
            assertEquals(BatchPhase.FAILED, fixture.model.state.value.phase)
            assertEquals("Controlled processor initialization failure", fixture.model.state.value.error)
            assertNotNull("Recovery checkpoint must precede processor initialization", checkpointAtInit)
            assertEquals(listOf(BatchRowStatus.PENDING), checkpointAtInit!!.rows.map { it.status })
            fixture.closePage()
            assertTrue(fixture.journal.pending().contains(job.id))
            assertTrue(job.source.sourceFile.isFile)
            assertTrue(job.rows.single().target.sourceFile.isFile)
            fixture.assertOriginals()
        }
    }

    @Test fun missingFrozenSourceIsAnUnpersistedDraftAndCloseDeletesCopies() {
        BatchStateTestFixture().use { fixture ->
            fixture.addTargets()
            val job = fixture.model.state.value.job
            assertTrue(job.source.sourceFile.delete())
            fixture.main { fixture.model.start(ExportFormat.JPEG, null) }
            fixture.joinWorker()
            assertEquals(BatchPhase.FAILED, fixture.model.state.value.phase)
            assertFalse(fixture.journal.pending().contains(job.id))
            fixture.closePage()
            assertFalse("Unpersisted failed task is a draft", File(fixture.journalRoot, job.id).exists())
            fixture.assertOriginals()
        }
    }

    @Test fun missingFrozenLookIsAnUnpersistedDraftAndCloseDeletesCopies() {
        BatchStateTestFixture(settings = EditSettings(film = "provia")).use { fixture ->
            fixture.addTargets()
            val job = fixture.model.state.value.job
            assertTrue(checkNotNull(job.source.lookFile).delete())
            fixture.main { fixture.model.start(ExportFormat.JPEG, null) }
            fixture.joinWorker()
            assertEquals(BatchPhase.FAILED, fixture.model.state.value.phase)
            assertFalse(fixture.journal.pending().contains(job.id))
            fixture.closePage()
            assertFalse(File(fixture.journalRoot, job.id).exists())
            fixture.assertOriginals()
        }
    }

    @Test fun firstCheckpointFailureIsShownAndCloseDeletesUnpersistedCopies() {
        val fail = AtomicBoolean(false)
        val initialized = AtomicBoolean(false)
        BatchStateTestFixture(factory = { mode, _ ->
            if (fail.get()) initialized.set(true)
            NativeProcessor(mode)
        }).use { fixture ->
            fixture.addTargets()
            val job = fixture.model.state.value.job
            val blocked = File(fixture.journalRoot, "${job.id}.properties").apply { mkdirs() }
            File(blocked, "block").writeText("Prevent replacement with a journal file")
            try {
                fail.set(true)
                fixture.main { fixture.model.start(ExportFormat.JPEG, null) }
                fixture.joinWorker()
                assertEquals(BatchPhase.FAILED, fixture.model.state.value.phase)
                assertNotNull(fixture.model.state.value.error)
                assertFalse("Failed checkpoint must prevent processor initialization", initialized.get())
                assertFalse(fixture.journal.pending().contains(job.id))
                fixture.closePage()
                assertFalse(File(fixture.journalRoot, job.id).exists())
                fixture.assertOriginals()
            } finally { blocked.deleteRecursively() }
        }
    }

    @Test fun persistedUnfinishedSelectingJobIsNotMistakenForDraft() {
        BatchStateTestFixture().use { fixture ->
            fixture.addTargets()
            val job = fixture.model.state.value.job
            fixture.journal.save(job)
            fixture.closePage()
            assertTrue("Journal, not SELECTING phase, owns recovery", fixture.journal.pending().contains(job.id))
            assertTrue(job.source.sourceFile.isFile)
            fixture.assertOriginals()
        }
    }

    @Test fun unpersistedSelectingDraftIsDeletedOnClose() {
        BatchStateTestFixture().use { fixture ->
            fixture.addTargets()
            val job = fixture.model.state.value.job
            fixture.closePage()
            assertFalse(File(fixture.journalRoot, job.id).exists())
            assertFalse(fixture.journal.pending().contains(job.id))
            fixture.assertOriginals()
        }
    }
}
