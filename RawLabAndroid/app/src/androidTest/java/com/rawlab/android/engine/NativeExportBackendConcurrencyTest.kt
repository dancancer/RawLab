package com.rawlab.android.engine

import android.os.Bundle
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import com.rawlab.android.batch.workflow.BatchTestCleanup
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings

class NativeExportBackendConcurrencyTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val cleanup = BatchTestCleanup(context)
    @get:Rule val isolated = RuleChain.outerRule(cleanup)

    @Test fun completedExportReportsBackendWithoutWaitingForAnotherSession() {
        val id = UUID.randomUUID().toString()
        cleanup.begin(id)
        val root = File(context.filesDir, "RawLab/BatchJobs/$id/inputs").apply { mkdirs() }
        val input = File(root, "source.arw")
        val metadata = CountDownLatch(1)
        val release = CountDownLatch(1)
        val returned = CountDownLatch(1)
        val backend = AtomicInteger(-1)
        val failure = AtomicReference<Throwable>()
        val processors = mutableListOf<NativeProcessor>()
        val threads = mutableListOf<Thread>()
        try {
            instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
            val output = object : File(root, "export.jpg") {
                private val calls = AtomicInteger()
                override fun getCanonicalPath(): String {
                    val path = super.getCanonicalPath()
                    // 第二次 canonical 检查是 metadata 入口，此时真实 native 导出已经完成。
                    if (calls.incrementAndGet() == 2) {
                        check(File(path).length() > 0)
                        metadata.countDown()
                        check(release.await(20, TimeUnit.SECONDS))
                    }
                    return path
                }
            }
            processors += NativeProcessor(NativeProcessor.CPU)
            processors += NativeProcessor(NativeProcessor.CPU)
            val exporting = Thread({
                try { backend.set(processors[0].export(input, null, EditSettings(customWb = true), output, ExportFormat.JPEG, 300)) }
                catch (error: Throwable) { failure.compareAndSet(null, error) }
                finally { returned.countDown() }
            }, "batch-backend-export").also { threads += it }
            val previewing = Thread({
                try { processors[1].preview(input, null, EditSettings(customWb = true,
                    denoise = DenoiseSettings(true, 10f, 72f, 100f)), 1280, true) }
                catch (error: Throwable) { failure.compareAndSet(null, error) }
            }, "batch-backend-other-preview").also { threads += it }
            exporting.start()
            assertTrue("Real export must reach metadata", metadata.await(20, TimeUnit.SECONDS))
            previewing.start()
            val deadline = SystemClock.elapsedRealtime() + 20_000
            while (!inNative(previewing, "nativeProcess") && previewing.isAlive && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(10)
            assertTrue("Probe NOT REACHED: second real CPU preview must hold the native mutex", inNative(previewing, "nativeProcess"))
            release.countDown()
            val completed = returned.await(1, TimeUnit.SECONDS)
            val otherActive = inNative(previewing, "nativeProcess")
            val getterBlocked = inNative(exporting, "nativeLastBackend")
            instrumentation.sendStatus(2, Bundle().apply {
                putString("stream", "BATCH_GPU metadataGateReached=true secondCpuPreviewNativeProcess=$otherActive exportReturned=$completed getterBlocked=$getterBlocked backend=${backend.get()}\n")
            })
            if (!completed) assertTrue("Probe NOT REACHED: failure must be the old getter lock, not metadata IO", getterBlocked && otherActive)
            assertTrue("Backend reporting must not wait for an unrelated session after rendering", completed)
            assertTrue("Probe NOT REACHED: the second preview must still be native-active", otherActive)
            assertNull(failure.get())
            assertEquals(0, backend.get())
        } finally {
            release.countDown()
            threads.forEach { it.join(60_000) }
            cleanup.finish(active = threads.any { it.isAlive }, cancel = {}, close = { processors.asReversed().forEach { it.close() } })
        }
        assertNull(failure.get())
    }

    private fun inNative(thread: Thread, method: String) = thread.stackTrace.any {
        it.className == NativeProcessor::class.java.name && it.methodName == method
    }
}
