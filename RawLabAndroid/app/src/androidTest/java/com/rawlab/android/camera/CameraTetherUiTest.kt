package com.rawlab.android.camera

import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.photo.MediaPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.testing.ForegroundTestRule
import java.io.File
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.rawlab.android.RawLabTheme
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.setChineseContent
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

class CameraTetherUiTest {
    private val compose = createComposeRule()
    @get:Rule val languageAndCompose: RuleChain = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    @Test fun manualWifiDoesNotPretendTheCameraIsAKnownModel() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val owner = androidx.lifecycle.ViewModelStore()
        lateinit var model: CameraImportViewModel
        try {
            instrumentation.runOnMainSync {
                model = CameraImportViewModel(instrumentation.targetContext.applicationContext as android.app.Application)
                owner.put("camera", model)
            }
            compose.waitUntil(10_000) { !model.state.value.preparing }
            assertEquals(SonyCameraModel.UNKNOWN, model.state.value.model)
            instrumentation.runOnMainSync {
                model.onCandidates(listOf(CameraCandidate("fixture", "ILCE-7CM2")))
                model.connect("fixture")
            }
            compose.waitUntil(10_000) { !model.state.value.closing }
            assertEquals(SonyCameraModel.A7CII, model.state.value.model)
            instrumentation.runOnMainSync { model.prepareLegacyWifi() }
            compose.waitUntil(10_000) { !model.state.value.closing }
            assertEquals(SonyCameraModel.UNKNOWN, model.state.value.model)
            instrumentation.runOnMainSync { model.useLegacyWifi() }
            compose.waitUntil(10_000) { !model.state.value.closing }
            assertEquals(SonyCameraModel.UNKNOWN, model.state.value.model)
        } finally { instrumentation.runOnMainSync { owner.clear() } }
    }

    @Test fun shutterOnlyWorksWhileReadyAndGridDoesNotChangeCameraState() {
        val state = mutableStateOf(CameraTetherState(phase = CameraTetherPhase.READY, live = true, frame = frame(), parameters = CameraTetherParameterState(captureReady = true)))
        var shots = 0
        compose.setChineseContent { RawLabTheme {
            CameraTetherWorkspace(state.value, { _, _ -> null }, { shots++ }, {}, {})
        } }
        compose.onNodeWithTag("tether-shutter").assertIsEnabled().performClick()
        assertEquals(1, shots)
        compose.onNodeWithTag("tether-menu").performClick()
        compose.onNodeWithTag("tether-grid-toggle").performClick()
        compose.onNodeWithTag("tether-grid").assertExists()
        compose.runOnIdle { state.value = state.value.copy(phase = CameraTetherPhase.WAITING) }
        compose.onNodeWithTag("tether-shutter").assertIsNotEnabled()
        compose.runOnIdle { state.value = state.value.copy(phase = CameraTetherPhase.PAUSED) }
        compose.onNodeWithTag("tether-shutter").assertIsNotEnabled()
        compose.onNodeWithTag("tether-reconnect").assertIsDisplayed()
        compose.onNodeWithText("LIVE").assertDoesNotExist()
        compose.onNodeWithText("取景已暂停").assertIsDisplayed()
        assertEquals(1, shots)
    }

    @Test fun legacySessionWithoutHardwareIdentityDoesNotOfferResume() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val owner = androidx.lifecycle.ViewModelStore()
        val photo = CameraPhoto("photo", "DSC00252.ARW", 32, 0)
        val run = CameraTetherRun("old-run", "old-camera", SonyCameraModel.A7CII.profileId, 1, emptyList(),
            CameraImportDestination(), listOf(CameraTetherBatch("batch", listOf(photo))), CameraTetherStatus.PAUSED)
        val jobs = listOf(CameraImportJob("batch", run.cameraId, 1, listOf(CameraImportItem(photo, digest = "a".repeat(64))),
            CameraJobStatus.PAUSED))
        lateinit var model: CameraImportViewModel
        PhotoStorage(context).use { storage ->
            try {
                instrumentation.runOnMainSync {
                    model = CameraImportViewModel(context.applicationContext as android.app.Application)
                    owner.put("camera", model)
                }
                compose.waitUntil(10_000) { !model.state.value.preparing }
                compose.runOnUiThread { model.tether.restore(listOf(run), jobs) }
                compose.setChineseContent { RawLabTheme { CameraScreen(model, storage, {}, {}, {}) } }
                compose.onNodeWithTag("camera-resume-tether").assertDoesNotExist()
                compose.onNodeWithTag("camera-mode-IMPORT").assertIsDisplayed().assertIsEnabled()
                compose.onNodeWithTag("camera-mode-TETHER").assertIsDisplayed().assertIsEnabled()
                compose.runOnUiThread { model.tether.restore(listOf(run.copy(hardwareIdentity =
                    CameraHardwareIdentity("ILCE-7CM2", "1234567"))), jobs) }
                compose.onNodeWithTag("camera-resume-tether").performScrollTo().assertIsDisplayed().assertIsEnabled()
            } finally { instrumentation.runOnMainSync { owner.clear() } }
        }
    }

    @Test fun unverifiablePausedSessionOffersManualImport() {
        val run = CameraTetherRun("old-run", "old-camera", SonyCameraModel.A7CII.profileId, 1, emptyList(),
            CameraImportDestination(), status = CameraTetherStatus.PAUSED)
        var imports = 0
        compose.setChineseContent { RawLabTheme {
            CameraTetherWorkspace(CameraTetherState(phase = CameraTetherPhase.PAUSED, run = run,
                failure = CameraTetherFailure.SOURCE), { _, _ -> null }, {}, {}, {}, onImport = { imports++ })
        } }
        compose.onNodeWithTag("tether-reconnect").assertDoesNotExist()
        compose.onNodeWithTag("tether-import-instead").assertIsDisplayed().performClick()
        assertEquals(1, imports)
    }

    @Test fun overBudgetRecoveryOffersManualImportInsteadOfReconnect() {
        val active = savedState((1..65).map { "DSC$it.ARW" })
        val run = checkNotNull(active.run).copy(status = CameraTetherStatus.PAUSED,
            hardwareIdentity = CameraHardwareIdentity("ILCE-7CM2", "1234567"))
        val jobs = active.jobs.map { job -> job.copy(items = job.items.map { it.copy(digest = "a".repeat(64)) }) }
        var imports = 0
        compose.setChineseContent { RawLabTheme {
            CameraTetherWorkspace(active.copy(phase = CameraTetherPhase.PAUSED, run = run, jobs = jobs,
                failure = CameraTetherFailure.BACKLOG), { _, _ -> null }, {}, {}, {}, onImport = { imports++ })
        } }
        compose.onNodeWithTag("tether-reconnect").assertDoesNotExist()
        compose.onNodeWithText("无法确认上次联机的相机原件。请手动选片补传。已保存的原件会保留。").assertExists()
        compose.onNodeWithTag("tether-import-instead").assertIsDisplayed().performClick()
        assertEquals(1, imports)
    }

    @Test fun receivingShowsOriginalProgressAndNeverEnablesTheShutter() {
        val photo = CameraPhoto("one", "DSC00252.ARW", 25_008_896, 0)
        compose.setChineseContent { RawLabTheme {
            CameraTetherWorkspace(CameraTetherState(phase = CameraTetherPhase.RECEIVING, live = true,
                frame = frame(), current = photo, currentBytes = 12_504_448),
                { _, _ -> null }, {}, {}, {})
        } }
        compose.onNodeWithText("DSC00252.ARW").assertIsDisplayed()
        compose.onNodeWithTag("tether-transfer-progress").assertExists()
        compose.onNodeWithTag("tether-shutter").assertIsNotEnabled()
    }

    @Test fun readBackParametersShowLegalChoicesAndKeepReadonlyReasonVisible() {
        val state = mutableStateOf(CameraTetherState(phase = CameraTetherPhase.READY, live = true, frame = frame(),
            parameters = CameraTetherParameterState(
                values = listOf(CameraTetherParameter(0xd20d, (1L shl 16) or 125L, emptyList(), writable = false, enabled = true),
                    CameraTetherParameter(0x5007, 280, emptyList(), writable = false, enabled = true), CameraTetherParameter(0xd21e, 200, listOf(100, 200, 400), writable = true, enabled = true),
                    CameraTetherParameter(0x5010, 0, listOf(-1000, 0, 1000), writable = false, enabled = false)),
                writable = true, read = true)))
        var selected = 0L
        compose.setChineseContent { RawLabTheme {
            CameraTetherWorkspace(state.value, { _, _ -> null }, {}, {}, {}, onSetParameter = { _, value -> selected = value })
        } }
        compose.onNodeWithTag("tether-parameter-strip").assertIsDisplayed()
        compose.onNodeWithText("1/125").assertIsDisplayed()
        compose.onNodeWithText("f/2.8").assertIsDisplayed()
        compose.onNodeWithText("ISO 200").assertIsDisplayed()
        compose.onNodeWithText("快门").assertDoesNotExist()
        compose.onNodeWithTag("tether-parameter-iso").performClick()
        compose.onNodeWithText("400").performClick()
        assertEquals(400L, selected)
        compose.onNodeWithTag("tether-parameter-ev").performClick()
        compose.onNodeWithText("当前拍摄模式下不可调整").assertIsDisplayed()
    }

    @Test fun reviewingAnOlderPhotoSurvivesNewArrivalsAndEditRequiresAnExplicitTap() {
        val state = mutableStateOf(savedState(listOf("FIRST.JPG", "SECOND.JPG")))
        var edits = 0
        compose.setChineseContent { RawLabTheme {
            CameraTetherWorkspace(state.value, { _, _ -> frame() }, {}, {}, { edits++ })
        } }
        compose.onNodeWithTag("tether-recent").performClick()
        compose.onNodeWithTag("tether-review").assertIsDisplayed()
        compose.onNode(hasText("SECOND.JPG") and hasAnyAncestor(hasTestTag("tether-review"))).assertIsDisplayed()
        compose.runOnIdle { state.value = savedState(listOf("FIRST.JPG", "SECOND.JPG", "THIRD.JPG")) }
        compose.onNode(hasText("SECOND.JPG") and hasAnyAncestor(hasTestTag("tether-review"))).assertIsDisplayed()
        assertEquals(0, edits)
        compose.onNodeWithTag("tether-review-previous").performClick()
        compose.onNode(hasText("THIRD.JPG") and hasAnyAncestor(hasTestTag("tether-review"))).assertIsDisplayed()
        capture("review")
        compose.onNodeWithTag("tether-review-edit").performClick()
        assertEquals(1, edits)
    }

    @Test fun shutterAndReviewControlsRemainReachableInPortraitLandscapeAndLargeText() {
        data class Size(val width: Int, val height: Int, val scale: Float)
        val size = mutableStateOf(Size(360, 700, 1f))
        compose.setChineseContent {
            CompositionLocalProvider(LocalDensity provides Density(1f, size.value.scale)) {
                RawLabTheme {
                    Box(Modifier.size(size.value.width.dp, size.value.height.dp).testTag("tether-fixture")) {
                        CameraTetherWorkspace(savedState(listOf("DSC00252.JPG")), { _, _ -> frame() }, {}, {}, {})
                    }
                }
            }
        }
        compose.onNodeWithTag("tether-shutter").assertIsDisplayed()
        capture("portrait")
        compose.runOnIdle { size.value = Size(680, 300, 1f) }
        compose.onNodeWithTag("tether-shutter").assertIsDisplayed()
        capture("landscape")
        compose.runOnIdle { size.value = Size(480, 240, 1.7f) }
        compose.onNodeWithTag("tether-shutter").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("tether-menu").performClick()
        compose.onNodeWithTag("tether-auto-review").assertIsDisplayed().performClick()
        capture("compact-landscape-large-text")
        compose.runOnIdle { size.value = Size(360, 740, 2f) }
        compose.onNodeWithTag("tether-shutter").assertIsDisplayed()
        compose.onNodeWithTag("tether-menu").performClick()
        compose.onNodeWithTag("tether-auto-review").assertIsDisplayed().performClick()
        capture("portrait-large-text")
    }

    private fun savedState(names: List<String>): CameraTetherState {
        val photos = names.map { CameraPhoto(it, it, 19_923_935, 0) }
        val batches = photos.mapIndexed { index, photo -> CameraTetherBatch("job-$index", listOf(photo)) }
        val run = CameraTetherRun("run", "camera", "ZV-E10/2.02", 0, emptyList(), CameraImportDestination(), batches)
        val jobs = photos.mapIndexed { index, photo -> CameraImportJob("job-$index", "camera", index.toLong(),
            listOf(CameraImportItem(photo, saved = MediaPhoto("content://media/$index", photo.name, "Pictures/", false))), CameraJobStatus.COMPLETE) }
        return CameraTetherState(phase = CameraTetherPhase.READY, live = true, frame = frame(), run = run, jobs = jobs.reversed())
    }

    private fun capture(name: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.getExternalFilesDir(null), "tether-ui").apply { mkdirs() }
        val bitmap = compose.onNodeWithTag(if (name == "review") "tether-review" else "tether-fixture").captureToImage().asAndroidBitmap()
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    private fun frame() = Bitmap.createBitmap(640, 424, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.DKGRAY) }
}
