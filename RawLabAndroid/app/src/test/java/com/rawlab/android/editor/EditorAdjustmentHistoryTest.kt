package com.rawlab.android.editor

import android.net.TestUri
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.AdjustmentNotReadyException
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
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class EditorAdjustmentHistoryTest {
    private fun testPhoto(root: File, name: String, id: String = "content://test/$name"): ImportedPhoto {
        val file = File(root, name).apply { if (!exists()) writeText(name) }
        return ImportedPhoto(TestUri.value, name, file, identity = PhotoIdentity(id), validateOriginal = {})
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
            assertTrue(history.interacting)

            val writer = Executors.newSingleThreadExecutor()
            try {
                val switching = writer.submit { history.acceptSource(photoB, recordB) }
                assertTrue(enteredValidatorB.await(5, TimeUnit.SECONDS))

                // While photoB's validator is still being built, readers must continue seeing photoA's complete state
                // rather than photoB paired with photoA's validator or a prematurely cleared interaction.
                assertEquals(recordA, history.loaded)
                assertTrue(history.interacting)
                assertThrows(IllegalStateException::class.java) { history.committedValidation(photoA, settingsA) }
                assertThrows(PhotoChangedException::class.java) { history.validateCommitted(photoB, settingsB) }
                assertEquals(0, validatedA.get())
                assertEquals(0, validatedB.get())

                releaseValidatorB.countDown()
                switching.get(5, TimeUnit.SECONDS)

                assertEquals(recordB, history.loaded)
                assertFalse(history.interacting)
                history.committedValidation(photoB, settingsB).invoke()
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

    @Test fun backgroundCommitDoesNotOverwriteNewerSourceOrReimportedSnapshot() {
        val root = Files.createTempDirectory("rawlab-history-commit-race").toFile()
        try {
            val photoA = testPhoto(root, "a.RAW")
            val photoB = testPhoto(root, "b.RAW")
            val initialA = EditSettings(exposure = 0f)
            val committedA = EditSettings(exposure = .75f)
            val initialB = EditSettings(exposure = -.25f)
            val updatedB = EditSettings(exposure = .5f)

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
            val lastValidatedIdentity = AtomicReference<PhotoIdentity?>()
            val history = EditorAdjustmentHistory(store) { photo ->
                { lastValidatedIdentity.set(photo.identity) }
            }

            // 1. Switching from photoA to photoB while photoA's commit is finishing on the background queue.
            val recordA = PhotoEditState(photoA.identity, null)
            val recordB = PhotoEditState(photoB.identity, initialB)
            assertEquals(EditSaveState.SAVED, store.save(photoB.identity, initialB).state)
            history.acceptSource(photoA, recordA)

            val worker = Executors.newSingleThreadExecutor()
            try {
                pauseWrite.set(true)
                val committingA = worker.submit(Callable { history.commit(photoA, committedA) })
                assertTrue(enteredWrite.get().await(5, TimeUnit.SECONDS))

                history.acceptSource(photoB, recordB)
                releaseWrite.get().countDown()
                assertEquals(EditSaveState.SAVED, committingA.get(5, TimeUnit.SECONDS).state)

                assertEquals(committedA, store.load(photoA.identity))
                assertEquals(recordB, history.loaded)
                history.validateCommitted(photoB, initialB)
                assertEquals(photoB.identity, lastValidatedIdentity.get())
                assertEquals(EditSaveState.SAVED, history.commit(photoB, updatedB).state)
                assertEquals(PhotoEditState(photoB.identity, updatedB), history.loaded)

                // 2. Re-importing the same photo identity/path (ABA) while an earlier commit is finishing.
                enteredWrite.set(CountDownLatch(1))
                releaseWrite.set(CountDownLatch(1))
                val reimportedSettings = EditSettings(exposure = -.5f)
                val reimportedRecord = PhotoEditState(photoB.identity, reimportedSettings)
                pauseWrite.set(true)
                val staleCommitB = worker.submit(Callable { history.commit(photoB, EditSettings(exposure = 1.25f)) })
                assertTrue(enteredWrite.get().await(5, TimeUnit.SECONDS))

                history.acceptSource(photoB, reimportedRecord)
                releaseWrite.get().countDown()
                assertEquals(EditSaveState.SAVED, staleCommitB.get(5, TimeUnit.SECONDS).state)

                assertEquals(reimportedRecord, history.loaded)
                history.validateCommitted(photoB, reimportedSettings)
            } finally {
                releaseWrite.get().countDown()
                worker.shutdownNow()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun backgroundCommitPreservesConcurrentInteractionStartedOnSamePhoto() {
        val root = Files.createTempDirectory("rawlab-history-interaction-cas").toFile()
        try {
            val photo = testPhoto(root, "a.RAW")
            val pauseWrite = AtomicBoolean(true)
            val enteredWrite = CountDownLatch(1)
            val releaseWrite = CountDownLatch(1)
            val store = EditorEditStore(File(root, "edits")) { dir ->
                EditStore(dir) { from, to ->
                    Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
                    if (pauseWrite.compareAndSet(true, false)) {
                        enteredWrite.countDown()
                        check(releaseWrite.await(5, TimeUnit.SECONDS))
                    }
                }
            }
            val history = EditorAdjustmentHistory(store) { { } }
            history.acceptSource(photo, PhotoEditState(photo.identity, null))

            val committed = EditSettings(exposure = .5f)
            val worker = Executors.newSingleThreadExecutor()
            try {
                val saveFuture = worker.submit(Callable { history.commit(photo, committed) })
                assertTrue(enteredWrite.await(5, TimeUnit.SECONDS))

                assertEquals(EditSaveState.SAVED, history.begin(photo, committed, revision = 3L).state)
                assertTrue(history.interacting)

                releaseWrite.countDown()
                assertEquals(EditSaveState.SAVED, saveFuture.get(5, TimeUnit.SECONDS).state)

                assertEquals(PhotoEditState(photo.identity, committed), history.loaded)
                assertTrue(history.interacting)
                assertEquals(committed, history.cancel(photo, revision = 3L))
                assertFalse(history.interacting)
            } finally {
                releaseWrite.countDown()
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

                val failure = assertThrows(java.util.concurrent.ExecutionException::class.java) {
                    recovering.get(5, TimeUnit.SECONDS)
                }
                assertTrue(failure.cause is PhotoChangedException)
                assertEquals(recordB, history.loaded)
                history.validateCommitted(photoB, settingsB)
                assertEquals(photoB.identity, validated.get())
            } finally {
                releaseReopen.countDown()
                worker.shutdownNow()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun concurrentReadersAndWritersNeverObserveTornOrStaleSnapshot() {
        val root = Files.createTempDirectory("rawlab-history-stress").toFile()
        try {
            val store = EditorEditStore(File(root, "edits"))
            val photos = listOf(
                testPhoto(root, "0.RAW"),
                testPhoto(root, "1.RAW"),
                testPhoto(root, "2.RAW"),
            )
            data class Stamp(val identity: PhotoIdentity, val path: String, val step: Int)
            val nextValidatorStep = ThreadLocal<Int>()
            val observedStamp = ThreadLocal<Stamp?>()

            val history = EditorAdjustmentHistory(store) { photo ->
                val step = nextValidatorStep.get() ?: -1
                val stamp = Stamp(photo.identity, photo.file.absolutePath, step)
                return@EditorAdjustmentHistory { observedStamp.set(stamp) }
            }

            val iterations = 400
            val done = AtomicBoolean(false)
            val barrier = CyclicBarrier(4)
            val pool = Executors.newFixedThreadPool(4)
            try {
                // Writer 1: rapidly switches sources (including consecutive updates on the same photo) with paired step+exposure.
                val sourceSwitcher = pool.submit(Callable {
                    barrier.await(5, TimeUnit.SECONDS)
                    for (i in 1..iterations) {
                        val photo = photos[i % photos.size]
                        val step = (i % 16) + 1
                        val settings = EditSettings(exposure = step * .05f)
                        nextValidatorStep.set(step)
                        try {
                            history.acceptSource(photo, PhotoEditState(photo.identity, settings))
                        } finally {
                            nextValidatorStep.remove()
                        }
                    }
                })

                // Writer 2: rapidly begins/finishes/cancels slider interactions across photos.
                val interactor = pool.submit(Callable {
                    barrier.await(5, TimeUnit.SECONDS)
                    var rev = 1L
                    while (!done.get()) {
                        val photo = photos[(rev % photos.size).toInt()]
                        history.begin(photo, EditSettings(exposure = .1f), rev)
                        if (rev % 2L == 0L) history.finish(photo, rev) else history.cancel(photo, rev)
                        rev += 1L
                    }
                })

                // Reader 1 & Reader 2: continuously capture & invoke committedValidation / validateCommitted, checking
                // that loaded settings, sourcePath, and validator always come from the exact same immutable snapshot.
                fun readerTask() = Callable {
                    barrier.await(5, TimeUnit.SECONDS)
                    while (!done.get()) {
                        for (photo in photos) {
                            val currentLoaded = history.loaded ?: continue
                            if (currentLoaded.identity != photo.identity) continue
                            val settings = currentLoaded.settings ?: continue
                            val expectedStep = Math.round(settings.exposure / .05f)
                            try {
                                val check = history.committedValidation(photo, settings)
                                observedStamp.set(null)
                                check.invoke()
                                val stamp = observedStamp.get()
                                assertNotNull("Validator must never be missing for an accepted source", stamp)
                                assertEquals(photo.identity, stamp!!.identity)
                                assertEquals(photo.file.absolutePath, stamp.path)
                                assertEquals("Loaded settings and validator must come from the same snapshot",
                                    expectedStep, stamp.step)
                            } catch (_: AdjustmentNotReadyException) {
                            } catch (_: PhotoChangedException) {
                            } catch (_: IllegalStateException) {
                            } catch (_: AdjustmentTransferException) {
                            }
                        }
                    }
                }

                val reader1 = pool.submit(readerTask())
                val reader2 = pool.submit(readerTask())

                sourceSwitcher.get(15, TimeUnit.SECONDS)
                done.set(true)
                interactor.get(5, TimeUnit.SECONDS)
                reader1.get(5, TimeUnit.SECONDS)
                reader2.get(5, TimeUnit.SECONDS)
            } finally {
                done.set(true)
                pool.shutdownNow()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun acceptSavedRejectsStaleSaveActiveInteractionAndDifferentSourceWithoutTearing() {
        val root = Files.createTempDirectory("rawlab-history-accept-saved").toFile()
        try {
            val photoA = testPhoto(root, "a.RAW")
            val photoB = testPhoto(root, "b.RAW")
            val firstA = EditSettings(exposure = .2f)
            val secondA = EditSettings(exposure = .6f)
            val settingsB = EditSettings(exposure = -.3f)
            val store = EditorEditStore(File(root, "edits"))
            val lastValidated = AtomicReference<PhotoIdentity?>()
            val history = EditorAdjustmentHistory(store) { photo -> { lastValidated.set(photo.identity) } }

            history.acceptSource(photoA, PhotoEditState(photoA.identity, null))
            assertEquals(EditSaveState.SAVED, history.commit(photoA, firstA).state)
            assertEquals(EditSaveState.SAVED, history.commit(photoA, secondA).state)

            // Older save is no longer session-current and must not regress loaded state.
            assertFalse(history.acceptSaved(photoA, PhotoEditState(photoA.identity, firstA)))
            assertEquals(PhotoEditState(photoA.identity, secondA), history.loaded)

            // Active interaction rejects acceptSaved.
            assertEquals(EditSaveState.SAVED, history.begin(photoA, secondA, revision = 1L).state)
            assertFalse(history.acceptSaved(photoA, PhotoEditState(photoA.identity, secondA)))
            assertTrue(history.finish(photoA, revision = 1L))
            assertTrue(history.acceptSaved(photoA, PhotoEditState(photoA.identity, secondA)))

            // After switching to photoB, a delayed acceptSaved for photoA must not clobber photoB or tear its validator.
            val recordB = PhotoEditState(photoB.identity, settingsB)
            history.acceptSource(photoB, recordB)
            assertFalse(history.acceptSaved(photoA, PhotoEditState(photoA.identity, secondA)))
            assertEquals(recordB, history.loaded)
            history.validateCommitted(photoB, settingsB)
            assertEquals(photoB.identity, lastValidated.get())
        } finally {
            root.deleteRecursively()
        }
    }
}
