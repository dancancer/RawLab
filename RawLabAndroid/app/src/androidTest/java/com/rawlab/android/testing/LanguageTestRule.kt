package com.rawlab.android.testing

import android.app.LocaleManager
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import android.os.LocaleList
import androidx.activity.ComponentActivity
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Locale
import org.junit.rules.TestRule
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import com.rawlab.android.i18n.AppStrings

class LanguageTestRule(private val language: String = "zh-Hans") : TestWatcher() {
    private var previous = "system"
    private var previousLocales: LocaleList? = null
    private var configuration: Configuration? = null
    override fun starting(description: Description) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        previous = AppStrings.preference(context)
        if (Build.VERSION.SDK_INT >= 33) previousLocales = context.getSystemService(LocaleManager::class.java).applicationLocales
        configuration = Configuration(context.resources.configuration)
        AppStrings.setPreference(context, language)
        val chinese = Configuration(context.resources.configuration)
        chinese.setLocales(if (language == "system") Resources.getSystem().configuration.locales
            else LocaleList(Locale.forLanguageTag(language)))
        @Suppress("DEPRECATION")
        context.resources.updateConfiguration(chinese, context.resources.displayMetrics)
    }
    override fun finished(description: Description) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        if (Build.VERSION.SDK_INT >= 33) context.getSystemService(LocaleManager::class.java).applicationLocales = previousLocales ?: LocaleList.getEmptyLocaleList()
        else AppStrings.setPreference(context, previous)
        configuration?.let {
            @Suppress("DEPRECATION")
            context.resources.updateConfiguration(it, context.resources.displayMetrics)
        }
    }
}

fun ComposeContentTestRule.setChineseContent(content: @Composable () -> Unit) {
    setContent {
        val context = AppStrings.localizedContext(LocalContext.current)
        CompositionLocalProvider(LocalContext provides context,
            LocalConfiguration provides context.resources.configuration, content = content)
    }
}

// 语言门统一语义（TB320FC/SDK35 实测）：系统对 LocaleManager 写入的重建时机随 OEM 而异，
// 身份比较又接不住 ComposeTimeoutException；唯一稳定的可观察量是当前 Activity 的
// resources locale 跟随所选语言（重建与否由 helper 兜底）。
// 等待超时后强制重建再等一次；仍不跟随则抛错并带上 actual/sdk 便于定性。
fun AndroidComposeTestRule<out TestRule, out ComponentActivity>.waitForActivityLocale(language: String, timeoutMs: Long = 15_000) {
    val wanted = Locale.forLanguageTag(language).language
    fun follows(): Boolean = runCatching {
        activity.resources.configuration.locales[0].language == wanted
    }.getOrDefault(false)
    @Suppress("UNCHECKED_CAST")
    fun recreateActivity() = (activityRule as androidx.test.ext.junit.rules.ActivityScenarioRule<ComponentActivity>).scenario.recreate()
    try {
        waitUntil(timeoutMs) { follows() }
    } catch (_: ComposeTimeoutException) {
        recreateActivity()
        try {
            waitUntil(timeoutMs) { follows() }
        } catch (timeout: ComposeTimeoutException) {
            val actual = runCatching { activity.resources.configuration.locales.toLanguageTags() }.getOrDefault("<none>")
            throw AssertionError("Activity locale must follow choice \"$language\": actual=$actual sdk=${Build.VERSION.SDK_INT}", timeout)
        }
    }
}
