package com.rawlab.android.ui

import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.click
import androidx.compose.ui.test.down
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.up
import androidx.core.app.ActivityOptionsCompat
import com.rawlab.android.RawLabTheme
import com.rawlab.android.camera.CameraTetherParameterState
import com.rawlab.android.camera.CameraTetherPhase
import com.rawlab.android.camera.CameraTetherState
import com.rawlab.android.camera.CameraTetherWorkspace
import com.rawlab.android.camera.protocol.SonyTetherSession
import com.rawlab.android.editor.PendingLookCompatibility
import com.rawlab.android.editor.ui.LUTCompatibilityDialog
import com.rawlab.android.looks.LUTCompatibility
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

class StandaloneUiSmokeTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule("zh-Hans")).around(ForegroundTestRule()).around(compose)

    @Test fun lutCompatibilityPickerSmoke() {
        val draft = LUTCompatibility.parse("""{"eligible":true,"source_sha256":"test","fixed_contract":false,"photo_style":"std","extreme_values":false,"hints":[],"contract":{"version":1,"input":{"space":"","reference":"display","range":"full"},"output":{"space":"","reference":"display","range":"full"},"interpolation":"linear","base_rendering":"rawlab-neutral-v1"}}""")!!
        val launched = mutableListOf<Intent>()
        compose.setContent {
            val context = LocalContext.current
            val storage = PhotoStorage(context)
            val registry = object : ActivityResultRegistry() {
                override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
                    launched += contract.createIntent(context, input)
                }
            }
            val owner = object : ActivityResultRegistryOwner { override val activityResultRegistry = registry }
            CompositionLocalProvider(LocalActivityResultRegistryOwner provides owner) {
                RawLabTheme {
                    LUTCompatibilityDialog(PendingLookCompatibility(Uri.parse("content://test/unknown.cube"), "unknown.cube", draft), null, storage) {}
                }
            }
        }
        compose.onNodeWithTag("lut-reference-section").performScrollTo().performClick()
        compose.onNodeWithTag("lut-reference-picker").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(1, launched.size) }
    }

    @Test fun cameraTetherControlSmoke() {
        val frame = Bitmap.createBitmap(640, 480, Bitmap.Config.ARGB_8888)
        val frame2 = Bitmap.createBitmap(640, 480, Bitmap.Config.ARGB_8888)
        val state = mutableStateOf(
            CameraTetherState(
                phase = CameraTetherPhase.READY,
                frame = frame,
                live = true,
                parameters = CameraTetherParameterState(captureReady = true),
            ),
        )
        var shots = 0
        val focusTaps = mutableListOf<Pair<Int, Int>>()
        var cancelCount = 0
        try {
            compose.setContent {
                RawLabTheme {
                    CameraTetherWorkspace(
                        state.value,
                        { _, _ -> null },
                        { shots++ },
                        {},
                        {},
                        onFocusPoint = { x, y -> focusTaps.add(x to y) },
                        onCancelTouchFocus = { cancelCount++ },
                    )
                }
            }
            compose.onNodeWithTag("tether-focus-overlay").assertExists()
            compose.onNodeWithTag("tether-viewfinder").performTouchInput { click(center) }
            compose.runOnIdle {
                assertEquals(1, focusTaps.size)
                assertEquals(true, kotlin.math.abs(focusTaps[0].first - 320) <= 1)
                assertEquals(true, kotlin.math.abs(focusTaps[0].second - 240) <= 1)
            }
            // LiveView frames swap state.frame at ~10Hz; replacing frame mid-tap must not cancel detectTapGestures.
            compose.onNodeWithTag("tether-viewfinder").performTouchInput { down(center) }
            compose.runOnIdle { state.value = state.value.copy(frame = frame2) }
            compose.onNodeWithTag("tether-viewfinder").performTouchInput { up() }
            compose.runOnIdle {
                assertEquals(2, focusTaps.size)
                assertEquals(true, kotlin.math.abs(focusTaps[1].first - 320) <= 1)
                assertEquals(true, kotlin.math.abs(focusTaps[1].second - 240) <= 1)
            }
            compose.runOnIdle { state.value = state.value.copy(focusBusy = true) }
            compose.onNodeWithTag("tether-focus-busy").assertDoesNotExist()
            compose.onNodeWithTag("tether-focus-overlay").assertExists()

            state.value = state.value.copy(
                focusBusy = false,
                tapFocusLocked = true,
                focusFrames = listOf(
                    SonyTetherSession.LiveViewFocusFrame(
                        SonyTetherSession.LiveViewFrameKind.FOCUS,
                        0.5f,
                        0.5f,
                        0.1f,
                        0.1f,
                        false,
                    ),
                ),
                parameters = state.value.parameters.copy(canCancelTouchFocus = true, focusLocked = false),
            )
            compose.onNodeWithTag("tether-focus-overlay").assertExists()
            compose.onNodeWithTag("tether-cancel-focus").assertIsDisplayed().performClick()
            compose.runOnIdle {
                assertEquals(1, cancelCount)
                assertEquals(2, focusTaps.size)
            }
            compose.onNodeWithTag("tether-shutter").assertIsEnabled().performClick()
            assertEquals(1, shots)
            compose.onNodeWithTag("tether-menu").performClick()
            compose.onNodeWithTag("tether-grid-toggle").performClick()
            compose.onNodeWithTag("tether-grid").assertExists()
        } finally {
            compose.runOnIdle {
                frame.recycle()
                frame2.recycle()
            }
        }
    }
}
