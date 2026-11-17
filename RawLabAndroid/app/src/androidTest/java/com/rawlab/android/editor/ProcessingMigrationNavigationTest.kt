package com.rawlab.android.editor

import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.editor.render.SerialWorkQueue
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.ProcessingIdentity
import com.rawlab.android.settings.ProcessingMigrationQuality
import com.rawlab.android.settings.ProcessingMigrationStatus
import com.rawlab.android.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.Base64
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class ProcessingMigrationNavigationTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rules: RuleChain = RuleChain.outerRule(LanguageTestRule()).around(compose)

    private fun field(model: EditorViewModel, name: String): Any? =
        EditorViewModel::class.java.getDeclaredField(name).apply { isAccessible = true }.get(model)

    private fun block(queue: SerialWorkQueue): CountDownLatch {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        queue.submit({ entered.countDown(); check(release.await(60, TimeUnit.SECONDS)) }) {}
        assertTrue("worker barrier entered", entered.await(10, TimeUnit.SECONDS))
        return release
    }

    private fun drain(queue: SerialWorkQueue) {
        val drained = CountDownLatch(1)
        queue.submit({}) { drained.countDown() }
        assertTrue("worker drained", drained.await(30, TimeUnit.SECONDS))
        compose.runOnIdle {}
    }

    @Test fun cancellingUnusableBPreservesARollbackAndSuccessfulBPublishesOnlyItsOwnReceipt() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        fun source() = File(context.cacheDir, "receipt-navigation-${UUID.randomUUID()}.png").also { file ->
            Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let { bitmap ->
                file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
            }
        }
        val a = source(); val b = source()
        val aID = PhotoIdentity(Uri.fromFile(a).toString()); val bID = PhotoIdentity(Uri.fromFile(b).toString())
        val directory = File(context.filesDir, "edits")
        val store = EditStore(directory)
        val original = EditSettings(customWb = true, processing = ProcessingIdentity.C5)
        val quality = ProcessingMigrationQuality(.001f, .003f, .002f, .001f, 20)
        store.save(aID, original)
        store.commitProcessingMigration(store.readState(aID), original.copy(processing = ProcessingIdentity.CURRENT), quality)
        val receiptA = requireNotNull(store.processingMigration(aID))
        // A genuinely unusable saved record takes the renderer's recovery path, not a fabricated WorkResult.
        store.save(bID, original)
        val key = Base64.getUrlEncoder().withoutPadding().encodeToString(bID.value.toByteArray(Charsets.UTF_8))
        File(directory, "edits.properties").appendText("\nrecord.$key.unknown=broken\n")
        val model = compose.activity.model
        val frames = mutableListOf<EditorState>()
        var observation: kotlinx.coroutines.Job? = null
        try {
            compose.runOnIdle { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(a)) }
            compose.waitUntil(30_000) { model.state.value.canExport }
            compose.runOnIdle { model.importPhoto(Uri.fromFile(b)) }
            compose.waitUntil(30_000) { model.state.value.recoverUnusableRecord }
            compose.onNodeWithText(compose.activity.getString(R.string.cancel)).performClick()
            compose.runOnIdle {
                assertFalse(model.state.value.recoverUnusableRecord)
                assertEquals(aID, model.state.value.photo?.identity)
                assertEquals("cancelling recovery must preserve A's rollback entry", receiptA, model.state.value.processingMigration)
                model.setEditorActive(false); model.setEditorActive(true)
                assertNull(model.state.value.saveError)
            }
            compose.onNode(hasContentDescription("更多") and hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
            compose.onNodeWithTag("processing-settings").performClick()
            compose.onNodeWithTag("processing.migration.status").assertIsDisplayed()
            compose.onNodeWithTag("processing.migration.rollback").assertIsDisplayed().assertIsEnabled()
            compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()

            store.resetToUnmodified(bID)
            val originalB = original.copy(exposure = .5f)
            store.save(bID, originalB)
            store.commitProcessingMigration(store.readState(bID), originalB.copy(processing = ProcessingIdentity.CURRENT), quality)
            val receiptB = requireNotNull(store.processingMigration(bID))
            assertNotEquals(receiptA, receiptB)
            compose.runOnIdle {
                // Unconfined observes every publication synchronously, including a transient stale A receipt on B.
                observation = CoroutineScope(Dispatchers.Unconfined).launch { model.state.collect { frames += it } }
                model.importPhoto(Uri.fromFile(b))
            }
            compose.waitUntil(30_000) { model.state.value.photo?.identity == bID && model.state.value.canExport }
            compose.runOnIdle {
                observation?.cancel()
                assertTrue(frames.any { it.photo?.identity == bID && it.canExport })
                frames.forEach { state ->
                    if (state.photo?.identity == aID) assertEquals(receiptA, state.processingMigration)
                    if (state.photo?.identity == bID) assertEquals("B and B's receipt must be adopted atomically", receiptB, state.processingMigration)
                }
                assertEquals(ProcessingMigrationStatus.MIGRATED, model.state.value.processingMigration?.status)
            }
        } finally {
            compose.runOnIdle { observation?.cancel() }
            store.reset(aID); store.resetToUnmodified(bID)
            a.delete(); b.delete()
        }
    }

    @Test fun openingAlbumDiscardsQueuedMigrationWithoutAnAdjustmentGesture() = leaveDuringMigration(false)
    @Test fun openingAlbumInvalidatesMigrationAlreadyQueuedForSaving() = leaveDuringMigration(true)
    @Test fun openingCameraDiscardsQueuedMigrationWithoutAnAdjustmentGesture() = leaveDuringMigration(false, camera = true)
    @Test fun openingCameraInvalidatesMigrationAlreadyQueuedForSaving() = leaveDuringMigration(true, camera = true)

    private fun leaveDuringMigration(commitQueued: Boolean, camera: Boolean = false) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val source = File(context.cacheDir, "migration-navigation-${UUID.randomUUID()}.png")
        Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let { bitmap ->
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
        val identity = PhotoIdentity(Uri.fromFile(source).toString())
        val directory = File(context.filesDir, "edits")
        val store = EditStore(directory)
        store.save(identity, EditSettings(processing = ProcessingIdentity.C5))
        val model = compose.activity.model
        val migration = field(model, "processingMigrationQueue") as SerialWorkQueue
        val adjustments = field(model, "adjustmentQueue") as SerialWorkQueue
        val migrationRelease = block(migration)
        var commitRelease: CountDownLatch? = null
        try {
            compose.runOnIdle { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntil(30_000) { model.state.value.matchingProcessing && model.state.value.exact }
            compose.waitForIdle()
            compose.waitUntil(10_000) { !model.state.value.rendering && !model.state.value.previewResizePending }
            if (commitQueued) {
                commitRelease = block(adjustments)
                migrationRelease.countDown()
                compose.waitUntil(30_000) { model.state.value.committingAdjustments }
            }
            lateinit var savedBytes: ByteArray
            var revision: Any? = null
            compose.runOnIdle {
                savedBytes = File(directory, "edits.properties").readBytes()
                revision = field(model, "currentRevision")
            }
            if (camera) {
                compose.onNode(hasContentDescription("更多") and hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
                compose.onNodeWithTag("camera-entry").performClick()
                compose.onNodeWithTag("camera-back").assertIsDisplayed()
            } else {
                val permission = if (Build.VERSION.SDK_INT >= 33) {
                    "android.permission.READ_MEDIA_IMAGES"
                } else {
                    "android.permission.READ_EXTERNAL_STORAGE"
                }
                val instrumentation = InstrumentationRegistry.getInstrumentation()
                if (context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                    instrumentation.uiAutomation.grantRuntimePermission(context.packageName, permission)
                }
                compose.onNodeWithContentDescription("相册").performClick()
                compose.waitUntil(10_000) { compose.onAllNodesWithText("全部相册").fetchSemanticsNodes().isNotEmpty() }
            }
            compose.runOnIdle { assertEquals("hidden editor stays inactive", false, field(model, "editorActive")) }
            migrationRelease.countDown()
            commitRelease?.countDown()
            drain(migration)
            drain(adjustments)
            compose.waitUntil(10_000) { !model.state.value.matchingProcessing && !model.state.value.committingAdjustments }
            compose.runOnIdle {
                assertArrayEquals("navigation must not save a migration", savedBytes, File(directory, "edits.properties").readBytes())
                assertEquals(ProcessingIdentity.C5, model.state.value.edits.processing)
                assertNull(store.processingMigration(identity))
                assertNull(model.state.value.processingMigration)
                assertNull(model.state.value.saveError)
                assertEquals("navigation must not schedule a migration preview", revision, field(model, "currentRevision"))
            }
            if (camera) {
                compose.onNodeWithTag("camera-back").performClick()
                compose.onNodeWithContentDescription("相册").assertIsDisplayed()
                compose.runOnIdle {
                    assertEquals("camera back restores the editor activity", true, field(model, "editorActive"))
                    assertFalse("returning does not retry the cancelled open context", model.state.value.matchingProcessing)
                }
            }
        } finally {
            migrationRelease.countDown()
            commitRelease?.countDown()
            source.delete()
        }
    }
}
