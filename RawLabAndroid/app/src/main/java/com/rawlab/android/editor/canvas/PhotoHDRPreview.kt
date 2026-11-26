package com.rawlab.android.editor.canvas

import android.app.Activity
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.rawlab.android.editor.render.HDRBitmapAdapter
import com.rawlab.android.editor.render.HDRPreviewFrame
import com.rawlab.android.engine.HDRDisplayController
import com.rawlab.android.engine.HDRDisplayParameters
import com.rawlab.android.engine.HDRDisplayState
import com.rawlab.android.engine.HDRPreviewMode

internal data class PhotoHDRPreview(
    val display: HDRDisplayState,
    val parameters: HDRDisplayParameters,
    val bitmap: Bitmap?,
    val onModeChange: (HDRPreviewMode) -> Unit,
    val onFalseColorChange: (Boolean) -> Unit,
) {
    val fp16Enabled get() = display.available || parameters.falseColor
}

@Composable
internal fun rememberPhotoHDRPreview(frame: HDRPreviewFrame?, resetKey: Any? = null): PhotoHDRPreview {
    val view = LocalView.current
    val activity = remember(view.context) {
        generateSequence(view.context) { (it as? ContextWrapper)?.baseContext }
            .filterIsInstance<Activity>()
            .firstOrNull()
    }
    val hardwareCanvas = view.isHardwareAccelerated
    val controller = remember(activity) { activity?.let { HDRDisplayController(it.window) } }
    var display by remember { mutableStateOf(HDRDisplayState(false, 1f)) }
    var mode by rememberSaveable { mutableStateOf(HDRPreviewMode.AUTOMATIC) }
    var falseColor by rememberSaveable { mutableStateOf(false) }
    var resumeTick by remember { mutableIntStateOf(0) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, controller) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                controller?.invalidateWindowMode()
                resumeTick++
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(frame, controller, mode, hardwareCanvas, resumeTick) {
        display = controller?.refresh(
            surfaceReady = frame != null && hardwareCanvas && mode == HDRPreviewMode.AUTOMATIC,
        ) ?: HDRDisplayState(false, 1f, "No activity window")
    }
    DisposableEffect(controller) {
        if (activity != null && Build.VERSION.SDK_INT >= 34) {
            controller?.registerRatioChanges(activity.mainExecutor) { display = it }
        }
        onDispose { controller?.close() }
    }
    val parameters = HDRDisplayParameters(display.headroom, mode, falseColor)
    val bitmap = HDRBitmapAdapter.rememberBitmap(frame, parameters, display.available || falseColor, resetKey = resetKey)
    return PhotoHDRPreview(display, parameters, bitmap, { mode = it }, { falseColor = it })
}
