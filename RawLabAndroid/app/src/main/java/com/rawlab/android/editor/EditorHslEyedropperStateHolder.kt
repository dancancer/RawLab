package com.rawlab.android.editor

import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.settings.CurveTargetInteraction
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslTargetAvailability
import com.rawlab.android.settings.HslTargetInteraction
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.HslTargetState
import com.rawlab.android.settings.ToneCurveChannel
import com.rawlab.android.settings.ToneCurveMode
import com.rawlab.android.settings.ToneCurvePoint
import com.rawlab.android.settings.ToneCurveSettings
import com.rawlab.android.settings.ToneCurveShape
import com.rawlab.android.settings.canonicalZeros
import com.rawlab.android.settings.editingCurve
import com.rawlab.android.settings.editingHsl
import com.rawlab.android.settings.synchronizeHDR
import com.rawlab.android.settings.withEditingCurve
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
    private val sampleCurve: (ToneCurveSettings, ToneCurveChannel) -> List<ToneCurvePoint> = { settings, channel ->
        com.rawlab.android.engine.ToneCurveSampling.samples(settings, channel)
    },
    private val sampleParametric: (ToneCurveSettings, Double) -> Double = { settings, x ->
        com.rawlab.android.engine.ToneCurveSampling.sampleParametricValue(settings, x)
    },
) {
    private val mutableTarget = MutableStateFlow(HslTargetState())
    val state = mutableTarget.asStateFlow()
    private val interaction = HslTargetInteraction()
    private val curveInteraction = CurveTargetInteraction()
    private var activeGroup: AdjustmentGroup? = null
    private var historyActive = false
    private var acceptedPreview: Work.Preview? = null
    private var acceptedSettings: EditSettings? = null
    private var acceptedRevision: HslTargetRevision? = null

    val isWaiting: Boolean get() = interaction.waiting || curveInteraction.waiting

    fun recordAcceptedPreview(request: Work.Preview, settings: EditSettings, sourceRev: Long, renderRev: Long) {
        acceptedPreview = request
        acceptedSettings = settings
        acceptedRevision = HslTargetRevision(sourceRev, renderRev)
    }

    fun acceptedPreviewRequest(): Work.Preview? = acceptedPreview

    fun setEnabled(enabled: Boolean) {
        cancel()
        val group = mutable.value.draft?.group
        val allowed = group == AdjustmentGroup.HSL || group == AdjustmentGroup.CURVE
        mutableTarget.value = mutableTarget.value.copy(
            enabled = enabled && allowed,
            curveMode = group == AdjustmentGroup.CURVE,
        )
    }

    fun setAxis(axis: Int) {
        require(axis in 0..2)
        cancel()
        mutableTarget.value = mutableTarget.value.copy(axis = axis)
    }

    fun setCurveChannel(channel: ToneCurveChannel) {
        cancel()
        mutableTarget.value = mutableTarget.value.copy(curveChannel = channel)
    }

    fun begin(x: Float, y: Float, keyDelta: Float? = null) {
        cancel()
        val current = mutable.value
        val target = mutableTarget.value
        val preview = acceptedPreview
        val revision = acceptedRevision
        val group = current.draft?.group
        val isHsl = group == AdjustmentGroup.HSL
        val isCurve = group == AdjustmentGroup.CURVE
        if (!target.enabled || !current.controlsEnabled || current.rendering || current.previewResizePending ||
            current.error != null || (!isHsl && !isCurve) ||
            preview == null || revision == null || revision.source != currentSourceRevision() ||
            current.visibleEdits != acceptedSettings ||
            current.photo?.identity != preview.photo.identity || current.photo?.file != preview.photo.file
        ) {
            mutableTarget.value = target.copy(notice = HslTargetAvailability.STALE)
            return
        }
        activeGroup = group
        val token = if (isCurve) {
            val editing = current.visibleEdits.editingCurve
            val samplingInput = if (editing.shape(target.curveChannel).mode == ToneCurveMode.LEGACY) {
                editing.replacing(target.curveChannel, ToneCurveShape.identity)
            } else {
                editing
            }
            val sampled = runCatching { sampleCurve(samplingInput, target.curveChannel) }.getOrElse {
                ToneCurveShape.identity.points
            }
            val parametricEvaluator: ((Double) -> Double)? =
                if (target.curveChannel == ToneCurveChannel.RGB && !editing.parametric.isIdentity) {
                    { px -> sampleParametric(editing, px) }
                } else {
                    null
                }
            curveInteraction.begin(
                editing, target.curveChannel, revision, sampled,
                isHdr = current.visibleEdits.isHDREditing,
                parametricEvaluator = parametricEvaluator,
            )
        } else {
            interaction.begin(current.visibleEdits.editingHsl, target.axis, revision)
        }
        mutableTarget.value = target.copy(x = x, y = y, sample = null, waiting = true, notice = null, curveMode = isCurve)
        if (keyDelta != null) {
            if (isCurve) {
                curveInteraction.move(keyDelta)
                curveInteraction.end()
            } else {
                interaction.move(keyDelta)
                interaction.end()
            }
        }
        submitProbe(Work.HslProbe(preview, current.visibleEdits, revision, token, if (isCurve) 0 else target.axis, x, y))
    }

    fun accept(value: WorkResult.HslProbe) {
        val work = value.request
        val isCurve = activeGroup == AdjustmentGroup.CURVE && curveInteraction.matches(work.token)
        val isHsl = activeGroup == AdjustmentGroup.HSL && interaction.matches(work.token)
        if (!isCurve && !isHsl) return
        val current = mutable.value
        val target = mutableTarget.value
        val expectedGroup = if (isCurve) AdjustmentGroup.CURVE else AdjustmentGroup.HSL
        if (!target.enabled || (!isCurve && target.axis != work.axis) || current.visibleEdits != work.before ||
            current.draft?.group != expectedGroup || currentSourceRevision() != work.revision.source ||
            current.photo?.identity != work.preview.photo.identity
        ) {
            cancel()
            mutableTarget.value = mutableTarget.value.copy(notice = HslTargetAvailability.STALE)
            return
        }
        if (isCurve) {
            val next = curveInteraction.accept(value.sample, work.token, acceptedRevision)
            mutableTarget.value = target.copy(
                sample = curveInteraction.selection,
                waiting = false,
                notice = if (next == null) curveInteraction.selection?.availability ?: HslTargetAvailability.STALE else null,
            )
            if (next == null) return
            changeTargetDraft(current.visibleEdits.withEditingCurve(next), AdjustmentGroup.CURVE, true)
            historyActive = mutable.value.draft?.interacting == true
            if (!historyActive) {
                clear()
                mutableTarget.value = target.copy(notice = HslTargetAvailability.FAILED)
                return
            }
            if (!curveInteraction.dragging) end()
        } else {
            val next = interaction.accept(value.sample, work.token, acceptedRevision)
            mutableTarget.value = target.copy(
                sample = interaction.selection,
                waiting = false,
                notice = if (next == null) interaction.selection?.availability ?: HslTargetAvailability.STALE else null,
            )
            if (next == null) return
            changeTargetDraft(current.visibleEdits.withEditingHsl(next), AdjustmentGroup.HSL, true)
            historyActive = mutable.value.draft?.interacting == true
            if (!historyActive) {
                clear()
                mutableTarget.value = target.copy(notice = HslTargetAvailability.FAILED)
                return
            }
            if (!interaction.dragging) end()
        }
    }

    fun move(delta: Float) {
        if (activeGroup == AdjustmentGroup.CURVE) {
            val next = curveInteraction.move(delta) ?: return
            if (!historyActive) return
            changeTargetDraft(mutable.value.visibleEdits.withEditingCurve(next), AdjustmentGroup.CURVE, true)
            return
        }
        val next = interaction.move(delta) ?: return
        if (!historyActive) return
        changeTargetDraft(mutable.value.visibleEdits.withEditingHsl(next), AdjustmentGroup.HSL, true)
    }

    fun end() {
        val group = activeGroup
        if (group == AdjustmentGroup.CURVE) curveInteraction.end() else interaction.end()
        if (historyActive && group != null) {
            historyActive = false
            changeTargetDraft(mutable.value.visibleEdits, group, false)
        }
    }

    private fun changeTargetDraft(edits: EditSettings, group: AdjustmentGroup, interactive: Boolean) {
        if (mutable.value.draft?.group == group) {
            onChangeDraft(edits.canonicalZeros().synchronizeHDR(), interactive)
        }
    }

    fun clear(disable: Boolean = false) {
        interaction.cancel()
        curveInteraction.cancel()
        activeGroup = null
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
        val group = activeGroup
        clear()
        val draft = mutable.value.draft
        if (active && group != null && draft?.group == group && draft.interacting && draft.canUndo) {
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
        if (interaction.dragging || curveInteraction.dragging || target.x == null || target.y == null) return
        if (interaction.waiting || curveInteraction.waiting) {
            if (activeGroup == AdjustmentGroup.CURVE) curveInteraction.accumulateReleased(delta)
            else interaction.accumulateReleased(delta)
            return
        }
        begin(target.x, target.y, delta)
    }
}
