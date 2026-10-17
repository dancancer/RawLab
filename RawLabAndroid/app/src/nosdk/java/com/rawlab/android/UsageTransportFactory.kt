package com.rawlab.android

import android.content.Context

// ============================================================================
//  不带统计 SDK 的构建（默认 Debug，或 -PrawlabRumRelease=false 的离线正式包）
//  统计不可用；开关仍反映同意值，用户仍可关闭
// ============================================================================

internal object UsageTransportFactory {
    @Suppress("UNUSED_PARAMETER")
    fun create(context: Context): UsageAnalyticsTransport = UnavailableUsageTransport
}
