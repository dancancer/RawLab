package com.rawlab.android.analytics.rum

import android.content.Context
import java.net.URI
import org.json.JSONObject

// ============================================================================
//  阿里云 RUM 的接入参数与安全前提（不依赖 SDK，调试构建同样编译与测试）
//  - 正式配置只有一份：沿用现有云端应用，正式包 env=PROD，本地验证 env=LOCAL
//  - 远端只开 customevent 的策略由操作者核实；不符的配置一律视为不可用
//  - 随包的 rum_android_config.json 覆盖 SDK 自带默认：只开 customevent、关闭链路追踪
// ============================================================================

data class RumRemoteCollectorPolicy(
    val remoteVerified: Boolean,
    val enabledCollectors: Set<String>,
    val networkConfigVerified: Boolean = false,
    val verifiedServiceId: String? = null,
    val verifiedWorkspace: String? = null,
    val verifiedEndpoint: String? = null,
) {
    fun isSafe(configuration: RumConfiguration): Boolean = remoteVerified &&
        networkConfigVerified &&
        enabledCollectors == setOf("customevent") &&
        verifiedServiceId == configuration.serviceId &&
        verifiedWorkspace == configuration.workspace &&
        verifiedEndpoint == configuration.endpoint
}

data class RumConfiguration(
    val serviceId: String,
    val workspace: String,
    val endpoint: String,
    val remotePolicy: RumRemoteCollectorPolicy,
) {
    fun isValid(): Boolean = serviceId.matches(SERVICE_ID_PATTERN) &&
        workspace.matches(WORKSPACE_PATTERN) &&
        endpointIsShanghaiHttps() &&
        remotePolicy.isSafe(this)

    private fun endpointIsShanghaiHttps(): Boolean = runCatching {
        val uri = URI(endpoint)
        uri.scheme.equals("https", ignoreCase = true) &&
            uri.userInfo == null && uri.query == null && uri.fragment == null &&
            (uri.port == -1 || uri.port == 443) &&
            uri.path.isEmpty() &&
            uri.host?.lowercase()?.endsWith(".cn-shanghai.log.aliyuncs.com") == true
    }.getOrDefault(false)

    companion object {
        // ServiceId 是移动 SDK 的应用 ID，与 ARMS API 的 PID 不能互换（应用 rawlab-rum-local-android）
        private const val SERVICE_ID = "chrtja4hrt@fd771ea48015c6f41b4ba"
        private const val WORKSPACE = "default-cms-1268858473429241-cn-shanghai"
        private const val ENDPOINT = "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com"
        private val SERVICE_ID_PATTERN = Regex("[A-Za-z0-9._@-]{8,128}")
        private val WORKSPACE_PATTERN = Regex("[A-Za-z0-9._-]{1,128}")

        /** 公开接入参数，可以写进源码；客户端不放任何 AccessKey */
        val PRODUCTION = RumConfiguration(
            serviceId = SERVICE_ID,
            workspace = WORKSPACE,
            endpoint = ENDPOINT,
            remotePolicy = RumRemoteCollectorPolicy(
                remoteVerified = true,
                enabledCollectors = setOf("customevent"),
                networkConfigVerified = true,
                verifiedServiceId = SERVICE_ID,
                verifiedWorkspace = WORKSPACE,
                verifiedEndpoint = ENDPOINT,
            ),
        )
    }
}

internal fun interface RumSDKPreflight {
    fun isSafe(context: Context): Boolean
}

internal object BundledRumSDKPreflight : RumSDKPreflight {
    override fun isSafe(context: Context): Boolean = runCatching {
        val root = context.assets.open("rum_android_config.json").bufferedReader().use { JSONObject(it.readText()) }
        if (!root.optBoolean("enable", false)) return false
        if (root.optJSONObject("tracing")?.optBoolean("enable", true) != false) return false
        val collectors = root.optJSONArray("collectors") ?: return false
        val enabled = buildSet {
            for (index in 0 until collectors.length()) {
                val collector = collectors.optJSONObject(index) ?: return@runCatching false
                val name = collector.optString("name", "")
                if (name.isBlank() || !collector.has("enable")) return@runCatching false
                if (collector.optBoolean("enable", false)) add(name)
            }
        }
        enabled == setOf("customevent")
    }.getOrDefault(false)
}
