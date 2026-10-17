package com.rawlab.android

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Test

// ============================================================================
//  回归：AppStrings 的语言来源
//  纯 Compose 测试、ViewModel 文案等路径从不经过 MainActivity；
//  它们取到的文字也必须跟随所选语言，不能悄悄退回中文。
// ============================================================================

class AppStringsTest {
    @Test fun lookupFollowsSelectedLanguageWithoutAnyActivity() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val previous = AppStrings.preference(context)
        try {
            AppStrings.setPreference(context, "de")
            assertEquals("Farbton", AppStrings.text(R.string.hsl_hue))
            assertEquals("Korrigiert: Farbton", AppStrings.format(R.string.lens_corrected, "Farbton"))
        } finally {
            AppStrings.setPreference(context, previous)
        }
    }
}
