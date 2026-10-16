package com.rawlab.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RumLocalUsageAnalyticsTransportTest {
    @Test
    fun withdrawalDuringBlockedStartClosesAndRequiresProcessRestart() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val sdk = BlockingRumSDKClient()
        val transport = RumLocalUsageAnalyticsTransport(
            context = context,
            configuration = RumLocalConfigurationProvider.load(context),
            preflight = RumLocalSDKPreflight { true },
            sdk = sdk,
        )

        transport.start()
        assertTrue(sdk.startEntered.await(5, TimeUnit.SECONDS))
        transport.stop()
        sdk.allowStart.countDown()
        assertTrue(transport.awaitIdle(5_000))
        assertEquals(1, sdk.stopCalls.get())

        val restart = runCatching { transport.start() }.exceptionOrNull()
        assertTrue(restart is IllegalStateException)
        assertEquals(1, sdk.startCalls.get())
        assertEquals(1, sdk.stopCalls.get())
    }

    private class BlockingRumSDKClient : RumSDKClient {
        val startEntered = CountDownLatch(1)
        val allowStart = CountDownLatch(1)
        val startCalls = AtomicInteger()
        val recordCalls = AtomicInteger()
        val stopCalls = AtomicInteger()

        override fun start(context: android.content.Context, configuration: RumLocalConfiguration, deviceId: String) {
            startEntered.countDown()
            check(allowStart.await(5, TimeUnit.SECONDS))
            startCalls.incrementAndGet()
        }

        override fun record(record: UsageRecord, validationRun: String?) {
            recordCalls.incrementAndGet()
        }

        override fun stop() {
            stopCalls.incrementAndGet()
        }
    }
}
