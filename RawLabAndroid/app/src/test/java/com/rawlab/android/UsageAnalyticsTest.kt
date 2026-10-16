package com.rawlab.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private class TestConsent(var enabled: Boolean = false) : UsageConsentStore {
    var failSave = false
    override fun load(): Boolean = enabled
    override fun save(enabled: Boolean) {
        if (failSave) throw IllegalStateException("storage failure")
        this.enabled = enabled
    }
}

private class TestTransport(override val isAvailable: Boolean = true) : UsageAnalyticsTransport {
    var starts = 0
    var stops = 0
    var records = mutableListOf<UsageRecord>()
    var failStart = false
    private var issueListener: (UsageIssue) -> Unit = {}

    override fun start() {
        if (failStart) throw IllegalStateException("start failure")
        starts += 1
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
        val usage = UsageAnalytics(store, transport)
        assertTrue(usage.state.value.enabled)
        usage.beginSession()
        store.failSave = true
        assertFalse(usage.setEnabled(false))
        assertFalse(usage.state.value.enabled)
        usage.record(UsageEvent.PhotoImported)
        assertTrue(transport.records.isEmpty())
        assertEquals(UsageIssue.STORAGE_FAILED, usage.state.value.issue)
    }

    @Test fun defaultOffDoesNotStartOrQueueEvents() {
        val transport = TestTransport()
        val usage = UsageAnalytics(TestConsent(), transport)

        usage.beginSession()
        usage.record(UsageEvent.PhotoImported)

        assertFalse(usage.state.value.enabled)
        assertEquals(0, transport.starts)
        assertTrue(transport.records.isEmpty())
    }

    @Test fun enableStartsOnceAndWithdrawalStopsAndDropsEvents() {
        val transport = TestTransport()
        val usage = UsageAnalytics(TestConsent(), transport)

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
        val usage = UsageAnalytics(TestConsent(), transport)

        usage.beginSession()
        usage.setEnabled(true)

        assertFalse(usage.state.value.enabled)
        assertFalse(usage.state.value.available)
        assertEquals(0, transport.starts)
        assertTrue(transport.records.isEmpty())
    }

    @Test fun failedStartLeavesEditingIndependentAndDoesNotRecord() {
        val transport = TestTransport().apply { failStart = true }
        val usage = UsageAnalytics(TestConsent(), transport)

        usage.beginSession()
        usage.setEnabled(true)
        usage.record(UsageEvent.PhotoImported)

        assertFalse(usage.state.value.enabled)
        assertTrue(usage.state.value.issue == UsageIssue.START_FAILED)
        assertTrue(transport.records.isEmpty())
    }

    @Test fun asynchronousTransportIssueDoesNotExposeRawError() {
        val transport = TestTransport()
        val usage = UsageAnalytics(TestConsent(), transport)

        usage.beginSession()
        usage.setEnabled(true)
        transport.emit(UsageIssue.RECORD_FAILED)

        assertEquals(UsageIssue.RECORD_FAILED, usage.state.value.issue)
        assertTrue(usage.state.value.enabled)
    }

    @Test fun restartRequiredDisablesProviderUntilTheNextProcess() {
        val transport = TestTransport()
        val usage = UsageAnalytics(TestConsent(), transport)

        usage.beginSession()
        usage.setEnabled(true)
        transport.emit(UsageIssue.RESTART_REQUIRED)

        assertFalse(usage.state.value.available)
        assertFalse(usage.state.value.enabled)
        assertEquals(UsageIssue.RESTART_REQUIRED, usage.state.value.issue)
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

    @Test fun localRumRequiresVerifiedCustomEventOnlyRemotePolicy() {
        val unverified = RumLocalConfiguration(
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
    }
}
