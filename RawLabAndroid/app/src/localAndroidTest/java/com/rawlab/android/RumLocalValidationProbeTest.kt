package com.rawlab.android

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RumLocalValidationProbeTest {
    @Test
    fun sendSyntheticUsageEventsOnlyWhenExplicitlyEnabled() {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue(arguments.getString("rumLocalProbe") == "true")
        check(arguments.getString("rumLimitVerified") == "true") { "rumLimitVerified gate is required" }
        check(arguments.getString("rumNetwork") == "china-telecom") { "rumNetwork gate is required" }
        check(arguments.getString("rumConfigVerified") == "true") { "rumConfigVerified gate is required" }
        val validationRun = arguments.getString("rumValidationRun")
            ?.takeIf { runCatching { java.util.UUID.fromString(it) }.isSuccess }
            ?: error("rumValidationRun is required")

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertNetworkPreflight(context)
        val configuration = RumLocalConfigurationProvider.load(context)
        check(configuration.isValid()) { "operator-verified local RUM configuration is unavailable" }
        val transport = RumLocalUsageAnalyticsTransport(
            context = context,
            configuration = configuration,
            validationRun = validationRun,
        )
        check(transport.isAvailable) { "local SDK safety preflight rejected the bundled policy" }
        val issues = mutableListOf<UsageIssue>()
        transport.setIssueListener { issue -> synchronized(issues) { issues += issue } }
        try {
            transport.start()
            check(transport.awaitIdle(5_000)) { "local SDK start did not drain" }
            assertNoUnexpectedIssues(issues, "start")
            transport.record(UsageEvent.AppStarted.toRecord())
            transport.record(UsageEvent.PhotoImported.toRecord())
            transport.record(UsageEvent.FilmSelected(UsageFilmKind.BuiltIn).toRecord())
            transport.record(UsageEvent.ExportCompleted.toRecord())
            transport.record(UsageEvent.BatchExportCompleted(1, 0, UsageBatchOutcome.Completed).toRecord())
            check(transport.awaitIdle(5_000)) { "synthetic events did not drain" }
            assertNoUnexpectedIssues(issues, "record")
            Log.i("RawLabRumLocalProbe", "SUBMITTED marker=$validationRun")
            Thread.sleep(15_000)
        } finally {
            transport.stop()
            check(transport.awaitIdle(5_000)) { "local SDK stop did not drain" }
            assertNoUnexpectedIssues(issues, "stop")
            check(synchronized(issues) { UsageIssue.RESTART_REQUIRED in issues })
        }
    }

    private fun assertNetworkPreflight(context: Context) {
        val connectivity = checkNotNull(context.getSystemService(ConnectivityManager::class.java))
        val network = checkNotNull(connectivity.activeNetwork) { "no active network; probe not sent" }
        val capabilities = checkNotNull(connectivity.getNetworkCapabilities(network)) { "no active network capabilities; probe not sent" }
        check(!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) { "active VPN; probe not sent" }
        val linkProperties = checkNotNull(connectivity.getLinkProperties(network)) { "no active link properties; probe not sent" }
        check(linkProperties.httpProxy == null) { "active HTTP proxy; probe not sent" }
    }

    private fun assertNoUnexpectedIssues(issues: List<UsageIssue>, phase: String) {
        val unexpected = synchronized(issues) { issues.filter { it != UsageIssue.RESTART_REQUIRED } }
        check(unexpected.isEmpty()) { "RUM $phase issue: $unexpected" }
    }
}
