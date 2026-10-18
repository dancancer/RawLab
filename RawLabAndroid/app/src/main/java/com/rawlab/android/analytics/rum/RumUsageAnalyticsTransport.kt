package com.rawlab.android.analytics.rum

import android.content.Context
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import com.rawlab.android.analytics.UsageAnalyticsTransport
import com.rawlab.android.analytics.UsageIssue
import com.rawlab.android.analytics.UsageRecord

// ============================================================================
//  RUM 传输层：正式包与本地验证构建共用，本身不依赖 SDK
//  SDK 调用只经 RumSDKClient（src/rum 里的 AlibabaRumSDKClient），因此调试构建也能编译和测试它。
//  所有 SDK 调用串行在一个后台线程上，队列有界，不阻塞编辑与渲染；SDK 的文件与偏好隔离在
//  RumIsolatedContext 里，关闭统计时一并清除。
// ============================================================================

internal interface RumSDKClient {
    fun start(context: Context, configuration: RumConfiguration, deviceId: String)
    fun record(record: UsageRecord, validationRun: String?)
    fun stop()
}

internal class RumUsageAnalyticsTransport(
    context: Context,
    private val configuration: RumConfiguration,
    private val sdk: RumSDKClient,
    private val preflight: RumSDKPreflight = BundledRumSDKPreflight,
    private val validationRun: String? = null,
) : UsageAnalyticsTransport {
    private val appContext = context.applicationContext ?: context
    private val isolatedContext = RumIsolatedContext(appContext)
    private val epoch = AtomicLong(0)
    private val sdkStarted = AtomicBoolean(false)
    // 供应商 SDK 同进程停止后再启动的行为未经验证：停止后即退役，重新开启需重启应用
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

    // 启动在专用线程上进行；SDK 的任何失败（含 x86_64 缺原生库的 UnsatisfiedLinkError）都只报 START_FAILED
    override fun start(installId: String) {
        check(!retired.get()) { "RUM requires a process restart after stop" }
        if (!isAvailable) return
        val token = epoch.get()
        executor.execute {
            if (token != epoch.get() || sdkStarted.get()) return@execute
            try {
                sdkStartAttempted.set(true)
                sdk.start(isolatedContext, configuration, installId)
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
        override fun newThread(runnable: Runnable): Thread = Thread(runnable, "rawlab-rum").apply {
            isDaemon = true
        }
    }

    private companion object {
        const val QUEUE_CAPACITY = 32
    }
}
