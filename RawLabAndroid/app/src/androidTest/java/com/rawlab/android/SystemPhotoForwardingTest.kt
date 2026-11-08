package com.rawlab.android

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.core.app.ActivityScenario
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.i18n.AppStrings
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class SystemPhotoForwardingTest {
    private val compose = createEmptyComposeRule()
    @get:Rule val rule = RuleChain.outerRule(ForegroundTestRule()).around(compose)
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val deniedUri get() = Uri.parse("content://${InstrumentationRegistry.getInstrumentation().context.packageName}.system-photo-private/photo")

    // MainActivity 在 onNewIntent 里换成转发来的 intent；ActivityScenario 按启动 intent 识别活动，
    // 关闭前不换回去就收不到 DESTROYED，会在活动已销毁后仍等待超时。
    private fun withMainActivity(block: (ActivityScenario<MainActivity>) -> Unit) {
        val launch = Intent(context, MainActivity::class.java)
        ActivityScenario.launch<MainActivity>(launch).use { scenario ->
            try { block(scenario) } finally { scenario.onActivity { it.intent = launch } }
        }
    }

    @Test fun viewPreservesDataTypeAndEveryGrantedClipUri() {
        val source = Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse("content://photos/one"), "image/jpeg").apply {
            clipData = ClipData.newRawUri("source", Uri.parse("content://photos/one"))
            clipData!!.addItem(ClipData.Item(Uri.parse("content://photos/two")))
        }
        val forwarded = SystemPhotoForwarding.intent(context, source)

        assertEquals(source.data, forwarded.data)
        assertEquals("content://photos/one", forwarded.data.toString())
        assertEquals("image/jpeg", forwarded.type)
        assertEquals(2, forwarded.clipData!!.itemCount)
        assertEquals("content://photos/one", forwarded.clipData!!.getItemAt(0).uri.toString())
        assertEquals("content://photos/two", forwarded.clipData!!.getItemAt(1).uri.toString())
        assertTrue(forwarded.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertTrue(forwarded.getStringExtra(SystemPhotoForwarding.EXTRA_REQUEST_ID).orEmpty().isNotBlank())
    }

    @Test fun sendDoesNotTreatItsUnrelatedDataUriAsAStream() {
        val source = Intent(Intent.ACTION_SEND).setDataAndType(Uri.parse("content://unrelated/data"), "image/jpeg").apply {
            putExtra(Intent.EXTRA_STREAM, Uri.parse("content://photos/stream"))
            clipData = ClipData.newRawUri("source", Uri.parse("content://photos/clip"))
        }
        val forwarded = SystemPhotoForwarding.intent(context, source)
        val uris = (0 until forwarded.clipData!!.itemCount).map { forwarded.clipData!!.getItemAt(it).uri.toString() }

        assertEquals(listOf("content://photos/stream", "content://photos/clip"), uris)
    }

    @Test fun deniedGrantKeepsActionRequestAndAllUriSourcesWithoutGrantingAgain() {
        val source = Intent(Intent.ACTION_SEND_MULTIPLE).setDataAndType(Uri.parse("content://unrelated/data"), "image/png").apply {
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(Uri.parse("content://photos/stream")))
            clipData = ClipData.newRawUri("source", Uri.parse("content://photos/clip"))
        }
        val forwarded = SystemPhotoForwarding.intent(context, source)
        val requestID = forwarded.getStringExtra(SystemPhotoForwarding.EXTRA_REQUEST_ID)
        var attempts = 0

        SystemPhotoForwarding.start(forwarded, source) { request ->
            attempts++
            assertSame(forwarded, request)
            if (attempts == 1) {
                assertTrue(request.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
                throw SecurityException("URI is not granted")
            }
            assertEquals(0, request.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
            assertEquals(Intent.ACTION_SEND_MULTIPLE, request.action)
            assertEquals(source.data, request.data)
            assertEquals("image/png", request.type)
            assertEquals(requestID, request.getStringExtra(SystemPhotoForwarding.EXTRA_REQUEST_ID))
            @Suppress("DEPRECATION")
            assertEquals(listOf(Uri.parse("content://photos/stream")), request.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM))
            assertEquals(listOf("content://photos/stream", "content://photos/clip"),
                (0 until request.clipData!!.itemCount).map { request.clipData!!.getItemAt(it).uri.toString() })
            assertEquals(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP, request.flags)
        }

        assertEquals(2, attempts)
    }

    @Test fun deniedStreamStillTransfersTheOriginalClipGrant() {
        val readable = Uri.parse("content://photos/readable")
        val denied = Uri.parse("content://photos/denied")
        val source = Intent(Intent.ACTION_SEND_MULTIPLE).setType("image/png").apply {
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(readable, denied))
            clipData = ClipData.newRawUri("source", readable)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val forwarded = SystemPhotoForwarding.intent(context, source)
        val requestID = forwarded.getStringExtra(SystemPhotoForwarding.EXTRA_REQUEST_ID)
        var attempts = 0

        SystemPhotoForwarding.start(forwarded, source) { request ->
            attempts++
            if (attempts == 1) throw SecurityException("second URI is not granted")
            assertTrue(request.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            assertEquals(1, request.clipData!!.itemCount)
            assertEquals(readable, request.clipData!!.getItemAt(0).uri)
            @Suppress("DEPRECATION")
            assertEquals(listOf(readable, denied), request.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM))
            assertEquals(requestID, request.getStringExtra(SystemPhotoForwarding.EXTRA_REQUEST_ID))
        }

        assertEquals(2, attempts)
    }

    @Test fun revokedOriginalGrantFallsBackWithoutGrantingAgain() {
        val source = Intent(Intent.ACTION_SEND).setType("image/png").apply {
            putExtra(Intent.EXTRA_STREAM, Uri.parse("content://photos/revoked"))
            clipData = ClipData.newRawUri("source", Uri.parse("content://photos/revoked"))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val forwarded = SystemPhotoForwarding.intent(context, source)
        var attempts = 0

        SystemPhotoForwarding.start(forwarded, source) { request ->
            attempts++
            if (attempts <= 2) throw SecurityException("grant revoked")
            assertEquals(0, request.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
            assertEquals(source.clipData!!.getItemAt(0).uri, request.clipData!!.getItemAt(0).uri)
        }

        assertEquals(3, attempts)
    }

    @Test fun ungrantedSendReportsReadFailureAndKeepsTheForegroundEditor() {
        assertNotEquals(InstrumentationRegistry.getInstrumentation().context.applicationInfo.uid, context.applicationInfo.uid)
        assertThrows(SecurityException::class.java) { context.contentResolver.openInputStream(deniedUri)?.close() }
        val source = File(context.cacheDir, "forward-editor-${UUID.randomUUID()}.png").apply { writeBytes(UnsharedPhotoProvider.png()) }
        try {
            withMainActivity { scenario ->
                lateinit var main: MainActivity
                scenario.onActivity { main = it; it.model.setGpuEnabled(false); it.model.importPhoto(Uri.fromFile(source)) }
                compose.waitUntil(30_000) { main.model.state.value.canExport || main.model.state.value.error != null }
                assertNull(main.model.state.value.error)
                scenario.onActivity { it.model.edit(it.model.state.value.edits.copy(exposure = .75f)) }
                compose.waitUntil(30_000) { main.model.state.value.canExport || main.model.state.value.error != null }
                assertNull(main.model.state.value.error)
                val before = main.model.state.value

                // 与实际 adb 复现一致：am 只授权 data/ClipData，EXTRA_STREAM 中的 URI 不会获权。
                val command = "am start -W -a android.intent.action.SEND -t image/png " +
                    "--eu android.intent.extra.STREAM $deniedUri --grant-read-uri-permission " +
                    "-n ${context.packageName}/com.rawlab.android.SystemPhotoForwardActivity"
                val output = ParcelFileDescriptor.AutoCloseInputStream(
                    InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command),
                ).use { it.readBytes().toString(Charsets.UTF_8) }
                assertFalse(output, output.contains("Error:"))
                compose.waitUntil(30_000) {
                    main.intent.getStringExtra(SystemPhotoForwarding.EXTRA_REQUEST_ID) != null && main.model.state.value.error != null
                }

                assertFalse(main.isDestroyed)
                scenario.onActivity { assertSame(main, it) }
                assertSame(before.photo, main.model.state.value.photo)
                assertEquals(.75f, main.model.state.value.edits.exposure, 0f)
                assertEquals(Intent.ACTION_SEND, main.intent.action)
                assertFalse(main.intent.getStringExtra(SystemPhotoForwarding.EXTRA_REQUEST_ID).isNullOrBlank())
                @Suppress("DEPRECATION")
                assertEquals(deniedUri, main.intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
                assertNull(main.intent.clipData!!.getItemAt(0).uri)
                assertThrows(SecurityException::class.java) { context.contentResolver.openInputStream(deniedUri)?.close() }
                val error = main.model.state.value.error!!
                assertTrue(error, error.startsWith(AppStrings.text(R.string.process_error)))
                compose.onNodeWithText(error, substring = true).assertIsDisplayed()
            }
        } finally { source.delete() }
    }

    @Test fun partiallyUngrantedMultipleSendAddsTheReadablePhotoToTheCollection() {
        assertNotEquals(InstrumentationRegistry.getInstrumentation().context.applicationInfo.uid, context.applicationInfo.uid)
        assertThrows(SecurityException::class.java) { context.contentResolver.openInputStream(deniedUri)?.close() }
        val readable = deniedUri.buildUpon().appendPath(UUID.randomUUID().toString()).build()
        assertThrows(SecurityException::class.java) { context.contentResolver.openInputStream(readable)?.close() }
        val destroyed = CountDownLatch(1)
        val lifecycle = ActivityLifecycleMonitorRegistry.getInstance()
        val callback = ActivityLifecycleCallback { activity, stage ->
            if (activity is SystemPhotoForwardActivity && stage == Stage.DESTROYED) destroyed.countDown()
        }
        lifecycle.addLifecycleCallback(callback)
        val retainedFiles = mutableListOf<File>()
        try {
            withMainActivity { scenario ->
                lateinit var main: MainActivity
                scenario.onActivity { main = it; it.model.setGpuEnabled(false) }
                val existing = main.model.collection.value.photos.map { it.id }.toSet()

                val sender = Intent().setClassName(InstrumentationRegistry.getInstrumentation().context.packageName,
                    SystemPhotoShareActivity::class.java.name).apply {
                    putExtra("targetPackage", context.packageName)
                    putExtra("readable", readable.toString())
                    putExtra("denied", deniedUri.toString())
                }
                scenario.onActivity { it.startActivity(sender) }
                compose.waitUntil(30_000) {
                    val collection = main.model.collection.value
                    !collection.busy && collection.photos.any { it.id !in existing }
                }

                assertFalse(main.isDestroyed)
                scenario.onActivity { assertSame(main, it) }
                assertEquals(Intent.ACTION_SEND_MULTIPLE, main.intent.action)
                assertFalse(main.intent.getStringExtra(SystemPhotoForwarding.EXTRA_REQUEST_ID).isNullOrBlank())
                assertTrue(main.intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
                assertEquals(listOf(readable),
                    (0 until main.intent.clipData!!.itemCount).map { main.intent.clipData!!.getItemAt(it).uri })
                val imported = main.model.collection.value.photos.filter { it.id !in existing }.single()
                retainedFiles += imported.sourceFile
                assertTrue("Forward Activity must finish before checking the surviving grant", destroyed.await(10, TimeUnit.SECONDS))
                val bytes = context.contentResolver.openInputStream(readable)!!.use { it.readBytes() }
                assertArrayEquals(bytes, imported.sourceFile.readBytes())
                assertThrows(SecurityException::class.java) { context.contentResolver.openInputStream(deniedUri)?.close() }
                assertNull(main.model.collection.value.error)
                assertTrue(main.model.state.value.error.orEmpty().startsWith(AppStrings.text(R.string.process_error)))
            }
        } finally {
            lifecycle.removeLifecycleCallback(callback)
            retainedFiles.forEach { it.delete(); File(it.parentFile, it.nameWithoutExtension + ".name").delete() }
        }
    }

}
