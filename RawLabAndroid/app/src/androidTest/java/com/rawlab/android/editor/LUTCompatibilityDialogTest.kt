package com.rawlab.android.editor

import android.net.Uri
import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import com.rawlab.android.RawLabTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.rawlab.android.R
import com.rawlab.android.editor.ui.LUTCompatibilityDialog
import com.rawlab.android.looks.LUTCompatibility
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.format.PhotoInputKind
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import java.io.File
import java.util.UUID
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class LUTCompatibilityDialogTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Test fun advancedFieldsAreFoldedAndCancelDoesNotConfirm() {
        val draft = LUTCompatibility.parse("""{"eligible":true,"source_sha256":"test","fixed_contract":false,"photo_style":"std","extreme_values":false,"hints":[],"contract":{"version":1,"input":{"space":"","reference":"display","range":"full"},"output":{"space":"","reference":"display","range":"full"},"interpolation":"linear","base_rendering":"rawlab-neutral-v1"}}""")!!
        var cancelled = false
        compose.setContent {
            var visible by remember { mutableStateOf(true) }
            val storage = remember { com.rawlab.android.photo.PhotoStorage(compose.activity) }
            RawLabTheme { if (visible) LUTCompatibilityDialog(PendingLookCompatibility(Uri.parse("content://test/unknown.cube"), "unknown.cube", draft), null, storage) {
                cancelled = it == null; visible = false
            } }
        }
        compose.onNodeWithText(compose.activity.getString(R.string.lut_input_color)).assertDoesNotExist()
        compose.onNodeWithTag("lut-compatibility-confirm").assertIsNotEnabled()
        compose.onNodeWithTag("lut-advanced-settings").performScrollTo().performClick()
        compose.onNodeWithText(compose.activity.getString(R.string.lut_input_color)).assertExists()
        compose.onNodeWithTag("lut-reference-section").performScrollTo().performClick()
        compose.onNodeWithTag("lut-reference-compare").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText(compose.activity.getString(R.string.cancel)).performClick()
        compose.runOnIdle { assertTrue(cancelled) }
    }

    @Test fun librarySelectionRequiresConfirmationAndCancellationKeepsPreview() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName,
            if (Build.VERSION.SDK_INT >= 33) "android.permission.READ_MEDIA_IMAGES" else "android.permission.READ_EXTERNAL_STORAGE")
        val root = File(context.cacheDir, "lut-library-${UUID.randomUUID()}").apply { mkdirs() }
        val photo = File(root, "current.png")
        val replacementName = "Library-${UUID.randomUUID()}.png"
        val resolver = context.contentResolver
        val uri = requireNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, replacementName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RawLab LUT tests")
        }))
        try {
            Bitmap.createBitmap(32, 16, Bitmap.Config.ARGB_8888).let { bitmap ->
                bitmap.eraseColor(Color.rgb(60, 90, 120))
                photo.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.eraseColor(Color.rgb(120, 90, 60))
                resolver.openOutputStream(uri)!!.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
            val lut = File(root, "unknown.cube").apply { writeText("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n") }
            val draft = LUTCompatibility.parse(NativeProcessor.inspectLutCompatibility(lut))!!
            val current = ImportedPhoto(Uri.fromFile(photo), photo.name, photo, inputKind = PhotoInputKind.RASTER)
            var finished = false
            compose.setContent {
                val storage = remember { PhotoStorage(compose.activity, looksDirectory = File(root, "looks")) }
                RawLabTheme { LUTCompatibilityDialog(PendingLookCompatibility(Uri.fromFile(lut), lut.name, draft), current, storage) { finished = true } }
            }
            compose.waitUntil(15_000) { compose.onAllNodesWithText("current.png").fetchSemanticsNodes().isNotEmpty() }
            val candidate = draft.candidates.first { draft.applying(it, true) != null }
            fun selectCandidate() {
                compose.waitUntil(30_000) {
                    compose.onAllNodes(hasTestTag("lut-${candidate.id}") and isEnabled()).fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNodeWithTag("lut-${candidate.id}").performScrollTo().performClick()
                compose.onNodeWithTag("lut-compatibility-confirm").assertIsEnabled()
                compose.onNodeWithTag("lut-preview-photo").performScrollTo()
            }
            selectCandidate()
            val choose = compose.activity.getString(R.string.lut_use_library_photo)
            fun openLibrary() {
                compose.onNodeWithTag("lut-preview-photo").performClick()
                compose.onNodeWithTag("lut-photo-library").assertExists()
                compose.waitUntil(10_000) { compose.onAllNodesWithText(replacementName).fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText(choose).assertIsNotEnabled()
                compose.onAllNodesWithContentDescription(compose.activity.getString(R.string.open_file)).assertCountEquals(0)
                compose.onNodeWithText(replacementName).performClick()
                compose.onNodeWithText(choose).assertIsEnabled()
            }
            openLibrary()
            compose.onNodeWithContentDescription(compose.activity.getString(R.string.back)).performClick()
            compose.onNodeWithText("current.png").assertExists()
            compose.onNodeWithTag("lut-compatibility-confirm").assertIsEnabled()
            compose.runOnIdle { assertFalse(finished) }
            openLibrary()
            compose.onNodeWithText(choose).performClick()
            compose.waitUntil(15_000) { compose.onAllNodesWithText(replacementName).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("lut-photo-library").assertDoesNotExist()
            compose.onNodeWithTag("lut-compatibility-confirm").assertIsNotEnabled()
            selectCandidate()
            compose.runOnIdle { assertFalse(finished); assertEquals("current.png", current.name) }
        } finally {
            resolver.delete(uri, null, null)
            root.deleteRecursively()
        }
    }
}
