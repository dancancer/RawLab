package com.rawlab.android

import android.content.Context

object UsageAnalyticsRegistry {
    @Volatile private var instance: UsageAnalytics? = null

    fun get(context: Context): UsageAnalytics = instance ?: synchronized(this) {
        instance ?: create(context.applicationContext ?: context).also { instance = it }
    }

    private fun create(context: Context): UsageAnalytics {
        val preferences = context.getSharedPreferences("usage_analytics_rumlocal", Context.MODE_PRIVATE)
        val configuration = RumLocalConfigurationProvider.load(context)
        val transport = configuration
            ?.takeIf(RumLocalConfiguration::isValid)
            ?.let { RumLocalUsageAnalyticsTransport(context, it) }
            ?: UnavailableUsageTransport
        return UsageAnalytics(SharedPreferencesUsageConsentStore(preferences), transport)
    }
}
