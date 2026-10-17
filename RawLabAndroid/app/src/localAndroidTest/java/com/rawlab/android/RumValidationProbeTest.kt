package com.rawlab.android

import android.Manifest
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

// ============================================================================
//  实网验证探针：发送 5 条带随机标记的合成事件，随后由操作者用 API 回读
//  - 只在显式传入全部 instrumentation 参数时运行；普通测试一律跳过，绝不发送
//  - rumEnvironment=PROD 时走与正式包相同的构造路径（UsageTransportFactory.rum），
//    正式配置、真实版本号，只多一个 validation_run 字段；LOCAL 仍是验证环境
//  - 用探针自己的随机安装标识，不读写用户的同意值与安装标识
// ============================================================================

@RunWith(AndroidJUnit4::class)
class RumValidationProbeTest {
    @Test
    @SdkSuppress(minSdkVersion = 29)
    @RequiresApi(29)
    fun sendSyntheticUsageEventsOnlyWhenExplicitlyEnabled() {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue(arguments.getString("rumProbe") == "true")
        check(arguments.getString("rumLimitVerified") == "true") { "rumLimitVerified gate is required" }
        check(arguments.getString("rumNetwork") == "china-telecom") { "rumNetwork gate is required" }
        check(arguments.getString("rumConfigVerified") == "true") { "rumConfigVerified gate is required" }
        val environment = arguments.getString("rumEnvironment")
            ?.takeIf { it in setOf("LOCAL", "PROD") }
            ?: error("rumEnvironment must be LOCAL or PROD")
        val validationRun = arguments.getString("rumValidationRun")
            ?.takeIf { runCatching { UUID.fromString(it) }.isSuccess }
            ?: error("rumValidationRun is required")

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertNetworkPreflight(context)
        check(RumConfiguration.PRODUCTION.isValid()) { "operator-verified RUM configuration is unavailable" }
        val transport = UsageTransportFactory.rum(context, environment, validationRun)
        check(transport.isAvailable) { "SDK safety preflight rejected the bundled policy" }
        val issues = mutableListOf<UsageIssue>()
        transport.setIssueListener { issue -> synchronized(issues) { issues += issue } }
        try {
            transport.start(UUID.randomUUID().toString())
            check(transport.awaitIdle(5_000)) { "SDK start did not drain" }
            assertNoUnexpectedIssues(issues, "start")
            transport.record(UsageEvent.AppStarted.toRecord())
            transport.record(UsageEvent.PhotoImported.toRecord())
            transport.record(UsageEvent.FilmSelected(UsageFilmKind.BuiltIn).toRecord())
            transport.record(UsageEvent.ExportCompleted.toRecord())
            transport.record(UsageEvent.BatchExportCompleted(1, 0, UsageBatchOutcome.Completed).toRecord())
            check(transport.awaitIdle(5_000)) { "synthetic events did not drain" }
            assertNoUnexpectedIssues(issues, "record")
            Log.i("RawLabRumProbe", "SUBMITTED env=$environment version=${BuildConfig.VERSION_NAME} marker=$validationRun")
            Thread.sleep(15_000)
        } finally {
            transport.stop()
            check(transport.awaitIdle(5_000)) { "SDK stop did not drain" }
            assertNoUnexpectedIssues(issues, "stop")
            check(synchronized(issues) { UsageIssue.RESTART_REQUIRED in issues })
        }
    }

    // 应用不申请网络状态权限；探针借用 shell 身份只做发送前的 VPN/代理检查
    @RequiresApi(29)
    private fun assertNetworkPreflight(context: Context) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.adoptShellPermissionIdentity(Manifest.permission.ACCESS_NETWORK_STATE)
        try {
            val connectivity = checkNotNull(context.getSystemService(ConnectivityManager::class.java))
            val network = checkNotNull(connectivity.activeNetwork) { "no active network; probe not sent" }
            val capabilities = checkNotNull(connectivity.getNetworkCapabilities(network)) { "no active network capabilities; probe not sent" }
            check(!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) { "active VPN; probe not sent" }
            val linkProperties = checkNotNull(connectivity.getLinkProperties(network)) { "no active link properties; probe not sent" }
            check(linkProperties.httpProxy == null) { "active HTTP proxy; probe not sent" }
        } finally {
            automation.dropShellPermissionIdentity()
        }
    }

    private fun assertNoUnexpectedIssues(issues: List<UsageIssue>, phase: String) {
        val unexpected = synchronized(issues) { issues.filter { it != UsageIssue.RESTART_REQUIRED } }
        check(unexpected.isEmpty()) { "RUM $phase issue: $unexpected" }
    }
}
