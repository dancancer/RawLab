package com.rawlab.android.editor

import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.settings.ProcessingIdentity
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class EditorWorkspaceResetRuntimeTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    @Test fun neutralLegacyAllInGeometryHasZeroSaveAndPreviewEffects() = neutralAll(ProcessingIdentity.LEGACY)
    @Test fun neutralCurrentAllInGeometryHasZeroSaveAndPreviewEffects() = neutralAll(ProcessingIdentity.CURRENT)
    private fun neutralAll(processing: ProcessingIdentity) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val source = File(compose.activity.cacheDir, "neutral-workspace-${System.nanoTime()}.RAW")
        instrumentation.context.assets.open("sample.RAW").use { input -> source.outputStream().use { input.copyTo(it) } }
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(processing = processing)) }
            compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-geometry"))
            compose.onNodeWithTag("editor-group-geometry").performClick()
            compose.waitUntil(180_000) { model.state.value.draftReady }
            val snapshot = model.state.value
            assertFalse(snapshot.draft!!.changed)
            val revision = EditorViewModel::class.java.getDeclaredField("currentRevision").apply { isAccessible = true }
            val beforeRequest = revision.getLong(model)
            val record = File(compose.activity.filesDir, "edits/edits.properties")
            val bytes = record.readBytes()
            compose.onNodeWithContentDescription("重置调整").performClick()
            compose.onNodeWithTag("editor-reset-all").performClick()
            compose.waitForIdle()
            assertSame(snapshot.draft, model.state.value.draft)
            assertSame(snapshot.preview, model.state.value.preview)
            assertEquals(beforeRequest, revision.getLong(model))
            assertArrayEquals(bytes, record.readBytes())
            assertEquals(processing, model.state.value.edits.processing)
            compose.onNodeWithTag("editor-reset-confirm").assertDoesNotExist()
            compose.onNodeWithTag("editor-tool-17").assertIsSelected()
        } finally { source.delete() }
    }
}
