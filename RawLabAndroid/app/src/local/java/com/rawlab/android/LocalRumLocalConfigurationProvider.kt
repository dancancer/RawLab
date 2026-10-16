package com.rawlab.android

import android.content.Context

object RumLocalConfigurationProvider {
    // ServiceId is the mobile SDK app ID; the ARMS API PID is not interchangeable.
    fun load(context: Context): RumLocalConfiguration = RumLocalConfiguration(
        serviceId = "chrtja4hrt@fd771ea48015c6f41b4ba",
        workspace = "default-cms-1268858473429241-cn-shanghai",
        endpoint = "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com",
        remotePolicy = RumRemoteCollectorPolicy(
            remoteVerified = true,
            enabledCollectors = setOf("customevent"),
            networkConfigVerified = true,
            verifiedServiceId = "chrtja4hrt@fd771ea48015c6f41b4ba",
            verifiedWorkspace = "default-cms-1268858473429241-cn-shanghai",
            verifiedEndpoint = "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com",
        ),
    )
}
