package com.rawlab.android

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.exifinterface.media.ExifInterface
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.filters.SdkSuppress
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.util.UUID

@SdkSuppress(minSdkVersion = 29)
class AlbumScreenTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val resolver = InstrumentationRegistry.getInstrumentation().targetContext.contentResolver
    private val bucket = "Scroll-${UUID.randomUUID().toString().take(8)}"
    private val media = mutableListOf<Uri>()
    private fun photoName(index: Int) = "$bucket-${index.toString().padStart(4, '0')}.dng"
    private val grid get() = compose.onNode(hasScrollToIndexAction() and
        SemanticsMatcher.keyIsDefined(SemanticsProperties.VerticalScrollAxisRange))

    @Before fun createPhotos() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.grantRuntimePermission(instrumentation.targetContext.packageName,
            if (Build.VERSION.SDK_INT >= 33) "android.permission.READ_MEDIA_IMAGES" else "android.permission.READ_EXTERNAL_STORAGE")
        for (index in 0..160) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, photoName(index))
                put(MediaStore.Images.Media.MIME_TYPE, "image/x-adobe-dng")
                put(MediaStore.Images.Media.DATE_ADDED, 1_900_000_000L + index)
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/${if (index == 160) "$bucket-other" else bucket}")
            }
            media += requireNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
        }
    }

    @After fun removePhotos() {
        media.forEach { resolver.delete(it, null, null) }
    }

    private fun openAlbum() {
        compose.onNodeWithContentDescription("相册").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("全部相册").fetchSemanticsNodes().isNotEmpty() }
        compose.onNode(hasScrollToIndexAction() and SemanticsMatcher.keyIsDefined(SemanticsProperties.HorizontalScrollAxisRange))
            .performScrollToNode(hasText(bucket))
    }

    private fun scrollInBucket(): String {
        openAlbum()
        compose.onNodeWithText(bucket).performClick()
        val photos = compose.activity.model.storage.album().filter { it.album == bucket }
        assertEquals(160, photos.size)
        grid.performScrollToIndex(90)
        val name = photos[90].name
        compose.onNodeWithText(name).assertIsDisplayed()
        return name
    }

    private fun selectColumns(count: Int) {
        compose.onNodeWithContentDescription("视图选项").performClick()
        compose.onNodeWithText("每行 $count 张").performClick()
    }

    private fun selectMode(name: String) {
        compose.onNodeWithContentDescription("视图选项").performClick()
        compose.onNodeWithText(name).performClick()
    }

    private fun writePreview(index: Int, width: Int, height: Int) {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.CYAN)
        try {
            resolver.openOutputStream(media[index], "wt")!!.use { output ->
                assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, output))
            }
        } finally { bitmap.recycle() }
        resolver.update(media[index], ContentValues().apply {
            put(MediaStore.Images.Media.WIDTH, width)
            put(MediaStore.Images.Media.HEIGHT, height)
            put(MediaStore.Images.Media.ORIENTATION, 0)
        }, null, null)
    }

    private fun assertPreviewRatio(index: Int, ratio: Float) {
        val photos = compose.activity.model.storage.album().filter { it.album == bucket }
        val position = photos.indexOfFirst { it.uri == media[index] }
        assertTrue("Preview fixture remains an album photo", position >= 0)
        grid.performScrollToIndex(position)
        val name = photos[position].name
        val node = compose.onNodeWithContentDescription(name, useUnmergedTree = true)
        compose.waitUntil(10_000) {
            val bounds = compose.onAllNodesWithContentDescription(name, useUnmergedTree = true)
                .fetchSemanticsNodes().singleOrNull()?.boundsInRoot
            bounds != null && bounds.width > with(compose.density) { 40.dp.toPx() }
        }
        val bounds = node.fetchSemanticsNode().boundsInRoot
        assertEquals("Photo $index has the selected aspect ratio", ratio, bounds.width / bounds.height, .02f)
    }

    @Test fun previewsKeepLandscapeAndPortraitRatiosByDefault() {
        writePreview(159, 600, 300)
        writePreview(158, 300, 600)
        openAlbum()
        compose.onNodeWithText(bucket).performClick()
        assertPreviewRatio(159, 2f)
        assertPreviewRatio(158, .5f)
    }

    @Test fun previewModeSwitchesBetweenSquareAndOriginal() {
        writePreview(159, 600, 300)
        writePreview(158, 300, 600)
        openAlbum()
        compose.onNodeWithText(bucket).performClick()
        selectMode("方形缩略图")
        assertPreviewRatio(159, 1f)
        assertPreviewRatio(158, 1f)
        selectMode("原始比例")
        assertPreviewRatio(159, 2f)
        assertPreviewRatio(158, .5f)
    }

    @Test fun rotatedPreviewUsesDisplayOrientation() {
        writePreview(159, 600, 300)
        resolver.openFileDescriptor(media[159], "rw")!!.use { descriptor ->
            ExifInterface(descriptor.fileDescriptor).apply {
                setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
                saveAttributes()
            }
        }
        resolver.update(media[159], ContentValues().apply {
            put(MediaStore.Images.Media.WIDTH, 600)
            put(MediaStore.Images.Media.HEIGHT, 300)
            put(MediaStore.Images.Media.ORIENTATION, 90)
        }, null, null)
        openAlbum()
        compose.onNodeWithText(bucket).performClick()
        assertPreviewRatio(159, .5f)
    }

    @Test fun gridOffersOneThroughSixColumns() {
        openAlbum()
        compose.onNodeWithText(bucket).performClick()
        val photos = compose.activity.model.storage.album().filter { it.album == bucket }
        grid.performScrollToIndex(0)
        selectMode("方形缩略图")
        compose.onNodeWithContentDescription("视图选项").performClick()
        for (count in 1..6) compose.onNodeWithText("每行 $count 张").assertIsDisplayed()
        compose.onNodeWithText("每行 7 张").assertDoesNotExist()
        compose.onNodeWithText("每行 1 张").performClick()
        val width = grid.fetchSemanticsNode().boundsInRoot.width
        val single = compose.onNodeWithText(photos.first().name).fetchSemanticsNode().boundsInRoot
        assertTrue("One column fills the grid width", single.width > width * .9f)

        selectColumns(6)
        val firstRow = photos.take(6).map { compose.onNodeWithText(it.name).fetchSemanticsNode().boundsInRoot }
        assertTrue("Six photos share the row", firstRow.all { kotlin.math.abs(it.top - firstRow.first().top) < 1f })
        assertTrue(firstRow.zipWithNext().all { (left, right) -> left.right < right.left })
        assertTrue(firstRow.all { it.width < width / 5f })
        val next = compose.onNodeWithText(photos[6].name).fetchSemanticsNode().boundsInRoot
        assertTrue("The seventh photo starts the next row", next.top > firstRow.first().top)
        assertEquals(firstRow.first().left, next.left, 1f)
    }

    @Test fun changingViewKeepsCurrentPhotoVisible() {
        val name = scrollInBucket()
        selectColumns(1)
        compose.onNodeWithText(name).assertIsDisplayed()
        selectColumns(6)
        compose.onNodeWithText(name).assertIsDisplayed()
        selectMode("方形缩略图")
        compose.onNodeWithText(name).assertIsDisplayed()
    }

    @Test fun shrinkingTilesKeepsPartlyVisiblePhotoInView() {
        openAlbum()
        compose.onNodeWithText(bucket).performClick()
        selectColumns(1)
        grid.performScrollToIndex(90)
        val name = compose.activity.model.storage.album().filter { it.album == bucket }[90].name
        grid.performSemanticsAction(SemanticsActions.ScrollBy) { scroll ->
            scroll(0f, with(compose.density) { 160.dp.toPx() })
        }
        compose.onNodeWithText(name).assertIsDisplayed()
        selectColumns(6)
        compose.onNodeWithText(name).assertIsDisplayed()
    }

    @Test fun viewOptionsSurviveEditorReturnAndRecreation() {
        openAlbum()
        compose.onNodeWithText(bucket).performClick()
        selectColumns(6)
        selectMode("方形缩略图")
        grid.performScrollToIndex(90)
        val name = compose.activity.model.storage.album().filter { it.album == bucket }[90].name
        compose.onNodeWithText(name).performClick()
        compose.waitUntil(10_000) { compose.activity.model.state.value.operation == Operation.NONE }
        compose.activityRule.scenario.recreate()
        openAlbum()
        compose.onNodeWithText(bucket).assertIsSelected()
        compose.onNodeWithText(name).assertIsDisplayed()
        compose.onNodeWithContentDescription("视图选项").performClick()
        compose.onNodeWithText("每行 6 张").assertIsSelected()
        compose.onNodeWithText("方形缩略图").assertIsSelected()
    }

    @Test fun selectedPhotoAndBucketSurviveReturningFromEditor() {
        val name = scrollInBucket()
        val before = compose.onNodeWithText(name).fetchSemanticsNode().boundsInRoot.top
        // 空 RAW 足以覆盖真实选片导航；不把滚动测试绑定到耗时的显影结果。
        compose.onNodeWithText(name).performClick()
        compose.waitUntil(10_000) { compose.activity.model.state.value.operation == Operation.NONE }
        openAlbum()
        compose.onNodeWithText(bucket).assertIsSelected()
        compose.onNodeWithText(name).assertIsDisplayed()
        val after = compose.onNodeWithText(name).fetchSemanticsNode().boundsInRoot.top
        assertEquals(before, after, 1f)
    }

    @Test fun refreshKeepsVisiblePhotoAndBucket() {
        val name = scrollInBucket()
        val before = compose.onNodeWithText(name).fetchSemanticsNode().boundsInRoot.top
        compose.onNodeWithContentDescription("刷新").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText(bucket).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(bucket).assertIsSelected()
        compose.onNodeWithText(name).assertIsDisplayed()
        assertEquals(before, compose.onNodeWithText(name).fetchSemanticsNode().boundsInRoot.top, 1f)
    }

    @Test fun activityRecreationKeepsVisiblePhotoAndBucket() {
        val name = scrollInBucket()
        compose.activityRule.scenario.recreate()
        compose.waitUntil(10_000) { compose.onAllNodesWithText(bucket).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(bucket).assertIsSelected()
        compose.onNodeWithText(name).assertIsDisplayed()
    }

    @Test fun editorRecreationKeepsSavedAlbumPosition() {
        val name = scrollInBucket()
        compose.onNodeWithText(name).performClick()
        compose.waitUntil(10_000) { compose.activity.model.state.value.operation == Operation.NONE }
        compose.activityRule.scenario.recreate()
        openAlbum()
        compose.onNodeWithText(bucket).assertIsSelected()
        compose.onNodeWithText(name).assertIsDisplayed()
    }

    @Test fun resumeKeepsVisiblePhotoAndBucket() {
        val name = scrollInBucket()
        val before = compose.onNodeWithText(name).fetchSemanticsNode().boundsInRoot.top
        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        compose.waitUntil(10_000) { compose.onAllNodesWithText(bucket).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(bucket).assertIsSelected()
        compose.onNodeWithText(name).assertIsDisplayed()
        assertEquals(before, compose.onNodeWithText(name).fetchSemanticsNode().boundsInRoot.top, 1f)
    }

    @Test fun deletedBucketFallsBackToAvailablePhotos() {
        scrollInBucket()
        media.take(160).forEach { resolver.delete(it, null, null); media.remove(it) }
        compose.onNodeWithContentDescription("刷新").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText(photoName(160)).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("全部相册").assertIsSelected()
        compose.onNodeWithText(photoName(160)).assertIsDisplayed()
        compose.onNodeWithText(bucket).assertDoesNotExist()
    }
}
