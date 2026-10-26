package com.rawlab.android.editor

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.adjustments.AdjustmentStatus
import com.rawlab.android.adjustments.AdjustmentField
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.adjustments.AdjustmentTransferSession
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.Properties
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

@RunWith(AndroidJUnit4::class)
class AdjustmentHistoryInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun <T> result(action: ((T) -> Unit) -> Unit): T {
        val latch = java.util.concurrent.CountDownLatch(1)
        var answer: T? = null
        main { action { answer = it; latch.countDown() } }
        assertTrue("Background adjustment did not finish", latch.await(60, java.util.concurrent.TimeUnit.SECONDS))
        return answer!!
    }
    private fun paste(model: EditorViewModel, operation: com.rawlab.android.adjustments.PreparedAdjustmentTransfer) =
        result<List<com.rawlab.android.adjustments.AdjustmentOutcome>> { model.applyAdjustmentPaste(operation, completed = it) }
    private fun undo(model: EditorViewModel) = result<List<com.rawlab.android.adjustments.AdjustmentOutcome>> { model.undoAdjustment(it) }
    private fun history(model: EditorViewModel, undo: Boolean, id: UUID) =
        result<List<com.rawlab.android.adjustments.AdjustmentOutcome>> { model.performAdjustmentHistory(undo, id, true, completed = it) }
    private fun await(model: EditorViewModel, predicate: (EditorState) -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 60_000
        while (SystemClock.uptimeMillis() < deadline) {
            if (predicate(model.state.value)) return
            SystemClock.sleep(30)
        }
        fail("Editor did not reach expected state: ${model.state.value}")
    }
    private fun png(file: File) {
        val image = Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888)
        image.eraseColor(0xff4a799b.toInt())
        file.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }; image.recycle()
    }
    private inline fun withModel(raw: Boolean = false, noinline storeFactory: (File) -> EditStore = { EditStore(it) },
        block: (EditorViewModel, EditStore, PhotoIdentity) -> Unit) {
        val root = File(context.cacheDir, "adjustment-history-${UUID.randomUUID()}").apply { mkdirs() }
        val source = File(root, if (raw) "source.ARW" else "source.png")
        if (raw) instrumentation.context.assets.open("sample.RAW").use { input -> source.outputStream().use(input::copyTo) }
        else png(source)
        val owner = ViewModelStore()
        lateinit var model: EditorViewModel
        val edits = EditStore(File(context.filesDir, "edits"))
        val identity = PhotoIdentity(Uri.fromFile(source).toString())
        try {
            main { model = EditorViewModel(context.applicationContext as Application, editStoreFactory = storeFactory); owner.put("editor", model)
                model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            await(model) { it.canExport }
            block(model, edits, identity)
        } finally { main { owner.clear() }; edits.reset(identity); root.deleteRecursively() }
    }

    @Test fun defaultScopeReceiptUndoAndRedoStayOffMainThreadAndCanonical() = withModel { model, edits, identity ->
        main { model.edit(model.state.value.edits.copy(exposure = .75f)) }; await(model) { it.canExport }
        main { model.copyAdjustments(AdjustmentScope.Custom(AdjustmentField.entries.filter { it.group != "geometry" }.toSet())) }
        main { model.edit(model.state.value.edits.copy(exposure = .25f)) }; await(model) { it.canExport }
        main { model.prepareAdjustmentPaste(model.adjustmentClipboard!!, listOf(model.state.value.photo!!.uri)) }
        val deadline = SystemClock.uptimeMillis() + 60_000
        while (model.adjustmentTransfer.value.preparing && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(20)
        val prepared = requireNotNull(model.adjustmentTransfer.value.prepared)
        val violations = java.util.Collections.synchronizedList(mutableListOf<String>())
        lateinit var old: android.os.StrictMode.ThreadPolicy
        main {
            old = android.os.StrictMode.getThreadPolicy()
            android.os.StrictMode.setThreadPolicy(android.os.StrictMode.ThreadPolicy.Builder().detectDiskReads().detectDiskWrites()
                .penaltyListener(java.util.concurrent.Executor { it.run() }) { violations += it.toString() }.build())
        }
        try {
            assertEquals(AdjustmentStatus.APPLIED, paste(model, prepared).single().status)
            await(model) { it.canExport && it.edits.exposure == .75f }
            assertEquals(AdjustmentStatus.APPLIED, undo(model).single().status)
            await(model) { it.canExport && it.edits.exposure == .25f }
            result<List<com.rawlab.android.adjustments.AdjustmentOutcome>> { model.redoAdjustment(it) }
            await(model) { it.canExport && it.edits.exposure == .75f }
            val captured = result<Result<AdjustmentPayload>> { model.capturePresetAdjustments(AdjustmentScope.All, it) }
            assertTrue(captured.isSuccess)
        } finally { main { android.os.StrictMode.setThreadPolicy(old) } }
        assertTrue("Disk access on editor main thread: $violations", violations.isEmpty())
        assertEquals(model.state.value.edits, edits.versionedState(identity).settings)
        assertEquals(0, model.state.value.edits.highlights.toRawBits())
    }

    @Test fun switchingEditedPhotosReleasesOldWorkingCopiesButKeepsHistory() = withModel { model, _, firstID ->
        val first = model.state.value.photo!!.uri
        val second = File(context.cacheDir, "switch-target-${UUID.randomUUID()}.png").also(::png)
        try {
            repeat(3) { round ->
                main { model.edit(model.state.value.edits.copy(exposure = .25f + round * .1f)) }; await(model) { it.canExport }
                val old = model.state.value.photo!!.file
                val next = if (model.state.value.photo!!.identity == firstID) Uri.fromFile(second) else first
                main { model.importPhoto(next) }; await(model) { it.canExport && it.photo!!.uri == next }
                assertFalse("Previously edited working copy retained", old.exists())
                assertEquals(1, model.state.value.photo!!.file.parentFile!!.listFiles()!!.count { it.extension == "input" })
            }
            main { model.importPhoto(first) }; await(model) { it.canExport && it.photo!!.uri == first }
            assertEquals(AdjustmentStatus.APPLIED, undo(model).single().status)
            await(model) { it.canExport }
        } finally { second.delete(); EditStore(File(context.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(second).toString())) }
    }

    @Test fun batchEntryReleasesDecodedRasterAndReturningEditorRebuildsIt() = withModel { model, _, _ ->
        val source = File(context.cacheDir, "large-batch-${UUID.randomUUID()}.png")
        val generated = Bitmap.createBitmap(4096, 4096, Bitmap.Config.ARGB_8888)
        generated.eraseColor(0xff4a799b.toInt())
        source.outputStream().use { generated.compress(Bitmap.CompressFormat.PNG, 100, it) }; generated.recycle()
        try {
            main { model.importPhoto(Uri.fromFile(source)) }; await(model) { it.canExport && it.photo!!.uri == Uri.fromFile(source) }
            val renderer = EditorViewModel::class.java.getDeclaredField("renderer").apply { isAccessible = true }.get(model)
            val processorField = renderer.javaClass.getDeclaredField("processor").apply { isAccessible = true }
            fun cachedBitmap(): Bitmap {
                val processor = processorField.get(renderer)!!
                val decoded = processor.javaClass.getDeclaredField("raster").apply { isAccessible = true }.get(processor) as com.rawlab.android.raster.DecodedRaster
                return decoded.bitmap
            }
            val decoded = cachedBitmap()
            val decodedBytes = decoded.allocationByteCount
            val before = android.os.Debug.getNativeHeapAllocatedSize()
            main { model.beginBatch() }
            val deadline = SystemClock.uptimeMillis() + 60_000
            while (model.batch.value == null && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(20)
            assertNotNull(model.batch.value)
            val after = android.os.Debug.getNativeHeapAllocatedSize()
            println("RASTER_CACHE bytes=$decodedBytes native_before=$before native_after=$after")
            assertTrue("Batch entry retains the editor's full decoded raster", decoded.isRecycled)
            main { model.closeBatch(); model.edit(model.state.value.edits.copy(exposure = .2f)) }
            await(model) { it.canExport && it.edits.exposure == .2f }
            assertFalse(cachedBitmap().isRecycled)
            assertNotSame(decoded, cachedBitmap())
        } finally { source.delete() }
    }

    @Test fun dragIsOneDurableEditAndCancellationRestoresBeforeState() = withModel { model, edits, identity ->
        assertNull(edits.load(identity))
        main {
            repeat(20) { model.edit(model.state.value.edits.copy(exposure = (it + 1) / 20f), interactive = true) }
            assertNull(edits.load(identity)); assertTrue(model.adjustmentTransactions.isEmpty())
            model.edit(model.state.value.edits)
        }
        await(model) { it.canExport }
        assertEquals(1, model.adjustmentTransactions.size)
        val receipt = edits.versionedState(identity)
        assertEquals(1f, receipt.settings!!.exposure)
        main { model.updatePreviewSize(512) }
        await(model) { it.canExport && maxOf(it.preview!!.result.width, it.preview.result.height) <= 512 }
        assertEquals(receipt, edits.versionedState(identity))
        assertEquals(AdjustmentStatus.APPLIED, undo(model).single().status)
        await(model) { it.canExport && it.edits.exposure == 0f }
        assertNull(edits.load(identity))
        main { model.redoAdjustment() }
        await(model) { it.canExport && it.edits.exposure == 1f }
        val beforeCancel = edits.versionedState(identity)
        main {
            model.edit(model.state.value.edits.copy(exposure = 2f), interactive = true)
            model.cancelAdjustmentInteraction()
        }
        await(model) { it.canExport && it.edits.exposure == 1f }
        assertEquals(beforeCancel, edits.versionedState(identity)); assertEquals(1, model.adjustmentTransactions.size)
    }

    @Test fun targetSampleReleaseMakesOneHistoryAndResizeCancelsPendingSample() = withModel { model, edits, identity ->
        main {
            model.setHslTargetEnabled(true)
            model.beginHslTarget(.5f, .5f)
            assertTrue(model.hslTarget.value.waiting)
            model.moveHslTarget(20f)
            model.endHslTarget()
        }
        await(model) { !model.hslTarget.value.waiting && it.canExport && !it.edits.hsl.isIdentity }
        assertEquals(1, model.adjustmentTransactions.size)
        val saved = edits.versionedState(identity)
        main {
            model.beginHslTarget(.5f, .5f)
            model.moveHslTarget(40f)
            model.cancelHslTarget()
            model.endHslTarget()
        }
        await(model) { !it.rendering }
        assertEquals(saved, edits.versionedState(identity))
        main {
            model.beginHslTarget(.5f, .5f)
            assertTrue(model.hslTarget.value.waiting)
            model.updatePreviewSize(64)
            assertFalse(model.hslTarget.value.waiting)
        }
        await(model) { it.canExport && maxOf(it.preview!!.result.width, it.preview.result.height) <= 64 }
        assertFalse(model.hslTarget.value.waiting)
        assertEquals(saved, edits.versionedState(identity))
        assertEquals(1, model.adjustmentTransactions.size)
        main {
            model.beginHslTarget(.5f, .5f)
            model.retry()
            assertFalse(model.hslTarget.value.waiting)
        }
        await(model) { it.canExport }
        assertEquals(saved, edits.versionedState(identity))
    }

    @Test fun externalRecordConflictNeedsExplicitReloadAndNeverOverwritesExternalEdit() = withModel { model, edits, identity ->
        main { model.edit(model.state.value.edits.copy(exposure = .5f)) }
        await(model) { it.canExport }
        val count = model.adjustmentTransactions.size
        edits.save(identity, edits.load(identity)!!.copy(exposure = 1.5f))
        main { model.edit(model.state.value.edits.copy(exposure = .75f)) }
        await(model) { !it.rendering }
        assertEquals(EditSaveState.FAILED, model.state.value.saveState)
        assertTrue(model.adjustmentReloadRequired)
        assertEquals(1.5f, edits.load(identity)!!.exposure)
        assertEquals(count, model.adjustmentTransactions.size)
        main { model.reloadSavedAdjustments { assertTrue(it) } }
        await(model) { it.canExport && it.edits.exposure == 1.5f }
        main { model.edit(model.state.value.edits.copy(exposure = .75f)) }
        await(model) { it.canExport }
        assertEquals(.75f, edits.load(identity)!!.exposure)
        assertEquals(count + 1, model.adjustmentTransactions.size)
    }

    @Test fun realRawCalibrationAndNavigationDoNotCreateFalseEdits() = withModel(raw = true) { model, edits, identity ->
        assertTrue(model.state.value.preview!!.temperature.isFinite())
        assertNull(edits.load(identity)); assertTrue(model.adjustmentTransactions.isEmpty())
        main { model.edit(model.state.value.edits) }
        await(model) { it.canExport }
        main { model.beginExport { assertTrue(it); model.cancelExport() } }
        await(model) { it.canExport }
        assertNull(edits.load(identity)); assertTrue(model.adjustmentTransactions.isEmpty())
        main { model.edit(model.state.value.edits.copy(exposure = .5f)) }
        await(model) { it.canExport }
        assertEquals(1, model.adjustmentTransactions.size)
        main { model.undoAdjustment() }
        await(model) { it.canExport && it.edits.exposure == 0f }
        assertNull(edits.load(identity)); assertEquals(1, model.adjustmentTransactions.size)
    }

    @Test fun replacingOriginalSourceBlocksEditsEvenWhenWorkingCopyIsUnchanged() = withModel { model, edits, identity ->
        val photo = model.state.value.photo!!
        val working = photo.file.readBytes()
        val original = File(photo.uri.path!!)
        val replacement = File(original.parentFile, "replacement.png")
        png(replacement)
        Files.move(replacement.toPath(), original.toPath(), StandardCopyOption.REPLACE_EXISTING)
        main { model.edit(model.state.value.edits.copy(exposure = .5f)) }
        await(model) { !it.rendering }
        assertArrayEquals(working, photo.file.readBytes())
        assertEquals(EditSaveState.FAILED, model.state.value.saveState)
        assertNull(edits.load(identity)); assertTrue(model.adjustmentTransactions.isEmpty())
    }

    @Test fun closingPreflightReleasesUncommittedTargetCopies() = withModel { model, _, _ ->
        val target = File(context.cacheDir, "discard-preflight-${UUID.randomUUID()}.png"); png(target)
        try {
            main { model.edit(model.state.value.edits.copy(exposure = .5f)) }; await(model) { it.canExport }
            main { model.copyAdjustments(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE))) }
            val directory = model.state.value.photo!!.file.parentFile!!
            val before = directory.listFiles()!!.map { it.name }.toSet()
            main { model.prepareAdjustmentPaste(model.adjustmentClipboard!!, listOf(Uri.fromFile(target))) }
            val deadline = SystemClock.uptimeMillis() + 30_000
            while (model.adjustmentTransfer.value.preparing && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(30)
            assertNotNull(model.adjustmentTransfer.value.prepared)
            assertTrue(directory.listFiles()!!.any { it.name !in before })
            main { model.closeAdjustmentOperation() }
            assertEquals(before, directory.listFiles()!!.map { it.name }.toSet())
        } finally { target.delete() }
    }

    @Test fun originalReplacementAlsoBlocksPreparedPasteAndHistory() = withModel { model, edits, identity ->
        main { model.edit(model.state.value.edits.copy(exposure = .5f)) }; await(model) { it.canExport }
        main { model.copyAdjustments(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE))) }
        main { model.edit(model.state.value.edits.copy(exposure = .9f)) }; await(model) { it.canExport }
        main { model.prepareAdjustmentPaste(model.adjustmentClipboard!!, listOf(model.state.value.photo!!.uri)) }
        val deadline = SystemClock.uptimeMillis() + 30_000
        while (model.adjustmentTransfer.value.preparing && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(30)
        val operation = requireNotNull(model.adjustmentTransfer.value.prepared)
        val before = edits.versionedState(identity)
        val original = File(model.state.value.photo!!.uri.path!!)
        val replacement = File(original.parentFile, "replacement-history.png"); png(replacement)
        Files.move(replacement.toPath(), original.toPath(), StandardCopyOption.REPLACE_EXISTING)
        assertEquals(AdjustmentStatus.CONFLICT, paste(model, operation).single().status)
        assertEquals(AdjustmentStatus.CONFLICT, undo(model).single().status)
        assertEquals(before, edits.versionedState(identity))
    }

    @Test fun externalChangeAfterSaveReceiptRequiresReloadBeforeUIAcceptsSuccess() = withModel { model, edits, identity ->
        main { model.edit(model.state.value.edits.copy(exposure = .5f)) }; await(model) { it.canExport }
        main { model.copyAdjustments(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE))) }
        main { model.edit(model.state.value.edits.copy(exposure = .9f)) }; await(model) { it.canExport }
        main { model.prepareAdjustmentPaste(model.adjustmentClipboard!!, listOf(model.state.value.photo!!.uri)) }
        val deadline = SystemClock.uptimeMillis() + 30_000
        while (model.adjustmentTransfer.value.preparing && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(30)
        val operation = requireNotNull(model.adjustmentTransfer.value.prepared)
        val results = AdjustmentTransferSession(edits).apply(operation)
        assertEquals(AdjustmentStatus.APPLIED, results.single().status)
        edits.save(identity, edits.load(identity)!!.copy(exposure = 1.5f))
        main {
            model.acceptAdjustmentOutcomes(results)
            assertTrue(model.adjustmentReloadRequired)
            assertEquals(EditSaveState.FAILED, model.state.value.saveState)
            model.reloadSavedAdjustments { assertTrue(it) }
        }
        await(model) { it.canExport && it.edits.exposure == 1.5f }
    }

    @Test fun nativeTargetPreflightAndPartialRetryShareSinglePhotoAndBatchHistory() {
        val second = File(context.cacheDir, "adjustment-target-${UUID.randomUUID()}.png"); png(second)
        val secondURI = Uri.fromFile(second); val secondID = PhotoIdentity(secondURI.toString())
        var failSecond = true
        val encoded = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(secondID.value.toByteArray())
        val factory: (File) -> EditStore = { directory -> EditStore(directory) { from, to ->
            val values = Properties().also { from.inputStream().use(it::load) }.getProperty("record.$encoded.values")
            if (failSecond && values?.let { com.rawlab.android.settings.StructuredSettingsCodec.decode(it, "photo_edit").exposure } == .5f) throw IOException("injected target B replacement failure")
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
        } }
        try {
            withModel(storeFactory = factory) { model, edits, firstID ->
                main { model.edit(model.state.value.edits.copy(exposure = .5f)) }
                await(model) { it.canExport }
                main { assertNotNull(model.copyAdjustments(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE)))) }
                val frozen = model.adjustmentClipboard!!
                main { model.edit(model.state.value.edits.copy(exposure = .9f)) }
                await(model) { it.canExport }
                edits.save(secondID, EditSettings(exposure = -.2f, geometry = GeometrySettings(cropWidth = .6f)))
                main { model.prepareAdjustmentPaste(frozen, listOf(model.state.value.photo!!.uri, secondURI)) }
                val deadline = SystemClock.uptimeMillis() + 30_000
                while (model.adjustmentTransfer.value.preparing && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(30)
                val operation = requireNotNull(model.adjustmentTransfer.value.prepared)
                assertTrue(operation.targets.all { it.error == null })
                assertEquals(listOf(AdjustmentStatus.APPLIED, AdjustmentStatus.FAILED), paste(model, operation).map { it.status })
                await(model) { it.canExport && it.edits.exposure == .5f }
                main { model.undoAdjustment() }
                await(model) { it.canExport && it.edits.exposure == .9f }
                val receipt = edits.versionedState(firstID)
                failSecond = false
                assertTrue(paste(model, operation).all { it.status == AdjustmentStatus.APPLIED })
                assertEquals(receipt, edits.versionedState(firstID)); assertEquals(.9f, model.state.value.edits.exposure)
                assertEquals(.5f, edits.load(secondID)!!.exposure); assertEquals(.6f, edits.load(secondID)!!.geometry.cropWidth)
                assertEquals(listOf(secondID.value), history(model, true, operation.id).map { it.targetID })
                assertEquals(-.2f, edits.load(secondID)!!.exposure)
                assertEquals(2, history(model, false, operation.id).size)
                await(model) { it.canExport && it.edits.exposure == .5f }
                assertEquals(.5f, edits.load(secondID)!!.exposure)
            }
        } finally { second.delete(); EditStore(File(context.filesDir, "edits")).reset(secondID) }
    }

    @Test fun presetCaptureKeepsClipboardPhotoRevisionAndHistoryUnchanged() = withModel(raw = true) { model, edits, identity ->
        main { model.edit(model.state.value.edits.copy(exposure = 1.25f, contrast = .2f)) }
        await(model) { it.canExport }
        main { model.copyAdjustments(AdjustmentScope.Custom(setOf(AdjustmentField.CONTRAST))) }
        val clipboard = model.adjustmentClipboard
        val receipt = edits.versionedState(identity)
        val history = model.adjustmentTransactions
        lateinit var preset: com.rawlab.android.presets.AdjustmentPreset
        val payload = result<Result<AdjustmentPayload>> {
            model.capturePresetAdjustments(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE)), it)
        }.getOrThrow()
        main { preset = model.presetStore.create("Native-${UUID.randomUUID()}", payload) }
        try {
            assertEquals(setOf(AdjustmentField.EXPOSURE), preset.payload.fields)
            assertEquals(clipboard, model.adjustmentClipboard)
            assertEquals(receipt, edits.versionedState(identity)); assertEquals(history, model.adjustmentTransactions)
            main { model.edit(model.state.value.edits.copy(exposure = .3f)) }
            await(model) { it.canExport }
            main { model.prepareAdjustmentPaste(preset.payload, listOf(model.state.value.photo!!.uri),
                com.rawlab.android.adjustments.AdjustmentHistoryTransaction.Action.PRESET) }
            val deadline = SystemClock.uptimeMillis() + 60_000
            while (model.adjustmentTransfer.value.preparing && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(30)
            val prepared = requireNotNull(model.adjustmentTransfer.value.prepared)
            assertEquals(AdjustmentStatus.APPLIED, paste(model, prepared).single().status)
            await(model) { it.canExport && it.edits.exposure == 1.25f }
            assertEquals(.2f, edits.load(identity)!!.contrast)
            assertEquals(com.rawlab.android.adjustments.AdjustmentHistoryTransaction.Action.PRESET, model.adjustmentTransactions.last().action)
            main { model.undoAdjustment() }; await(model) { it.canExport && it.edits.exposure == .3f }
            main { model.redoAdjustment() }; await(model) { it.canExport && it.edits.exposure == 1.25f }
            assertEquals(clipboard, model.adjustmentClipboard)
        } finally { model.presetStore.delete(preset) }
    }

    @Test fun presetCaptureRejectsDraftAndFailedPhotoSave() {
        var failWrite = false
        withModel(storeFactory = { directory -> EditStore(directory) { from, to ->
            if (failWrite) throw IOException("preset photo persistence failure")
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
        } }) { model, _, _ ->
            main { model.beginDraft(AdjustmentGroup.GEOMETRY) }
            await(model) { it.draftReady }
            assertTrue(result<Result<AdjustmentPayload>> { model.capturePresetAdjustments(AdjustmentScope.All, it) }.isFailure)
            main { model.discardDraft() }
            await(model) { it.canExport }
            failWrite = true
            main { model.edit(model.state.value.edits.copy(exposure = .7f)) }
            await(model) { it.saveState == EditSaveState.FAILED && !it.rendering }
            assertTrue(result<Result<AdjustmentPayload>> { model.capturePresetAdjustments(AdjustmentScope.All, it) }.isFailure)
            assertNull(model.adjustmentClipboard)
        }
    }


    @Test fun presetCaptureRejectsExternallyChangedCommittedRecord() = withModel { model, edits, identity ->
        main { model.edit(model.state.value.edits.copy(exposure = .4f)) }
        await(model) { it.canExport }
        val history = model.adjustmentTransactions
        edits.save(identity, model.state.value.edits.copy(exposure = 1.6f))
        val receipt = edits.versionedState(identity)
        assertTrue("Stale committed snapshot cannot be captured", result<Result<AdjustmentPayload>> {
            model.capturePresetAdjustments(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE)), it)
        }.isFailure)
        assertEquals(receipt, edits.versionedState(identity)); assertEquals(history, model.adjustmentTransactions)
    }

    @Test fun collectionSyncMicroEditDraftSkipAndFrozenNativePreview() = withModel { model, edits, sourceID ->
        val folder = File(context.cacheDir, "collection-native-${UUID.randomUUID()}").apply { mkdirs() }
        val target = File(folder, "source.png"); png(target)
        val targetURI = Uri.fromFile(target); val targetID = PhotoIdentity(targetURI.toString())
        var jobID: String? = null
        fun waitFor(condition: () -> Boolean) {
            val deadline = SystemClock.uptimeMillis() + 60_000
            while (!condition() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(30)
            assertTrue("Collection operation timed out", condition())
        }
        try {
            main { model.edit(model.state.value.edits.copy(exposure = .6f)) }
            await(model) { it.canExport }
            main { model.copyAdjustments(AdjustmentScope.Custom(setOf(AdjustmentField.CONTRAST)))
                model.addCollectionPhotos(listOf(model.state.value.photo!!.uri, targetURI, targetURI)) }
            waitFor { !model.collection.value.busy }
            assertEquals(2, model.collection.value.photos.size)
            val clipboard = model.adjustmentClipboard
            val sync = result<CollectionSynchronization?> {
                model.captureCollectionSynchronization(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE)), it)
            }!!
            main { model.prepareAdjustmentPaste(sync.payload, sync.targets, com.rawlab.android.adjustments.AdjustmentHistoryTransaction.Action.SYNCHRONIZE) }
            waitFor { !model.adjustmentTransfer.value.preparing }
            val prepared = model.adjustmentTransfer.value.prepared!!
            assertEquals(listOf(targetID.value), prepared.targets.map { it.id })
            assertEquals(AdjustmentStatus.APPLIED, paste(model, prepared).single().status)
            assertEquals(clipboard, model.adjustmentClipboard)
            assertEquals(prepared.id, model.collection.value.lastSynchronization)
            main { model.closeAdjustmentOperation() }
            assertTrue(result<Boolean> { model.editCollectionPhoto(targetID.value, it) })
            await(model) { it.canExport && it.photo?.identity == targetID }
            main { model.edit(model.state.value.edits.copy(contrast = .3f)) }
            await(model) { it.canExport }
            assertTrue(result<Boolean> { model.returnToCollection(it) })
            assertEquals(setOf(sourceID.value, targetID.value), model.collection.value.selected)
            assertEquals(prepared.id, model.collection.value.lastSynchronization)
            main { model.beginDraft(AdjustmentGroup.GEOMETRY) }
            await(model) { it.draftReady }
            var review: com.rawlab.android.batch.CollectionExportReview? = null
            main { model.prepareCollectionExport(emptySet(), com.rawlab.android.format.ExportFormat.JPEG, 256, null) { review = it } }
            waitFor { !model.collection.value.busy }
            assertFalse(review!!.ready)
            main { model.prepareCollectionExport(setOf(targetID.value), com.rawlab.android.format.ExportFormat.JPEG, 256, null) { review = it } }
            waitFor { !model.collection.value.busy }
            assertTrue(review!!.ready); assertEquals(listOf(sourceID.value), review!!.rows.map { it.target.id })
            assertNotNull(model.state.value.draft); assertEquals(2, model.collection.value.selected.size)
            main { model.resolveCollectionDraft(false) { assertTrue(it) } }
            await(model) { it.canExport }
            main { model.prepareCollectionExport(emptySet(), com.rawlab.android.format.ExportFormat.JPEG, 256, null) { review = it } }
            waitFor { !model.collection.value.busy }
            assertTrue(review!!.ready)
            main { model.freezeCollectionExport(review!!) { assertTrue(it) } }
            waitFor { !model.collection.value.busy && model.batch.value?.state?.value?.phase == com.rawlab.android.batch.BatchPhase.SELECTING }
            val batch = model.batch.value!!; val job = batch.state.value.job; jobID = job.id
            val frozenTarget = job.rows.first { it.id == targetID.value }.target
            assertEquals(.3f, frozenTarget.frozen!!.settings.contrast)
            main { model.edit(model.state.value.edits.copy(exposure = 1.6f)) }
            await(model) { it.canExport }
            val frozen = kotlinx.coroutines.runBlocking { batch.preview(frozenTarget) }
            val later = com.rawlab.android.engine.NativeProcessor(com.rawlab.android.engine.NativeProcessor.CPU, model.storage.lensDatabase()).use {
                it.preview(model.state.value.photo!!.file, null, model.state.value.edits, 1280, true,
                    com.rawlab.android.format.PhotoInputKind.RASTER).bitmap()
            }
            assertFalse("Frozen pixels retain the pre-edit settings", frozen.sameAs(later))
            frozen.recycle(); later.recycle()
            assertEquals(.6f, frozenTarget.frozen!!.settings.exposure)
            assertEquals(prepared.id, model.collection.value.lastSynchronization)
            assertEquals(clipboard, model.adjustmentClipboard)
            target.delete()
            val stillAvailable = kotlinx.coroutines.runBlocking { batch.preview(frozenTarget) }; stillAvailable.recycle()
            main { assertTrue(batch.discard()); model.closeBatch() }
        } finally {
            edits.reset(targetID); folder.deleteRecursively()
            jobID?.let { com.rawlab.android.batch.journal.BatchJournal(File(context.filesDir, "RawLab/BatchJobs")).discard(it) }
        }
    }

    @Test fun collectionRemoveAllowsExplicitReimportAndFailedUrisStayVisible() = withModel { model, _, _ ->
        val target = File(context.cacheDir, "collection-reimport-${UUID.randomUUID()}.png"); png(target)
        val uri = Uri.fromFile(target); val missing = Uri.fromFile(File(context.cacheDir, "absent-${UUID.randomUUID()}.png"))
        fun waitForImport() {
            val deadline = SystemClock.uptimeMillis() + 60_000
            while (model.collection.value.busy && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(30)
            assertFalse(model.collection.value.busy)
        }
        try {
            main { model.addCollectionPhotos(listOf(uri, missing)) }; waitForImport()
            assertEquals(listOf(uri.toString(), missing.toString()), model.collection.value.photos.map { it.id })
            assertTrue(missing.toString() in model.collection.value.failures)
            val old = model.collection.value.photos.first().sourceFile
            main { model.removeCollectionPhoto(uri.toString()) }
            assertFalse(old.exists())
            val replacement = File(target.parentFile, "replacement-${UUID.randomUUID()}.png"); png(replacement)
            Files.move(replacement.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
            main { model.addCollectionPhotos(listOf(uri)) }; waitForImport()
            assertFalse(uri.toString() in model.collection.value.failures)
            assertNotEquals(old, model.collection.value.photos.last().sourceFile)
        } finally { target.delete() }
    }

}
