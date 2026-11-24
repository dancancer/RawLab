package com.rawlab.android.editor

import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentTransferException
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class EditorDocumentSessionTest {
    @Test
    fun monotonicRevisionsEmitTypedSessionEventsSynchronously() = runBlocking {
        EditorViewModelTestHarness().use { harness ->
            val session = EditorDocumentSession(harness.createDependencies(), harness.scope)
            try {
                val collected = async { session.events.take(3).toList() }
                // Give collector coroutine a moment to subscribe to SharedFlow.
                kotlinx.coroutines.yield()

                var syncedSource = -1L
                val sessionWithSync = EditorDocumentSession(
                    harness.createDependencies(),
                    harness.scope,
                    onSourceRevisionSynced = { syncedSource = it },
                )
                assertEquals(1L, sessionWithSync.incrementSourceRevision())
                assertEquals(1L, syncedSource)
                assertEquals(1L, sessionWithSync.incrementEditRevision())
                sessionWithSync.adjustmentQueue.close()

                assertEquals(1L, session.incrementSourceRevision())
                assertEquals(1L, session.incrementEditRevision())
                session.emit(EditorSessionEvent.FadeSaveNoticeRequested)

                val events = collected.await()
                assertEquals(
                    listOf(
                        EditorSessionEvent.SourceChanged(1L),
                        EditorSessionEvent.EditRevisionChanged(1L),
                        EditorSessionEvent.FadeSaveNoticeRequested,
                    ),
                    events,
                )
            } finally {
                session.disposed = true
                session.adjustmentQueue.close()
            }
        }
    }

    @Test
    fun commitAdjustmentsEnforcesSingleSlotAndReleasesStorageManifest() {
        EditorViewModelTestHarness().use { harness ->
            val session = EditorDocumentSession(harness.createDependencies(), harness.scope)
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val firstDone = CountDownLatch(1)
            var secondFailure: Throwable? = null
            var afterUnlockCalls = 0
            session.actions.finishAdjustmentClose = { afterUnlockCalls += 1 }
            try {
                session.commitAdjustments(
                    work = {
                        entered.countDown()
                        assertTrue(release.await(5, TimeUnit.SECONDS))
                        "committed"
                    },
                    completed = { firstDone.countDown() },
                )
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                assertTrue(session.mutable.value.committingAdjustments)

                // Overlapping second commit must fail immediately with AdjustmentFailure.DRAFT.
                session.commitAdjustments(
                    work = { "should-not-run" },
                    completed = { secondFailure = it.exceptionOrNull() },
                )
                assertTrue(secondFailure is AdjustmentTransferException)
                assertEquals(AdjustmentFailure.DRAFT, (secondFailure as AdjustmentTransferException).reason)

                release.countDown()
                assertTrue(firstDone.await(5, TimeUnit.SECONDS))
                harness.drainMain()
                assertFalse(session.mutable.value.committingAdjustments)
                assertTrue(afterUnlockCalls >= 1)

                // Closing adjustmentQueue releases its StorageReleaseManifest participant.
                assertFalse(session.storageRelease.isReleased())
                session.adjustmentQueue.close()
                for (participant in setOf(
                    "renderQueue",
                    "lookQueue",
                    "adjustmentPreparationQueue",
                    "processingMigrationQueue",
                    "collections",
                )) {
                    session.storageRelease.release(participant)
                }
                assertTrue(session.storageRelease.isReleased())
            } finally {
                release.countDown()
                session.disposed = true
                session.adjustmentQueue.close()
            }
        }
    }
}
