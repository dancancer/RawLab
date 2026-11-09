package com.rawlab.android.album

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.photo.EditedPhotoPreviews
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.testing.LanguageTestRule
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

@SdkSuppress(minSdkVersion = 29)
class EditedPhotoPreviewTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val resolver = context.contentResolver
    private val bucket = "Edited-${UUID.randomUUID().toString().take(8)}"
    private val photos = mutableListOf<Uri>()
    private val store get() = EditStore(File(context.filesDir, "edits"))

    @Before fun fixtures() {
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(context.packageName,
            if (Build.VERSION.SDK_INT >= 33) "android.permission.READ_MEDIA_IMAGES" else "android.permission.READ_EXTERNAL_STORAGE")
        for (index in 0..1) {
            val uri = requireNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, "$bucket-$index.jpg")
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/$bucket")
                put(MediaStore.Images.Media.WIDTH, 320); put(MediaStore.Images.Media.HEIGHT, 200)
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }))
            photos += uri
            write(uri, if (index == 0) 50 else 100)
            resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        }
    }
    private fun write(uri: Uri, level: Int) {
        val bitmap = Bitmap.createBitmap(320, 200, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.rgb(level, level, level))
        try { resolver.openOutputStream(uri, "wt")!!.use { assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it)) } }
        finally { bitmap.recycle() }
    }
    @After fun cleanup() {
        for (uri in photos) { store.reset(PhotoIdentity(uri.toString())); resolver.delete(uri, null, null) }
    }

    @Test fun editedFilterAndBadgeFollowSavedReset() {
        store.save(PhotoIdentity(photos[0].toString()), EditSettings(exposureMode = 2, exposure = 1f))
        compose.onNodeWithContentDescription("相册").performClick()
        compose.waitUntil(15_000) { compose.onAllNodesWithText(bucket).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(bucket).performClick()
        compose.waitUntil(15_000) { compose.onAllNodesWithTag("album-edited-${photos[0]}", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("album-edit-filter-edited").performClick()
        compose.onNodeWithTag("album-photo-${photos[0]}").assertExists()
        compose.onNodeWithTag("album-photo-${photos[1]}").assertDoesNotExist()
        store.reset(PhotoIdentity(photos[0].toString()))
        compose.waitUntil(15_000) { compose.onAllNodesWithTag("album-photo-${photos[0]}").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithTag("album-edit-filter-unedited").performClick()
        compose.onNodeWithTag("album-photo-${photos[0]}").assertExists()
        compose.onNodeWithTag("album-photo-${photos[1]}").assertExists()
        compose.onNodeWithTag("album-edited-${photos[0]}", useUnmergedTree = true).assertDoesNotExist()
    }

    @Test fun editFiltersKeepPhotoSelection() {
        store.save(PhotoIdentity(photos[0].toString()), EditSettings(exposureMode = 2, exposure = 1f))
        val selected = mutableStateOf(emptySet<String>())
        compose.activityRule.scenario.onActivity { activity ->
            activity.setContent {
                MaterialTheme {
                    AlbumScreen(activity.model.storage, {}, null, { uri ->
                        selected.value = if (uri.toString() in selected.value) selected.value - uri.toString()
                            else selected.value + uri.toString()
                    }, selectedPhotos = selected.value, onDone = {}, initialPhotos = photos.map { it.toString() }.toSet())
                }
            }
        }
        compose.waitUntil(15_000) { compose.onAllNodesWithTag("album-photo-${photos[0]}").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("album-photo-${photos[0]}").performClick()
        compose.onNodeWithTag("album-edit-filter-unedited").performClick()
        compose.onNodeWithTag("album-photo-${photos[0]}").assertDoesNotExist()
        compose.runOnIdle { assertEquals(setOf(photos[0].toString()), selected.value) }
        compose.onNodeWithTag("album-edit-filter-all").performClick()
        compose.onNode(hasAnyAncestor(hasTestTag("album-photo-${photos[0]}")) and isToggleable(), useUnmergedTree = true).assertIsOn()
    }

    @Test fun renderedThumbnailChangesWithExposureGeometryAndSource() = runBlocking {
        val uri = photos[0]
        val identity = PhotoIdentity(uri.toString())
        val row = compose.activity.model.storage.album().first { it.uri == uri }
        val service = EditedPhotoPreviews(context)
        try {
            val neutral = EditSettings(exposureMode = 2)
            store.save(identity, neutral)
            val original = service.image(row)
            store.save(identity, neutral.copy(exposure = 1f))
            val adjusted = service.image(row)
            assertTrue("Saved exposure appears in the rendered thumbnail",
                Color.red(adjusted.getPixel(adjusted.width / 2, adjusted.height / 2)) >
                    Color.red(original.getPixel(original.width / 2, original.height / 2)) + 5)
            store.save(identity, neutral.copy(geometry = GeometrySettings(quarterTurns = 1)))
            val rotated = service.image(row)
            assertTrue("Saved geometry changes thumbnail orientation", rotated.height > rotated.width)
            write(uri, 160)
            val replaced = service.image(row)
            assertTrue("Replacing the source invalidates the cached pixels",
                Color.red(replaced.getPixel(replaced.width / 2, replaced.height / 2)) >
                    Color.red(rotated.getPixel(rotated.width / 2, rotated.height / 2)) + 30)
        } finally { service.close() }
    }
}
