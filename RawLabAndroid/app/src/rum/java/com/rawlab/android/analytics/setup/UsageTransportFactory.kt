package com.rawlab.android.analytics.setup

import android.content.Context
import com.rawlab.android.BuildConfig
import com.rawlab.android.analytics.UsageAnalyticsTransport
import com.rawlab.android.analytics.rum.AlibabaRumSDKClient
import com.rawlab.android.analytics.rum.RumConfiguration
import com.rawlab.android.analytics.rum.RumUsageAnalyticsTransport

// ============================================================================
//  带统计 SDK 的构建：正式包（env=PROD），以及 -PrawlabRumLocal=true 的本地验证
//  Debug（env=LOCAL）。环境与版本号来自 BuildConfig，接入参数只有一份正式配置。
//  实网验证探针与正式包走同一条构造路径，只多一个 validation_run 标记。
// ============================================================================

internal object UsageTransportFactory {
    fun create(context: Context): UsageAnalyticsTransport = rum(context, BuildConfig.RUM_ENVIRONMENT)

    fun rum(context: Context, environment: String, validationRun: String? = null) = RumUsageAnalyticsTransport(
        context = context,
        configuration = RumConfiguration.PRODUCTION,
        sdk = AlibabaRumSDKClient(environment, BuildConfig.VERSION_NAME),
        validationRun = validationRun,
    )
}
