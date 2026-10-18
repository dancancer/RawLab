package com.rawlab.android.analytics.rum

import android.content.Context
import com.alibabacloud.rum.AlibabaCloudRum
import com.rawlab.android.analytics.UsageRecord

// ============================================================================
//  供应商 SDK 的唯一接触面
//  其余统计代码只依赖 RumSDKClient 接口，因此默认 Debug 可以完全不带 SDK。
//  设备标识只用应用自己生成的安装标识；应用名由 SDK 读取应用标签（RawLab）。
// ============================================================================

internal class AlibabaRumSDKClient(
    private val environment: String,
    private val appVersion: String,
) : RumSDKClient {
    override fun start(context: Context, configuration: RumConfiguration, deviceId: String) {
        AlibabaCloudRum.withServiceId(configuration.serviceId)
            .withWorkspace(configuration.workspace)
            .withEndpoint(configuration.endpoint)
            .withDeviceID(deviceId)
            .withAppVersion(appVersion)
            .withEnvironment(AlibabaCloudRum.Env.valueOf(environment))
            .also { AlibabaCloudRum.setSelfMonitor(false) }
            .start(context, false)
    }

    override fun record(record: UsageRecord, validationRun: String?) {
        val properties = record.properties.toMutableMap().apply {
            if (validationRun != null) put("validation_run", validationRun)
        }
        AlibabaCloudRum.setCustomEvent(
            record.name,
            record.group,
            null,
            record.value.toDouble(),
            properties.toMap(),
        )
    }

    override fun stop() = AlibabaCloudRum.stop()
}
