package com.rawlab.android

import android.graphics.Bitmap
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

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
        val directory = requireNotNull(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir("recipe-screenshots"))
        val bitmap = list.captureToImage().asAndroidBitmap()
        File(directory, "master-recipes.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
