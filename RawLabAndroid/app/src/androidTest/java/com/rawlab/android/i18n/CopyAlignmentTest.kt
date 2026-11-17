package com.rawlab.android.i18n

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.testing.openEditorMenu
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.waitForActivityLocale
import java.io.File
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test

class CopyAlignmentTest {
    val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun chineseAndEnglishCopyRemainsReachable() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = File(context.cacheDir, "copy-alignment.RAW")
        instrumentation.context.assets.open("sample.RAW").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        try {
            for (language in listOf("zh-Hans", "en")) {
                compose.runOnUiThread { AppStrings.setPreference(compose.activity, language) }
                compose.waitForActivityLocale(language, timeoutMs = 30_000)
                val model = compose.activity.model
                compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
                compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
                assertNull(model.state.value.error)
                capture("editor-$language")
                compose.onNodeWithContentDescription(AppStrings.text(R.string.export)).performClick()
                capture("export-$language")
                compose.onNodeWithText(AppStrings.text(R.string.cancel)).performClick()
                compose.openEditorMenu()
                compose.onNodeWithText(AppStrings.text(R.string.about_rawlab)).performScrollTo().assertIsDisplayed().performClick()
                compose.onNodeWithContentDescription(AppStrings.text(R.string.usage_analytics))
                    .performScrollTo().assertIsDisplayed()
                capture("about-$language")
                compose.onNodeWithText(AppStrings.text(R.string.confirm)).performClick()
            }
        } finally {
            source.delete()
        }
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.waitForIdle(1_000, 5_000)
        val image = automation.takeScreenshot()
        val directory = File(compose.activity.getExternalFilesDir(null), "copy-alignment").apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
