package com.rawlab.android

import android.content.Context

object UsageAnalyticsRegistry {
    @Volatile private var instance: UsageAnalytics? = null

    fun get(context: Context): UsageAnalytics = instance ?: synchronized(this) {
        instance ?: UsageAnalytics(
            SharedPreferencesUsageConsentStore(
                context.applicationContext.getSharedPreferences("usage_analytics", Context.MODE_PRIVATE),
            ),
            UnavailableUsageTransport,
        ).also { instance = it }
    }
}
