package com.rawlab.android.editor

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.editor.render.SerialWorkQueue
import com.rawlab.android.settings.AdjustmentOperationExpiredException
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.ProcessingIdentity
import com.rawlab.android.settings.ProcessingMigrationQuality
import com.rawlab.android.settings.ProcessingMigrationStatus
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

@RunWith(AndroidJUnit4::class)
class ProcessingMigrationCommitTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun field(model: EditorViewModel, name: String): Any? =
        EditorViewModel::class.java.getDeclaredField(name).apply { isAccessible = true }.get(model)
    private fun await(condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (!condition() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(10)
        assertTrue("migration state settled", condition())
    }

    @Test fun becomingActiveAfterImportStartsTheDeferredMigration() {
        val source = File(context.cacheDir, "inactive-migration-${UUID.randomUUID()}.png")
        Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let { bitmap ->
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
        val identity = PhotoIdentity(Uri.fromFile(source).toString())
        val store = EditStore(File(context.filesDir, "edits"))
        store.save(identity, EditSettings(processing = ProcessingIdentity.C5))
        val owner = ViewModelStore()
        val releaseFit = CountDownLatch(1)
        lateinit var model: EditorViewModel
        try {
            main {
                model = EditorViewModel(context.applicationContext as Application)
                owner.put("editor", model)
                model.setGpuEnabled(false)
                model.setEditorActive(false)
            }
            val queue = field(model, "processingMigrationQueue") as SerialWorkQueue
            val entered = CountDownLatch(1)
            queue.submit({ entered.countDown(); check(releaseFit.await(30, TimeUnit.SECONDS)) }) {}
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            main { model.importPhoto(Uri.fromFile(source)) }
            await { model.state.value.exact && !model.state.value.rendering }
            main {
                assertEquals(ProcessingIdentity.C5, model.state.value.edits.processing)
                assertFalse(model.state.value.matchingProcessing)
                model.setEditorActive(true)
                assertTrue("activation must start migration when import already finished", model.state.value.matchingProcessing)
            }
            releaseFit.countDown()
            await { model.state.value.canExport && model.state.value.edits.processing == ProcessingIdentity.CURRENT }
            assertEquals(ProcessingMigrationStatus.MIGRATED, model.state.value.processingMigration?.status)
        } finally {
            releaseFit.countDown()
            main { owner.clear() }
            source.delete()
        }
    }

    @Test fun leavingAfterAtomicReplacementStillAdoptsTheCommittedEdit() {
        val source = File(context.cacheDir, "committed-migration-${UUID.randomUUID()}.png")
        Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let { bitmap ->
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
        val identity = PhotoIdentity(Uri.fromFile(source).toString())
        val directory = File(context.filesDir, "edits")
        val store = EditStore(directory)
        store.save(identity, EditSettings(processing = ProcessingIdentity.C5))
        val owner = ViewModelStore()
        val armed = AtomicBoolean(false)
        val landed = CountDownLatch(1)
        val releaseWrite = CountDownLatch(1)
        val releaseFit = CountDownLatch(1)
        lateinit var model: EditorViewModel
        try {
            main {
                model = EditorViewModel(context.applicationContext as Application, editStoreFactory = { location ->
                    EditStore(location) { from, to ->
                        Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
                        if (armed.compareAndSet(true, false)) {
                            landed.countDown()
                            check(releaseWrite.await(30, TimeUnit.SECONDS))
                        }
                    }
                })
                owner.put("editor", model)
                model.setGpuEnabled(false)
            }
            val queue = field(model, "processingMigrationQueue") as SerialWorkQueue
            val entered = CountDownLatch(1)
            queue.submit({ entered.countDown(); check(releaseFit.await(30, TimeUnit.SECONDS)) }) {}
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            main { model.importPhoto(Uri.fromFile(source)) }
            await { model.state.value.matchingProcessing && model.state.value.exact }
            armed.set(true)
            releaseFit.countDown()
            assertTrue("atomic replacement happened before cancellation", landed.await(30, TimeUnit.SECONDS))
            val revision = field(model, "currentRevision")
            val preview = model.state.value.preview
            main {
                assertTrue(model.state.value.committingAdjustments)
                assertEquals(ProcessingIdentity.C5, model.state.value.edits.processing)
                model.onBackground()
            }
            releaseWrite.countDown()
            await { !model.state.value.committingAdjustments }
            main {
                val saved = store.readState(identity)
                assertEquals(ProcessingIdentity.CURRENT, saved.settings!!.processing)
                assertEquals("durable success must reach the current editor", saved.settings, model.state.value.edits)
                val history = field(model, "adjustmentHistory") as EditorAdjustmentHistory
                assertEquals(saved, history.loaded)
                assertTrue(history.session!!.isCurrentSave(saved))
                assertEquals(ProcessingMigrationStatus.MIGRATED, model.state.value.processingMigration?.status)
                assertNull(model.state.value.saveError)
                assertSame("inactive editor retains its existing frame until resuming", preview, model.state.value.preview)
                assertFalse(model.state.value.rendering)
                assertFalse("the old frame is not marked exact for the committed settings", model.state.value.exact)
            }
            main { model.setEditorActive(true) }
            await { model.state.value.canExport }
            assertNotEquals(revision, field(model, "currentRevision"))
            assertNotSame(preview, model.state.value.preview)
            lateinit var reopened: EditorViewModel
            main {
                reopened = EditorViewModel(context.applicationContext as Application)
                owner.put("reopened", reopened)
                reopened.setGpuEnabled(false)
                reopened.importPhoto(Uri.fromFile(source))
            }
            await { reopened.state.value.canExport }
            assertTrue("resumed pixels match a fresh open of the committed v3 record",
                model.state.value.preview!!.result.sameAs(reopened.state.value.preview!!.result))
            main { model.edit(model.state.value.edits.copy(exposure = .5f)) }
            await { model.state.value.canExport && model.state.value.edits.exposure == .5f }
            assertEquals(ProcessingIdentity.CURRENT, store.readState(identity).settings!!.processing)
            assertEquals(.5f, store.readState(identity).settings!!.exposure, 0f)
        } finally {
            releaseFit.countDown(); releaseWrite.countDown()
            main { owner.clear() }
            source.delete()
        }
    }

    @Test fun fullResetClearsInMemoryAndPersistedProcessingMigrationReceipt() {
        val source = File(context.cacheDir, "full-reset-migration-${UUID.randomUUID()}.png")
        Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let { bitmap ->
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
        val identity = PhotoIdentity(Uri.fromFile(source).toString())
        val store = EditStore(File(context.filesDir, "edits"))
        val quality = ProcessingMigrationQuality(.001f, .003f, .002f, .001f, 20)
        store.save(identity, EditSettings(exposure = .5f, saturation = .2f, processing = ProcessingIdentity.C5))
        store.commitProcessingMigration(store.readState(identity),
            EditSettings(exposure = .6f, saturation = .2f, processing = ProcessingIdentity.CURRENT), quality)
        val owner = ViewModelStore()
        lateinit var model: EditorViewModel
        try {
            main {
                model = EditorViewModel(context.applicationContext as Application)
                owner.put("editor", model)
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(source))
            }
            await { model.state.value.canExport }
            assertEquals(ProcessingMigrationStatus.MIGRATED, model.state.value.processingMigration?.status)
            main {
                val reset = requireNotNull(model.prepareReset(EditorResetScope.All).prepared)
                assertTrue(model.commitReset(reset))
            }
            await { model.state.value.canExport && model.state.value.edits.exposure == 0f && model.state.value.edits.saturation == 0f }
            assertNull("Reset All must clear EditorState.processingMigration in memory", model.state.value.processingMigration)
            assertNull("Reset All must clear persisted migration receipt", store.processingMigration(identity))
            val resetStored = requireNotNull(store.load(identity))
            assertEquals(ProcessingIdentity.CURRENT, resetStored.processing)
            assertEquals(model.state.value.edits, resetStored)
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                store.rollbackProcessingMigration(store.readState(identity))
            }
            lateinit var reopened: EditorViewModel
            main {
                reopened = EditorViewModel(context.applicationContext as Application)
                owner.put("reopened", reopened)
                reopened.setGpuEnabled(false)
                reopened.importPhoto(Uri.fromFile(source))
            }
            await { reopened.state.value.canExport }
            assertNull("Reopened ViewModel must still report null processingMigration", reopened.state.value.processingMigration)

            val undoDone = CountDownLatch(1)
            main { model.undoAdjustment { undoDone.countDown() } }
            assertTrue(undoDone.await(10, TimeUnit.SECONDS))
            await {
                model.state.value.canExport &&
                    model.state.value.edits.exposure == .6f &&
                    model.state.value.edits.saturation == .2f
            }
            assertNull("Undoing Reset All keeps EditorState.processingMigration null", model.state.value.processingMigration)
            assertNull("Undoing Reset All keeps persisted migration receipt null", store.processingMigration(identity))
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                store.rollbackProcessingMigration(store.readState(identity))
            }
        } finally {
            main { owner.clear() }
            store.reset(identity)
            source.delete()
        }
    }

    @Test fun partialResetPreservesProcessingMigrationReceiptInMemoryAndOnDisk() {
        val source = File(context.cacheDir, "partial-reset-migration-${UUID.randomUUID()}.png")
        Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let { bitmap ->
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
        val identity = PhotoIdentity(Uri.fromFile(source).toString())
        val store = EditStore(File(context.filesDir, "edits"))
        val quality = ProcessingMigrationQuality(.001f, .003f, .002f, .001f, 20)
        store.save(identity, EditSettings(exposure = .5f, saturation = .2f, processing = ProcessingIdentity.C5))
        store.commitProcessingMigration(store.readState(identity),
            EditSettings(exposure = .6f, saturation = .2f, processing = ProcessingIdentity.CURRENT), quality)
        val owner = ViewModelStore()
        lateinit var model: EditorViewModel
        try {
            main {
                model = EditorViewModel(context.applicationContext as Application)
                owner.put("editor", model)
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(source))
            }
            await { model.state.value.canExport }
            assertEquals(ProcessingMigrationStatus.MIGRATED, model.state.value.processingMigration?.status)
            main {
                val lightReset = requireNotNull(model.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.LIGHT)).prepared)
                assertTrue(model.commitReset(lightReset))
            }
            await { model.state.value.canExport && model.state.value.edits.exposure == 0f }
            assertEquals(.2f, model.state.value.edits.saturation, 0f)
            assertEquals(ProcessingMigrationStatus.MIGRATED, model.state.value.processingMigration?.status)
            assertEquals(ProcessingMigrationStatus.MIGRATED, store.processingMigration(identity)?.status)

            // Reset the remaining group via non-All scope so edits reach defaults without Reset All intent.
            main {
                val colorReset = requireNotNull(model.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.COLOR)).prepared)
                assertTrue(model.commitReset(colorReset))
            }
            await { model.state.value.canExport && model.state.value.edits.saturation == 0f }
            assertEquals("Non-All group reset must keep EditorState.processingMigration even at neutral values",
                ProcessingMigrationStatus.MIGRATED, model.state.value.processingMigration?.status)
            assertEquals(ProcessingMigrationStatus.MIGRATED, store.processingMigration(identity)?.status)
        } finally {
            main { owner.clear() }
            store.reset(identity)
            source.delete()
        }
    }

    @Test fun discardingFailedFullResetDoesNotLeakClearIntentToSubsequentPartialReset() {
        val source = File(context.cacheDir, "discard-failed-reset-${UUID.randomUUID()}.png")
        Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let { bitmap ->
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
        val identity = PhotoIdentity(Uri.fromFile(source).toString())
        val store = EditStore(File(context.filesDir, "edits"))
        val quality = ProcessingMigrationQuality(.001f, .003f, .002f, .001f, 20)
        store.save(identity, EditSettings(exposure = .5f, processing = ProcessingIdentity.C5))
        store.commitProcessingMigration(store.readState(identity),
            EditSettings(exposure = .6f, processing = ProcessingIdentity.CURRENT), quality)
        val owner = ViewModelStore()
        val failWrites = AtomicBoolean(false)
        lateinit var model: EditorViewModel
        try {
            main {
                model = EditorViewModel(context.applicationContext as Application, editStoreFactory = { location ->
                    EditStore(location) { from, to ->
                        if (failWrites.get()) throw IOException("injected reset write failure")
                        Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
                    }
                })
                owner.put("editor", model)
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(source))
            }
            await { model.state.value.canExport }
            assertEquals(ProcessingMigrationStatus.MIGRATED, model.state.value.processingMigration?.status)

            failWrites.set(true)
            main {
                val fullReset = requireNotNull(model.prepareReset(EditorResetScope.All).prepared)
                assertTrue(model.commitReset(fullReset))
            }
            await {
                model.state.value.exact && !model.state.value.rendering &&
                    !model.state.value.committingAdjustments && model.state.value.saveState == EditSaveState.FAILED
            }
            assertEquals(ProcessingMigrationStatus.MIGRATED, model.state.value.processingMigration?.status)
            assertEquals(ProcessingMigrationStatus.MIGRATED, store.processingMigration(identity)?.status)

            val discardDone = CountDownLatch(1)
            val discarded = AtomicBoolean(false)
            main { model.resolveCollectionDraft(false) { discarded.set(it); discardDone.countDown() } }
            assertTrue(discardDone.await(10, TimeUnit.SECONDS))
            assertTrue(discarded.get())
            await { model.state.value.canExport && model.state.value.edits.exposure == .6f }
            assertNull("Discarding unsaved changes must clear pendingResetMigrationClear",
                field(model, "pendingResetMigrationClear"))

            failWrites.set(false)
            main {
                val partialReset = requireNotNull(model.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.LIGHT)).prepared)
                assertTrue(model.commitReset(partialReset))
            }
            await { model.state.value.canExport && model.state.value.edits.exposure == 0f }
            assertEquals("Subsequent partial reset after failed-reset discard must keep in-memory receipt",
                ProcessingMigrationStatus.MIGRATED, model.state.value.processingMigration?.status)
            assertEquals("Subsequent partial reset after failed-reset discard must keep persisted receipt",
                ProcessingMigrationStatus.MIGRATED, store.processingMigration(identity)?.status)
        } finally {
            failWrites.set(false)
            main { owner.clear() }
            store.reset(identity)
            source.delete()
        }
    }

    @Test fun discardingFailedSaveWhenEditsMatchSavedRecordClearsFailedState() {
        val source = File(context.cacheDir, "discard-unchanged-failed-save-${UUID.randomUUID()}.png")
        val backup = File(context.cacheDir, "discard-unchanged-failed-save-${UUID.randomUUID()}.bak")
        Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let { bitmap ->
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
        val identity = PhotoIdentity(Uri.fromFile(source).toString())
        val store = EditStore(File(context.filesDir, "edits"))
        val owner = ViewModelStore()
        lateinit var model: EditorViewModel
        try {
            main {
                model = EditorViewModel(context.applicationContext as Application)
                owner.put("editor", model)
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(source))
            }
            await { model.state.value.canExport }
            assertEquals(EditSaveState.NONE, model.state.value.saveState)

            // 1) Unsaved/default record (loaded.settings == null): failed pre-export persist keeps edits == restored;
            //    resolveCollectionDraft(false) must reset FAILED -> NONE and clear saveError.
            val importedFile = requireNotNull(model.state.value.photo).file
            Files.move(importedFile.toPath(), backup.toPath(), StandardCopyOption.REPLACE_EXISTING)
            val exportFailedNone = CountDownLatch(1)
            val exportResultNone = AtomicBoolean(true)
            main { model.beginExport { exportResultNone.set(it); exportFailedNone.countDown() } }
            assertTrue(exportFailedNone.await(10, TimeUnit.SECONDS))
            assertFalse(exportResultNone.get())
            assertEquals(EditSaveState.FAILED, model.state.value.saveState)
            assertNotNull(model.state.value.saveError)
            Files.move(backup.toPath(), importedFile.toPath(), StandardCopyOption.REPLACE_EXISTING)

            val revBeforeNoneDiscard = model.state.value.adjustmentRevision
            val discardNoneDone = CountDownLatch(1)
            val discardNoneAccepted = AtomicBoolean(false)
            main { model.resolveCollectionDraft(false) { discardNoneAccepted.set(it); discardNoneDone.countDown() } }
            assertTrue(discardNoneDone.await(10, TimeUnit.SECONDS))
            assertTrue(discardNoneAccepted.get())
            assertEquals(EditSaveState.NONE, model.state.value.saveState)
            assertNull(model.state.value.saveError)
            assertEquals(revBeforeNoneDiscard + 1, model.state.value.adjustmentRevision)

            // 2) Non-null saved record (loaded.settings != null): failed pre-export persist keeps edits == restored;
            //    resolveCollectionDraft(false) must reset FAILED -> SAVED and clear saveError.
            main { model.edit(model.state.value.edits.copy(exposure = .5f)) }
            await { model.state.value.canExport && model.state.value.edits.exposure == .5f && model.state.value.saveState == EditSaveState.SAVED }

            Files.move(importedFile.toPath(), backup.toPath(), StandardCopyOption.REPLACE_EXISTING)
            val exportFailedSaved = CountDownLatch(1)
            val exportResultSaved = AtomicBoolean(true)
            main { model.beginExport { exportResultSaved.set(it); exportFailedSaved.countDown() } }
            assertTrue(exportFailedSaved.await(10, TimeUnit.SECONDS))
            assertFalse(exportResultSaved.get())
            assertEquals(EditSaveState.FAILED, model.state.value.saveState)
            assertNotNull(model.state.value.saveError)
            Files.move(backup.toPath(), importedFile.toPath(), StandardCopyOption.REPLACE_EXISTING)

            val revBeforeSavedDiscard = model.state.value.adjustmentRevision
            val discardSavedDone = CountDownLatch(1)
            val discardSavedAccepted = AtomicBoolean(false)
            main { model.resolveCollectionDraft(false) { discardSavedAccepted.set(it); discardSavedDone.countDown() } }
            assertTrue(discardSavedDone.await(10, TimeUnit.SECONDS))
            assertTrue(discardSavedAccepted.get())
            assertEquals(.5f, model.state.value.edits.exposure, 0f)
            assertEquals(EditSaveState.SAVED, model.state.value.saveState)
            assertNull(model.state.value.saveError)
            assertEquals(revBeforeSavedDiscard + 1, model.state.value.adjustmentRevision)
        } finally {
            if (backup.exists() && !source.exists()) {
                runCatching { Files.move(backup.toPath(), source.toPath(), StandardCopyOption.REPLACE_EXISTING) }
            }
            backup.delete()
            main { owner.clear() }
            store.reset(identity)
            source.delete()
        }
    }
}
