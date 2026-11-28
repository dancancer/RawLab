package com.rawlab.android.camera

import com.rawlab.android.diagnostics.DiagnosticRegistry
import com.rawlab.android.diagnostics.DiagnosticSessionStore

internal class CameraDiagnosticException(message: String) : RuntimeException(message)

/**
 * 相机连接与会话的脱敏诊断桥接：仅记录阶段、状态码与不含 SSID/密码/MAC/IP/文件名的上下文。
 */
internal object CameraDiagnostics {
    @Volatile
    internal var storeOverride: DiagnosticSessionStore? = null

    private fun store(): DiagnosticSessionStore? = storeOverride ?: DiagnosticRegistry.peek()

    fun breadcrumb(
        stage: String,
        message: String,
        level: String = "info",
        context: Map<String, String> = emptyMap(),
    ) {
        store()?.recordBreadcrumb(
            level = level,
            category = "camera",
            stage = stage,
            message = SonySshTunnel.redactIps(message),
            context = context.mapValues { (_, value) -> SonySshTunnel.redactIps(value) },
        )
    }

    fun error(
        stage: String,
        error: Throwable,
        context: Map<String, String> = emptyMap(),
    ) {
        val redactedMessage = SonySshTunnel.redactIps(error.message ?: error.javaClass.simpleName)
        val safeError = if (error is CameraDiagnosticException || redactedMessage == error.message) {
            error
        } else {
            CameraDiagnosticException("${error.javaClass.simpleName}: $redactedMessage")
        }
        store()?.recordError(
            operation = "camera",
            stage = stage,
            error = safeError,
            context = context.mapValues { (_, value) -> SonySshTunnel.redactIps(value) },
        )
    }

    fun failure(
        stage: String,
        reason: String,
        detail: String? = null,
        context: Map<String, String> = emptyMap(),
    ) {
        val message = if (detail.isNullOrBlank()) reason else "$reason: $detail"
        error(
            stage = stage,
            error = CameraDiagnosticException(message),
            context = context + ("reason" to reason),
        )
    }
}
