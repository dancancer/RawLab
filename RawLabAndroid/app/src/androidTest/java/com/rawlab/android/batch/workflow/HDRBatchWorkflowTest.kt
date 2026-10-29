package com.rawlab.android.batch.workflow

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.batch.*
import com.rawlab.android.engine.NativeHDRBridge
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.editor.Operation
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.settings.*
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

class HDRBatchWorkflowTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    val compose = createAndroidComposeRule<MainActivity>()
    private val cleanup = BatchTestCleanup(instrumentation.targetContext)
    @get:Rule val rules = org.junit.rules.RuleChain.outerRule(cleanup).around(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    @Test fun uniformHDRSourcePreflightsMixedTargetsAndFreezesTheirModes() {
        val id=UUID.randomUUID().toString();cleanup.begin(id)
        val context=instrumentation.targetContext
        val root=File(context.cacheDir,"hdr-batch-$id").apply { mkdirs() }
        fun asset(name: String, file: String)=File(root,file).also { output ->
            instrumentation.context.assets.open(name).use { input -> output.outputStream().use { input.copyTo(it) } }
        }
        val hdr=asset("hdr-sample.jpg","batch-gpu-$id-hdr.jpg")
        val oldHDR=hdr.copyTo(File(root,"batch-gpu-$id-old-hdr.jpg"))
        val raw=asset("sample.RAW","batch-gpu-$id-raw.dng")
        val jpeg=File(root,"batch-gpu-$id-ordinary.jpg").also { file ->
            val image=Bitmap.createBitmap(48,32,Bitmap.Config.ARGB_8888);image.eraseColor(android.graphics.Color.rgb(180,80,30))
            file.outputStream().use { assertTrue(image.compress(Bitmap.CompressFormat.JPEG,95,it)) };image.recycle()
        }
        val targets=listOf(hdr,jpeg,raw,oldHDR)
        val originals=targets.associateWith { BatchFrozenSettings.checksum(it) }
        val store=EditStore(File(context.filesDir,"edits"))
        val oldID=PhotoIdentity(Uri.fromFile(oldHDR).toString());store.save(oldID,EditSettings(exposure=-.75f))
        val model=compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false);model.importPhoto(Uri.fromFile(hdr)) }
            compose.waitUntil(120_000) { model.state.value.canExport || model.state.value.error!=null };assertNull(model.state.value.error)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure=.5f)) }
            compose.waitUntil(120_000) { model.state.value.canExport && model.state.value.edits.exposure==.5f }
            val sourceSettings=model.state.value.edits
            assertTrue(sourceSettings.isHDREditing)
            val records=targets.associateWith { store.versionedState(PhotoIdentity(Uri.fromFile(it).toString())) }
            compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
            compose.waitUntil(60_000) { compose.onAllNodes(hasText(compose.activity.getString(R.string.batch_export)) and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText(compose.activity.getString(R.string.batch_export)).performClick()
            compose.waitUntil(60_000) {
                model.state.value.error?.let { throw AssertionError("Opening batch failed: $it") }
                model.batch.value!=null
            }
            val batch=requireNotNull(model.batch.value);cleanup.trackJob(batch.state.value.job.id)
            compose.waitUntil(60_000) { batch.state.value.phase==BatchPhase.SELECTING }
            compose.runOnUiThread { batch.addUris(targets.map(Uri::fromFile)) }
            compose.waitUntil(120_000) { batch.state.value.phase!=BatchPhase.PREPARING }
            assertNull(batch.state.value.error);assertEquals(4,batch.state.value.job.rows.size)
            compose.onNodeWithText("导出 4 张").assertIsDisplayed().assertIsEnabled()
            val previewTarget=batch.state.value.job.rows.first { it.target.displayName==jpeg.name }.target
            val preview=runCatching { runBlocking { batch.preview(previewTarget) }.also { it.recycle() } }
            compose.runOnUiThread { batch.start(ExportFormat.JPEG,null,128) }
            compose.waitUntil(240_000) { batch.state.value.phase !in setOf(BatchPhase.PREPARING,BatchPhase.RUNNING) }
            val state=batch.state.value
            assertTrue("Mixed batch failed: ${state.error}; ${state.job.rows.map { it.error }}",state.job.rows.all { it.status==BatchRowStatus.SUCCESS })
            assertTrue("Ordinary target preview failed: ${preview.exceptionOrNull()}",preview.isSuccess)
            assertEquals(BatchSettingsMode.PER_TARGET_FROZEN,state.job.settingsMode)
            state.job.rows.forEach { row ->
                val frozen=requireNotNull(row.target.frozen)
                assertEquals(row.target.displayName==hdr.name,frozen.settings.isHDREditing)
                assertEquals(.5f,frozen.settings.exposure)
                val output=File(root,"output-${row.id.hashCode()}.jpg")
                context.contentResolver.openInputStream(Uri.parse(row.outputUri))!!.use { input -> output.outputStream().use { input.copyTo(it) } }
                assertNull(NativeHDRBridge.probe(output))
            }
            assertEquals(sourceSettings,state.job.source.settings)
            targets.forEach { assertEquals(originals[it],BatchFrozenSettings.checksum(it));assertEquals(records[it],store.versionedState(PhotoIdentity(Uri.fromFile(it).toString()))) }
            compose.waitForIdle()
            val screenshot=File(compose.activity.getExternalFilesDir(null),"hdr-tests/mixed-batch.png");screenshot.parentFile!!.mkdirs()
            instrumentation.uiAutomation.takeScreenshot()!!.let { image -> screenshot.outputStream().use { image.compress(Bitmap.CompressFormat.PNG,100,it) };image.recycle() }
        } finally {
            val batch=model.batch.value
            cleanup.finish(batch?.state?.value?.phase in setOf(BatchPhase.PREPARING,BatchPhase.RUNNING) || model.state.value.operation!=Operation.NONE,
                cancel={batch?.cancel()},close={compose.runOnUiThread { model.closeBatch() }})
            root.deleteRecursively()
        }
    }

    @Test fun processorStartupFailureKeepsTheCommittedFrozenJobInMemory() {
        val id=UUID.randomUUID().toString();cleanup.begin(id)
        val context=instrumentation.targetContext
        val input=File(context.cacheDir,"startup-$id.jpg")
        instrumentation.context.assets.open("hdr-sample.jpg").use { from -> input.outputStream().use { from.copyTo(it) } }
        val identity=PhotoIdentity(Uri.fromFile(input).toString())
        val source=BatchSourceSnapshot(identity,input,sourceDefaultSettings(true),inputKind=PhotoInputKind.RASTER)
        val target=BatchTarget(identity,input,input.name,inputKind=PhotoInputKind.RASTER,sourceIsHDR=true)
        val draft=BatchJob(source,listOf(target),id=id)
        val batch=BatchExportModel(context,PhotoStorage(context),source,initial=draft,gpuMode=NativeProcessor.CPU,
            processorFactory={_,_->throw java.io.IOException("Injected processor startup failure")})
        try {
            compose.waitUntil(60_000) { batch.state.value.phase!=BatchPhase.PREPARING }
            compose.runOnUiThread { batch.start(ExportFormat.JPEG,null,128) }
            compose.waitUntil(60_000) { batch.state.value.phase !in setOf(BatchPhase.PREPARING,BatchPhase.RUNNING) }
            assertEquals(BatchPhase.FAILED,batch.state.value.phase)
            assertEquals(BatchSettingsMode.PER_TARGET_FROZEN,batch.state.value.job.settingsMode)
            val saved=BatchJournal(File(context.filesDir,"RawLab/BatchJobs")).load(id)!!
            assertEquals(saved.settingsFor(saved.rows.single().target),batch.state.value.job.settingsFor(batch.state.value.job.rows.single().target))
        } finally {
            cleanup.finish(batch.state.value.phase in setOf(BatchPhase.PREPARING,BatchPhase.RUNNING),cancel=batch::cancel,close=batch::close)
            input.delete()
        }
    }
}
