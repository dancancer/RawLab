package com.rawlab.android.editor

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.adjustments.*
import com.rawlab.android.editor.render.RenderQueue
import com.rawlab.android.editor.render.SerialWorkQueue
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.settings.EditStore
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
class EditorAsyncOperationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private fun main(work: () -> Unit) = instrumentation.runOnMainSync(work)
    private fun await(timeout: Long = 30_000, condition: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + timeout
        while (!condition() && SystemClock.elapsedRealtime() < until) SystemClock.sleep(20)
        assertTrue("operation did not finish", condition())
    }
    private fun ready(model: EditorViewModel) = await { model.state.value.canExport }
    private fun fixture(): File = File(context.cacheDir, "async-${UUID.randomUUID()}.png").also { file ->
        Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let {
            file.outputStream().use { stream -> it.compress(Bitmap.CompressFormat.PNG, 100, stream) }; it.recycle()
        }
    }
    private fun field(model: EditorViewModel, name: String) = EditorViewModel::class.java.getDeclaredField(name).apply { isAccessible = true }.get(model)
    private fun queue(model: EditorViewModel) = field(model, "adjustmentQueue") as SerialWorkQueue
    private fun block(queue: SerialWorkQueue): CountDownLatch {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        queue.submit({ entered.countDown(); check(release.await(30, TimeUnit.SECONDS)) }) {}
        assertTrue(entered.await(5, TimeUnit.SECONDS)); return release
    }
    @Test fun resetSaveFailureSurvivesLatePreview() {
        val source = fixture(); val owner = ViewModelStore(); val fail = AtomicBoolean(false)
        val renderRelease = CountDownLatch(1)
        try {
            lateinit var model: EditorViewModel
            main {
                model = EditorViewModel(context.applicationContext as Application, editStoreFactory = { directory ->
                    EditStore(directory) { from, to ->
                        if (fail.get()) error("injected reset save failure")
                        Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
                    }
                }); owner.put("editor", model); model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source))
            }
            ready(model)
            main { model.edit(model.state.value.edits.copy(exposure = .5f)) }; ready(model)
            assertEquals(EditSaveState.SAVED, model.state.value.saveState)
            @Suppress("UNCHECKED_CAST") val render = field(model, "queue") as RenderQueue<Work, WorkResult>
            val entered = CountDownLatch(1)
            render.performAfterPending { entered.countDown(); check(renderRelease.await(30, TimeUnit.SECONDS)) }
            assertTrue(entered.await(5, TimeUnit.SECONDS)); fail.set(true)
            main { assertTrue(model.commitReset(model.prepareReset(EditorResetScope.Tool(2)).prepared!!)) }
            await { !model.state.value.committingAdjustments }
            assertEquals(EditSaveState.FAILED, model.state.value.saveState)
            renderRelease.countDown(); await { !model.state.value.rendering }
            assertEquals(EditSaveState.FAILED, model.state.value.saveState)
        } finally { renderRelease.countDown(); main { owner.clear() }; source.delete() }
    }
    @Test fun blockedPreflightDoesNotBlockSavingAndCloseCancelsItsTargets() {
        val source = fixture(); val target = fixture(); val owner = ViewModelStore()
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        try {
            lateinit var model: EditorViewModel
            main { model = EditorViewModel(context.applicationContext as Application); owner.put("editor", model)
                model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            ready(model)
            lateinit var payload: AdjustmentPayload
            main { payload = model.copyAdjustments(AdjustmentScope.All)!! }
            val blocker = Thread { synchronized(model.storage) { entered.countDown(); release.await(90, TimeUnit.SECONDS) } }.apply { start() }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val root = model.state.value.photo!!.file.parentFile!!
            val before = root.listFiles()!!.toSet()
            main { model.prepareAdjustmentPaste(payload, listOf(Uri.fromFile(target))); model.edit(model.state.value.edits.copy(exposure = .75f)) }
            await(5000) { !model.state.value.committingAdjustments }
            assertEquals(EditSaveState.SAVED, model.state.value.saveState)
            main { model.closeAdjustmentOperation() }
            release.countDown(); blocker.join(5000)
            // Drain the queue that owns preparation, then the UI callbacks.
            val preparation = runCatching { field(model, "adjustmentPreparationQueue") as SerialWorkQueue }.getOrElse { queue(model) }
            val drained = CountDownLatch(1); preparation.submit({}) { drained.countDown() }
            assertTrue(drained.await(10, TimeUnit.SECONDS)); main {}
            assertNull(model.adjustmentTransfer.value.prepared)
            assertFalse(model.adjustmentTransfer.value.preparing)
            assertEquals(before, root.listFiles()!!.toSet())
        } finally { release.countDown(); main { owner.clear() }; source.delete(); target.delete() }
    }
    @Test fun lookImportWaitsForBusyCommitAndThenSavesAndRenders() {
        val source = fixture(); val owner = ViewModelStore()
        val look = File(context.cacheDir, "busy-${UUID.randomUUID()}.cube").apply {
            writeText("#Gamma:F-Log2 to Synthetic Look\n#Gamut:F-Gamut to ITU-R BT.709\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
        }
        var release: CountDownLatch? = null
        try {
            lateinit var model: EditorViewModel
            main { model = EditorViewModel(context.applicationContext as Application); owner.put("editor", model)
                model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready(model)
            release = block(queue(model))
            main { model.edit(model.state.value.edits.copy(exposure = .3f)); model.importLook(Uri.fromFile(look)) }
            val lookQueue = field(model, "lookQueue") as RenderQueue<*, *>
            val loaded = CountDownLatch(1); lookQueue.performAfterPending { loaded.countDown() }
            assertTrue(loaded.await(10, TimeUnit.SECONDS)); main {}
            release.countDown()
            try { await { model.state.value.canExport && model.state.value.edits.film != "neutral" } }
            catch (error: AssertionError) { throw AssertionError("look state: " + model.state.value.copy(preview=null), error) }
            val state = model.state.value
            assertNull(state.error)
            assertEquals(EditSaveState.SAVED, state.saveState)
            assertEquals(state.edits.film, EditStore(File(context.filesDir, "edits")).load(state.photo!!.identity)!!.film)
        } finally { release?.countDown(); main { owner.clear() }; source.delete(); look.delete() }
    }
    @Test fun collectionRemovalDefersDeletionUntilCommitStopsUsingCopies() {
        val source = fixture(); val target = fixture(); val owner = ViewModelStore()
        var release: CountDownLatch? = null
        try {
            lateinit var model: EditorViewModel
            main { model = EditorViewModel(context.applicationContext as Application); owner.put("editor", model)
                model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready(model)
            val collection = field(model, "collections") as EditorCollections
            main { collection.add(listOf(Uri.fromFile(target))) }
            await { !collection.state.value.busy }
            val imported = collection.photo(Uri.fromFile(target).toString())!!.file
            release = block(queue(model))
            main { model.edit(model.state.value.edits.copy(exposure = .4f)); collection.remove(Uri.fromFile(target).toString()) }
            assertTrue(imported.exists())
            release.countDown(); await { !model.state.value.committingAdjustments }
            assertFalse("retired collection copy must be released after the commit", imported.exists())
        } finally { release?.countDown(); main { owner.clear() }; source.delete(); target.delete() }
    }
    @Test fun cancelledPreflightStopsBetweenTargetsAndDeletesItsImportedCopy() {
        val source = fixture(); val first = fixture(); val second = fixture(); val owner = ViewModelStore()
        try {
            lateinit var model: EditorViewModel
            main { model = EditorViewModel(context.applicationContext as Application); owner.put("editor", model)
                model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready(model)
            lateinit var payload: AdjustmentPayload
            main { payload = model.copyAdjustments(AdjustmentScope.All)!! }
            val root = model.state.value.photo!!.file.parentFile!!
            val before = root.listFiles()!!.toSet()
            var checkedTargets = 0
            val work = AdjustmentPreparationWork(UUID.randomUUID(), payload, listOf(Uri.fromFile(first), Uri.fromFile(second)),
                model.state.value.photo, { true }, validateCollection = { checkedTargets++ })
            val preparation = EditorAdjustmentPreparation(context, model.storage,
                field(model, "editStore") as com.rawlab.android.editor.storage.EditorEditStore)
            val result = runCatching { preparation.prepare(work) { checkedTargets > 0 } }
            assertTrue(result.exceptionOrNull() is java.util.concurrent.CancellationException)
            assertEquals(1, checkedTargets)
            assertEquals(before, root.listFiles()!!.toSet())
        } finally { main { owner.clear() }; source.delete(); first.delete(); second.delete() }
    }
    @Test fun busyPasteReportsFailureAndClosedCommitReleasesOwnedCopy() {
        val source = fixture(); val target = fixture(); val owner = ViewModelStore()
        var release: CountDownLatch? = null
        try {
            lateinit var model: EditorViewModel
            main { model = EditorViewModel(context.applicationContext as Application); owner.put("editor", model)
                model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready(model)
            main { model.edit(model.state.value.edits.copy(exposure = .6f)) }; ready(model)
            main { model.prepareAdjustmentPaste(model.copyAdjustments(AdjustmentScope.All)!!, listOf(Uri.fromFile(target))) }
            await { model.adjustmentTransfer.value.prepared != null }
            val prepared = model.adjustmentTransfer.value.prepared!!
            @Suppress("UNCHECKED_CAST") val owned = (field(model, "adjustmentOwnedFiles") as Map<String, File>).values.toList()
            assertEquals(1, owned.size); assertTrue(owned.single().exists())
            release = block(queue(model))
            var calls = 0
            main {
                model.edit(model.state.value.edits.copy(exposure = .8f))
                model.applyAdjustmentPaste(prepared) { calls++; assertTrue(it.all { result -> result.status == AdjustmentStatus.FAILED }) }
            }
            assertEquals("busy operation must complete its callback", 1, calls)
            release.countDown(); ready(model)
            release = block(queue(model))
            main { model.applyAdjustmentPaste(prepared); model.closeAdjustmentOperation() }
            assertTrue("copy must stay alive until commit completes", owned.single().exists())
            release.countDown(); await { !model.state.value.committingAdjustments }
            assertFalse("closed operation must release its copy", owned.single().exists())
            assertNull(model.adjustmentTransfer.value.prepared)
        } finally { release?.countDown(); main { owner.clear() }; source.delete(); target.delete() }
    }
}
