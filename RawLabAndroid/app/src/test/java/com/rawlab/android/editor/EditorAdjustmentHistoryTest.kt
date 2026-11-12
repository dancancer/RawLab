package com.rawlab.android.editor

import android.net.TestUri
import com.rawlab.android.adjustments.AdjustmentStatus
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoChangedException
import com.rawlab.android.settings.PhotoEditState
import com.rawlab.android.settings.PhotoIdentity
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class EditorAdjustmentHistoryTest {
    private fun testPhoto(
        root: File,
        name: String,
        id: String = "content://test/$name",
        validateOriginal: () -> Unit = {},
    ): ImportedPhoto {
        val file = File(root, name).apply { if (!exists()) writeText(name) }
        return ImportedPhoto(TestUri.value, name, file, identity = PhotoIdentity(id), validateOriginal = validateOriginal)
    }

    @Test fun acceptSourcePublishesLoadedPathInteractionAndValidatorAtomically() {
        val root = Files.createTempDirectory("rawlab-history-atomic").toFile()
        try {
            val photoA = testPhoto(root, "a.RAW")
            val photoB = testPhoto(root, "b.RAW")
            val settingsA = EditSettings(exposure = .25f)
            val settingsB = EditSettings(exposure = -.5f)
            val recordA = PhotoEditState(photoA.identity, settingsA)
            val recordB = PhotoEditState(photoB.identity, settingsB)
            val validatedA = AtomicInteger()
            val validatedB = AtomicInteger()
            val enteredValidatorB = CountDownLatch(1)
            val releaseValidatorB = CountDownLatch(1)

            val store = EditorEditStore(File(root, "edits"))
            val history = EditorAdjustmentHistory(store) { photo ->
                if (photo.identity == photoB.identity) {
                    enteredValidatorB.countDown()
                    check(releaseValidatorB.await(5, TimeUnit.SECONDS))
                    return@EditorAdjustmentHistory { validatedB.incrementAndGet() }
                }
                return@EditorAdjustmentHistory { validatedA.incrementAndGet() }
            }

            history.acceptSource(photoA, recordA)
            assertEquals(EditSaveState.SAVED, history.begin(photoA, settingsA, revision = 1L).state)
            assertTrue(history.snapshot().interacting)

            val writer = Executors.newSingleThreadExecutor()
            try {
                val switching = writer.submit { history.acceptSource(photoB, recordB) }
                assertTrue(enteredValidatorB.await(5, TimeUnit.SECONDS))

                // Single snapshot read while photoB's validator is still being constructed must see photoA intact.
                val midSwitch = history.snapshot()
                assertEquals(recordA, midSwitch.loaded)
                assertTrue(midSwitch.interacting)
                assertThrows(IllegalStateException::class.java) { midSwitch.committedValidation(photoA, settingsA) }
                assertThrows(PhotoChangedException::class.java) { midSwitch.validateCommitted(photoB, settingsB) }
                assertEquals(0, validatedA.get())
                assertEquals(0, validatedB.get())

                releaseValidatorB.countDown()
                switching.get(5, TimeUnit.SECONDS)

                val afterSwitch = history.snapshot()
                assertEquals(recordB, afterSwitch.loaded)
                assertFalse(afterSwitch.interacting)
                afterSwitch.committedValidation(photoB, settingsB).invoke()
                assertEquals(0, validatedA.get())
                assertEquals(1, validatedB.get())
            } finally {
                releaseValidatorB.countDown()
                writer.shutdownNow()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun snapshotProvidesConsistentSingleReadViewAcrossConcurrentSourceUpdates() {
        val root = Files.createTempDirectory("rawlab-history-single-read").toFile()
        try {
            val photo = testPhoto(root, "same.RAW")
            val step1 = EditSettings(exposure = .25f)
            val step2 = EditSettings(exposure = .75f)
            val step3 = EditSettings(exposure = 1.15f)
            val nextStamp = AtomicReference("v1")
            val observedStamp = AtomicReference<String?>()

            val store = EditorEditStore(File(root, "edits"))
            val history = EditorAdjustmentHistory(store) {
                val captured = nextStamp.get()
                return@EditorAdjustmentHistory { observedStamp.set(captured) }
            }

            // 1. A snapshot read once keeps loaded, interacting, and committedValidation consistent even after
            // the live history advances to new settings and enters an active slider interaction on the same photo.
            history.acceptSource(photo, PhotoEditState(photo.identity, step1))
            val snap1 = history.snapshot()
            assertEquals(step1, requireNotNull(snap1.loaded).settings)
            assertFalse(snap1.interacting)

            nextStamp.set("v2")
            history.acceptSource(photo, PhotoEditState(photo.identity, step2))
            assertEquals(EditSaveState.SAVED, history.begin(photo, step2, revision = 2L).state)
            assertTrue(history.snapshot().interacting)

            observedStamp.set(null)
            snap1.committedValidation(photo, step1).invoke()
            assertEquals("v1", observedStamp.get())

            // 2. Deterministic cross-thread handoff: reader captures snapshot once, writer replaces same photo
            // with step3, and reader validates its captured snapshot without throwing or observing v3's validator.
            assertTrue(history.finish(photo, revision = 2L))
            val readerCaptured = CountDownLatch(1)
            val writerUpdated = CountDownLatch(1)
            val executor = Executors.newFixedThreadPool(2)
            try {
                val reader = executor.submit(Callable {
                    val snap2 = history.snapshot()
                    readerCaptured.countDown()
                    check(writerUpdated.await(5, TimeUnit.SECONDS))
                    val settings = requireNotNull(snap2.loaded?.settings)
                    val localObserved = AtomicReference<String?>()
                    // Synchronize observedStamp read around invocation on this thread.
                    observedStamp.set(null)
                    snap2.committedValidation(photo, settings).invoke()
                    localObserved.set(observedStamp.get())
                    settings to localObserved.get()
                })
                val writer = executor.submit(Callable {
                    check(readerCaptured.await(5, TimeUnit.SECONDS))
                    nextStamp.set("v3")
                    history.acceptSource(photo, PhotoEditState(photo.identity, step3))
                    writerUpdated.countDown()
                })

                writer.get(5, TimeUnit.SECONDS)
                val (capturedSettings, capturedValidatorStamp) = reader.get(5, TimeUnit.SECONDS)
                assertEquals(step2, capturedSettings)
                assertEquals("v2", capturedValidatorStamp)

                val snap3 = history.snapshot()
                assertEquals(step3, snap3.loaded?.settings)
                observedStamp.set(null)
                snap3.validateCommitted(photo, step3)
                assertEquals("v3", observedStamp.get())
            } finally {
                readerCaptured.countDown()
                writerUpdated.countDown()
                executor.shutdownNow()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun backgroundCommitInterceptedBySourceSwitchNeitherOverwritesSnapshotNorPollutesSession() {
        val root = Files.createTempDirectory("rawlab-history-commit-race").toFile()
        try {
            val photoA = testPhoto(root, "a.RAW")
            val oldOriginalValid = AtomicBoolean(true)
            val newHistoryChecks = AtomicInteger()
            val photoBOld = testPhoto(root, "b.RAW") {
                if (!oldOriginalValid.get()) throw PhotoChangedException()
            }
            val initialB = EditSettings(exposure = -.25f)
            val updatedB = EditSettings(exposure = .5f)
            val committedA = EditSettings(exposure = .75f)

            val writeCount = AtomicInteger()
            val pauseWrite = AtomicBoolean(false)
            val enteredWrite = AtomicReference(CountDownLatch(1))
            val releaseWrite = AtomicReference(CountDownLatch(1))
            val store = EditorEditStore(File(root, "edits")) { dir ->
                EditStore(dir) { from, to ->
                    Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
                    writeCount.incrementAndGet()
                    if (pauseWrite.compareAndSet(true, false)) {
                        enteredWrite.get().countDown()
                        check(releaseWrite.get().await(5, TimeUnit.SECONDS))
                    }
                }
            }
            val lastValidatedIdentity = AtomicReference<PhotoIdentity?>()
            val history = EditorAdjustmentHistory(store) { photo ->
                { lastValidatedIdentity.set(photo.identity) }
            }

            // 1. Switching from photoA to photoB while photoA's commit is finishing on the background queue.
            val recordA = PhotoEditState(photoA.identity, null)
            val recordB = PhotoEditState(photoBOld.identity, initialB)
            assertEquals(EditSaveState.SAVED, store.save(photoBOld.identity, initialB).state)
            history.acceptSource(photoA, recordA)

            val worker = Executors.newSingleThreadExecutor()
            try {
                pauseWrite.set(true)
                val committingA = worker.submit(Callable { history.commit(photoA, committedA) })
                assertTrue(enteredWrite.get().await(5, TimeUnit.SECONDS))

                history.acceptSource(photoBOld, recordB)
                releaseWrite.get().countDown()
                assertEquals(EditSaveState.SAVED, committingA.get(5, TimeUnit.SECONDS).state)

                assertEquals(committedA, store.load(photoA.identity))
                assertEquals(recordB, history.snapshot().loaded)
                assertTrue(history.session!!.transactions.isEmpty())
                history.snapshot().validateCommitted(photoBOld, initialB)
                assertEquals(photoBOld.identity, lastValidatedIdentity.get())
                assertEquals(EditSaveState.SAVED, history.commit(photoBOld, updatedB).state)
                assertEquals(PhotoEditState(photoBOld.identity, updatedB), history.snapshot().loaded)
                assertEquals(1, history.session!!.transactions.size)

                // 2. Same-photo ABA re-import while staleCommitB (1.25f) is finishing:
                // staleCommitB must neither overwrite Snapshot nor pollute AdjustmentTransferSession.
                enteredWrite.set(CountDownLatch(1))
                releaseWrite.set(CountDownLatch(1))
                val staleTargetSettings = EditSettings(exposure = 1.25f)
                val reimportedSettings = EditSettings(exposure = -.5f)
                val reimportedRecord = PhotoEditState(photoBOld.identity, reimportedSettings)
                val photoBReimported = ImportedPhoto(
                    TestUri.value,
                    photoBOld.name,
                    photoBOld.file,
                    identity = photoBOld.identity,
                    validateOriginal = { newHistoryChecks.incrementAndGet() },
                )

                pauseWrite.set(true)
                val staleCommitB = worker.submit(Callable { history.commit(photoBOld, staleTargetSettings) })
                assertTrue(enteredWrite.get().await(5, TimeUnit.SECONDS))

                oldOriginalValid.set(false)
                history.acceptSource(photoBReimported, reimportedRecord)
                releaseWrite.get().countDown()
                assertEquals(EditSaveState.SAVED, staleCommitB.get(5, TimeUnit.SECONDS).state)

                val session = requireNotNull(history.session)
                assertEquals(reimportedRecord, history.snapshot().loaded)
                assertTrue(session.isCurrentSave(reimportedRecord))
                assertFalse(session.isCurrentSave(PhotoEditState(photoBReimported.identity, staleTargetSettings)))
                assertEquals(1, session.transactions.size)
                history.snapshot().validateCommitted(photoBReimported, reimportedSettings)

                // Subsequent commit of 1.25f on the re-imported snapshot must NOT be skipped as UNCHANGED.
                assertEquals(reimportedRecord, EditStore(File(root, "edits")).save(photoBReimported.identity, reimportedSettings))
                val writesBeforeFreshCommit = writeCount.get()
                assertEquals(EditSaveState.SAVED, history.commit(photoBReimported, staleTargetSettings).state)
                assertEquals(writesBeforeFreshCommit + 1, writeCount.get())
                assertEquals(staleTargetSettings, store.load(photoBReimported.identity))
                assertEquals(2, session.transactions.size)

                // Undo uses the re-imported source validator rather than staleCommitB's invalidated validator.
                val undoOutcome = session.undoPhoto(photoBReimported.identity).single()
                assertEquals(AdjustmentStatus.APPLIED, undoOutcome.status)
                assertEquals(reimportedSettings, store.load(photoBReimported.identity))
                assertTrue(newHistoryChecks.get() > 0)
            } finally {
                releaseWrite.get().countDown()
                worker.shutdownNow()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun backgroundCommitPreservesConcurrentInteractionWithoutTearingAcrossSameAndSwitchedPhotos() {
        val root = Files.createTempDirectory("rawlab-history-interaction-cas").toFile()
        try {
            val photoA = testPhoto(root, "a.RAW")
            val photoB = testPhoto(root, "b.RAW")
            val pauseWrite = AtomicBoolean(false)
            val enteredWrite = AtomicReference(CountDownLatch(1))
            val releaseWrite = AtomicReference(CountDownLatch(1))
            val store = EditorEditStore(File(root, "edits")) { dir ->
                EditStore(dir) { from, to ->
                    Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
                    if (pauseWrite.compareAndSet(true, false)) {
                        enteredWrite.get().countDown()
                        check(releaseWrite.get().await(5, TimeUnit.SECONDS))
                    }
                }
            }
            val history = EditorAdjustmentHistory(store) { { } }
            history.acceptSource(photoA, PhotoEditState(photoA.identity, null))

            val committedA1 = EditSettings(exposure = .5f)
            val committedA2 = EditSettings(exposure = .9f)
            val initialB = EditSettings(exposure = -.25f)
            val draggedB = EditSettings(exposure = -.1f)
            val worker = Executors.newSingleThreadExecutor()
            try {
                // 1. Same photo: concurrent slider begin on photoA is preserved while loaded advances.
                pauseWrite.set(true)
                val firstSave = worker.submit(Callable { history.commit(photoA, committedA1) })
                assertTrue(enteredWrite.get().await(5, TimeUnit.SECONDS))

                assertEquals(EditSaveState.SAVED, history.begin(photoA, committedA1, revision = 3L).state)
                assertTrue(history.snapshot().interacting)

                releaseWrite.get().countDown()
                assertEquals(EditSaveState.SAVED, firstSave.get(5, TimeUnit.SECONDS).state)

                val samePhotoSnap = history.snapshot()
                assertEquals(PhotoEditState(photoA.identity, committedA1), samePhotoSnap.loaded)
                assertTrue(samePhotoSnap.interacting)
                assertEquals(committedA1, history.cancel(photoA, revision = 3L))
                assertFalse(history.snapshot().interacting)

                // 2. Switched photo: photoA's late commit finishing during photoB's active drag must not tear
                // photoB's loaded identity away from photoB's interaction and break photoB's release commit.
                val recordB = PhotoEditState(photoB.identity, initialB)
                assertEquals(EditSaveState.SAVED, store.save(photoB.identity, initialB).state)

                enteredWrite.set(CountDownLatch(1))
                releaseWrite.set(CountDownLatch(1))
                pauseWrite.set(true)
                val staleSaveA = worker.submit(Callable { history.commit(photoA, committedA2) })
                assertTrue(enteredWrite.get().await(5, TimeUnit.SECONDS))

                history.acceptSource(photoB, recordB)
                assertEquals(EditSaveState.SAVED, history.begin(photoB, initialB, revision = 4L).state)

                releaseWrite.get().countDown()
                assertEquals(EditSaveState.SAVED, staleSaveA.get(5, TimeUnit.SECONDS).state)

                val activeB = history.snapshot()
                assertEquals(recordB, activeB.loaded)
                assertTrue(activeB.interacting)
                assertTrue(history.finish(photoB, revision = 4L))
                assertEquals(EditSaveState.SAVED, history.commit(photoB, draggedB).state)
                assertEquals(draggedB, store.load(photoB.identity))
                assertEquals(PhotoEditState(photoB.identity, draggedB), history.snapshot().loaded)
            } finally {
                releaseWrite.get().countDown()
                worker.shutdownNow()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun earlierStalledAcceptSourceDoesNotOverwriteNewerSourceOrSessionValidator() {
        val root = Files.createTempDirectory("rawlab-history-accept-order").toFile()
        try {
            val freshHistoryChecks = AtomicInteger()
            val freshEditorChecks = AtomicInteger()
            val basePhoto = testPhoto(root, "photo.RAW")
            val stalePhotoCopy = ImportedPhoto(
                TestUri.value,
                basePhoto.name,
                basePhoto.file,
                identity = basePhoto.identity,
                validateOriginal = { throw PhotoChangedException() },
            )
            val freshPhotoCopy = ImportedPhoto(
                TestUri.value,
                basePhoto.name,
                basePhoto.file,
                identity = basePhoto.identity,
                validateOriginal = { freshHistoryChecks.incrementAndGet() },
            )

            val enteredStaleValidate = CountDownLatch(1)
            val releaseStaleValidate = CountDownLatch(1)
            val store = EditorEditStore(File(root, "edits"))
            val history = EditorAdjustmentHistory(store) { photo ->
                if (photo === stalePhotoCopy) {
                    enteredStaleValidate.countDown()
                    check(releaseStaleValidate.await(5, TimeUnit.SECONDS))
                    return@EditorAdjustmentHistory { throw PhotoChangedException() }
                }
                if (photo === freshPhotoCopy) {
                    return@EditorAdjustmentHistory { freshEditorChecks.incrementAndGet() }
                }
                return@EditorAdjustmentHistory { }
            }

            val committed = EditSettings(exposure = .3f)
            history.acceptSource(basePhoto, PhotoEditState(basePhoto.identity, null))
            assertEquals(EditSaveState.SAVED, history.commit(basePhoto, committed).state)

            val staleRecord = PhotoEditState(basePhoto.identity, EditSettings(exposure = -.8f))
            val freshRecord = PhotoEditState(basePhoto.identity, committed)
            val worker = Executors.newSingleThreadExecutor()
            try {
                val stalled = worker.submit { history.acceptSource(stalePhotoCopy, staleRecord) }
                assertTrue(enteredStaleValidate.await(5, TimeUnit.SECONDS))

                // Newer acceptSource starts and finishes while the earlier call is still inside validateSource.
                history.acceptSource(freshPhotoCopy, freshRecord)
                releaseStaleValidate.countDown()
                stalled.get(5, TimeUnit.SECONDS)

                val snap = history.snapshot()
                assertEquals(freshRecord, snap.loaded)
                snap.validateCommitted(freshPhotoCopy, committed)
                assertEquals(1, freshEditorChecks.get())

                // Session's sourceValidators must also retain freshPhotoCopy rather than stalePhotoCopy.
                val undone = history.session!!.undoPhoto(freshPhotoCopy.identity).single()
                assertEquals(AdjustmentStatus.APPLIED, undone.status)
                assertTrue(freshHistoryChecks.get() > 0)
            } finally {
                releaseStaleValidate.countDown()
                worker.shutdownNow()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun recoverSourceRejectsSourceSwitchMidRecoveryWithoutOverwritingNewPhoto() {
        val root = Files.createTempDirectory("rawlab-history-recover-race").toFile()
        try {
            val photoA = testPhoto(root, "a.RAW")
            val photoB = testPhoto(root, "b.RAW")
            val settingsB = EditSettings(exposure = .4f)
            val recordB = PhotoEditState(photoB.identity, settingsB)
            val failOpen = AtomicBoolean(true)
            val enteredReopen = CountDownLatch(1)
            val releaseReopen = CountDownLatch(1)

            val store = EditorEditStore(File(root, "edits")) { dir ->
                if (failOpen.get()) throw IOException("Store unavailable")
                enteredReopen.countDown()
                check(releaseReopen.await(5, TimeUnit.SECONDS))
                EditStore(dir)
            }
            val validated = AtomicReference<PhotoIdentity?>()
            val history = EditorAdjustmentHistory(store) { photo -> { validated.set(photo.identity) } }

            history.acceptSource(photoA, null)
            failOpen.set(false)

            val worker = Executors.newSingleThreadExecutor()
            try {
                val recovering = worker.submit(Callable { history.recoverSource(photoA) })
                assertTrue(enteredReopen.await(5, TimeUnit.SECONDS))

                history.acceptSource(photoB, recordB)
                releaseReopen.countDown()

                val failure = assertThrows(ExecutionException::class.java) {
                    recovering.get(5, TimeUnit.SECONDS)
                }
                assertTrue(failure.cause is PhotoChangedException)
                val snap = history.snapshot()
                assertEquals(recordB, snap.loaded)
                snap.validateCommitted(photoB, settingsB)
                assertEquals(photoB.identity, validated.get())
            } finally {
                releaseReopen.countDown()
                worker.shutdownNow()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun acceptSavedRequiresMatchingSourceTokenNonNullBaselineAndCurrentSessionSave() {
        val root = Files.createTempDirectory("rawlab-history-accept-saved").toFile()
        try {
            val photoA = testPhoto(root, "a.RAW")
            val photoB = testPhoto(root, "b.RAW")
            val firstA = EditSettings(exposure = .2f)
            val secondA = EditSettings(exposure = .6f)
            val migratedSettingsA = EditSettings(exposure = .85f)
            val settingsB = EditSettings(exposure = -.3f)
            val store = EditorEditStore(File(root, "edits"))
            val lastValidated = AtomicReference<PhotoIdentity?>()
            val history = EditorAdjustmentHistory(store) { photo -> { lastValidated.set(photo.identity) } }

            // 1. Uninitialized snapshot and null-loaded baseline must reject acceptSaved so validator is never null.
            val preSaved = PhotoEditState(photoA.identity, firstA)
            history.session!!.adoptProcessingMigration(preSaved)
            assertTrue(history.session!!.isCurrentSave(preSaved))
            assertFalse(history.acceptSaved(photoA, preSaved, expectedSourceToken = 0L))
            assertFalse(history.acceptSaved(photoA, preSaved, expectedSourceToken = 1L))
            assertNull(history.snapshot().loaded)

            history.acceptSource(photoA, null)
            val unloadedToken = history.snapshot().sourceToken
            assertFalse(history.acceptSaved(photoA, preSaved, unloadedToken))
            assertNull(history.snapshot().loaded)

            // 2. Superseded session save and active slider interaction must reject acceptSaved.
            history.acceptSource(photoA, PhotoEditState(photoA.identity, null))
            val tokenA1 = history.snapshot().sourceToken
            assertEquals(EditSaveState.SAVED, history.commit(photoA, firstA).state)
            assertEquals(EditSaveState.SAVED, history.commit(photoA, secondA).state)

            assertFalse(history.acceptSaved(photoA, PhotoEditState(photoA.identity, firstA), tokenA1))
            assertEquals(PhotoEditState(photoA.identity, secondA), history.snapshot().loaded)

            assertEquals(EditSaveState.SAVED, history.begin(photoA, secondA, revision = 1L).state)
            assertFalse(history.acceptSaved(photoA, PhotoEditState(photoA.identity, secondA), tokenA1))
            assertTrue(history.finish(photoA, revision = 1L))
            assertTrue(history.acceptSaved(photoA, PhotoEditState(photoA.identity, secondA), tokenA1))

            // 3. Same-photo ABA re-open: even when session.isCurrentSave(migratedA) is true, a late acceptSaved
            // carrying the pre-reopen tokenA1 must not overwrite the newly accepted tokenA2 snapshot.
            val reimportedA = PhotoEditState(photoA.identity, null)
            history.acceptSource(photoA, reimportedA)
            val tokenA2 = history.snapshot().sourceToken
            assertNotEquals(tokenA1, tokenA2)

            val migratedA = PhotoEditState(photoA.identity, migratedSettingsA)
            history.session!!.adoptProcessingMigration(migratedA)
            assertTrue(history.session!!.isCurrentSave(migratedA))
            assertFalse(history.acceptSaved(photoA, migratedA, tokenA1))
            assertEquals(reimportedA, history.snapshot().loaded)
            assertTrue(history.acceptSaved(photoA, migratedA, tokenA2))
            assertEquals(migratedA, history.snapshot().loaded)

            // 4. After switching to photoB, a delayed acceptSaved for photoA must not clobber photoB.
            val recordB = PhotoEditState(photoB.identity, settingsB)
            history.acceptSource(photoB, recordB)
            assertFalse(history.acceptSaved(photoA, migratedA, tokenA2))
            val snapB = history.snapshot()
            assertEquals(recordB, snapB.loaded)
            snapB.validateCommitted(photoB, settingsB)
            assertEquals(photoB.identity, lastValidated.get())
        } finally {
            root.deleteRecursively()
        }
    }
}
