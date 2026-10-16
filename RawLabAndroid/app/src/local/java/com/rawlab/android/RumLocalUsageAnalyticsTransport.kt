package com.rawlab.android

import android.content.Context
import com.alibabacloud.rum.AlibabaCloudRum
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

internal interface RumSDKClient {
    fun start(context: Context, configuration: RumLocalConfiguration, deviceId: String)
    fun record(record: UsageRecord, validationRun: String?)
    fun stop()
}

internal object AlibabaRumSDKClient : RumSDKClient {
    override fun start(context: Context, configuration: RumLocalConfiguration, deviceId: String) {
        AlibabaCloudRum.withServiceId(configuration.serviceId)
            .withWorkspace(configuration.workspace)
            .withEndpoint(configuration.endpoint)
            .withDeviceID(deviceId)
            .withAppVersion("0.0.0-local")
            .withEnvironment(AlibabaCloudRum.Env.LOCAL)
            .also { AlibabaCloudRum.setSelfMonitor(false) }
            .start(context, false)
    }

    override fun record(record: UsageRecord, validationRun: String?) {
        val properties = record.properties.toMutableMap().apply {
            if (validationRun != null) put("validation_run", validationRun)
        }
        AlibabaCloudRum.setCustomEvent(
            record.name,
            record.group,
            null,
            record.value.toDouble(),
            properties.toMap(),
        )
    }

    override fun stop() = AlibabaCloudRum.stop()
}

internal class RumLocalUsageAnalyticsTransport(
    context: Context,
    private val configuration: RumLocalConfiguration,
    private val preflight: RumLocalSDKPreflight = BundledRumLocalSDKPreflight,
    private val sdk: RumSDKClient = AlibabaRumSDKClient,
    private val validationRun: String? = null,
) : UsageAnalyticsTransport {
    private val appContext = context.applicationContext ?: context
    private val isolatedContext = RumIsolatedContext(appContext)
    private val deviceId = UUID.randomUUID().toString()
    private val epoch = AtomicLong(0)
    private val sdkStarted = AtomicBoolean(false)
    // The vendor SDK's same-process stop/start contract is not verified; retire after stop.
    private val retired = AtomicBoolean(false)
    private val resourcesCleaned = AtomicBoolean(false)
    private val restartNotified = AtomicBoolean(false)
    private val queue = ArrayBlockingQueue<Runnable>(QUEUE_CAPACITY)
    private val executor = ThreadPoolExecutor(
        1,
        1,
        0L,
        TimeUnit.MILLISECONDS,
        queue,
        DaemonThreadFactory,
        ThreadPoolExecutor.AbortPolicy(),
    )
    private val sdkStartAttempted = AtomicBoolean(false)
    @Volatile private var issueListener: (UsageIssue) -> Unit = {}
    private val configured = configuration.isValid() && preflight.isSafe(appContext)

    override val isAvailable: Boolean
        get() = configured && !retired.get()

    override fun setIssueListener(listener: (UsageIssue) -> Unit) {
        issueListener = listener
    }

    override fun start() {
        check(!retired.get()) { "local RUM requires a process restart after stop" }
        if (!isAvailable) return
        val token = epoch.get()
        executor.execute {
            if (token != epoch.get() || sdkStarted.get()) return@execute
            try {
                sdkStartAttempted.set(true)
                sdk.start(isolatedContext, configuration, deviceId)
                if (token != epoch.get()) {
                    closeSdk(notifyRestart = true)
                } else {
                    sdkStarted.set(true)
                }
            } catch (_: Throwable) {
                retired.set(true)
                notifyIssue(UsageIssue.START_FAILED)
                closeSdk()
            }
        }
    }

    override fun record(record: UsageRecord) {
        if (!isAvailable) return
        val token = epoch.get()
        executor.execute {
            if (token != epoch.get() || !sdkStarted.get()) return@execute
            try {
                sdk.record(record, validationRun)
            } catch (_: Throwable) {
                notifyIssue(UsageIssue.RECORD_FAILED)
            }
        }
    }

    override fun stop() {
        retired.set(true)
        val token = epoch.incrementAndGet()
        queue.clear()
        executor.execute {
            if (token != epoch.get()) return@execute
            closeSdk(notifyRestart = true)
        }
    }

    internal fun awaitIdle(timeoutMs: Long): Boolean {
        val drained = CountDownLatch(1)
        return try {
            executor.execute { drained.countDown() }
            drained.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: RejectedExecutionException) {
            false
        }
    }

    private fun closeSdk(notifyRestart: Boolean = false) {
        val needsStop = sdkStarted.get() || sdkStartAttempted.get()
        if (needsStop) {
            try {
                sdk.stop()
                sdkStarted.set(false)
                sdkStartAttempted.set(false)
            } catch (_: Throwable) {
                notifyIssue(UsageIssue.STOP_FAILED)
                return
            }
        }
        if (!cleanupOwnedResources()) {
            notifyIssue(UsageIssue.CLEANUP_FAILED)
            return
        }
        if (notifyRestart && restartNotified.compareAndSet(false, true)) {
            notifyIssue(UsageIssue.RESTART_REQUIRED)
        }
    }

    private fun cleanupOwnedResources(): Boolean {
        if (resourcesCleaned.get()) return true
        val clean = isolatedContext.cleanup()
        if (clean) resourcesCleaned.set(true)
        return clean
    }

    private fun notifyIssue(issue: UsageIssue) {
        runCatching { issueListener(issue) }
    }

    private object DaemonThreadFactory : ThreadFactory {
        override fun newThread(runnable: Runnable): Thread = Thread(runnable, "rawlab-rum-local").apply {
            isDaemon = true
        }
    }

    private companion object {
        const val QUEUE_CAPACITY = 32
    }
}
