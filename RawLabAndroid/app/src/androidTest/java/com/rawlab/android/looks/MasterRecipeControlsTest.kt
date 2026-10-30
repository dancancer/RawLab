package com.rawlab.android.looks

import android.graphics.Bitmap
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.ui.MasterRecipePicker
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.setChineseContent

class MasterRecipeControlsTest {
    // 配方名随界面语言变化：固定为中文，断言用原名
    val compose = createComposeRule()
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)
    @Test fun presetSelectionAndDragScrollingAreReachable() {
        val recipes = MasterRecipe.load(InstrumentationRegistry.getInstrumentation().targetContext)
        var current = EditSettings()
        compose.setChineseContent {
            var selected by remember { mutableStateOf<String?>(null) }
            RawLabTheme {
                Surface(Modifier.width(360.dp)) {
                    MasterRecipePicker(recipes, selected, true) { recipe ->
                        current = if (recipe == null) current.selectFilm("neutral") else current.applyRecipe(recipe)
                        selected = current.recipeID
                    }
                }
            }
        }
        // 配方卡显示随包附带的插图，而不是通用图标
        compose.waitUntil(10_000) {
            compose.onAllNodesWithTag("recipe-artwork-${recipes[0].id}", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithContentDescription("向左滚动大师配方").assertDoesNotExist()
        compose.onNodeWithContentDescription("向右滚动大师配方").assertDoesNotExist()
        val list = compose.onNodeWithTag("master-recipe-choices")
        repeat(12) { list.performTouchInput { swipeLeft() } }
        compose.onNodeWithText(recipes.last().name).assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(recipes.last().id, current.recipeID) }
        repeat(12) { list.performTouchInput { swipeRight() } }
        compose.onNodeWithText("滨田英明").performClick()
        compose.runOnIdle {
            assertEquals(recipes[0].id, current.recipeID)
            assertEquals(4f, current.hsl.value(1, 4))
        }
        compose.onNodeWithTag("recipe-selected-${recipes[0].id}", useUnmergedTree = true).assertIsDisplayed()
        val directory = requireNotNull(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir("recipe-screenshots"))
        val bitmap = list.captureToImage().asAndroidBitmap()
        File(directory, "master-recipes.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    // 配方横排与胶片条一样留出左右边距：第一张卡片不贴屏幕边缘
    @Test fun recipeRowKeepsAnEdgeInset() {
        val recipes = MasterRecipe.load(InstrumentationRegistry.getInstrumentation().targetContext)
        compose.setChineseContent {
            RawLabTheme { Surface(Modifier.width(360.dp)) { MasterRecipePicker(recipes, null, true) { } } }
        }
        val list = compose.onNodeWithTag("master-recipe-choices").fetchSemanticsNode().boundsInRoot
        val first = compose.onAllNodes(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.RadioButton))
            .fetchSemanticsNodes().minOf { it.boundsInRoot.left }
        val inset = with(compose.density) { (first - list.left).toDp() }
        assertTrue("inset=$inset", inset >= 12.dp)
    }
}
