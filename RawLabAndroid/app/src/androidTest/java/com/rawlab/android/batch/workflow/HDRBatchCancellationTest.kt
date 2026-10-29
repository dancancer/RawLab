package com.rawlab.android.batch.workflow

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.R
import com.rawlab.android.analytics.UsageBatchOutcome
import com.rawlab.android.batch.*
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.batch.ui.BatchExportScreen
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.*
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

class HDRBatchCancellationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val compose = createComposeRule()
    private val cleanup = BatchTestCleanup(context)
    @get:Rule val rules: RuleChain = RuleChain.outerRule(cleanup).around(LanguageTestRule())
        .around(ForegroundTestRule()).around(compose)

    @Test fun userCancellationDuringPreflightClearsTheErrorAndReportsCancelled() =
        cancelPreflight(forBackground = false, expected = UsageBatchOutcome.Cancelled)

    @Test fun backgroundCancellationDuringPreflightClearsTheErrorAndReportsInterrupted() =
        cancelPreflight(forBackground = true, expected = UsageBatchOutcome.Interrupted)

    private fun cancelPreflight(forBackground: Boolean, expected: UsageBatchOutcome) {
        val id = UUID.randomUUID().toString(); cleanup.begin(id)
        val root = File(context.cacheDir, "hdr-cancel-$id").apply { mkdirs() }
        val sourceFile = File(root, "source.jpg")
        instrumentation.context.assets.open("hdr-sample.jpg").use { input -> sourceFile.outputStream().use(input::copyTo) }
        val targetFile = File(root, "target.png")
        Bitmap.createBitmap(48, 32, Bitmap.Config.ARGB_8888).let { bitmap ->
            bitmap.eraseColor(android.graphics.Color.rgb(180, 80, 30))
            targetFile.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            bitmap.recycle()
        }
        val originalBytes = targetFile.readBytes()
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val armed = AtomicBoolean(false)
        // 只暂停真实的预检文件读取；启动界面时已进入 PREPARING，不会被缩略图读取抢先触发。
        val targetInput = object : File(targetFile.path) {
            override fun getPath(): String {
                if (armed.compareAndSet(true, false)) {
                    entered.countDown()
                    check(release.await(30, TimeUnit.SECONDS)) { "Preflight file read timed out" }
                }
                return super.getPath()
            }
        }
        val source = BatchSourceSnapshot(PhotoIdentity(Uri.fromFile(sourceFile).toString()), sourceFile,
            sourceDefaultSettings(true), inputKind = PhotoInputKind.RASTER)
        val targetID = PhotoIdentity(Uri.fromFile(targetFile).toString())
        val target = BatchTarget(targetID, targetInput, targetFile.name, inputKind = PhotoInputKind.RASTER)
        val draft = BatchJob(source, listOf(target), id = id)
        val journal = BatchJournal(File(context.filesDir, "RawLab/BatchJobs"))
        val records = EditStore(File(context.filesDir, "edits"))
        val originalRecord = records.versionedState(targetID)
        val outcomes = CopyOnWriteArrayList<Triple<Int, Int, UsageBatchOutcome>>()
        val storage = PhotoStorage(context)
        lateinit var batch: BatchExportModel
        compose.runOnUiThread {
            batch = BatchExportModel(context, storage, source, initial = draft, gpuMode = NativeProcessor.CPU,
                processorFactory = { _, _ -> error("Cancelled preflight must not create a processor") },
                onTerminal = { succeeded, failed, outcome -> outcomes += Triple(succeeded, failed, outcome) })
        }
        try {
            compose.waitUntil(30_000) { batch.state.value.phase != BatchPhase.PREPARING }
            assertNull(batch.state.value.error)
            val persisted = journal.load(id)
            compose.runOnUiThread { armed.set(true); batch.start(ExportFormat.JPEG, null) }
            assertTrue("HDR preflight must reach the target read", entered.await(30, TimeUnit.SECONDS))
            assertEquals(BatchPhase.PREPARING, batch.state.value.phase)
            compose.setContent { MaterialTheme { BatchExportScreen(batch, storage, onBack = {}) } }
            compose.onNodeWithText(AppStrings.text(R.string.message_preparing)).assertIsDisplayed()
            if (forBackground) compose.runOnUiThread { batch.cancel(forBackground = true) }
            else compose.onNodeWithText(AppStrings.text(R.string.cancel)).performClick()
            assertTrue(batch.state.value.stopping)
            // 后到的生命周期/用户取消不能覆盖首次停止原因。
            compose.runOnUiThread { batch.cancel(forBackground = !forBackground) }
            release.countDown()
            compose.waitUntil(30_000) { batch.state.value.phase != BatchPhase.PREPARING && outcomes.isNotEmpty() }
            val result = batch.state.value
            assertEquals(BatchPhase.SELECTING, result.phase)
            assertNull("Cancelling HDR preflight must not display an error", result.error)
            assertFalse(result.stopping)
            assertEquals(listOf(Triple(0, 0, expected)), outcomes.toList())
            assertEquals(BatchSettingsMode.UNIFORM_FROZEN, result.job.settingsMode)
            assertEquals(listOf(BatchRowStatus.PENDING), result.job.rows.map { it.status })
            assertEquals(persisted, journal.load(id))
            assertEquals(originalRecord, records.versionedState(targetID))
            assertArrayEquals(originalBytes, targetFile.readBytes())
            compose.onNodeWithText("CancellationException", substring = true).assertDoesNotExist()
            compose.onNodeWithText(AppStrings.format(R.string.message_export_photos, "1"))
                .assertIsDisplayed().assertIsEnabled()
            val screenshot = File(context.getExternalFilesDir(null), "hdr-tests/preflight-cancel-$forBackground.png")
            screenshot.parentFile!!.mkdirs()
            instrumentation.uiAutomation.takeScreenshot()!!.let { image ->
                screenshot.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }; image.recycle()
            }
        } finally {
            release.countDown()
            val worker = BatchExportModel::class.java.getDeclaredField("running").apply { isAccessible = true }.get(batch) as Job?
            runBlocking { withTimeout(30_000) { worker?.join() } }
            cleanup.finish(false, cancel = batch::cancel, close = { batch.close(); storage.close() })
            root.deleteRecursively()
        }
    }
}
