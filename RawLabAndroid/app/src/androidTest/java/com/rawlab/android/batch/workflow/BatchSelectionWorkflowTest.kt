package com.rawlab.android.batch.workflow

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

class BatchSelectionWorkflowTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private fun screenshot(name: String) {
        compose.waitForIdle()
        val file = File(compose.activity.getExternalFilesDir(null), "ux02-batch/$name.png")
        file.parentFile!!.mkdirs()
        val automation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.waitForIdle(200, 5_000)
        val bitmap = automation.takeScreenshot()
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    @Test fun selectedPhotoUsesExistingEditorAndReturnsToFrozenConfirmation() {
        val context = compose.activity
        val root = File(context.cacheDir, "collection-ui-${UUID.randomUUID()}").apply { mkdirs() }
        val source = File(root, "photo.png")
        Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).also { bitmap ->
            bitmap.eraseColor(0xff557799.toInt())
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
        val uri = Uri.fromFile(source)
        val model = compose.activity.model
        var jobID: String? = null
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(uri) }
            compose.waitUntil(60_000) { model.state.value.canExport }
            compose.onNode(hasContentDescription(AppStrings.text(R.string.more)) and
                !hasAnyAncestor(hasTestTag("adjustment-dock"))).performClick()
            compose.onNodeWithTag("collection-menu").performClick()
            compose.waitUntil(60_000) { !model.collection.value.busy && model.collection.value.photos.size == 1 }
            compose.onNodeWithTag("batch-selection-root").assertIsDisplayed()
            screenshot("collection")
            compose.onNodeWithTag("collection-sync").assertIsNotEnabled()
            compose.onNodeWithTag("collection-edit-$uri").performClick()
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .4f)) }
            compose.waitUntil(60_000) { model.state.value.canExport }
            compose.onNode(hasContentDescription(AppStrings.text(R.string.more)) and
                !hasAnyAncestor(hasTestTag("adjustment-dock"))).performClick()
            compose.onNodeWithTag("collection-menu").performClick()
            assertEquals(setOf(uri.toString()), model.collection.value.selected)
            compose.onNodeWithTag("collection-export").performClick()
            compose.onNodeWithTag("collection-export-start").assertIsDisplayed().assertIsEnabled()
            screenshot("export-configuration")
            compose.onNodeWithTag("collection-export-start").performClick()
            compose.waitUntil(60_000) { model.batch.value?.state?.value?.phase == com.rawlab.android.batch.BatchPhase.COMPLETE }
            val batch = model.batch.value!!
            jobID = batch.state.value.job.id
            assertEquals(.4f, batch.state.value.job.rows.single().target.frozen!!.settings.exposure)
            assertEquals(com.rawlab.android.batch.BatchRowStatus.SUCCESS, batch.state.value.job.rows.single().status)
            compose.onNodeWithText(AppStrings.text(R.string.message_export_complete)).assertIsDisplayed()
            screenshot("completed")
            batch.state.value.job.rows.mapNotNull { it.outputUri }.forEach { context.contentResolver.delete(Uri.parse(it), null, null) }
            compose.runOnUiThread { assertTrue(batch.discard()); model.closeBatch() }
            compose.waitUntil(10_000) { model.batch.value == null }
            compose.onNodeWithTag("batch-selection-root").assertIsDisplayed()
            assertEquals(.4f, EditStore(File(context.filesDir, "edits")).load(PhotoIdentity(uri.toString()))!!.exposure)
        } finally {
            jobID?.let { com.rawlab.android.batch.journal.BatchJournal(File(context.filesDir, "RawLab/BatchJobs")).discard(it) }
            EditStore(File(context.filesDir, "edits")).reset(PhotoIdentity(uri.toString()))
            root.deleteRecursively()
        }
    }
}
