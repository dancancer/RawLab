package com.rawlab.android.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.app.ActivityOptionsCompat
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.PendingLookCompatibility
import com.rawlab.android.editor.ui.LUTCompatibilityDialog
import com.rawlab.android.looks.LUTCompatibility
import com.rawlab.android.photo.PhotoStorage
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
            compose.waitUntilDraftReady(model)
            compose.onNodeWithTag("hdr-rendition-reset").performScrollTo().assertIsEnabled().performClick()
            compose.cancelWorkbenchDraft(model)
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
            compose.onNodeWithTag("x3f-mode-legacy").performScrollTo().performClick()
            compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()
            compose.waitUntilEditorReady(model)
            assertEquals(X3fMode.LEGACY, model.state.value.edits.x3fMode)
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }

    @Test fun lutCompatibilityPickerSmoke() {
        val draft = LUTCompatibility.parse("""{"eligible":true,"source_sha256":"test","fixed_contract":false,"photo_style":"std","extreme_values":false,"hints":[],"contract":{"version":1,"input":{"space":"","reference":"display","range":"full"},"output":{"space":"","reference":"display","range":"full"},"interpolation":"linear","base_rendering":"rawlab-neutral-v1"}}""")!!
        val launched = mutableListOf<Intent>()
        val registry = object : ActivityResultRegistry() {
            override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
                launched += contract.createIntent(compose.activity, input)
            }
        }
        val owner = object : ActivityResultRegistryOwner { override val activityResultRegistry = registry }
        compose.setContent {
            val storage = PhotoStorage(compose.activity)
            CompositionLocalProvider(LocalActivityResultRegistryOwner provides owner) {
                RawLabTheme {
                    LUTCompatibilityDialog(PendingLookCompatibility(Uri.parse("content://test/unknown.cube"), "unknown.cube", draft), null, storage) {}
                }
            }
        }
        compose.onNodeWithTag("lut-reference-section").performScrollTo().performClick()
        compose.onNodeWithTag("lut-reference-picker").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(1, launched.size) }
    }
}
