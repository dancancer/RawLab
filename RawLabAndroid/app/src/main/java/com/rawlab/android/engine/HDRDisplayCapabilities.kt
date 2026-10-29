package com.rawlab.android.engine

import android.app.Activity
import android.content.pm.ActivityInfo
import android.os.Build
import android.view.Display
import android.view.SurfaceView
import android.view.Window
import java.util.concurrent.Executor
import java.util.function.Consumer

data class HDRDisplayState(val available: Boolean, val headroom: Float, val reason: String? = null)

/** Runtime gate for the FP16/scRGB display path; every failure is an explicit SDR fallback. */
internal class HDRDisplayController(private val window: Window) : AutoCloseable {
    private var display: Display? = null
    private var listener: Consumer<Display>? = null
    private var registeredDisplay: Display? = null
    private var lastSurfaceReady = false
    private var lastSurface: SurfaceView? = null
    private var lastContentHeadroom = 1f

    fun refresh(surfaceReady: Boolean, surface: SurfaceView? = null, contentHeadroom: Float = 1f): HDRDisplayState {
        lastSurfaceReady = surfaceReady; lastSurface = surface; lastContentHeadroom = contentHeadroom
        if (Build.VERSION.SDK_INT < 34) return fallback("HDR UI requires API 34")
        val target = window.decorView.display ?: return fallback("No presentation display")
        display = target
        val hdrTypes = target.mode.supportedHdrTypes
        if (hdrTypes.isEmpty()) return fallback("Display mode has no HDR type")
        if (!surfaceReady) return fallback("FP16/scRGB surface is unavailable")
        window.setColorMode(ActivityInfo.COLOR_MODE_HDR)
        if (!target.isHdrSdrRatioAvailable) return fallback("Display HDR/SDR ratio unavailable")
        val ratio = target.hdrSdrRatio.takeIf { it.isFinite() && it > 1f }
            ?: return HDRDisplayState(false, 1f, "Display headroom is SDR")
        val desired = contentHeadroom.takeIf { it.isFinite() && it >= 1f }?.coerceIn(1f, ratio) ?: 1f
        window.setColorMode(ActivityInfo.COLOR_MODE_HDR)
        if (Build.VERSION.SDK_INT >= 35) window.setDesiredHdrHeadroom(desired)
        if (surface != null) {
            runCatching {
                if (Build.VERSION.SDK_INT >= 35) surface.setDesiredHdrHeadroom(desired)
                else surface.surfaceControl.let { control ->
                    android.view.SurfaceControl.Transaction().setExtendedRangeBrightness(control, 1f, desired).apply()
                }
            }.onFailure { return fallback("Surface HDR headroom unavailable") }
        }
        return HDRDisplayState(true, ratio)
    }

    fun registerRatioChanges(executor: Executor, changed: (HDRDisplayState) -> Unit) {
        if (Build.VERSION.SDK_INT < 34) return
        val current = display ?: window.decorView.display ?: return
        unregisterRatioChanges()
        if (!current.isHdrSdrRatioAvailable) return
        val callback = Consumer<Display> { changed(refresh(lastSurfaceReady, lastSurface, lastContentHeadroom)) }
        current.registerHdrSdrRatioChangedListener(executor, callback)
        listener = callback
        registeredDisplay = current
    }

    private fun fallback(reason: String): HDRDisplayState {
        window.setColorMode(ActivityInfo.COLOR_MODE_DEFAULT)
        return HDRDisplayState(false, 1f, reason)
    }

    private fun unregisterRatioChanges() {
        if (Build.VERSION.SDK_INT >= 34) {
            val current = registeredDisplay
            val callback = listener
            if (current != null && callback != null) current.unregisterHdrSdrRatioChangedListener(callback)
        }
        listener = null
        registeredDisplay = null
    }

    override fun close() {
        unregisterRatioChanges()
        window.setColorMode(ActivityInfo.COLOR_MODE_DEFAULT)
    }
}

internal fun Activity.hdrDisplayController() = HDRDisplayController(window)
