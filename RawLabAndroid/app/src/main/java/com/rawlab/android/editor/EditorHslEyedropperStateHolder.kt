package com.rawlab.android.editor

import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslTargetAvailability
import com.rawlab.android.settings.HslTargetInteraction
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.HslTargetState
import com.rawlab.android.settings.canonicalZeros
import com.rawlab.android.settings.editingHsl
import com.rawlab.android.settings.synchronizeHDR
import com.rawlab.android.settings.withEditingHsl
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal class EditorHslEyedropperStateHolder(
    private val mutable: MutableStateFlow<EditorState>,
    private val currentSourceRevision: () -> Long,
    private val currentRenderRevision: () -> Long,
    private val submitProbe: (Work.HslProbe) -> Unit,
    private val onChangeDraft: (EditSettings, Boolean) -> Unit,
    private val onIncrementDraftRevision: () -> Unit,
    private val onRenderDraft: (Boolean) -> Unit,
) {
    private val mutableTarget = MutableStateFlow(HslTargetState())
    val state = mutableTarget.asStateFlow()
    private val interaction = HslTargetInteraction()
    private var historyActive = false
    private var acceptedPreview: Work.Preview? = null
    private var acceptedSettings: EditSettings? = null
    private var acceptedRevision: HslTargetRevision? = null

    val isWaiting: Boolean get() = interaction.waiting

    fun recordAcceptedPreview(request: Work.Preview, settings: EditSettings, sourceRev: Long, renderRev: Long) {
        acceptedPreview = request
        acceptedSettings = settings
        acceptedRevision = HslTargetRevision(sourceRev, renderRev)
    }

    fun acceptedPreviewRequest(): Work.Preview? = acceptedPreview

    fun setEnabled(enabled: Boolean) {
        cancel()
        mutableTarget.value = mutableTarget.value.copy(
            enabled = enabled && mutable.value.draft?.group == AdjustmentGroup.HSL,
        )
    }

    fun setAxis(axis: Int) {
        require(axis in 0..2)
        cancel()
        mutableTarget.value = mutableTarget.value.copy(axis = axis)
    }

    fun begin(x: Float, y: Float, keyDelta: Float? = null) {
        cancel()
        val current = mutable.value
        val target = mutableTarget.value
        val preview = acceptedPreview
        val revision = acceptedRevision
        if (!target.enabled || !current.controlsEnabled || current.rendering || current.previewResizePending ||
            current.error != null || current.draft?.group != AdjustmentGroup.HSL ||
            preview == null || revision == null || revision.source != currentSourceRevision() ||
            current.visibleEdits != acceptedSettings ||
            current.photo?.identity != preview.photo.identity || current.photo?.file != preview.photo.file
        ) {
            mutableTarget.value = target.copy(notice = HslTargetAvailability.STALE)
            return
        }
        val token = interaction.begin(current.visibleEdits.editingHsl, target.axis, revision)
        mutableTarget.value = target.copy(x = x, y = y, sample = null, waiting = true, notice = null)
        if (keyDelta != null) {
            interaction.move(keyDelta)
            interaction.end()
        }
        submitProbe(Work.HslProbe(preview, current.visibleEdits, revision, token, target.axis, x, y))
    }

    fun accept(value: WorkResult.HslProbe) {
        val work = value.request
        if (!interaction.matches(work.token)) return
        val current = mutable.value
        val target = mutableTarget.value
        if (!target.enabled || target.axis != work.axis || current.visibleEdits != work.before ||
            current.draft?.group != AdjustmentGroup.HSL || currentSourceRevision() != work.revision.source ||
            current.photo?.identity != work.preview.photo.identity
        ) {
            cancel()
            mutableTarget.value = mutableTarget.value.copy(notice = HslTargetAvailability.STALE)
            return
        }
        val next = interaction.accept(value.sample, work.token, acceptedRevision)
        mutableTarget.value = target.copy(
            sample = interaction.selection,
            waiting = false,
            notice = if (next == null) interaction.selection?.availability ?: HslTargetAvailability.STALE else null,
        )
        if (next == null) return
        changeHslDraft(current.visibleEdits.withEditingHsl(next), true)
        historyActive = mutable.value.draft?.interacting == true
        if (!historyActive) {
            clear()
            mutableTarget.value = target.copy(notice = HslTargetAvailability.FAILED)
            return
        }
        if (!interaction.dragging) end()
    }

    fun move(delta: Float) {
        val next = interaction.move(delta) ?: return
        if (!historyActive) return
        changeHslDraft(mutable.value.visibleEdits.withEditingHsl(next), true)
    }

    fun end() {
        interaction.end()
        if (historyActive) {
            historyActive = false
            changeHslDraft(mutable.value.visibleEdits, false)
        }
    }

    private fun changeHslDraft(edits: EditSettings, interactive: Boolean) {
        if (mutable.value.draft?.group == AdjustmentGroup.HSL) {
            onChangeDraft(edits.canonicalZeros().synchronizeHDR(), interactive)
        }
    }

    fun clear(disable: Boolean = false) {
        interaction.cancel()
        historyActive = false
        mutableTarget.value = mutableTarget.value.copy(
            enabled = !disable && mutableTarget.value.enabled,
            x = null,
            y = null,
            sample = null,
            waiting = false,
            notice = null,
        )
    }

    fun cancel() {
        val active = historyActive
        clear()
        val draft = mutable.value.draft
        if (active && draft?.group == AdjustmentGroup.HSL && draft.interacting && draft.canUndo) {
            onIncrementDraftRevision()
            mutable.value = mutable.value.copy(draft = draft.undo().copy(redoSteps = emptyList()))
            onRenderDraft(false)
        }
    }

    fun reject() {
        cancel()
        mutableTarget.value = mutableTarget.value.copy(notice = HslTargetAvailability.OUTSIDE)
    }

    fun key(delta: Float) {
        val target = mutableTarget.value
        if (interaction.dragging || target.x == null || target.y == null) return
        if (interaction.waiting) {
            interaction.accumulateReleased(delta)
            return
        }
        begin(target.x, target.y, delta)
    }
}
