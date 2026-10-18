package com.rawlab.android.analytics

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import com.rawlab.android.analytics.rum.RumConfiguration
import com.rawlab.android.analytics.rum.RumSDKClient
import com.rawlab.android.analytics.rum.RumSDKPreflight
import com.rawlab.android.analytics.rum.RumUsageAnalyticsTransport

// ============================================================================
//  RUM 传输层（不依赖 SDK，用假的 RumSDKClient）：调试构建也跑，不会联网
// ============================================================================

@RunWith(AndroidJUnit4::class)
class RumUsageAnalyticsTransportTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun transport(sdk: RumSDKClient) = RumUsageAnalyticsTransport(
        context = context,
        configuration = RumConfiguration.PRODUCTION,
        sdk = sdk,
        preflight = RumSDKPreflight { true },
    )

    @Test
    fun installIdBecomesTheSdkDeviceId() {
        val sdk = RecordingRumSDKClient()
        val transport = transport(sdk)

        transport.start("7d1c3b0e-2f4a-4c55-9a51-4b7e9f0d2c11")
        assertTrue(transport.awaitIdle(5_000))

        assertEquals(listOf("7d1c3b0e-2f4a-4c55-9a51-4b7e9f0d2c11"), sdk.deviceIds)
        transport.stop()
        assertTrue(transport.awaitIdle(5_000))
    }

    // x86_64 缺 librum-native-core.so 一类的失败：只让本进程不可用，不崩溃、不改写同意值
    @Test
    fun nativeStartFailureMarksUsageUnavailableWithoutTouchingConsent() {
        val sdk = RecordingRumSDKClient(startFailure = UnsatisfiedLinkError("dlopen failed: librum-native-core.so"))
        val transport = transport(sdk)
        val store = MemoryConsent()
        val usage = UsageAnalytics(store, MemoryInstallId(), transport)

        usage.beginSession()
        assertTrue(transport.awaitIdle(5_000))
        usage.record(UsageEvent.PhotoImported)

        assertFalse(usage.state.value.available)
        assertTrue(usage.state.value.enabled)
        assertEquals(UsageIssue.START_FAILED, usage.state.value.issue)
        assertEquals(0, store.saves)
        assertEquals(0, sdk.records.get())
    }

    @Test
    fun withdrawalDuringBlockedStartClosesAndRequiresProcessRestart() {
        val sdk = BlockingRumSDKClient()
        val transport = transport(sdk)

        transport.start("7d1c3b0e-2f4a-4c55-9a51-4b7e9f0d2c11")
        assertTrue(sdk.startEntered.await(5, TimeUnit.SECONDS))
        transport.stop()
        sdk.allowStart.countDown()
        assertTrue(transport.awaitIdle(5_000))
        assertEquals(1, sdk.stopCalls.get())

        val restart = runCatching { transport.start("7d1c3b0e-2f4a-4c55-9a51-4b7e9f0d2c11") }.exceptionOrNull()
        assertTrue(restart is IllegalStateException)
        assertEquals(1, sdk.startCalls.get())
        assertEquals(1, sdk.stopCalls.get())
    }

    private class MemoryConsent : UsageConsentStore {
        var saves = 0
        override fun load() = true
        override fun save(enabled: Boolean) { saves += 1 }
    }

    private class MemoryInstallId : UsageInstallId {
        override fun obtain() = "7d1c3b0e-2f4a-4c55-9a51-4b7e9f0d2c11"
        override fun delete() = Unit
    }

    private class RecordingRumSDKClient(private val startFailure: Throwable? = null) : RumSDKClient {
        val deviceIds = mutableListOf<String>()
        val records = AtomicInteger()

        override fun start(context: android.content.Context, configuration: RumConfiguration, deviceId: String) {
            startFailure?.let { throw it }
            deviceIds += deviceId
        }

        override fun record(record: UsageRecord, validationRun: String?) {
            records.incrementAndGet()
        }

        override fun stop() = Unit
    }

    private class BlockingRumSDKClient : RumSDKClient {
        val startEntered = CountDownLatch(1)
        val allowStart = CountDownLatch(1)
        val startCalls = AtomicInteger()
        val stopCalls = AtomicInteger()

        override fun start(context: android.content.Context, configuration: RumConfiguration, deviceId: String) {
            startEntered.countDown()
            check(allowStart.await(5, TimeUnit.SECONDS))
            startCalls.incrementAndGet()
        }

        override fun record(record: UsageRecord, validationRun: String?) = Unit

        override fun stop() {
            stopCalls.incrementAndGet()
        }
    }
}
