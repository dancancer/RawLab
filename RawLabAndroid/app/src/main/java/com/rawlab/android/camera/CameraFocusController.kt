package com.rawlab.android.camera

import com.rawlab.android.camera.protocol.SonyTetherSession

internal interface FocusCancellable {
    fun cancel()
}

internal fun interface FocusScheduler {
    fun schedule(delayMs: Long, action: () -> Unit): FocusCancellable
}

internal data class CameraFocusSnapshot(
    val focusBusy: Boolean,
    val tapActive: Boolean,
    val tapU: Float?,
    val tapV: Float?,
    val tapFocusLocked: Boolean,
    val propsFocusLocked: Boolean,
    val canCancelTouchFocus: Boolean,
    val lastFocusSquareRatio: Float?,
    val focusFrames: List<SonyTetherSession.LiveViewFocusFrame>,
)

internal class CameraFocusController(
    private val clock: () -> Long,
    private val scheduler: FocusScheduler,
    private val onTimeoutUpdate: (CameraFocusSnapshot) -> Unit = {},
) {
    private val lock = Any()
    private val stateBytes = ByteArray(SonyCameraNative.nativeFocusStateSize())
    private var liveViewFrames: List<SonyTetherSession.LiveViewFocusFrame> = emptyList()
    private var pendingTimer: FocusCancellable? = null
    private var scheduledGeneration: Long? = null

    init {
        SonyCameraNative.nativeFocusStateInit(stateBytes)
    }

    fun snapshot(): CameraFocusSnapshot = synchronized(lock) { buildSnapshotLocked() }

    fun reset(preserveLastRatio: Boolean = false): CameraFocusSnapshot = synchronized(lock) {
        SonyCameraNative.nativeFocusStateReset(stateBytes, preserveLastRatio)
        liveViewFrames = emptyList()
        syncTimerLocked()
        buildSnapshotLocked()
    }

    fun onTap(tap: CameraFocusTap): CameraFocusSnapshot = synchronized(lock) {
        SonyCameraNative.nativeFocusStateOnTap(
            stateBytes,
            tap.u.toDouble(),
            tap.v.toDouble(),
            tap.x,
            tap.y,
            clock(),
        )
        liveViewFrames = emptyList()
        syncTimerLocked()
        buildSnapshotLocked()
    }

    fun onCancelStart(): CameraFocusSnapshot = synchronized(lock) {
        SonyCameraNative.nativeFocusStateOnCancelStart(stateBytes)
        liveViewFrames = emptyList()
        syncTimerLocked()
        buildSnapshotLocked()
    }

    fun onFocusFinished(succeeded: Boolean, focusLocked: Boolean): CameraFocusSnapshot = synchronized(lock) {
        SonyCameraNative.nativeFocusStateOnFocusFinished(stateBytes, succeeded, focusLocked, clock())
        syncTimerLocked()
        buildSnapshotLocked()
    }

    fun onLiveFrame(
        frames: List<SonyTetherSession.LiveViewFocusFrame>,
        imageWidth: Int,
        imageHeight: Int,
    ): CameraFocusSnapshot = synchronized(lock) {
        val packed = DoubleArray(frames.size * 6)
        for (i in frames.indices) {
            val f = frames[i]
            val b = i * 6
            packed[b + 0] = f.kind.ordinal.toDouble()
            packed[b + 1] = if (f.focused) 1.0 else 0.0
            packed[b + 2] = f.cx.toDouble()
            packed[b + 3] = f.cy.toDouble()
            packed[b + 4] = f.width.toDouble()
            packed[b + 5] = f.height.toDouble()
        }
        SonyCameraNative.nativeFocusStateOnLiveFrame(
            stateBytes,
            packed,
            imageWidth.toDouble(),
            imageHeight.toDouble(),
        )
        val raw = SonyCameraNative.nativeFocusStateSnapshot(stateBytes)
        liveViewFrames = if (raw[0] != 0.0) emptyList() else frames
        syncTimerLocked()
        buildSnapshotLocked()
    }

    fun onProperties(
        canCancelTouchFocus: Boolean,
        propsFocusLocked: Boolean,
        propsFocusFailed: Boolean,
    ): CameraFocusSnapshot = synchronized(lock) {
        SonyCameraNative.nativeFocusStateOnProperties(
            stateBytes,
            canCancelTouchFocus,
            propsFocusLocked,
            propsFocusFailed,
        )
        syncTimerLocked()
        buildSnapshotLocked()
    }

    fun onCaptureOrParameterStart(): CameraFocusSnapshot = synchronized(lock) {
        SonyCameraNative.nativeFocusStateOnCaptureOrParamStart(stateBytes)
        syncTimerLocked()
        buildSnapshotLocked()
    }

    fun onLiveChanged(liveActive: Boolean): CameraFocusSnapshot = synchronized(lock) {
        SonyCameraNative.nativeFocusStateOnLiveChanged(stateBytes, liveActive)
        if (!liveActive) {
            liveViewFrames = emptyList()
        }
        syncTimerLocked()
        buildSnapshotLocked()
    }

    fun tick(): CameraFocusSnapshot = synchronized(lock) {
        SonyCameraNative.nativeFocusStateOnTick(stateBytes, clock())
        syncTimerLocked()
        buildSnapshotLocked()
    }

    private fun handleTimeout(generation: Long) {
        val updated = synchronized(lock) {
            SonyCameraNative.nativeFocusStateOnTimeout(stateBytes, generation, clock())
            pendingTimer = null
            scheduledGeneration = null
            syncTimerLocked()
            buildSnapshotLocked()
        }
        onTimeoutUpdate(updated)
    }

    private fun syncTimerLocked() {
        val raw = SonyCameraNative.nativeFocusStateSnapshot(stateBytes)
        val hasPendingDeadline = raw[13] != 0.0
        if (hasPendingDeadline) {
            val generation = raw[2].toLong()
            if (scheduledGeneration != generation || pendingTimer == null) {
                pendingTimer?.cancel()
                scheduledGeneration = generation
                val deadlineMs = raw[7].toLong()
                val delayMs = (deadlineMs - clock()).coerceAtLeast(0L)
                pendingTimer = scheduler.schedule(delayMs) {
                    handleTimeout(generation)
                }
            }
        } else {
            pendingTimer?.cancel()
            pendingTimer = null
            scheduledGeneration = null
        }
    }

    private fun buildSnapshotLocked(): CameraFocusSnapshot {
        val raw = SonyCameraNative.nativeFocusStateSnapshot(stateBytes)
        val focusBusy = raw[0] != 0.0
        val tapActive = raw[1] != 0.0
        val hasLastRatio = raw[12] != 0.0
        return CameraFocusSnapshot(
            focusBusy = focusBusy,
            tapActive = tapActive,
            tapU = if (tapActive) raw[3].toFloat() else null,
            tapV = if (tapActive) raw[4].toFloat() else null,
            tapFocusLocked = raw[8] != 0.0,
            propsFocusLocked = raw[9] != 0.0,
            canCancelTouchFocus = raw[10] != 0.0,
            lastFocusSquareRatio = if (hasLastRatio) raw[14].toFloat() else null,
            focusFrames = if (focusBusy) emptyList() else liveViewFrames,
        )
    }
}
