package com.rawlab.android.editor

import android.app.Application
import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.adjustments.*
import com.rawlab.android.editor.ui.AdjustmentPresetSheet
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.io.File
import java.util.Locale
import java.util.UUID

@RunWith(Parameterized::class)
class AdjustmentPresetLayoutTest(private val language: String) {
    companion object {
        @JvmStatic @Parameterized.Parameters(name = "{0}")
        fun languages() = listOf("zh-Hans", "en", "de", "fr", "ja", "es")
    }
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule(language)).around(compose)

    @Test fun localizedLargeTextKeepsNamesAndActionsReachable() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val owner = ViewModelStore()
        lateinit var model: EditorViewModel
        var saving by mutableStateOf(false)
        val source = File(context.cacheDir, "preset-layout-${UUID.randomUUID()}.png")
        Bitmap.createBitmap(40, 30, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let { bitmap ->
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
        compose.runOnUiThread {
            model = EditorViewModel(context.applicationContext as Application); owner.put("editor", model)
            model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source))
        }
        compose.waitUntil(60_000) { model.state.value.canExport || model.state.value.error != null }
        assertNull(model.state.value.error)
        val name = "Morning light · 明るい朝 · Lang benannte Belichtungsvorgabe · ${UUID.randomUUID()}"
        val preset = model.presetStore.create(name, AdjustmentPayload(AdjustmentSource("layout", true, 2),
            mapOf(AdjustmentField.EXPOSURE to AdjustmentValue.Number(1.25))))
        try {
            compose.setContent {
                val config = Configuration(context.resources.configuration).apply { setLocale(Locale.forLanguageTag(language)); fontScale = 1.6f }
                val density = LocalDensity.current.density
                CompositionLocalProvider(LocalDensity provides Density(density, 1.6f), LocalContext provides context.createConfigurationContext(config), LocalConfiguration provides config) {
                    RawLabTheme { key(language, saving) { AdjustmentPresetSheet(model, saving, {}, {}) } }
                }
            }
            val output = File(context.getExternalFilesDir(null), "adjustment-presets/layout").apply { mkdirs() }
            fun capture(locale: String, suffix: String) {
                File(output, "$locale-$suffix.png").outputStream().use {
                    compose.onNodeWithTag("preset-root").captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
                }
            }
            fun touchTarget(tag: String) {
                val node = compose.onNodeWithTag(tag).performScrollTo().assertIsDisplayed()
                val bounds = node.fetchSemanticsNode().boundsInRoot
                assertTrue("$tag meets 48dp height: $bounds density=${context.resources.displayMetrics.density}",
                    bounds.height >= 48 * context.resources.displayMetrics.density - 1)
            }
            run {
                val locale = language
                compose.runOnIdle { saving = false }
                compose.waitUntil(10_000) { compose.onAllNodesWithTag("preset-apply-${preset.id}").fetchSemanticsNodes().isNotEmpty() }
                compose.waitForIdle()
                val localized = context.createConfigurationContext(Configuration(context.resources.configuration).apply {
                    setLocale(Locale.forLanguageTag(locale))
                })
                compose.onNodeWithTag("preset-apply-${preset.id}").assertTextEquals(localized.getString(R.string.preset_apply))
                capture(locale, "library-before-scroll"); touchTarget("preset-apply-${preset.id}"); capture(locale, "library")
                val layouts = mutableListOf<TextLayoutResult>()
                compose.onNodeWithText(name).performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                assertTrue(layouts.isNotEmpty()); assertTrue(layouts.none { it.hasVisualOverflow })
                compose.runOnIdle { saving = true }
                val field = compose.onNodeWithTag("preset-name")
                field.performTextReplacement(name); field.performImeAction(); compose.waitForIdle()
                touchTarget("preset-save"); compose.onNodeWithTag("preset-save").assertTextEquals(localized.getString(R.string.preset_save)); capture(locale, "save")
                compose.onNodeWithTag("preset-close").assertIsDisplayed()
            }
        } finally { model.presetStore.delete(preset); compose.runOnUiThread { owner.clear() }; source.delete() }
    }
}
