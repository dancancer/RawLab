package com.rawlab.android

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
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
