package com.rawlab.android.analytics

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import com.rawlab.android.analytics.rum.RumConfiguration
import com.rawlab.android.analytics.rum.RumRemoteCollectorPolicy

// 与真实存储一致：没有存过选择即为开启
private class TestConsent(var enabled: Boolean = true) : UsageConsentStore {
    var failLoad = false
    var failSave = false
    var saves = 0
    override fun load(): Boolean {
        if (failLoad) throw ClassCastException("corrupt consent")
        return enabled
    }
    override fun save(enabled: Boolean) {
        if (failSave) throw IllegalStateException("storage failure")
        saves += 1
        this.enabled = enabled
    }
}

private class TestInstallId(var value: String? = null) : UsageInstallId {
    var failDelete = false
    override fun obtain(): String = value ?: UUID.randomUUID().toString().also { value = it }
    override fun delete() {
        if (failDelete) throw IllegalStateException("storage failure")
        value = null
    }
}

private class TestTransport(override val isAvailable: Boolean = true) : UsageAnalyticsTransport {
    var starts = 0
    val installIds = mutableListOf<String>()
    var stops = 0
    var records = mutableListOf<UsageRecord>()
    var startFailure: Throwable? = null
    private var issueListener: (UsageIssue) -> Unit = {}

    override fun start(installId: String) {
        startFailure?.let { throw it }
        starts += 1
        installIds += installId
    }

    override fun record(record: UsageRecord) {
        records += record
    }

    override fun stop() {
        stops += 1
    }

    override fun setIssueListener(listener: (UsageIssue) -> Unit) {
        issueListener = listener
    }

    fun emit(issue: UsageIssue) = issueListener(issue)
}

class UsageAnalyticsTest {
    @Test fun withdrawalStillWorksWithUnavailableProviderAndFailedPersistence() {
        val store = TestConsent(enabled = true)
        val transport = TestTransport(isAvailable = false)
        val usage = UsageAnalytics(store, TestInstallId(), transport)
        assertTrue(usage.state.value.enabled)
        usage.beginSession()
        store.failSave = true
        assertFalse(usage.setEnabled(false))
        assertFalse(usage.state.value.enabled)
        usage.record(UsageEvent.PhotoImported)
        assertTrue(transport.records.isEmpty())
        assertEquals(UsageIssue.STORAGE_FAILED, usage.state.value.issue)
    }

    @Test fun missingChoiceStartsOnceAndRecordsLaunch() {
        val transport = TestTransport()
        val usage = UsageAnalytics(TestConsent(), TestInstallId(), transport)

        usage.beginSession()
        usage.beginSession()

        assertTrue(usage.state.value.enabled)
        assertEquals(1, transport.starts)
        assertEquals(listOf("app_started"), transport.records.map { it.name })
    }

    @Test fun explicitOptOutDoesNotStartOrQueueEvents() {
        val transport = TestTransport()
        val usage = UsageAnalytics(TestConsent(enabled = false), TestInstallId(), transport)

        usage.beginSession()
        usage.record(UsageEvent.PhotoImported)

        assertFalse(usage.state.value.enabled)
        assertEquals(0, transport.starts)
        assertTrue(transport.records.isEmpty())
    }

    @Test fun unreadableChoiceIsTreatedAsOffAndReported() {
        val transport = TestTransport()
        val usage = UsageAnalytics(TestConsent().apply { failLoad = true }, TestInstallId(), transport)

        usage.beginSession()

        assertFalse(usage.state.value.enabled)
        assertEquals(UsageIssue.STORAGE_FAILED, usage.state.value.issue)
        assertEquals(0, transport.starts)
    }

    @Test fun enableStartsOnceAndWithdrawalStopsAndDropsEvents() {
        val transport = TestTransport()
        val usage = UsageAnalytics(TestConsent(enabled = false), TestInstallId(), transport)

        usage.beginSession()
        usage.setEnabled(true)
        usage.record(UsageEvent.PhotoImported)
        usage.setEnabled(false)
        usage.record(UsageEvent.ExportCompleted)
        usage.setEnabled(true)

        assertEquals(2, transport.starts)
        assertEquals(1, transport.stops)
        assertEquals(listOf("app_started", "photo_imported"), transport.records.map { it.name })
    }

    @Test fun unavailableTransportCannotBeEnabled() {
        val transport = TestTransport(isAvailable = false)
        val usage = UsageAnalytics(TestConsent(enabled = false), TestInstallId(), transport)

        usage.beginSession()
        usage.setEnabled(true)

        assertFalse(usage.state.value.enabled)
        assertFalse(usage.state.value.available)
        assertEquals(0, transport.starts)
        assertTrue(transport.records.isEmpty())
    }

    @Test fun unavailableTransportStillShowsConsentAndAllowsOptOut() {
        val store = TestConsent()
        val usage = UsageAnalytics(store, TestInstallId(), TestTransport(isAvailable = false))

        usage.beginSession()
        assertTrue(usage.state.value.enabled)
        assertFalse(usage.state.value.available)

        assertTrue(usage.setEnabled(false))
        assertFalse(store.enabled)
    }

    @Test fun failedStartMarksProcessUnavailableWithoutRewritingConsent() {
        listOf(IllegalStateException("start failure"), UnsatisfiedLinkError("librum-native-core.so")).forEach { failure ->
            val store = TestConsent()
            val transport = TestTransport().apply { startFailure = failure }
            val usage = UsageAnalytics(store, TestInstallId(), transport)

            usage.beginSession()
            usage.record(UsageEvent.PhotoImported)

            assertTrue(usage.state.value.enabled)
            assertFalse(usage.state.value.available)
            assertEquals(UsageIssue.START_FAILED, usage.state.value.issue)
            assertTrue(transport.records.isEmpty())
            assertEquals(0, store.saves)
            assertTrue(store.enabled)
        }
    }

    @Test fun asynchronousTransportIssueDoesNotExposeRawError() {
        val transport = TestTransport()
        val usage = UsageAnalytics(TestConsent(), TestInstallId(), transport)

        usage.beginSession()
        transport.emit(UsageIssue.RECORD_FAILED)

        assertEquals(UsageIssue.RECORD_FAILED, usage.state.value.issue)
        assertTrue(usage.state.value.enabled)
        assertTrue(usage.state.value.available)
    }

    @Test fun processFailuresOnlyMarkThisProcessUnavailable() {
        listOf(UsageIssue.START_FAILED, UsageIssue.STOP_FAILED, UsageIssue.CLEANUP_FAILED, UsageIssue.RESTART_REQUIRED)
            .forEach { issue ->
                val store = TestConsent()
                val transport = TestTransport()
                val usage = UsageAnalytics(store, TestInstallId(), transport)

                usage.beginSession()
                transport.emit(issue)
                usage.record(UsageEvent.PhotoImported)

                assertFalse(issue.name, usage.state.value.available)
                assertTrue(issue.name, usage.state.value.enabled)
                assertEquals(issue, usage.state.value.issue)
                assertEquals(issue.name, listOf("app_started"), transport.records.map { it.name })
                assertEquals(issue.name, 0, store.saves)

                assertTrue(usage.setEnabled(false))
                assertFalse(store.enabled)
                assertEquals(issue, usage.state.value.issue)
            }
    }

    @Test fun startUsesTheStoredInstallId() {
        val stored = "7d1c3b0e-2f4a-4c55-9a51-4b7e9f0d2c11"
        val transport = TestTransport()
        UsageAnalytics(TestConsent(), TestInstallId(stored), transport).beginSession()

        assertEquals(listOf(stored), transport.installIds)
    }

    @Test fun optOutDeletesTheInstallIdAndReEnableCreatesANewOne() {
        val installId = TestInstallId()
        val transport = TestTransport()
        val usage = UsageAnalytics(TestConsent(), installId, transport)

        usage.beginSession()
        val first = transport.installIds.single()
        assertTrue(usage.setEnabled(false))
        assertNull(installId.value)
        usage.setEnabled(true)

        assertEquals(2, transport.installIds.size)
        assertNotEquals(first, transport.installIds.last())
        assertEquals(transport.installIds.last(), installId.value)
    }

    @Test fun optedOutLaunchRemovesALeftoverInstallId() {
        val installId = TestInstallId("7d1c3b0e-2f4a-4c55-9a51-4b7e9f0d2c11")
        UsageAnalytics(TestConsent(enabled = false), installId, TestTransport()).beginSession()

        assertNull(installId.value)
    }

    @Test fun failedInstallIdDeletionIsReported() {
        val installId = TestInstallId().apply { failDelete = true }
        val store = TestConsent()
        val usage = UsageAnalytics(store, installId, TestTransport())

        usage.beginSession()

        assertFalse(usage.setEnabled(false))
        assertFalse(store.enabled)
        assertEquals(UsageIssue.STORAGE_FAILED, usage.state.value.issue)
    }

    @Test fun eventsExposeOnlyFixedSafeFieldsAndBoundCounts() {
        val film = UsageEvent.FilmSelected(UsageFilmKind.Custom).toRecord()
        val batch = UsageEvent.BatchExportCompleted(-10, 200_000, UsageBatchOutcome.Partial).toRecord()

        assertEquals(mapOf("schema_version" to "1", "platform" to "android", "kind" to "custom"), film.properties)
        assertEquals(0, batch.value)
        assertEquals(
            mapOf(
                "schema_version" to "1",
                "platform" to "android",
                "outcome" to "partial",
                "succeeded_count" to "0",
                "failed_count" to "100000",
            ),
            batch.properties,
        )
    }

    @Test fun rumRequiresVerifiedCustomEventOnlyRemotePolicy() {
        val unverified = RumConfiguration(
            serviceId = "service-id",
            workspace = "default",
            endpoint = "https://proj.cn-shanghai.log.aliyuncs.com",
            remotePolicy = RumRemoteCollectorPolicy(
                remoteVerified = false,
                enabledCollectors = setOf("customevent"),
                networkConfigVerified = true,
                verifiedServiceId = "service-id",
                verifiedWorkspace = "default",
                verifiedEndpoint = "https://proj.cn-shanghai.log.aliyuncs.com",
            ),
        )
        val verified = unverified.copy(
            remotePolicy = RumRemoteCollectorPolicy(
                remoteVerified = true,
                enabledCollectors = setOf("customevent"),
                networkConfigVerified = true,
                verifiedServiceId = "service-id",
                verifiedWorkspace = "default",
                verifiedEndpoint = "https://proj.cn-shanghai.log.aliyuncs.com",
            ),
        )

        assertFalse(unverified.isValid())
        assertTrue(verified.isValid())
        assertFalse(verified.copy(endpoint = "https://other.cn-shanghai.log.aliyuncs.com").isValid())
        assertTrue(RumConfiguration.PRODUCTION.isValid())
    }
}
