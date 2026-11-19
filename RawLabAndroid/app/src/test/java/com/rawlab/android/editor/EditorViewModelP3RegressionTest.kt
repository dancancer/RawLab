package com.rawlab.android.editor

import android.net.TestUri
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.photo.MediaPhotoLibrary
import com.rawlab.android.settings.EditSettings
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class EditorViewModelP3RegressionTest {
    @Test fun p3_31_constructionDefersSharedPreferencesAndUsesApplyForWrites() {
        EditorViewModelTestHarness().use { harness ->
            val mediaLibrary = MediaPhotoLibrary(harness.app)
            assertTrue("MediaPhotoLibrary must not read SharedPreferences on construction", harness.app.getSharedPreferencesCalls.isEmpty())

            val (_, uri) = harness.createTempPhoto("p3_31.raw")
            val lookFile = harness.syntheticCube("p3_31.cube")
            val model = harness.createViewModel()
            try {
                // Constructing EditorViewModel must not eagerly call getSharedPreferences on the main thread.
                assertTrue(
                    "Unexpected eager getSharedPreferences during VM construction: ${harness.app.getSharedPreferencesCalls}",
                    harness.app.getSharedPreferencesCalls.isEmpty(),
                )
                assertNotNull(mediaLibrary)

                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }

                harness.onMain { model.importLook(TestUri.of("/${lookFile.absolutePath.trimStart('/')}", scheme = "file", authority = "")) }
                harness.awaitState(model) { it.canExport && it.looks.any { look -> look.managed } }
                val managedId = model.state.value.looks.first { it.managed }.id

                harness.onMain { assertTrue(model.selectFilm("neutral")) }
                harness.awaitState(model) { it.canExport && it.edits.film == "neutral" }
                harness.onMain { assertTrue(model.selectFilm(managedId)) }
                harness.awaitState(model) { it.canExport && it.recentLookIds.contains(managedId) }

                harness.onMain {
                    model.receiveSystemPhotos(listOf(uri), requestID = "req-p3-31")
                }
                harness.awaitState(model) { model.systemPhotoRequests.value.isNotEmpty() }
                val request = model.systemPhotoRequests.value.first()
                harness.onMain { model.consumeSystemPhotoRequest(request) }
                harness.awaitState(model) { model.systemPhotoRequests.value.isEmpty() }

                val lookPrefs = harness.app.sharedPrefsMap["look-browser"]
                val systemPrefs = harness.app.sharedPrefsMap["system-photo-requests"]
                assertNotNull(lookPrefs)
                assertNotNull(systemPrefs)
                assertEquals(0, lookPrefs!!.commitCalls.get())
                assertEquals(0, systemPrefs!!.commitCalls.get())
                assertTrue(lookPrefs.applyCalls.get() > 0)
                assertTrue(systemPrefs.applyCalls.get() >= 2)
            } finally {
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun p3_32_storageReleaseManifestCountsByParticipantAndCoversOneFewerAndOneMoreTrigger() {
        val participants = setOf("renderQueue", "lookQueue", "adjustmentQueue", "adjustmentPreparationQueue", "processingMigrationQueue", "collections")
        val closes = AtomicInteger()
        val manifest = StorageReleaseManifest(participants) { closes.incrementAndGet() }

        assertEquals(6, manifest.pendingCount())
        assertFalse(manifest.isReleased())

        // 1. One fewer participant (5 of 6) must NOT close storage.
        val five = participants.take(5)
        five.forEach { assertFalse(manifest.release(it)) }
        assertEquals(1, manifest.pendingCount())
        assertEquals(0, closes.get())

        // 2. Duplicate release of an already-released participant (total 6 calls, still 1 missing) must NOT close storage!
        assertFalse(manifest.release(five.first()))
        assertEquals(1, manifest.pendingCount())
        assertEquals(0, closes.get())

        // 3. Unknown participant must be ignored.
        assertFalse(manifest.release("unknownQueue"))
        assertEquals(0, closes.get())

        // 4. Releasing the 6th unique participant closes storage exactly once.
        val last = participants.last()
        assertTrue(manifest.release(last))
        assertEquals(0, manifest.pendingCount())
        assertTrue(manifest.isReleased())
        assertEquals(1, closes.get())

        // 5. One more trigger after release must NOT close storage a second time.
        assertFalse(manifest.release(last))
        assertFalse(manifest.release(five.first()))
        assertEquals(1, closes.get())
    }

    @Test fun p3_32_editorViewModelOnClearedClosesStorageOnlyAfterAllSixManifestParticipantsDrain() {
        EditorViewModelTestHarness().use { harness ->
            val storage = harness.createStorage()
            val dirField = com.rawlab.android.photo.PhotoStorage::class.java.getDeclaredField("directory").apply { isAccessible = true }
            val workingDir = (dirField.get(storage) as File).apply { mkdirs() }
            File(workingDir, "marker.raw").writeText("active")
            val renderGateway = FakeRenderGateway { work, _ -> harness.defaultRender(work) }
            val model = harness.createViewModel(storage = storage, renderGateway = renderGateway)
            harness.awaitState(model) { !it.rendering && it.operation == Operation.NONE }
            assertTrue(workingDir.exists())
            assertEquals(6, model.storageRelease.pendingCount())
            assertFalse(model.storageRelease.isReleased())

            harness.onMain { model.clearForTest() }
            val deadline = System.currentTimeMillis() + 5_000L
            while (System.currentTimeMillis() < deadline && !model.storageRelease.isReleased()) {
                Thread.sleep(15)
            }
            assertTrue("Storage release manifest must complete after all 6 workers drain", model.storageRelease.isReleased())
            assertEquals(0, model.storageRelease.pendingCount())
            assertEquals(1, renderGateway.closeCalls.get())
            assertEquals(1, harness.previewCache.closeCalls.get())
            assertFalse("PhotoStorage.close() must delete its working directory", workingDir.exists())
        }
    }

    @Test fun p3_33_interactiveEditOnSwitchedPhotoInViewModelNeverReceivesFakeSaved() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uriA) = harness.createTempPhoto("p3_33_a.raw")
            val (_, uriB) = harness.createTempPhoto("p3_33_b.raw")
            val enteredB = CountDownLatch(1)
            val releaseB = CountDownLatch(1)
            val model = harness.createViewModel(
                renderHandler = { work, cancellation ->
                    if (work is Work.Import && work.uri == uriB) {
                        enteredB.countDown()
                        check(releaseB.await(5, TimeUnit.SECONDS))
                    }
                    harness.defaultRender(work)
                },
            )
            try {
                harness.onMain { model.importPhoto(uriA) }
                harness.awaitState(model) { it.canExport }

                // Start an interactive slider drag on photo A.
                harness.onMain { model.edit(model.state.value.edits.copy(exposure = 0.4f), interactive = true) }
                harness.awaitState(model) { !it.rendering }

                // Start switching to photo B (still importing, so acceptSource(B) hasn't run yet).
                harness.onMain { model.importPhoto(uriB) }
                assertTrue(enteredB.await(5, TimeUnit.SECONDS))

                // If anything tries to begin an interactive adjustment for photo B against A's active interaction,
                // EditorAdjustmentHistory.begin() must reject with PhotoChangedException, never fake SAVED.
                val photoB = com.rawlab.android.photo.ImportedPhoto(uriB, "p3_33_b.raw", File(uriB.path!!))
                val historyField = EditorViewModel::class.java.getDeclaredField("adjustmentHistory").apply { isAccessible = true }
                val history = historyField.get(model) as EditorAdjustmentHistory
                val res = history.begin(photoB, EditSettings(), revision = 2L)
                assertEquals(EditSaveState.FAILED, res.state)
                assertTrue(res.error is com.rawlab.android.settings.PhotoChangedException)

                releaseB.countDown()
                harness.awaitState(model) { it.photo?.uri == uriB && it.canExport }
            } finally {
                releaseB.countDown()
                harness.onMain { model.clearForTest() }
            }
        }
    }
}

internal fun EditorViewModel.clearForTest() {
    androidx.lifecycle.ViewModelStore().apply { put("editor", this@clearForTest) }.clear()
}
