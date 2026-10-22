package com.rawlab.android.editor.geometry

import android.graphics.Bitmap
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import kotlin.math.roundToInt

class PhotoViewLayoutTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)
    @Test fun chineseNarrowLarge() = verify("zh-Hans")
    @Test fun englishNarrowLarge() = verify("en")
    @Test fun japaneseNarrowLarge() = verify("ja")
    @Test fun germanNarrowLarge() = verify("de")
    @Test fun frenchNarrowLarge() = verify("fr")
    @Test fun spanishNarrowLarge() = verify("es")
    private fun verify(language: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).use { it.readBytes() }
        val density = compose.activity.resources.displayMetrics.density
        val source = File(compose.activity.cacheDir, "view-layout-${System.nanoTime()}.jpg")
        val bitmap = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }; bitmap.recycle()
        try {
            shell("wm size ${(320 * density).roundToInt()}x${(720 * density).roundToInt()}")
            shell("settings put system font_scale 1.6")
            compose.runOnUiThread { AppStrings.setPreference(compose.activity, language) }
            compose.waitUntil(20_000) { compose.activity.resources.configuration.let {
                it.locales[0].language == language.substringBefore('-') && it.fontScale == 1.6f && it.screenWidthDp == 320
            } }
            compose.runOnUiThread { compose.activity.model.setGpuEnabled(false); compose.activity.model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntil(180_000) { compose.activity.model.state.value.let { it.canExport || it.error != null } }
            assertNull(compose.activity.model.state.value.error)
            fun text(id: Int) = compose.activity.getString(id)
            compose.onNodeWithContentDescription(text(R.string.editor_compare_enable)).performClick()
            val canvas = compose.onNodeWithTag("editor-canvas").fetchSemanticsNode().boundsInRoot
            for (tag in listOf("comparison-mode", "photo-info-button")) {
                val rect = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
                assertTrue("$language $tag is a full 48dp target in the photo: $rect $canvas", rect.width >= 48 * density - 1 && rect.height >= 48 * density - 1 && rect.left >= canvas.left && rect.right <= canvas.right && rect.top >= canvas.top && rect.bottom <= canvas.bottom)
            }
            compose.onNodeWithTag("comparison-mode").performClick()
            for (id in listOf(R.string.editor_compare_side_by_side, R.string.editor_compare_wipe, R.string.editor_compare_disable)) {
                val node = compose.onNodeWithText(text(id)).performScrollTo().assertIsDisplayed()
                val layouts = mutableListOf<TextLayoutResult>()
                node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val layout = layouts.single(); val rect = node.fetchSemanticsNode().boundsInRoot
                android.util.Log.i("RawLabViewLabelEvidence", "locale=$language id=$id text=${text(id)} size=${layout.size} lines=${layout.lineCount} widthOverflow=${layout.didOverflowWidth} heightOverflow=${layout.didOverflowHeight} lastRight=${layout.getLineRight(layout.lineCount - 1)} rect=$rect")
                assertFalse("$language menu has no clipped lines", layout.didOverflowHeight)
                for (line in 0 until layout.lineCount) assertTrue("$language complete glyph line fits measured bounds", !layout.isLineEllipsized(line) && layout.getLineLeft(line) >= -1f && layout.getLineRight(line) <= layout.size.width + 1f)
                assertTrue("$language whole localized label is visible", rect.width >= layout.size.width - 1 && rect.height >= layout.size.height - 1)
            }
            compose.onNodeWithText(text(R.string.editor_compare_wipe)).performClick()
            compose.onNodeWithTag("comparison-wipe").assertIsDisplayed()
            val dir = File(compose.activity.getExternalFilesDir(null), "view-layout").apply { mkdirs() }
            File(dir, "$language-320-1.6.png").outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
            android.util.Log.i("RawLabViewLayoutEvidence", "locale=$language font=1.6 width=320 density=$density canvas=$canvas wipe=${compose.onNodeWithTag("comparison-wipe").fetchSemanticsNode().boundsInRoot}")
        } finally { shell("wm size reset"); shell("settings put system font_scale 1.0"); source.delete() }
    }
}
