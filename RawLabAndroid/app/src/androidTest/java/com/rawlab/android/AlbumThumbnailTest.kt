package com.rawlab.android

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Color
import android.provider.MediaStore
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

@SdkSuppress(minSdkVersion = 29)
class AlbumThumbnailTest {
    @get:Rule val compose = createComposeRule()

    @Test fun missingMetadataUsesDecodedThumbnailRatio() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val resolver = context.contentResolver
        val name = "Thumbnail-${UUID.randomUUID()}.dng"
        val uri = requireNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/x-adobe-dng")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RawLab-Thumbnail-Test")
        }))
        try {
            val bitmap = Bitmap.createBitmap(600, 300, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.CYAN)
            try {
                resolver.openOutputStream(uri, "wt")!!.use { assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it)) }
            } finally { bitmap.recycle() }
            PhotoStorage(context).use { storage ->
                val photo = AlbumPhoto(uri, name, "Test")
                assertNull(photo.aspectRatio)
                compose.setContent {
                    RawLabTheme {
                        Box(Modifier.width(160.dp)) { AlbumThumbnail(storage, photo, false, 0) }
                    }
                }
                compose.waitUntil(10_000) {
                    compose.onAllNodesWithContentDescription(name).fetchSemanticsNodes().singleOrNull()
                        ?.boundsInRoot?.width == with(compose.density) { 160.dp.toPx() }
                }
                compose.onNodeWithContentDescription(name).assertWidthIsEqualTo(160.dp).assertHeightIsEqualTo(80.dp)
            }
        } finally { resolver.delete(uri, null, null) }
    }
}
