package com.rawlab.android.camera

import android.content.ContentUris
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.exifinterface.media.ExifInterface
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.photo.MediaPhotoLibrary
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.security.MessageDigest
import java.util.UUID

@SdkSuppress(minSdkVersion = 29)
class CameraMediaUiTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val languageAndCompose: RuleChain = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun destinationSettingsRejectInvalidPathsAndKeepTheSavedRule() {
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.preparing }
        val previous = compose.activity.camera.state.value.destination
        try {
            compose.onNodeWithTag("camera-entry").performClick()
            compose.onNodeWithTag("camera-destination-settings").performClick()
            compose.onNodeWithTag("camera-directory-input").performTextReplacement("../Private")
            compose.onNodeWithTag("camera-destination-save").assertIsNotEnabled()
            compose.onNodeWithTag("camera-directory-input").performTextReplacement("Trips/Sony")
            compose.onNodeWithTag("camera-group-CAPTURE_MONTH").performScrollTo().performClick()
            compose.onNodeWithText("Pictures/Trips/Sony/2026-10/").performScrollTo().assertIsDisplayed()
            compose.onNodeWithTag("camera-destination-save").performClick()
            assertEquals(CameraImportDestination("Trips/Sony", CameraDirectoryGrouping.CAPTURE_MONTH), compose.activity.camera.state.value.destination)
            compose.onNodeWithTag("camera-destination-settings").performClick()
            compose.onNodeWithTag("camera-directory-input").assert(
                SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("Trips/Sony")))
            compose.onNodeWithTag("camera-destination-cancel").performClick()
        } finally { compose.runOnUiThread { compose.activity.camera.setDestination(previous) } }
    }

    @Test fun ownPhotosRemainVisibleWithoutFullPermissionAndSameNamedFoldersStaySeparate() = withMedia { root, prefix, save ->
        val permission = if (Build.VERSION.SDK_INT >= 33) "android.permission.READ_MEDIA_IMAGES" else "android.permission.READ_EXTERNAL_STORAGE"
        assertEquals("Run this test before granting full library access", PackageManager.PERMISSION_DENIED,
            compose.activity.checkSelfPermission(permission))
        val first = save("A", "FIRST.JPG", jpeg(root, Color.RED))
        val second = save("B", "SECOND.JPG", jpeg(root, Color.GREEN))
        val a = first.items.single().saved!!; val b = second.items.single().saved!!
        compose.onNodeWithContentDescription("相册").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("FIRST.JPG").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("SECOND.JPG").assertIsDisplayed()
        compose.onNodeWithTag("album-groups").performScrollToIndex(2)
        val key = "external_primary:Pictures/$prefix/A/2026-10-22/"
        compose.onNodeWithTag("album-groups").performScrollToIndex(
            if (compose.activity.model.storage.album(ownOnly = true).first().uri.toString() == b.uri) 2 else 1)
        compose.onNodeWithTag("album-group-$key").performClick()
        compose.onNodeWithText("FIRST.JPG").assertIsDisplayed()
        compose.onNodeWithText("SECOND.JPG").assertDoesNotExist()
        assertNotEquals(a.uri, b.uri)
    }

    @Test fun cameraAlbumHandoffPreservesDraftUntilThePhotoIsChosen() = withMedia { root, _, save ->
        val incoming = save("A", "INCOMING.JPG", jpeg(root, Color.GREEN))
        val originalFile = jpeg(root, Color.BLUE)
        compose.runOnUiThread { compose.activity.model.setGpuEnabled(false); compose.activity.model.importPhoto(Uri.fromFile(originalFile)) }
        compose.waitUntil(60_000) { compose.activity.model.state.value.let { it.canExport || it.error != null } }
        assertNull(compose.activity.model.state.value.error)
        compose.runOnUiThread { compose.activity.model.beginDraft(AdjustmentGroup.GEOMETRY) }
        compose.waitUntil(60_000) { compose.activity.model.state.value.draftReady }
        compose.runOnUiThread {
            val model = compose.activity.model
            model.changeDraft(model.state.value.visibleEdits.copy(geometry = model.state.value.visibleEdits.geometry.copy(cropWidth = .8f)), false)
        }
        compose.waitUntil(60_000) { compose.activity.model.state.value.draftReady }
        val original = compose.activity.model.state.value.photo!!.identity
        val draft = compose.activity.model.state.value.draft
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.preparing }
        compose.runOnUiThread { compose.activity.camera.selectJob(incoming) }
        compose.onNode(hasContentDescription("更多") and hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
        compose.onNodeWithTag("camera-entry").performClick()
        compose.onNodeWithText("查看导入任务").performClick()
        compose.onNodeWithTag("camera-view-album").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("INCOMING.JPG").fetchSemanticsNodes().isNotEmpty() }
        assertEquals(draft, compose.activity.model.state.value.draft)
        compose.onNodeWithText("INCOMING.JPG").performClick()
        compose.waitUntil(20_000) { compose.onAllNodesWithText("继续编辑").fetchSemanticsNodes().isNotEmpty() }
        assertEquals(original, compose.activity.model.state.value.photo!!.identity)
        assertEquals(draft, compose.activity.model.state.value.draft)
        compose.onNodeWithText("继续编辑").performClick()
        assertEquals(original, compose.activity.model.state.value.photo!!.identity)
    }

    @Test fun missingOriginalIsNotPresentedAsACompletedImport() = withMedia { root, _, save ->
        val job = save("A", "DELETED.JPG", jpeg(root, Color.RED))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.contentResolver.delete(Uri.parse(job.items.single().saved!!.uri), null, null)
        val restored = CameraImportStore(File(root, "jobs"), File(root, "partial"), MediaPhotoLibrary(context),
            CameraCaptureDateReader::read).load().single()
        compose.runOnUiThread { compose.activity.camera.selectJob(restored) }
        compose.onNodeWithTag("camera-open-task").performClick()
        compose.onNodeWithText("原片不可用").assertIsDisplayed()
        compose.onNodeWithText("已保存 0 / 1 张").assertIsDisplayed()
        compose.onNodeWithTag("camera-open").assertDoesNotExist()
        compose.onNodeWithTag("camera-view-album").assertDoesNotExist()
        compose.onNodeWithText("重新下载不可用的原片").assertIsDisplayed()
    }

    @Test fun tetherReviewUsesTheSavedOriginalAndOnlyEditLeavesTheCamera() = withMedia { root, _, save ->
        val job = save("Tether", "TETHER.JPG", jpeg(root, Color.GREEN))
        val camera = compose.activity.camera
        val field = CameraImportViewModel::class.java.getDeclaredField("store").apply { isAccessible = true }
        val productStore = field.get(camera) as CameraImportStore
        val run = CameraTetherRun(UUID.randomUUID().toString(), "fixture", "ZV-E10/2.02", 0, emptyList(), job.destination,
            listOf(CameraTetherBatch(job.id, job.items.map { it.photo })), CameraTetherStatus.PAUSED)
        productStore.save(job)
        try {
            compose.runOnUiThread { camera.tether.restore(listOf(run), listOf(job)); camera.setMode(CameraMode.TETHER) }
            compose.waitUntil(10_000) { !camera.state.value.closing }
            compose.onNodeWithTag("camera-entry").performClick()
            compose.onNodeWithTag("tether-shutter").assertIsNotEnabled()
            compose.onNodeWithTag("tether-recent").performClick()
            compose.onNodeWithTag("tether-review").assertIsDisplayed()
            assertNull(compose.activity.model.state.value.photo)
            compose.onNodeWithTag("tether-review-edit").performClick()
            compose.waitUntil(60_000) { compose.activity.model.state.value.let { it.canExport || it.error != null } }
            assertNull(compose.activity.model.state.value.error)
            assertEquals(job.items.single().saved!!.uri, compose.activity.model.state.value.photo!!.identity.value)
            compose.onNodeWithTag("tether-review").assertDoesNotExist()
            assertFalse(camera.state.value.connected)
        } finally {
            File(compose.activity.filesDir, "camera-media-imports/${job.id}.json").delete()
            compose.runOnUiThread { camera.setMode(CameraMode.IMPORT) }
        }
    }

    private fun jpeg(root: File, color: Int): File {
        val file = File(root, "${UUID.randomUUID()}.jpg")
        val bitmap = Bitmap.createBitmap(320, 240, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(color); file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }; bitmap.recycle()
        ExifInterface(file).apply { setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2026:10:22 18:28:03"); saveAttributes() }
        return file
    }
    private fun withMedia(test: (File, String, (String, String, File) -> CameraImportJob) -> Unit) {
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.preparing }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "camera-media-ui-${UUID.randomUUID()}").apply { mkdirs() }
        val prefix = "RawLab/Tests/${root.name}"
        val library = MediaPhotoLibrary(context)
        val store = CameraImportStore(File(root, "jobs"), File(root, "partial"), library, CameraCaptureDateReader::read)
        val owned = mutableSetOf<Uri>()
        try {
            test(root, prefix) { directory, name, file ->
                val job = store.create("fixture", listOf(CameraPhoto(UUID.randomUUID().toString(), name, file.length(), 0)), CameraImportDestination("$prefix/$directory"))
                file.copyTo(store.partial(job.id), overwrite = true)
                val digest = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
                store.publish(job, 0, store.partial(job.id), digest, CameraTransferPermit()).also { saved ->
                    owned += Uri.parse(saved.items.single().saved!!.uri)
                }
            }
        } finally {
            @Suppress("DEPRECATION")
            val collection = MediaStore.setIncludePending(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY))
            val existing = context.contentResolver.query(collection, arrayOf(MediaStore.Images.Media._ID),
                "${MediaStore.Images.Media.OWNER_PACKAGE_NAME} = ? AND ${MediaStore.Images.Media.RELATIVE_PATH} LIKE ?",
                arrayOf(context.packageName, "Pictures/$prefix/%"), null)?.use { cursor ->
                buildSet { while (cursor.moveToNext()) add(ContentUris.withAppendedId(
                    MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), cursor.getLong(0))) }
            }.orEmpty()
            existing.forEach { context.contentResolver.delete(it, null, null) }
            // Android 10 对重复删除已不存在的 URI 可能抛 SecurityException，先查本测试仍拥有的行。
            for (uri in owned + existing) context.getSharedPreferences("camera-media-sources", 0).edit().remove(uri.toString()).commit()
            root.deleteRecursively()
        }
    }
}
