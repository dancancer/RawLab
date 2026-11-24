package com.rawlab.android.editor

import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentTransferException
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
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
                val deadline = System.currentTimeMillis() + 5_000L
                while (!session.storageRelease.isReleased() && System.currentTimeMillis() < deadline) {
                    Thread.sleep(10)
                }
                assertTrue(session.storageRelease.isReleased())
            } finally {
                release.countDown()
                session.disposed = true
                session.adjustmentQueue.close()
            }
        }
    }

    @Test
    fun editorViewModelPreservesReflectionFieldsUsedByInstrumentedTests() {
        EditorViewModelTestHarness().use { harness ->
            val model = harness.createViewModel()
            try {
                fun readField(name: String): Any? =
                    EditorViewModel::class.java.getDeclaredField(name).apply { isAccessible = true }.get(model)

                val requiredFields = listOf(
                    "renderer",
                    "editStore",
                    "adjustmentHistory",
                    "currentRevision",
                    "sourceRevision",
                    "queue",
                    "adjustmentQueue",
                )
                for (name in requiredFields) {
                    assertNotNull("Expected EditorViewModel field '$name' to be declared", EditorViewModel::class.java.getDeclaredField(name))
                }
                assertSame(model.session.editStore, readField("editStore"))
                assertSame(model.session.adjustmentHistory, readField("adjustmentHistory"))
                assertSame(model.session.adjustmentQueue, readField("adjustmentQueue"))
                assertSame(model.viewport.queue, readField("queue"))
                assertEquals(0L, readField("currentRevision"))
                assertEquals(0L, readField("sourceRevision"))
            } finally {
                harness.onMain {
                    EditorViewModel::class.java.getDeclaredMethod("onCleared").apply { isAccessible = true }.invoke(model)
                }
            }
        }
    }
}
