package com.rawlab.android

import java.net.URI

data class RumRemoteCollectorPolicy(
    val remoteVerified: Boolean,
    val enabledCollectors: Set<String>,
    val networkConfigVerified: Boolean = false,
    val verifiedServiceId: String? = null,
    val verifiedWorkspace: String? = null,
    val verifiedEndpoint: String? = null,
) {
    fun isSafe(configuration: RumLocalConfiguration): Boolean = remoteVerified &&
        networkConfigVerified &&
        enabledCollectors == setOf("customevent") &&
        verifiedServiceId == configuration.serviceId &&
        verifiedWorkspace == configuration.workspace &&
        verifiedEndpoint == configuration.endpoint
}

data class RumLocalConfiguration(
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

    private companion object {
        val SERVICE_ID_PATTERN = Regex("[A-Za-z0-9._@-]{8,128}")
        val WORKSPACE_PATTERN = Regex("[A-Za-z0-9._-]{1,128}")
    }
}
