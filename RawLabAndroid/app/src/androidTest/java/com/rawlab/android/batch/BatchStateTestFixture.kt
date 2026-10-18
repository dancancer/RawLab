package com.rawlab.android.batch

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.analytics.UnavailableUsageTransport
import com.rawlab.android.analytics.UsageAnalytics
import com.rawlab.android.analytics.UsageConsentStore
import com.rawlab.android.analytics.UsageInstallId
import com.rawlab.android.editor.EditorBatches
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*

internal fun CountDownLatch.awaitBatch() { assertTrue("Batch latch timed out", await(30, TimeUnit.SECONDS)) }

/* factory 无法暂停读改写窗口；这里只拦截真实 Flow 写入，model、runner 和日志照常执行。 */
@OptIn(kotlinx.coroutines.ExperimentalForInheritanceCoroutinesApi::class)
internal class GatedBatchState(
    private val delegate: MutableStateFlow<BatchExportState>,
    private val before: (BatchExportState) -> Unit,
    private val after: (BatchExportState) -> Unit,
) : MutableStateFlow<BatchExportState> by delegate {
    override var value: BatchExportState
        get() = delegate.value
        set(value) { before(value); delegate.value = value; after(value) }

    override fun compareAndSet(expect: BatchExportState, update: BatchExportState): Boolean {
        before(update)
        return delegate.compareAndSet(expect, update).also { if (it) after(update) }
    }
}

internal class BatchStateTestFixture(
    settings: EditSettings = EditSettings(),
    factory: (Int, File?) -> NativeProcessor = { mode, _ -> NativeProcessor(mode) },
) : AutoCloseable {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    val context = instrumentation.targetContext
    val root = File(context.cacheDir, "batch-integrity-${UUID.randomUUID()}").apply { mkdirs() }
    val original = File(root, "source.png").apply {
        val bitmap = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.rgb(70, 140, 210))
        outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
    }
    private val originalBytes = original.readBytes()
    val storage = PhotoStorage(context)
    val editorCopy = storage.import(Uri.fromFile(original)).file
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val errors = mutableListOf<String?>()
    private val usage = UsageAnalytics(object : UsageConsentStore {
        override fun load() = false
        override fun save(enabled: Boolean) = Unit
    }, object : UsageInstallId {
        override fun obtain() = "unused"
        override fun delete() = Unit
    }, UnavailableUsageTransport)
    val editor = EditorBatches(context.applicationContext as Application, storage, scope, factory, usage) { errors += it }
    val journalRoot = File(context.filesDir, "RawLab/BatchJobs")
    val journal = BatchJournal(journalRoot)
    val model: BatchExportModel
    val outputs = java.util.Collections.synchronizedSet(mutableSetOf<Uri>())
    private val outputBytes = mutableMapOf<Uri, ByteArray>()

    init {
        main { editor.begin(BatchSourceSnapshot(PhotoIdentity(original.path), editorCopy, settings,
            original.name, inputKind = PhotoInputKind.RASTER), NativeProcessor.CPU) }
        model = checkNotNull(editor.active.value)
        awaitPhase(BatchPhase.SELECTING)
        assertNull(model.state.value.error)
    }

    fun main(block: () -> Unit) { instrumentation.runOnMainSync(block) }

    fun addTargets(count: Int = 1) {
        val uris = (1..count).map { index ->
            Uri.fromFile(File(root, "target-$index.png").also { original.copyTo(it) })
        }
        main { model.addUris(uris) }
        awaitPhase(BatchPhase.SELECTING)
        assertNull(model.state.value.error)
        assertEquals(count, model.state.value.selectedCount)
    }

    fun awaitPhase(phase: BatchPhase) = runBlocking {
        withTimeout(30_000) { model.state.first { it.phase == phase } }
    }

    @Suppress("UNCHECKED_CAST")
    fun gate(before: (BatchExportState) -> Unit = {}, after: (BatchExportState) -> Unit = {}) {
        val field = BatchExportModel::class.java.getDeclaredField("mutable").apply { isAccessible = true }
        val flow = field.get(model) as MutableStateFlow<BatchExportState>
        field.set(model, GatedBatchState(flow, before) { state ->
            state.job.rows.mapNotNull { it.outputUri?.let(Uri::parse) }.forEach(outputs::add)
            after(state)
        })
    }

    fun joinWorker() = runBlocking {
        val field = BatchExportModel::class.java.getDeclaredField("running").apply { isAccessible = true }
        withTimeout(30_000) { (field.get(model) as Job?)?.join() }
    }

    private fun joinModel() = runBlocking {
        val field = BatchExportModel::class.java.getDeclaredField("scope").apply { isAccessible = true }
        withTimeout(30_000) { (field.get(model) as CoroutineScope).coroutineContext[Job]!!.join() }
    }

    fun closePage() {
        main { editor.close() }
        assertNull("The result page must accept close", editor.active.value)
        joinModel()
        runBlocking {
            withTimeout(30_000) {
                do {
                    val children = scope.coroutineContext[Job]!!.children.toList()
                    children.joinAll()
                } while (scope.coroutineContext[Job]!!.children.any())
            }
        }
        val id = model.state.value.job.id
        assertEquals("Close must refresh the coordinator recovery list",
            File(journalRoot, "$id.properties").isFile, editor.pending.value.any { it.id == id })
        assertTrue(errors.toString(), errors.isEmpty())
    }

    fun assertOriginals() {
        assertArrayEquals(originalBytes, original.readBytes())
        assertArrayEquals(originalBytes, editorCopy.readBytes())
    }

    fun assertOutputs(job: BatchJob, expected: Int) {
        val uris = job.rows.mapNotNull { it.outputUri?.let(Uri::parse) }
        assertEquals(expected, uris.size)
        uris.forEach { uri ->
            outputs += uri
            val bytes = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
            val previous = outputBytes[uri]
            if (previous == null) outputBytes[uri] = bytes
            else assertArrayEquals("Published output bytes must not change", previous, bytes)
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            assertNotNull("Published output remains readable", bitmap)
            assertEquals(64, bitmap.width); assertEquals(48, bitmap.height)
            bitmap.recycle()
        }
    }

    override fun close() {
        main { model.close() }
        joinWorker()
        joinModel()
        outputs.forEach { context.contentResolver.delete(it, null, null) }
        journal.discard(model.state.value.job.id)
        scope.cancel()
        storage.close()
        root.deleteRecursively()
    }
}
