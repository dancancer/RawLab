package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import android.system.Os
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.adjustments.*
import com.rawlab.android.presets.AdjustmentPresetStore
import com.rawlab.android.settings.EditStore
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class AdjustmentPresetUITest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)
    private val model get() = compose.activity.model
    private fun ready() {
        compose.waitUntil(60_000) { model.state.value.let { (it.canExport && !it.previewResizePending) || it.error != null } }
        assertNull(model.state.value.error)
    }
    private fun fixture(name: String): File = File(compose.activity.cacheDir, "$name-${System.nanoTime()}.png").also { file ->
        Bitmap.createBitmap(40, 30, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let { bitmap ->
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
    }
    private fun click(tag: String) {
        val node = compose.onNodeWithTag(tag)
        if (compose.onAllNodes(hasTestTag(tag) and hasAnyAncestor(hasScrollAction())).fetchSemanticsNodes().isNotEmpty()) node.performScrollTo()
        node.performClick(); compose.waitForIdle()
        if (tag == "preset-save") compose.waitUntil(60_000) { !model.state.value.committingAdjustments }
    }
    private fun library() {
        compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and !hasAnyAncestor(hasTestTag("adjustment-dock"))).performClick()
        click("preset-menu")
        compose.waitUntil(10_000) { compose.onAllNodesWithTag("preset-create").fetchSemanticsNodes().isNotEmpty() }
    }
    private fun enterName(value: String) {
        val field = compose.onNodeWithTag("preset-name")
        field.performTextReplacement(value); field.performImeAction(); compose.waitForIdle()
    }
    private fun save(name: String) {
        click("preset-create")
        enterName(name)
        click("adjustment-copy-clear"); click("adjustment-group-light"); click("adjustment-field-light.exposure")
        click("preset-save")
    }
    private fun screenshot(name: String, tag: String = "preset-root") {
        val file = File(compose.activity.getExternalFilesDir(null), "adjustment-presets/$name.png")
        file.parentFile!!.mkdirs()
        file.outputStream().use { compose.onNodeWithTag(tag).captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
    private fun cleanup(original: Set<String>) {
        model.presetStore.list().filter { it.id !in original }.forEach { model.presetStore.delete(it) }
    }

    @Test fun closingPresetSheetCancelsPendingCaptureWithoutCreatingPreset() {
        val before = model.presetStore.list().map { it.id }.toSet()
        val source = fixture("preset-cancel-capture")
        val release = java.util.concurrent.CountDownLatch(1)
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready()
            library(); click("preset-create"); enterName("Cancelled capture")
            val field = EditorViewModel::class.java.getDeclaredField("adjustmentQueue").apply { isAccessible = true }
            val queue = field.get(model) as com.rawlab.android.editor.render.SerialWorkQueue
            queue.submit({ release.await(30, java.util.concurrent.TimeUnit.SECONDS) }, {})
            compose.onNodeWithTag("preset-save").performScrollTo().performClick()
            compose.waitUntil(10_000) { model.state.value.committingAdjustments }
            click("preset-close"); release.countDown()
            compose.waitUntil(30_000) { !model.state.value.committingAdjustments }
            compose.onNodeWithTag("preset-root").assertDoesNotExist()
            assertEquals(before, model.presetStore.list().map { it.id }.toSet())
        } finally { release.countDown(); cleanup(before); source.delete() }
    }

    @Test fun scopeCrudSourceIndependenceAndPresetHistory() {
        val before = model.presetStore.list().map { it.id }.toSet()
        val source = fixture("preset-source"); val target = fixture("preset-target")
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready()
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = 1.25f, contrast = .2f)) }; ready()
            compose.runOnUiThread { model.copyAdjustments(AdjustmentScope.Custom(setOf(AdjustmentField.CONTRAST))) }
            val clipboard = model.adjustmentClipboard
            val history = model.adjustmentTransactions
            val identity = model.state.value.photo!!.identity
            val revision = EditStore(File(compose.activity.filesDir, "edits")).versionedState(identity)
            library(); save("晨光 · 1.25")
            val preset = model.presetStore.list().single { it.id !in before }
            assertEquals(setOf(AdjustmentField.EXPOSURE), preset.payload.fields)
            assertEquals(clipboard, model.adjustmentClipboard); assertEquals(history, model.adjustmentTransactions)
            assertEquals(revision, EditStore(File(compose.activity.filesDir, "edits")).versionedState(identity))
            click("preset-manage-${preset.id}"); click("preset-rename")
            val longName = "Morning light · 明るい朝 · Lang benannte Belichtungsvorgabe 1.25"
            enterName(longName); click("preset-rename-save")
            val renamed = model.presetStore.list().single { it.id == preset.id }
            assertEquals(preset.id, renamed.id); assertEquals(preset.createdAt, renamed.createdAt)
            screenshot("renamed-long-name")
            click("preset-close")
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(target)) }; ready()
            assertTrue(source.delete())
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(contrast = .35f)) }; ready()
            library(); click("preset-apply-${preset.id}")
            click("adjustment-paste-preflight")
            compose.waitUntil(60_000) { model.adjustmentTransfer.value.prepared != null }
            click("adjustment-paste-apply"); ready()
            assertEquals(1.25f, model.state.value.edits.exposure); assertEquals(.35f, model.state.value.edits.contrast)
            assertEquals(AdjustmentHistoryTransaction.Action.PRESET, model.adjustmentTransactions.last().action)
            screenshot("applied-preset", "adjustment-transfer-root")
            click("adjustment-transfer-close")
            compose.runOnUiThread { model.undoAdjustment() }; ready(); assertEquals(0f, model.state.value.edits.exposure)
            compose.runOnUiThread { model.redoAdjustment() }; ready(); assertEquals(1.25f, model.state.value.edits.exposure)
            assertEquals(clipboard, model.adjustmentClipboard)
            compose.activityRule.scenario.recreate(); ready()
            assertEquals(renamed, model.presetStore.list().single { it.id == renamed.id })
            library(); click("preset-manage-${preset.id}"); click("preset-delete")
            click("preset-delete-cancel"); assertTrue(model.presetStore.list().any { it.id == preset.id })
            click("preset-manage-${preset.id}"); click("preset-delete"); click("preset-delete-confirm")
            assertFalse(model.presetStore.list().any { it.id == preset.id })
            assertEquals(1.25f, model.state.value.edits.exposure)
        } finally { cleanup(before); source.delete(); target.delete() }
    }

    @Test fun duplicateOverwriteSaveAsAndWriteFailureRetry() {
        val before = model.presetStore.list().map { it.id }.toSet()
        val source = fixture("preset-duplicate")
        val directory = model.presetStore.directory
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready()
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .5f)) }; ready()
            library(); save("Duplicate")
            val first = model.presetStore.list().single { it.id !in before }
            click("preset-close")
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .9f)) }; ready()
            library(); save("Duplicate"); click("preset-overwrite-confirm")
            val updated = model.presetStore.list().single { it.id == first.id }
            assertEquals(first.createdAt, updated.createdAt); assertEquals(.9, updated.payload[AdjustmentField.EXPOSURE]!!.number!!, .00001)
            save("Duplicate"); click("preset-save-as")
            enterName("Separate")
            click("preset-save"); assertEquals(before.size + 2, model.presetStore.list().size)
            click("preset-create"); enterName("After failure")
            val file = File(directory, "presets.json"); val bytes = file.readBytes()
            Os.chmod(directory.absolutePath, 320) // 0500：可以读取，但创建临时文件必须失败。
            click("preset-save"); compose.onNodeWithTag("preset-error").assertExists()
            assertArrayEquals(bytes, file.readBytes()); screenshot("write-failure")
            Os.chmod(directory.absolutePath, 448)
            click("preset-save")
            assertTrue(model.presetStore.list().any { it.name == "After failure" })
        } finally { Os.chmod(directory.absolutePath, 448); cleanup(before); source.delete() }
    }

    @Test fun corruptLibraryRecoveryAndGeometryDecision() {
        val before = model.presetStore.list().map { it.id }.toSet()
        val source = fixture("preset-geometry")
        val file = File(model.presetStore.directory, "presets.json")
        val original = file.takeIf { it.exists() }?.readBytes()
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready()
            file.parentFile!!.mkdirs(); file.writeText("{\"registry_version\":99,\"presets\":[]}")
            val future = file.readBytes()
            library(); compose.onNodeWithTag("preset-error").assertExists(); click("preset-reload")
            assertArrayEquals(future, file.readBytes()); screenshot("future-version")
            if (original == null) file.delete() else file.writeBytes(original)
            click("preset-reload"); click("preset-close")
            compose.runOnUiThread { model.beginDraft(AdjustmentGroup.GEOMETRY) }
            compose.waitUntil(60_000) { model.state.value.draftReady }
            compose.runOnUiThread { val edits = model.state.value.visibleEdits
                model.changeDraft(edits.copy(geometry = edits.geometry.copy(cropWidth = .8f))) }
            compose.waitUntil(60_000) { model.state.value.canApplyDraft }
            library()
            assertNotNull(model.state.value.draft)
            click("preset-create")
            compose.onNodeWithText(compose.activity.getString(R.string.adjustment_continue)).performClick()
            assertNotNull(model.state.value.draft)
            library(); click("preset-create")
            compose.onNode(hasText(compose.activity.getString(R.string.adjustment_apply)) and hasAnyAncestor(isDialog())).performClick()
            compose.waitUntil(60_000) { compose.onAllNodesWithTag("preset-name").fetchSemanticsNodes().isNotEmpty() }
            assertNull(model.state.value.draft); assertEquals(.8f, model.state.value.edits.geometry.cropWidth)
            enterName("After draft")
            click("preset-save"); screenshot("draft-after-save")
            assertTrue(compose.onNodeWithTag("preset-root").printToString() + " model=" + model.state.value,
                model.presetStore.list().any { it.name == "After draft" })
        } finally {
            if (runCatching { model.presetStore.list() }.isFailure) { if (original == null) file.delete() else file.writeBytes(original) }
            cleanup(before); source.delete()
        }
    }

    @Test fun processRestartKeepsPresetIndependentOfSource() {
        val phase = InstrumentationRegistry.getArguments().getString("presetPhase")
        org.junit.Assume.assumeTrue("Run with presetPhase=prepare or resume", phase != null)
        val source = File(compose.activity.filesDir, "preset-restart-source.png")
        val target = File(compose.activity.filesDir, "preset-restart-target.png")
        if (phase == "prepare") {
            fixture("restart-source").copyTo(source, overwrite = true)
            fixture("restart-target").copyTo(target, overwrite = true)
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready()
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = 1.1f)) }; ready()
            library(); save("Restart fixture"); click("preset-close")
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(target)) }; ready()
            assertTrue(source.delete())
        } else {
            assertEquals("resume", phase); assertFalse(source.exists())
            val preset = AdjustmentPresetStore(model.presetStore.directory).list().single { it.name == "Restart fixture" }
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(target)) }; ready()
            library(); click("preset-apply-${preset.id}"); click("adjustment-paste-preflight")
            compose.waitUntil(60_000) { model.adjustmentTransfer.value.prepared != null }
            click("adjustment-paste-apply"); ready()
            assertEquals(1.1f, model.state.value.edits.exposure)
            model.presetStore.delete(preset); target.delete()
        }
    }
}
