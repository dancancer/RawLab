package com.rawlab.android

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

// ============================================================================
//  使用统计的本机存储：同意值的默认与损坏处理，安装标识的生成、保存、删除与重建
//  用独立的测试文件，不碰应用自己的 usage_analytics
// ============================================================================

class UsagePreferencesTest {
    private val preferences = InstrumentationRegistry.getInstrumentation().targetContext
        .getSharedPreferences("usage_analytics_test", Context.MODE_PRIVATE)

    @Before @After fun clear() {
        check(preferences.edit().clear().commit())
    }

    @Test fun missingChoiceMeansEnabled() {
        assertTrue(SharedPreferencesUsageConsentStore(preferences).load())
    }

    @Test fun explicitOptOutStaysOff() {
        SharedPreferencesUsageConsentStore(preferences).save(false)
        assertFalse(SharedPreferencesUsageConsentStore(preferences).load())
    }

    @Test fun unreadableChoiceThrowsInsteadOfGuessing() {
        check(preferences.edit().putString("enabled", "yes").commit())
        assertTrue(runCatching { SharedPreferencesUsageConsentStore(preferences).load() }.isFailure)
    }

    @Test fun installIdIsARandomVersion4UuidThatPersists() {
        val id = SharedPreferencesUsageInstallId(preferences).obtain()

        assertEquals(4, UUID.fromString(id).version())
        assertEquals(id, preferences.getString("install_id", null))
        assertEquals(id, SharedPreferencesUsageInstallId(preferences).obtain())
    }

    @Test fun deletedInstallIdIsRegeneratedAsANewValue() {
        val installId = SharedPreferencesUsageInstallId(preferences)
        val first = installId.obtain()

        installId.delete()
        assertNull(preferences.getString("install_id", null))
        assertNotEquals(first, installId.obtain())
    }

    @Test fun malformedInstallIdIsReplaced() {
        check(preferences.edit().putString("install_id", "not-a-uuid").commit())
        assertEquals(4, UUID.fromString(SharedPreferencesUsageInstallId(preferences).obtain()).version())
    }
}
