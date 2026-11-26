package com.rawlab.android.engine

import android.app.Activity
import android.content.pm.ActivityInfo
import android.os.Build
import android.view.Display
import android.view.SurfaceView
import android.view.Window
import java.util.concurrent.Executor
import java.util.function.Consumer
import kotlin.math.round

data class HDRDisplayState(val available: Boolean, val headroom: Float, val reason: String? = null)

internal fun quantizedHdrHeadroom(raw: Float): Float {
    val safe = if (raw.isFinite()) raw.coerceIn(1f, 65504f) else 1f
    return round(safe * 200f) / 200f
}

internal interface HDRDisplayHost {
    val hasHdrTypes: Boolean
    val isHdrSdrRatioAvailable: Boolean
    val hdrSdrRatio: Float
    fun registerRatioListener(executor: Executor, onChanged: () -> Unit): AutoCloseable?
}

internal interface HDRWindowHost {
    val sdkInt: Int
    fun currentDisplay(): HDRDisplayHost?
    fun setColorMode(mode: Int)
    fun setDesiredHdrHeadroom(headroom: Float)
}

private class AndroidHDRDisplayHost(private val display: Display) : HDRDisplayHost {
    override val hasHdrTypes: Boolean
        get() = Build.VERSION.SDK_INT >= 34 && display.mode.supportedHdrTypes.isNotEmpty()

    override val isHdrSdrRatioAvailable: Boolean
        get() = Build.VERSION.SDK_INT >= 34 && display.isHdrSdrRatioAvailable

    override val hdrSdrRatio: Float
        get() = if (Build.VERSION.SDK_INT >= 34) display.hdrSdrRatio else 1f

    override fun registerRatioListener(executor: Executor, onChanged: () -> Unit): AutoCloseable? {
        if (Build.VERSION.SDK_INT < 34 || !display.isHdrSdrRatioAvailable) return null
        val callback = Consumer<Display> { onChanged() }
        display.registerHdrSdrRatioChangedListener(executor, callback)
        return AutoCloseable { display.unregisterHdrSdrRatioChangedListener(callback) }
    }

    override fun equals(other: Any?): Boolean = other is AndroidHDRDisplayHost && other.display === display

    override fun hashCode(): Int = System.identityHashCode(display)
}

private class AndroidHDRWindowHost(private val window: Window) : HDRWindowHost {
    override val sdkInt: Int
        get() = Build.VERSION.SDK_INT

    override fun currentDisplay(): HDRDisplayHost? = window.decorView.display?.let(::AndroidHDRDisplayHost)

    override fun setColorMode(mode: Int) {
        window.setColorMode(mode)
    }

    override fun setDesiredHdrHeadroom(headroom: Float) {
        if (Build.VERSION.SDK_INT >= 35) {
            window.setDesiredHdrHeadroom(headroom)
        }
    }
}

/** Runtime gate for the FP16/scRGB display path; every failure is an explicit SDR fallback. */
internal class HDRDisplayController internal constructor(private val host: HDRWindowHost) : AutoCloseable {
    constructor(window: Window) : this(AndroidHDRWindowHost(window))

    private var display: HDRDisplayHost? = null
    private var ratioExecutor: Executor? = null
    private var ratioChanged: ((HDRDisplayState) -> Unit)? = null
    private var registeredDisplay: HDRDisplayHost? = null
    private var ratioRegistration: AutoCloseable? = null
    private var lastSurfaceReady = false
    private var lastSurface: SurfaceView? = null
    private var lastContentHeadroom = 1f
    private var appliedColorMode: Int? = null
    private var appliedDesiredHeadroom: Float? = null
    private var closed = false

    fun refresh(surfaceReady: Boolean, surface: SurfaceView? = null, contentHeadroom: Float = 1f): HDRDisplayState {
        lastSurfaceReady = surfaceReady; lastSurface = surface; lastContentHeadroom = contentHeadroom
        if (closed) return HDRDisplayState(false, 1f, "Controller is closed")
        if (host.sdkInt < 34) return fallback("HDR UI requires API 34")
        val target = host.currentDisplay() ?: return fallback("No presentation display")
        display = target
        if (!target.hasHdrTypes) return fallback("Display mode has no HDR type")
        if (!surfaceReady) return fallback("FP16/scRGB surface is unavailable")
        if (!target.isHdrSdrRatioAvailable) return fallback("Display HDR/SDR ratio unavailable")

        // Configure HDR mode and unconstrained headroom BEFORE reading hdrSdrRatio so a transient 1.0 ratio
        // never ratchets or locks the window out of HDR recovery.
        applyWindowMode(ActivityInfo.COLOR_MODE_HDR, 0f)
        ensureRatioListenerRegistered(target)

        val ratio = quantizedHdrHeadroom(target.hdrSdrRatio)
        if (surface != null) {
            runCatching {
                if (host.sdkInt >= 35 && Build.VERSION.SDK_INT >= 35) {
                    surface.setDesiredHdrHeadroom(0f)
                } else if (Build.VERSION.SDK_INT >= 34) {
                    surface.surfaceControl.let { control ->
                        val desired = contentHeadroom.takeIf { it.isFinite() && it > 1f } ?: maxOf(2f, ratio)
                        val current = ratio.coerceIn(1f, desired)
                        android.view.SurfaceControl.Transaction().setExtendedRangeBrightness(control, current, desired).apply()
                    }
                }
            }.onFailure { return fallback("Surface HDR headroom unavailable") }
        }
        return HDRDisplayState(
            available = true,
            headroom = ratio,
            reason = if (ratio <= 1f) "Display headroom is SDR" else null,
        )
    }

    fun registerRatioChanges(executor: Executor, changed: (HDRDisplayState) -> Unit) {
        if (closed || host.sdkInt < 34) return
        ratioExecutor = executor
        ratioChanged = changed
        ensureRatioListenerRegistered(display ?: host.currentDisplay())
    }

    private fun ensureRatioListenerRegistered(target: HDRDisplayHost?) {
        if (closed || host.sdkInt < 34) return
        val executor = ratioExecutor ?: return
        if (ratioChanged == null || target == null || !target.isHdrSdrRatioAvailable) return
        if (registeredDisplay == target && ratioRegistration != null) return
        unregisterRatioRegistration()
        val registration = target.registerRatioListener(executor) {
            if (!closed) {
                ratioChanged?.invoke(refresh(lastSurfaceReady, lastSurface, lastContentHeadroom))
            }
        } ?: return
        ratioRegistration = registration
        registeredDisplay = target
    }

    private fun applyWindowMode(colorMode: Int, desiredHeadroom: Float) {
        if (appliedColorMode != colorMode) {
            host.setColorMode(colorMode)
            appliedColorMode = colorMode
        }
        if (host.sdkInt >= 35 && appliedDesiredHeadroom != desiredHeadroom) {
            host.setDesiredHdrHeadroom(desiredHeadroom)
            appliedDesiredHeadroom = desiredHeadroom
        }
    }

    private fun fallback(reason: String): HDRDisplayState {
        applyWindowMode(ActivityInfo.COLOR_MODE_DEFAULT, 0f)
        return HDRDisplayState(false, 1f, reason)
    }

    private fun unregisterRatioRegistration() {
        ratioRegistration?.close()
        ratioRegistration = null
        registeredDisplay = null
    }

    private fun unregisterRatioChanges() {
        unregisterRatioRegistration()
        ratioExecutor = null
        ratioChanged = null
    }

    override fun close() {
        closed = true
        unregisterRatioChanges()
        applyWindowMode(ActivityInfo.COLOR_MODE_DEFAULT, 0f)
    }
}

internal fun Activity.hdrDisplayController() = HDRDisplayController(window)
