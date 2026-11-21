package com.rawlab.android.ui

import android.net.Uri
import android.os.Build
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.X3fMode
import com.rawlab.android.testing.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.UUID

class HdrAndX3fUiSmokeTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule("zh-Hans")).around(ForegroundTestRule()).around(compose)

    @Test fun hdrSilverLookAndRenditionResetSmoke() {
        assumeTrue(Build.VERSION.SDK_INT >= 29)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(instrumentation.context.assets.list("")!!.contains("hdr-sample.jpg"))
        val source = File(compose.activity.cacheDir, "hdr-smoke-${UUID.randomUUID()}.jpg")
        instrumentation.context.assets.open("hdr-sample.jpg").use { input -> source.outputStream().use(input::copyTo) }
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntilEditorReady(model)

            compose.openWorkbenchTool(0)
            compose.onNodeWithTag("hdr-look-silver").performScrollTo().performClick()
            compose.waitUntil(30_000) { model.state.value.visibleEdits.hdr?.lookSettings?.name == "HDR Silver" }
            compose.applyWorkbenchDraft(model)

            compose.openWorkbenchTool(25)
            compose.setNumericAdjustmentValue(R.string.hdr_sdr_exposure, "1.2")
            compose.applyWorkbenchDraft(model)
            assertEquals(1.2f, model.state.value.edits.hdr?.renditionSettings?.sdrExposureEV ?: 0f, 0.01f)

            compose.openEditorMenu()
            compose.onNodeWithText(compose.activity.getString(R.string.editor_settings)).performScrollTo().performClick()
            compose.onNodeWithTag("hdr-rendition").performScrollTo().performClick()
            compose.onNodeWithTag("hdr-rendition-reset").performScrollTo().assertIsEnabled().performClick()
            compose.waitUntil(30_000) { model.state.value.edits.hdr?.renditionSettings?.isDefault == true }
            compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()
            compose.waitUntilEditorReady(model)
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }

    @Test fun x3fModeSwitchSmoke() {
        val source = File(compose.activity.cacheDir, "x3f-smoke-${UUID.randomUUID()}.X3F")
        InstrumentationRegistry.getInstrumentation().context.assets.open("sample.X3F").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntilEditorReady(model)
            assertEquals(X3fMode.NORMAL, model.state.value.edits.x3fMode)

            compose.openWorkbenchMenuItem("processing-settings")
            compose.onNodeWithTag("x3f.mode.legacy").performScrollTo().performClick()
            compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()
            compose.waitUntilEditorReady(model)
            assertEquals(X3fMode.LEGACY, model.state.value.edits.x3fMode)
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }
}
