package com.rawlab.android.editor

import android.app.Application
import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import android.os.FileObserver
import java.util.concurrent.atomic.AtomicInteger
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.LensSettings
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import com.rawlab.android.looks.LookLibrary
import com.rawlab.android.settings.DenoisePreset
import com.rawlab.android.settings.DenoiseSettings

@RunWith(AndroidJUnit4::class)
class EditorViewModelRaceInstrumentedTest {
    @Test fun denoiseResizeWaitsForQuietAndKeepsLatestEdits() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val raw = File(context.cacheDir, "resize-${UUID.randomUUID()}.arw")
        copyFixture(raw)
        val store = ViewModelStore()
        try {
            val model = EditorViewModel(context.applicationContext as Application)
            store.put("editor", model)
            model.importPhoto(Uri.fromFile(raw))
            awaitState(model) { it.canExport }
            instrumentation.runOnMainSync {
                model.edit(model.state.value.edits.copy(denoise = DenoiseSettings().withPreset(DenoisePreset.CLEAN)))
            }
            awaitState(model) { it.canExport }
            instrumentation.runOnMainSync {
                model.updatePreviewSize(768)
                model.updatePreviewSize(512)
                assertTrue(model.state.value.previewResizePending)
                assertFalse(model.state.value.canExport)
                model.edit(model.state.value.edits.copy(exposure = .5f))
            }
            awaitState(model) { it.canExport && maxOf(it.preview!!.result.width, it.preview.result.height) == 512 }
            assertEquals(.5f, model.state.value.edits.exposure)
            instrumentation.runOnMainSync {
                model.updatePreviewSize(640)
                model.updatePreviewSize(512)
                assertFalse(model.state.value.previewResizePending)
            }
            assertTrue(model.state.value.canExport)
            instrumentation.runOnMainSync {
                model.updatePreviewSize(768)
                model.edit(model.state.value.edits.copy(denoise = model.state.value.edits.denoise.copy(enabled = false)))
                assertFalse(model.state.value.previewResizePending)
            }
            awaitState(model) { it.canExport && maxOf(it.preview!!.result.width, it.preview.result.height) == 768 }
            instrumentation.runOnMainSync {
                model.updatePreviewSize(1216)
                model.edit(model.state.value.edits.copy(exposure = .75f), interactive = true)
            }
            awaitState(model) { !it.rendering && maxOf(it.preview!!.result.width, it.preview.result.height) == 1216 }
            assertFalse(model.state.value.exact)
            instrumentation.runOnMainSync { model.edit(model.state.value.edits) }
            awaitState(model) { it.canExport }
            instrumentation.runOnMainSync {
                assertTrue(model.beginExport())
                model.updatePreviewSize(896)
                model.cancelExport()
            }
            awaitState(model) { it.canExport && maxOf(it.preview!!.result.width, it.preview.result.height) == 896 }
        } finally { store.clear(); raw.delete() }
    }
    @Test fun startupLookLoadSurvivesImmediatePhotoImport() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.filesDir, "looks")
        val source = File(context.cacheDir, "startup-${UUID.randomUUID()}.cube").apply { writeText(syntheticCube()) }
        val raw = File(context.cacheDir, "startup-${UUID.randomUUID()}.arw")
        copyFixture(raw)
        val store = ViewModelStore()
        try {
            root.deleteRecursively()
            val managed = LookLibrary(root).importLook(source)
            val model = EditorViewModel(context.applicationContext as Application)
            store.put("editor", model)
            model.importPhoto(Uri.fromFile(raw))
            awaitState(model) { state -> state.photo != null && state.looks.any { it.id == managed.id } }
        } finally {
            store.clear()
            root.deleteRecursively()
            source.delete(); raw.delete()
        }
    }

    @Test fun importedLookDuringExactPreviewIsSelectedAndRerendered() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.filesDir, "looks")
        val source = File(context.cacheDir, "race-${UUID.randomUUID()}.cube").apply { writeText(syntheticCube()) }
        val raw = File(context.cacheDir, "race-${UUID.randomUUID()}.arw")
        copyFixture(raw)
        val store = ViewModelStore()
        try {
            root.deleteRecursively()
            val model = EditorViewModel(context.applicationContext as Application)
            store.put("editor", model)
            model.importPhoto(Uri.fromFile(raw))
            awaitState(model) { state -> state.photo != null && state.exact && !state.rendering }
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                model.edit(model.state.value.edits.copy(exposure = .25f))
                assertTrue(model.state.value.rendering)
                model.importLook(Uri.fromFile(source))
            }
            awaitState(model) { state ->
                state.looks.any { it.managed && it.name == source.name } &&
                    state.edits.film != "neutral" && state.exact && !state.rendering
            }
            val importedId = model.state.value.edits.film
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                model.edit(model.state.value.edits.copy(exposure = .5f))
                assertTrue(model.state.value.rendering)
                model.deleteLook(importedId)
            }
            awaitState(model) { state ->
                state.edits.film == "neutral" && state.looks.none { it.id == importedId } && state.canExport
            }
            assertEquals(null, model.state.value.error)
        } finally {
            store.clear()
            root.deleteRecursively()
            source.delete(); raw.delete()
        }
    }

    @Test fun invalidLookPreservesExactPreviewAndExportAvailability() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val source = File(context.cacheDir, "bad-${UUID.randomUUID()}.cube").apply { writeText("invalid") }
        val raw = File(context.cacheDir, "failure-${UUID.randomUUID()}.arw")
        copyFixture(raw)
        val store = ViewModelStore()
        try {
            val model = EditorViewModel(context.applicationContext as Application)
            store.put("editor", model)
            model.importPhoto(Uri.fromFile(raw))
            awaitState(model) { it.canExport }
            val selected = model.state.value.edits.film
            model.importLook(Uri.fromFile(source))
            awaitState(model) { it.operation == Operation.NONE && it.lookImportReport != null }
            assertEquals(selected, model.state.value.edits.film)
            assertFalse(model.state.value.rendering)
            assertTrue(model.state.value.canExport)
        } finally {
            store.clear()
            source.delete(); raw.delete()
        }
    }

    @Test fun batchLookImportKeepsPartialSuccessAndReportsFailuresAfterRendering() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.filesDir, "looks")
        val first = File(context.cacheDir, "batch-first-${UUID.randomUUID()}.cube").apply { writeText(syntheticCube()) }
        val last = File(context.cacheDir, "batch-last-${UUID.randomUUID()}.cube").apply { writeText(syntheticCube()) }
        val bad = File(context.cacheDir, "batch-bad-${UUID.randomUUID()}.cube").apply { writeText("invalid") }
        val otherBad = File(context.cacheDir, "batch-other-bad-${UUID.randomUUID()}.cube").apply { writeText("invalid") }
        val raw = File(context.cacheDir, "batch-${UUID.randomUUID()}.arw")
        copyFixture(raw)
        val store = ViewModelStore()
        try {
            root.deleteRecursively()
            val model = EditorViewModel(context.applicationContext as Application)
            store.put("editor", model)
            model.importPhoto(Uri.fromFile(raw))
            awaitState(model) { it.canExport }
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                model.importLooks(listOf(first, bad, last, otherBad).map(Uri::fromFile))
                assertEquals(Operation.IMPORT_LOOK, model.state.value.operation)
            }
            awaitState(model) { it.canExport && it.looks.count { look -> look.managed } == 2 }
            val state = model.state.value
            assertEquals(last.name, state.looks.single { it.id == state.edits.film }.name)
            assertTrue(state.lookImportReport?.contains(bad.name) == true)
            assertTrue(state.lookImportReport?.contains(otherBad.name) == true)
            assertEquals(syntheticCube(), first.readText())
            assertEquals(syntheticCube(), last.readText())
            val selected = state.edits.film
            model.importLooks(listOf(Uri.fromFile(bad), Uri.fromFile(otherBad)))
            awaitState(model) { it.operation == Operation.NONE && it.lookImportReport != null }
            assertEquals(selected, model.state.value.edits.film)
            assertTrue(model.state.value.canExport)
            model.importLooks(emptyList())
            assertEquals(selected, model.state.value.edits.film)
            model.dismissLookImportReport()
            assertEquals(null, model.state.value.lookImportReport)
            model.importLooks(listOf(Uri.fromFile(first), Uri.fromFile(last)))
            awaitState(model) { it.canExport && it.looks.count { look -> look.managed } == 4 }
            assertEquals(null, model.state.value.lookImportReport)
            first.delete(); last.delete()
            val restored = EditorViewModel(context.applicationContext as Application)
            store.put("restored", restored)
            awaitState(restored) { it.looks.count { look -> look.managed } == 4 }
        } finally {
            store.clear()
            root.deleteRecursively()
            first.delete(); last.delete(); bad.delete(); otherBad.delete(); raw.delete()
        }
    }

    @Test fun restoredViewportDemandPreservesSaveStateAndDoesNotWriteTheCommittedRecord() = restoredViewport(false)
    @Test fun restoredDenoiseViewportDemandPreservesSaveStateAndDoesNotWriteTheCommittedRecord() = restoredViewport(true)
    private fun restoredViewport(denoise: Boolean) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val raw = File(context.cacheDir, "restore-viewport-${UUID.randomUUID()}.RAW")
        copyFixture(raw)
        val owner = ViewModelStore()
        try {
            lateinit var model: EditorViewModel
            instrumentation.runOnMainSync {
                model = EditorViewModel(context.applicationContext as Application)
                owner.put("restore-viewport", model)
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(raw))
            }
            awaitState(model) { it.canExport }
            instrumentation.runOnMainSync { model.edit(model.state.value.edits.copy(exposure = .5f,
                denoise = model.state.value.edits.denoise.copy(enabled = denoise))) }
            awaitState(model) { it.canExport }
            instrumentation.runOnMainSync { model.importPhoto(Uri.fromFile(raw)) }
            awaitState(model) { it.canExport }
            assertEquals(EditSaveState.RESTORED, model.state.value.saveState)
            val record = File(context.filesDir, "edits/edits.properties")
            val bytes = record.readBytes()
            val committed = model.state.value.edits
            val inode = android.system.Os.stat(record.absolutePath).st_ino
            val writes = AtomicInteger()
            val observer = object : FileObserver(record.parentFile!!.absolutePath, FileObserver.MOVED_TO) {
                override fun onEvent(event: Int, path: String?) { if (path == record.name) writes.incrementAndGet() }
            }
            observer.startWatching()
            try {
                instrumentation.runOnMainSync {
                    model.updatePreviewSize(320)
                    assertEquals(EditSaveState.RESTORED, model.state.value.saveState)
                    assertEquals(inode, android.system.Os.stat(record.absolutePath).st_ino)
                    assertArrayEquals(bytes, record.readBytes())
                }
                awaitState(model) { it.canExport && maxOf(it.preview!!.result.width, it.preview.result.height) == 320 }
                assertEquals(committed, model.state.value.edits)
                assertEquals(inode, android.system.Os.stat(record.absolutePath).st_ino)
                assertArrayEquals(bytes, record.readBytes())
                assertTrue(model.state.value.saveState in setOf(EditSaveState.RESTORED, EditSaveState.NONE))
                assertEquals(0, writes.get())
            } finally { observer.stopWatching() }
        } finally {
            instrumentation.runOnMainSync { owner.clear() }
            raw.delete()
        }
    }

    @Test fun previewRetryKeepsUnsavedEditsFailedAndNeverWritesTheRecord() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val id = UUID.randomUUID()
        val raw = File(context.cacheDir, "view-retry-$id.RAW")
        val cube = File(context.cacheDir, "view-retry-$id.cube").apply { writeText(syntheticCube()) }
        copyFixture(raw)
        val owner = ViewModelStore()
        val record = File(context.filesDir, "edits/edits.properties")
        val recordBackup = File(context.cacheDir, "view-retry-$id.properties")
        var lut: File? = null
        var lutBackup: File? = null
        var observer: FileObserver? = null
        val writes = AtomicInteger()
        try {
            lateinit var model: EditorViewModel
            instrumentation.runOnMainSync {
                model = EditorViewModel(context.applicationContext as Application)
                owner.put("view-retry", model)
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(raw))
            }
            awaitState(model) { it.canExport }
            instrumentation.runOnMainSync { model.importLook(Uri.fromFile(cube)) }
            awaitState(model) { it.canExport && it.edits.film != "neutral" }
            // 单独完成相机 metadata 归一化；零写窗口使用明确的自定义 WB，不混入首次补元数据。
            instrumentation.runOnMainSync { model.edit(model.state.value.edits.copy(customWb = true, temperature = 4000f, tint = 5f, exposure = .5f)) }
            awaitState(model) { it.canExport }
            assertTrue(record.renameTo(recordBackup)); assertTrue(record.mkdir())
            File(record, "occupied").writeText("keep")
            instrumentation.runOnMainSync { model.edit(model.state.value.edits.copy(exposure = 1f)) }
            awaitState(model) { it.exact && !it.rendering }
            assertEquals(EditSaveState.FAILED, model.state.value.saveState)
            assertTrue(record.deleteRecursively()); assertTrue(recordBackup.renameTo(record))
            val committedRecord = record.readBytes()
            val inode = android.system.Os.stat(record.absolutePath).st_ino
            val unsaved = model.state.value.edits
            val lastFrame = model.state.value.preview
            lut = model.storage.lookPath(unsaved)!!
            lutBackup = File(lut!!.parentFile, "view-retry-$id.backup")
            assertTrue(lut!!.renameTo(lutBackup!!))
            instrumentation.runOnMainSync { model.updatePreviewSize(320) }
            awaitState(model) { !it.rendering && it.error != null }
            assertSame("Preview failure retains the last accepted pair", lastFrame, model.state.value.preview)
            assertFalse(model.state.value.exact)
            assertTrue(lutBackup!!.renameTo(lut!!))
            observer = object : FileObserver(record.parentFile!!.absolutePath, FileObserver.MOVED_TO) {
                override fun onEvent(event: Int, path: String?) { if (path == record.name) writes.incrementAndGet() }
            }.also { it.startWatching() }
            instrumentation.runOnMainSync { model.retry() }
            awaitState(model) { it.exact && !it.rendering && !it.previewResizePending && it.error == null }
            android.util.Log.i("RawLabViewRetryEvidence", "save=${model.state.value.saveState} writes=${writes.get()} wb=${model.state.value.edits.temperature} exact=${model.state.value.exact}")
            assertEquals("Preview recovery must not turn an unrelated failed save into success", EditSaveState.FAILED, model.state.value.saveState)
            assertEquals(unsaved, model.state.value.edits)
            assertFalse(model.state.value.canExport)
            assertEquals(inode, android.system.Os.stat(record.absolutePath).st_ino)
            assertArrayEquals(committedRecord, record.readBytes())
            assertEquals("Pure preview retry has zero record writes", 0, writes.get())
        } finally {
            observer?.stopWatching()
            if (lutBackup?.exists() == true) { lut?.delete(); lutBackup!!.renameTo(lut!!) }
            if (recordBackup.exists()) { record.deleteRecursively(); recordBackup.renameTo(record) }
            instrumentation.runOnMainSync { owner.clear() }
            raw.delete(); cube.delete()
        }
    }

    @Test fun viewportDemandCannotTurnAnUnsavedFailureIntoASuccessfulWrite() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val raw = File(context.cacheDir, "failed-viewport-${UUID.randomUUID()}.RAW")
        copyFixture(raw)
        val owner = ViewModelStore()
        val record = File(context.filesDir, "edits/edits.properties")
        val backup = File(context.cacheDir, "failed-viewport-${UUID.randomUUID()}.properties")
        try {
            lateinit var model: EditorViewModel
            instrumentation.runOnMainSync {
                model = EditorViewModel(context.applicationContext as Application)
                owner.put("failed-viewport", model)
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(raw))
            }
            awaitState(model) { it.canExport }
            instrumentation.runOnMainSync { model.edit(model.state.value.edits.copy(exposure = .5f)) }
            awaitState(model) { it.canExport }
            assertTrue(record.renameTo(backup)); assertTrue(record.mkdir())
            File(record, "occupied").writeText("keep")
            instrumentation.runOnMainSync { model.edit(model.state.value.edits.copy(exposure = 1f)) }
            awaitState(model) { it.exact && !it.rendering }
            assertEquals(EditSaveState.FAILED, model.state.value.saveState)
            assertTrue(record.deleteRecursively()); assertTrue(backup.renameTo(record))
            val bytes = record.readBytes()
            val inode = android.system.Os.stat(record.absolutePath).st_ino
            instrumentation.runOnMainSync {
                model.updatePreviewSize(320)
                assertEquals(EditSaveState.FAILED, model.state.value.saveState)
            }
            awaitState(model) { it.exact && !it.rendering && maxOf(it.preview!!.result.width, it.preview.result.height) == 320 }
            assertEquals(EditSaveState.FAILED, model.state.value.saveState)
            assertEquals(inode, android.system.Os.stat(record.absolutePath).st_ino)
            assertArrayEquals(bytes, record.readBytes())
            assertEquals(1f, model.state.value.edits.exposure)
        } finally {
            if (backup.exists()) { record.deleteRecursively(); backup.renameTo(record) }
            instrumentation.runOnMainSync { owner.clear() }
            raw.delete()
        }
    }

    @Test fun unchangedLensNavigationAndNeutralLegacyAllResetHaveNoWritesOrPreviewRequests() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val raw = File(context.cacheDir, "navigation-${UUID.randomUUID()}.RAW")
        copyFixture(raw)
        val owner = ViewModelStore()
        try {
            lateinit var model: EditorViewModel
            instrumentation.runOnMainSync {
                model = EditorViewModel(context.applicationContext as Application)
                owner.put("navigation", model)
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(raw))
            }
            awaitState(model) { it.canExport }
            instrumentation.runOnMainSync {
                model.edit(model.state.value.edits.copy(processing = com.rawlab.android.settings.ProcessingIdentity.LEGACY))
            }
            awaitState(model) { it.canExport }
            val revision = EditorViewModel::class.java.getDeclaredField("currentRevision").apply { isAccessible = true }
            val beforeRequest = revision.getLong(model)
            val record = File(context.filesDir, "edits/edits.properties")
            val beforeRecord = record.readBytes()
            val beforePreview = model.state.value.preview
            instrumentation.runOnMainSync {
                assertTrue(model.prepareReset(EditorResetScope.All).result is EditorResetResult.NoChange)
                model.beginDraft(AdjustmentGroup.LENS)
                assertFalse(model.state.value.draft!!.changed)
                model.discardDraft()
            }
            awaitState(model) { it.canExport }
            assertEquals(beforeRequest, revision.getLong(model))
            assertSame(beforePreview, model.state.value.preview)
            assertArrayEquals(beforeRecord, record.readBytes())
            assertEquals(com.rawlab.android.settings.ProcessingIdentity.LEGACY, model.state.value.edits.processing)
            instrumentation.runOnMainSync {
                model.edit(model.state.value.edits.copy(geometry = GeometrySettings(cropWidth = .8f)))
            }
            awaitState(model) { it.canExport }
            val croppedRecord = record.readBytes()
            instrumentation.runOnMainSync { model.beginDraft(AdjustmentGroup.GEOMETRY) }
            awaitState(model) { it.draftReady }
            val uncroppedRequest = revision.getLong(model)
            instrumentation.runOnMainSync { model.discardDraft() }
            awaitState(model) { it.canExport }
            assertEquals(uncroppedRequest + 1, revision.getLong(model))
            assertArrayEquals(croppedRecord, record.readBytes())
            assertEquals(.8f, model.state.value.edits.geometry.cropWidth)
        } finally {
            instrumentation.runOnMainSync { owner.clear() }
            raw.delete()
        }
    }

    @Test fun resetCommitRejectsStaleEditsAndOnlySkipsIdenticalDurablePreviewWrites() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val raw = File(context.cacheDir, "reset-${UUID.randomUUID()}.RAW")
        copyFixture(raw)
        val owner = ViewModelStore()
        val writes = AtomicInteger()
        val directory = File(context.filesDir, "edits")
        val observer = object : FileObserver(directory.absolutePath, FileObserver.MOVED_TO) {
            override fun onEvent(event: Int, path: String?) {
                if (path == "edits.properties") writes.incrementAndGet()
            }
        }
        try {
            lateinit var model: EditorViewModel
            instrumentation.runOnMainSync {
                model = EditorViewModel(context.applicationContext as Application)
                owner.put("reset", model)
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(raw))
            }
            awaitState(model) { it.canExport }
            instrumentation.runOnMainSync { model.edit(model.state.value.edits.copy(exposure = .5f, customWb = true, temperature = 4000f)) }
            awaitState(model) { it.canExport }
            val revision = EditorViewModel::class.java.getDeclaredField("currentRevision").apply { isAccessible = true }
            observer.startWatching()
            fun settle(expected: Int) {
                val deadline = SystemClock.elapsedRealtime() + 3000
                while (writes.get() < expected && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(20)
                SystemClock.sleep(150)
                assertEquals(expected, writes.get())
            }
            val beforeRequest = revision.getLong(model)
            instrumentation.runOnMainSync {
                val reset = model.prepareReset(EditorResetScope.Tool(2)).prepared!!
                assertTrue(model.commitReset(reset))
                assertEquals(beforeRequest + 1, revision.getLong(model))
            }
            awaitState(model) { it.canExport }
            settle(1)
            assertEquals(0f, model.state.value.edits.exposure, 0f)
            val preview = model.state.value.preview
            instrumentation.runOnMainSync {
                assertTrue(model.prepareReset(EditorResetScope.Tool(2)).result is EditorResetResult.NoChange)
                assertEquals(beforeRequest + 1, revision.getLong(model))
                assertSame(preview, model.state.value.preview)
            }
            settle(1)
            // 普通编辑保留既有的 edit + resolved-preview 两次保存。
            instrumentation.runOnMainSync { model.edit(model.state.value.edits.copy(exposure = .75f)) }
            awaitState(model) { it.canExport }
            settle(3)
            lateinit var stale: PreparedEditorReset
            instrumentation.runOnMainSync {
                stale = model.prepareReset(EditorResetScope.Tool(2)).prepared!!
                model.edit(model.state.value.edits.copy(exposure = 1f))
                model.edit(model.state.value.edits.copy(exposure = .75f))
            }
            awaitState(model) { it.canExport }
            val currentRequest = revision.getLong(model)
            val record = File(directory, "edits.properties").readBytes()
            instrumentation.runOnMainSync { assertFalse(model.commitReset(stale)) }
            assertEquals(currentRequest, revision.getLong(model))
            assertArrayEquals(record, File(directory, "edits.properties").readBytes())
            assertEquals(.75f, model.state.value.edits.exposure, 0f)
            settle(6)
            // 强制 WB 从自定义转换为相机；native 返回真实 metadata 必须沿原路径落盘。
            writes.set(0)
            instrumentation.runOnMainSync {
                model.edit(model.state.value.edits.copy(customWb = false, temperature = 6500f, tint = 0f))
            }
            awaitState(model) { it.canExport }
            settle(2)
            assertNotEquals(6500f, model.state.value.edits.temperature)
            assertEquals(model.state.value.edits, EditStore(directory).load(model.state.value.photo!!.identity))
            val unchangedRequest = revision.getLong(model)
            val unchangedRecord = File(directory, "edits.properties").readBytes()
            instrumentation.runOnMainSync {
                model.beginDraft(AdjustmentGroup.LENS)
                assertTrue(model.state.value.draftReady)
                assertFalse(model.applyDraft())
            }
            assertEquals(unchangedRequest, revision.getLong(model))
            assertArrayEquals(unchangedRecord, File(directory, "edits.properties").readBytes())
            settle(2)
            instrumentation.runOnMainSync {
                model.changeDraft(model.state.value.visibleEdits.copy(lens = LensSettings(autoCrop = false)))
            }
            awaitState(model) { it.canApplyDraft }
            settle(2)
            val draftRequest = revision.getLong(model)
            instrumentation.runOnMainSync {
                assertTrue(model.applyDraft())
                assertEquals(draftRequest + 1, revision.getLong(model))
            }
            awaitState(model) { it.canExport }
            settle(3)
            assertEquals(model.state.value.edits, EditStore(directory).load(model.state.value.photo!!.identity))
        } finally {
            observer.stopWatching()
            instrumentation.runOnMainSync { owner.clear() }
            raw.delete()
        }
    }

    @Test fun geometryGroupResetStaysInDraftAndAppliesBothFieldsOnce() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val raw = File(context.cacheDir, "pair-reset-${UUID.randomUUID()}.RAW")
        copyFixture(raw)
        val owner = ViewModelStore()
        try {
            lateinit var model: EditorViewModel
            instrumentation.runOnMainSync {
                model = EditorViewModel(context.applicationContext as Application)
                owner.put("pair-reset", model)
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(raw))
            }
            awaitState(model) { it.canExport }
            instrumentation.runOnMainSync {
                model.edit(model.state.value.edits.copy(exposure = .5f, customWb = true,
                    geometry = GeometrySettings(quarterTurns = 1), lens = LensSettings(autoCrop = false)))
            }
            awaitState(model) { it.canExport }
            val original = model.state.value.edits
            val identity = model.state.value.photo!!.identity
            val directory = File(context.filesDir, "edits")
            for (group in AdjustmentGroup.entries) {
                instrumentation.runOnMainSync { model.beginDraft(group) }
                awaitState(model) { it.draftReady }
                assertFalse(model.state.value.canApplyDraft)
                instrumentation.runOnMainSync {
                    val prepared = model.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.GEOMETRY)).prepared!!
                    assertTrue(model.commitReset(prepared))
                    assertEquals(original, model.state.value.edits)
                    assertEquals(original, EditStore(directory).load(identity))
                    assertEquals(GeometrySettings(), model.state.value.visibleEdits.geometry)
                    assertEquals(LensSettings(), model.state.value.visibleEdits.lens)
                }
                awaitState(model) { it.canApplyDraft }
                instrumentation.runOnMainSync { model.discardDraft() }
                awaitState(model) { it.canExport }
                assertEquals(original, model.state.value.edits)
            }
            instrumentation.runOnMainSync { model.beginDraft(AdjustmentGroup.GEOMETRY) }
            awaitState(model) { it.draftReady }
            instrumentation.runOnMainSync {
                assertTrue(model.commitReset(model.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.GEOMETRY)).prepared!!))
            }
            awaitState(model) { it.canApplyDraft }
            instrumentation.runOnMainSync { assertTrue(model.applyDraft()) }
            awaitState(model) { it.canExport }
            assertNull(model.state.value.draft)
            assertEquals(GeometrySettings(), model.state.value.edits.geometry)
            assertEquals(LensSettings(), model.state.value.edits.lens)
            assertEquals(.5f, model.state.value.edits.exposure, 0f)
            assertEquals(model.state.value.edits, EditStore(directory).load(identity))
        } finally {
            instrumentation.runOnMainSync { owner.clear() }
            raw.delete()
        }
    }

    private fun awaitState(model: EditorViewModel, predicate: (EditorState) -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (SystemClock.elapsedRealtime() < deadline && !predicate(model.state.value)) SystemClock.sleep(50)
        assertTrue("Timed out waiting for EditorViewModel state: ${model.state.value}", predicate(model.state.value))
    }

    private fun copyFixture(destination: File) {
        InstrumentationRegistry.getInstrumentation().context.assets.open("sample.RAW").use { from ->
            destination.outputStream().use { from.copyTo(it) }
        }
    }

    private fun syntheticCube() = """
        #Gamma:F-Log2 to Synthetic Look
        #Gamut:F-Gamut to ITU-R BT.709
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1 1 1
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
    """.trimIndent() + "\n"
}
