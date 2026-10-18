package com.rawlab.android.testing

import android.app.LocaleManager
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Locale
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import com.rawlab.android.i18n.AppStrings

class LanguageTestRule : TestWatcher() {
    private var previous = "system"
    private var previousLocales: LocaleList? = null
    private var configuration: Configuration? = null
    override fun starting(description: Description) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        previous = AppStrings.preference(context)
        if (Build.VERSION.SDK_INT >= 33) previousLocales = context.getSystemService(LocaleManager::class.java).applicationLocales
        configuration = Configuration(context.resources.configuration)
        AppStrings.setPreference(context, "zh-Hans")
        val chinese = Configuration(context.resources.configuration)
        chinese.setLocales(LocaleList(Locale.forLanguageTag("zh-Hans")))
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
