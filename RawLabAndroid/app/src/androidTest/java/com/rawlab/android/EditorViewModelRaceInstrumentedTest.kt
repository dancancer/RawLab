package com.rawlab.android

import android.app.Application
import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class EditorViewModelRaceInstrumentedTest {
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
