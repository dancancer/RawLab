package com.rawlab.android.editor

import android.net.Uri
import android.content.ContentUris
import android.provider.MediaStore
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.engine.NativeHDRBridge
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.looks.LUTCompatibility
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

class HDRWorkflowTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun freshImportPresetMonitoringModeSwitchAndExportChoices() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue("Supply -PrawlabTestHDRJPEG", instrumentation.context.assets.list("")!!.contains("hdr-sample.jpg"))
        val source = File(compose.activity.cacheDir, "hdr-ui-${UUID.randomUUID()}.jpg")
        val screenshots=File(compose.activity.getExternalFilesDir(null),"hdr-tests").apply { mkdirs() }
        fun capture(name: String) {
            compose.waitForIdle()
            val bitmap=requireNotNull(instrumentation.uiAutomation.takeScreenshot())
            File(screenshots,name).outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) }
            bitmap.recycle()
        }
        val look = File(compose.activity.cacheDir,"hdr-ui-${UUID.randomUUID()}.cube").apply {
            writeText("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
        }
        instrumentation.context.assets.open("hdr-sample.jpg").use { input -> source.outputStream().use { input.copyTo(it) } }
        try {
            compose.runOnUiThread { compose.activity.model.importPhoto(Uri.fromFile(source)) }
            fun ready() = compose.waitUntil(120_000) {
                val state = compose.activity.model.state.value
                if (state.error != null) throw AssertionError(state.error)
                state.canExport
            }
            ready()
            capture("hdr-editor.png")
            compose.runOnIdle {
                assertTrue(compose.activity.model.state.value.edits.isHDREditing)
                assertEquals(EditSaveState.NONE,compose.activity.model.state.value.saveState)
            }
            val captured = AtomicReference<Result<AdjustmentPayload>?>(null)
            compose.runOnUiThread { compose.activity.model.capturePresetAdjustments(AdjustmentScope.All) { captured.set(it) } }
            compose.waitUntil(15_000) { captured.get() != null }
            assertEquals(2, captured.get()!!.getOrThrow().payloadVersion)
            compose.onNodeWithTag("hdr-monitoring").performClick()
            compose.onNodeWithTag("hdr-histogram").assertExists()
            compose.onNodeWithTag("hdr-preview-sdr").performClick()
            compose.onNodeWithTag("hdr-false-color").performClick().assertIsOn()
            compose.waitUntil(15_000) { compose.onAllNodes(SemanticsMatcher.expectValue(
                androidx.compose.ui.semantics.SemanticsProperties.StateDescription,compose.activity.getString(R.string.hdr_false_color))).fetchSemanticsNodes().isNotEmpty() }
            capture("hdr-monitoring.png")
            compose.onNodeWithTag("hdr-false-color").performClick().assertIsOff()
            compose.onNodeWithTag("hdr-preview-auto").performClick()
            compose.onNodeWithTag("hdr-monitoring").performClick()
            fun mode(enabled: Boolean) {
                compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
                compose.onNodeWithText(compose.activity.getString(R.string.editor_settings)).performClick()
                compose.onNodeWithTag("hdr-editing").performClick()
                compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()
                ready()
                compose.runOnIdle { assertEquals(enabled, compose.activity.model.state.value.edits.isHDREditing) }
            }
            mode(false)
            compose.onNodeWithTag("hdr-monitoring").assertDoesNotExist()
            val draft=requireNotNull(LUTCompatibility.parse(NativeProcessor.inspectLutCompatibility(look)))
            compose.runOnUiThread { compose.activity.model.importLook(Uri.fromFile(look)) }
            val candidate=draft.candidates.first { draft.applying(it,true)!=null }
            compose.waitUntil(60_000) { compose.onAllNodes(hasTestTag("lut-${candidate.id}") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("lut-${candidate.id}").performScrollTo().performClick()
            compose.onNodeWithTag("lut-compatibility-confirm").assertIsEnabled()
            capture("sdr-lut-wizard.png")
            compose.onNodeWithText(compose.activity.getString(R.string.cancel)).performClick()
            ready()
            mode(true)
            compose.onNodeWithContentDescription(compose.activity.getString(R.string.export)).performClick()
            compose.onNodeWithTag("export-format-HDR_JPEG").assertExists().assertIsSelected()
            capture("hdr-export.png")
            compose.onNodeWithTag("export-format-JPEG").performClick().assertIsSelected()
            compose.onNodeWithTag("export-format-PNG").performClick().assertIsSelected()
            compose.onNodeWithTag("export-format-DNG").performClick().assertIsSelected()
            compose.onNodeWithTag("export-format-HDR_JPEG").performClick()
            compose.onNodeWithTag("export-size").performScrollTo().performClick()
            compose.onNodeWithTag("export-size-custom").performClick()
            compose.onNodeWithTag("export-size-custom-value").performScrollTo().performTextReplacement("128")
            compose.onNodeWithText(compose.activity.getString(R.string.save_album)).performScrollTo().performClick()
            val resolver=compose.activity.contentResolver
            fun gallery(): Set<Long> = resolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Images.Media._ID),"${MediaStore.Images.Media.RELATIVE_PATH} = ?",arrayOf("Pictures/RawLab/"),null)!!.use { cursor ->
                buildSet { while(cursor.moveToNext())add(cursor.getLong(0)) }
            }
            val before=gallery()
            compose.onNode(hasText(compose.activity.getString(R.string.export)) and hasClickAction()).performClick()
            ready()
            val created=gallery()-before
            try {
                assertEquals(1,created.size)
                val uri=ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,created.single())
                val copy=File(compose.activity.cacheDir,"hdr-gallery-${UUID.randomUUID()}.jpg")
                try {
                    resolver.openInputStream(uri)!!.use { input -> copy.outputStream().use { input.copyTo(it) } }
                    val info=requireNotNull(NativeHDRBridge.probe(copy))
                    assertEquals(128,maxOf(info.width,info.height))
                } finally { copy.delete() }
            } finally { created.forEach { resolver.delete(ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,it),null,null) } }
        } finally { source.delete();look.delete() }
    }
}
