package com.rawlab.android.ui

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.camera.CameraTetherParameterState
import com.rawlab.android.camera.CameraTetherPhase
import com.rawlab.android.camera.CameraTetherState
import com.rawlab.android.camera.CameraTetherWorkspace
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.testing.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.UUID

class AlbumBatchCameraUiSmokeTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule("zh-Hans")).around(ForegroundTestRule()).around(compose)

    @Test fun albumBrowseFilterAndOpenPhotoSmoke() {
        assumeTrue(Build.VERSION.SDK_INT >= 29)
        val context = compose.activity
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(
            context.packageName,
            if (Build.VERSION.SDK_INT >= 33) "android.permission.READ_MEDIA_IMAGES" else "android.permission.READ_EXTERNAL_STORAGE",
        )
        val bucket = "SmokeAlbum-${UUID.randomUUID().toString().take(8)}"
        val uri = requireNotNull(context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "$bucket.jpg")
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/$bucket")
            put(MediaStore.Images.Media.WIDTH, 120)
            put(MediaStore.Images.Media.HEIGHT, 80)
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }))
        val store = EditStore(File(context.filesDir, "edits"))
        try {
            val bitmap = Bitmap.createBitmap(120, 80, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.DKGRAY) }
            context.contentResolver.openOutputStream(uri, "wt")!!.use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
            bitmap.recycle()
            context.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            store.save(PhotoIdentity(uri.toString()), EditSettings(exposure = 0.5f))

            val album = AlbumRobot(compose)
            album.openAlbum(context.getString(R.string.open_album))
            album.selectBucket(bucket)
            album.selectFilter("edited")
            album.openPhoto(uri.toString())
            compose.waitUntilEditorReady(compose.activity.model)
        } finally {
            store.reset(PhotoIdentity(uri.toString()))
            context.contentResolver.delete(uri, null, null)
        }
    }

    @Test fun batchCollectionEditAndExportSmoke() {
        val context = compose.activity
        val root = File(context.cacheDir, "batch-smoke-${UUID.randomUUID()}").apply { mkdirs() }
        val source = File(root, "photo.png")
        Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).let { bitmap ->
            bitmap.eraseColor(0xff557799.toInt())
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
        val uri = Uri.fromFile(source)
        val model = compose.activity.model
        var jobID: String? = null
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(uri) }
            compose.waitUntilEditorReady(model)

            val batchRobot = BatchRobot(compose)
            batchRobot.openCollectionAndAssertDisplayed(model)
            batchRobot.editPhotoFromCollection(model, uri.toString())
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = 0.4f)) }
            compose.waitUntilEditorReady(model)
            batchRobot.toggleCollectionFromMenu(model)
            batchRobot.openBatchExportConfig()
            batchRobot.startAndAwaitComplete(model)

            val batch = model.batch.value!!
            jobID = batch.state.value.job.id
            assertEquals(0.4f, batch.state.value.job.rows.single().target.frozen!!.settings.exposure)
            batch.state.value.job.rows.mapNotNull { it.outputUri }.forEach { context.contentResolver.delete(Uri.parse(it), null, null) }
            compose.runOnUiThread { assertTrue(batch.discard()); model.closeBatch() }
        } finally {
            jobID?.let { BatchJournal(File(context.filesDir, "RawLab/BatchJobs")).discard(it) }
            EditStore(File(context.filesDir, "edits")).reset(PhotoIdentity(uri.toString()))
            root.deleteRecursively()
        }
    }

    @Test fun cameraTetherControlSmoke() {
        val state = mutableStateOf(CameraTetherState(phase = CameraTetherPhase.READY, live = true, parameters = CameraTetherParameterState(captureReady = true)))
        var shots = 0
        compose.setContent {
            RawLabTheme {
                CameraTetherWorkspace(state.value, { _, _ -> null }, { shots++ }, {}, {})
            }
        }
        compose.onNodeWithTag("tether-shutter").assertIsEnabled().performClick()
        assertEquals(1, shots)
        compose.onNodeWithTag("tether-menu").performClick()
        compose.onNodeWithTag("tether-grid-toggle").performClick()
        compose.onNodeWithTag("tether-grid").assertExists()
    }

    @Test fun exportSheetAndPhotoInfoOverlaySmoke() {
        val source = File(compose.activity.cacheDir, "export-smoke-${UUID.randomUUID()}.png")
        Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).let { bitmap ->
            bitmap.eraseColor(0xff335577.toInt())
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntilEditorReady(model)
            compose.cycleWorkbenchPhotoInfo(compose.activity.getString(R.string.editor_photo_info))
            compose.onNodeWithTag("photo-info-panel").assertIsDisplayed()
            ExportRobot(compose).openExportSheet(compose.activity.getString(R.string.export))
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }
}
