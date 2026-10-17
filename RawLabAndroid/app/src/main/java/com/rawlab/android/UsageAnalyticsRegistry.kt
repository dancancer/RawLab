package com.rawlab.android

import android.content.Context

// ============================================================================
//  进程内唯一的使用统计实例
//  构建差异只有两处：BuildConfig 里的存储名/默认值，以及 UsageTransportFactory
//  （带 SDK 的构建取 src/rum，其余取 src/nosdk）
// ============================================================================

object UsageAnalyticsRegistry {
    @Volatile private var instance: UsageAnalytics? = null

    fun get(context: Context): UsageAnalytics = instance ?: synchronized(this) {
        instance ?: create(context.applicationContext ?: context).also { instance = it }
    }

    private fun create(context: Context): UsageAnalytics {
        val preferences = context.getSharedPreferences(BuildConfig.USAGE_PREFERENCES, Context.MODE_PRIVATE)
        return UsageAnalytics(
            SharedPreferencesUsageConsentStore(preferences, BuildConfig.USAGE_DEFAULT_ENABLED),
            SharedPreferencesUsageInstallId(preferences),
            UsageTransportFactory.create(context),
        )
    }
}
