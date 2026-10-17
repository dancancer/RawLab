package com.rawlab.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.junit.Rule
import org.junit.Test

class AboutScreenTest {
    val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun nestedLensLicensesAreReadable() {
        compose.onNodeWithContentDescription("更多").performClick()
        compose.onNodeWithText(compose.activity.getString(R.string.licenses)).performClick()
        compose.waitUntil(15_000) {
            compose.onAllNodes(hasText("GLib-COPYING", substring = true)).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("确定").performClick()
    }

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

    // 调试构建不带 SDK：开关仍反映默认开启的同意值，状态行说明不可用，用户仍可关闭
    @Test fun usageSwitchShowsConsentAndAllowsOptOutWhenBuildHasNoTransport() {
        val preferences = compose.activity.getSharedPreferences(BuildConfig.USAGE_PREFERENCES, android.content.Context.MODE_PRIVATE)
        try {
            compose.onNodeWithContentDescription("更多").performClick()
            compose.onNodeWithText("关于 RawLab").performClick()
            compose.onNodeWithText("为统计活跃设备数，应用会在本机保存一个随机生成的安装标识，不含个人信息；关闭统计时一并删除。")
                .performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("当前构建未配置使用统计，未采集或上报。").performScrollTo().assertIsDisplayed()
            val usage = compose.onNodeWithContentDescription("使用统计").performScrollTo()
            usage.assertIsOn().assertIsEnabled().performClick()
            usage.assertIsOff().assertIsNotEnabled()
            compose.runOnIdle { check(!preferences.getBoolean("enabled", true)) }
        } finally {
            check(preferences.edit().remove("enabled").commit())
        }
    }
}
