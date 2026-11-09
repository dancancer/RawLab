package com.rawlab.android.editor

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.editor.render.SerialWorkQueue
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.ProcessingIdentity
import com.rawlab.android.settings.ProcessingMigrationStatus
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
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
}
