package com.rawlab.android.testing

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeTestRule
import android.view.KeyEvent
import androidx.test.platform.app.InstrumentationRegistry

/** 返回宫格时保留产品的离开确认；有未提交修改的调用方须先明确应用或取消。 */
fun ComposeTestRule.returnToWorkbench() {
    if (onAllNodesWithTag("workspace-more").fetchSemanticsNodes().isNotEmpty()) {
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        waitUntil(5_000) { onAllNodesWithTag("editor-groups").fetchSemanticsNodes().isNotEmpty() }
    }
    onNodeWithTag("editor-groups").assertIsDisplayed()
}

fun ComposeTestRule.requestWorkbenchLeave() {
    onNodeWithTag("workspace-more").assertIsDisplayed()
    InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
    val title = com.rawlab.android.i18n.AppStrings.text(com.rawlab.android.R.string.adjustment_leave)
    waitUntil(5_000) { onAllNodesWithText(title).fetchSemanticsNodes().isNotEmpty() }
    onNodeWithText(title).assertIsDisplayed()
}

fun ComposeTestRule.selectWorkbenchGroup(group: String) {
    returnToWorkbench()
    onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-$group"))
    onNodeWithTag("editor-group-$group").performClick().assertIsSelected()
}

/** 宫格和参数页分开定位，避免把已移除的横向工具条当成可达性证据。 */
fun ComposeTestRule.workbenchTool(tool: Int): SemanticsNodeInteraction {
    val group = when (tool) {
        0, 15 -> "looks"
        2, 3, 4, 5, 6, 18, 19 -> "light"
        7, 8, 14, 20, 21 -> "color"
        10, 11 -> "detail"
        16, 17 -> "geometry"
        12, 13, 22, 23 -> "effects"
        24, 25, 26, 27 -> "hdrRendition"
        else -> error("No workbench grid entry for tool $tool")
    }
    selectWorkbenchGroup(group)
    return onNodeWithTag("editor-tool-$tool").performScrollTo().assertIsDisplayed()
}

fun ComposeTestRule.openWorkbenchTool(tool: Int) {
    workbenchTool(tool).assertIsEnabled().performClick()
    onNodeWithTag("editor-parameters").assertIsDisplayed()
    onNodeWithTag("editor-groups").assertDoesNotExist()
}

fun ComposeTestRule.openWorkbenchMore() {
    onNodeWithTag("workspace-more").assertIsDisplayed().performTouchInput { click() }
}

fun ComposeTestRule.dismissWorkbenchMenu() {
    InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
    waitUntil(5_000) { onAllNodesWithTag("adjustment-fine").fetchSemanticsNodes().isEmpty() }
    onNodeWithTag("editor-parameters").assertIsDisplayed()
}

fun ComposeTestRule.openEditorMenu() {
    onNodeWithTag("editor-menu").assertIsDisplayed().performTouchInput { click() }
}

fun ComposeTestRule.toggleWorkbenchFine() {
    openWorkbenchMore()
    onNodeWithTag("adjustment-fine").assertIsDisplayed().performClick()
}

fun ComposeTestRule.assertWorkbenchFine(selected: Boolean) {
    openWorkbenchMore()
    val item = onNodeWithTag("adjustment-fine").assertIsDisplayed().assertHasClickAction()
    if (selected) item.assertIsSelected() else item.assertIsNotSelected()
    dismissWorkbenchMenu()
}

fun ComposeTestRule.toggleWorkbenchHistogram() {
    if (onAllNodesWithTag("workspace-more").fetchSemanticsNodes().isNotEmpty()) {
        openWorkbenchMore()
        onNodeWithTag("workspace-histogram").assertIsDisplayed().performClick()
    } else {
        openEditorMenu()
        onNodeWithText(com.rawlab.android.i18n.AppStrings.text(com.rawlab.android.R.string.editor_rgb_histogram))
            .performScrollTo().assertIsDisplayed().performClick()
    }
}

fun ComposeTestRule.chooseGeometryMenuItem(tag: String) {
    onNodeWithTag("geometry.ratios").performScrollTo().assertIsDisplayed().performClick()
    onNodeWithTag(tag).performScrollTo().assertIsDisplayed().performClick()
}

fun ComposeTestRule.openGeometryDimensions() {
    chooseGeometryMenuItem("geometry.dimensions")
    onNodeWithTag("adjustment-value-${com.rawlab.android.R.string.geometry_crop_width}").assertIsDisplayed()
}

fun ComposeTestRule.cycleWorkbenchPhotoInfo(label: String) {
    if (onAllNodesWithTag("workspace-more").fetchSemanticsNodes().isNotEmpty()) openWorkbenchMore()
    else openEditorMenu()
    onNodeWithText(label).performScrollTo().assertIsDisplayed().performClick()
}
