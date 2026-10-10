package com.rawlab.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.junit.Rule
import org.junit.Test

class AboutScreenTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun aboutLinksManualCheckAndOptOutRemainReachable() {
        compose.onNodeWithContentDescription("更多").performClick()
        compose.onNodeWithText("关于 RawLab").performClick()
        compose.onNodeWithText("GitHub 仓库").assertIsDisplayed()
        compose.onNodeWithText("作者的小红书主页").assertIsDisplayed()
        val version = compose.activity.packageManager.getPackageInfo(compose.activity.packageName, 0).versionName
        compose.onNodeWithText("版本 $version").assertIsDisplayed()
        compose.onNodeWithText("检查更新").assertExists()
        val automatic = compose.activity.updates.state.value.automatic
        compose.onNodeWithContentDescription("自动检查更新").performClick()
        compose.runOnIdle { check(compose.activity.updates.state.value.automatic != automatic) }
        compose.activityRule.scenario.recreate()
        compose.waitForIdle()
        compose.onNodeWithText("作者的小红书主页").assertIsDisplayed()
        compose.runOnIdle { check(compose.activity.updates.state.value.automatic != automatic) }
        compose.onNodeWithContentDescription("自动检查更新").performClick()
        compose.onNodeWithText("确定").performClick()
        compose.onNodeWithText("关于 RawLab").assertDoesNotExist()
    }
}
