package com.rawlab.android.editor

import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.WbProbeNotice
import com.rawlab.android.settings.WbProbeState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

internal class EditorWbEyedropperStateHolder(
    private val mutable: MutableStateFlow<EditorState>,
    private val currentSourceRevision: () -> Long,
    private val currentRenderRevision: () -> Long,
    private val onSubmitProbe: (Work.WbProbe) -> Long,
    private val onApplyEdit: (EditSettings) -> Unit,
) {
    private data class AcceptedPreview(
        val request: Work.Preview,
        val edits: EditSettings,
        val revision: HslTargetRevision,
    )

    private val mutableState = MutableStateFlow(WbProbeState())
    val state: StateFlow<WbProbeState> = mutableState.asStateFlow()

    private var acceptedPreview: AcceptedPreview? = null
    private var activeToken: Long = 0L

    val isWaiting: Boolean get() = mutableState.value.waiting

    fun recordAcceptedPreview(request: Work.Preview, edits: EditSettings, sourceRevision: Long, renderRevision: Long) {
        acceptedPreview = AcceptedPreview(request, edits, HslTargetRevision(sourceRevision, renderRevision))
    }

    fun setEnabled(enabled: Boolean) {
        activeToken += 1
        mutableState.value = if (enabled) {
            mutableState.value.copy(enabled = true, x = null, y = null, waiting = false, notice = null)
        } else {
            WbProbeState()
        }
    }

    fun begin(x: Float, y: Float) {
        val current = mutable.value
        val photo = current.photo ?: return
        val probe = mutableState.value
        if (!probe.enabled || !current.controlsEnabled || current.visibleEdits.isHDREditing) return
        if (!x.isFinite() || !y.isFinite() || x !in 0f..1f || y !in 0f..1f) {
            reject()
            return
        }
        val accepted = acceptedPreview
        val revision = HslTargetRevision(currentSourceRevision(), currentRenderRevision())
        if (accepted == null || accepted.request.photo != photo || accepted.revision.source != revision.source ||
            accepted.edits != current.visibleEdits
        ) {
            mutableState.value = probe.copy(x = x, y = y, waiting = false, notice = WbProbeNotice.STALE)
            return
        }
        activeToken += 1
        val token = activeToken
        mutableState.value = probe.copy(x = x, y = y, waiting = true, notice = null)
        onSubmitProbe(Work.WbProbe(accepted.request, current.visibleEdits, accepted.revision, token, x, y))
    }

    fun accept(result: WorkResult.WbProbe) {
        val probe = mutableState.value
        if (!probe.enabled || result.request.token != activeToken) return
        val current = mutable.value
        val photo = current.photo
        if (photo == null || photo != result.request.preview.photo ||
            currentSourceRevision() != result.request.revision.source ||
            current.visibleEdits != result.request.before
        ) {
            mutableState.value = probe.copy(waiting = false, notice = WbProbeNotice.STALE)
            return
        }
        val notice = when (result.sample.availability) {
            NativeProcessor.WbProbeAvailability.AVAILABLE -> null
            NativeProcessor.WbProbeAvailability.OVEREXPOSED -> WbProbeNotice.OVEREXPOSED
            NativeProcessor.WbProbeAvailability.OUTSIDE -> WbProbeNotice.OUTSIDE
            NativeProcessor.WbProbeAvailability.UNAVAILABLE -> WbProbeNotice.UNAVAILABLE
        }
        if (notice != null) {
            mutableState.value = probe.copy(waiting = false, notice = notice)
            return
        }
        val temperature = result.sample.temperature.coerceIn(2000f, 50000f)
        val tint = result.sample.tint.coerceIn(-150f, 150f)
        if (!temperature.isFinite() || !tint.isFinite()) {
            mutableState.value = probe.copy(waiting = false, notice = WbProbeNotice.UNAVAILABLE)
            return
        }
        val isRaster = photo.inputKind != PhotoInputKind.RAW
        val next = current.visibleEdits.copy(
            customWb = !isRaster,
            temperature = temperature,
            tint = tint,
        )
        mutableState.value = probe.copy(waiting = false, notice = null)
        onApplyEdit(next)
    }

    fun cancel() {
        activeToken += 1
        val probe = mutableState.value
        if (probe.waiting || probe.x != null || probe.y != null) {
            mutableState.value = probe.copy(x = null, y = null, waiting = false)
        }
    }

    fun reject() {
        activeToken += 1
        mutableState.value = mutableState.value.copy(x = null, y = null, waiting = false, notice = WbProbeNotice.OUTSIDE)
    }

    fun clear(disable: Boolean = false) {
        activeToken += 1
        mutableState.value = if (disable) {
            WbProbeState()
        } else {
            mutableState.value.copy(x = null, y = null, waiting = false, notice = null)
        }
    }
}
