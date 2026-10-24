package com.rawlab.android.settings

import kotlin.math.abs

data class HslTargetRevision(val source: Long, val request: Long)
enum class HslTargetAvailability { AVAILABLE, NEAR_GRAY, OUTSIDE, STALE, NONFINITE, FAILED }

class HslTargetSample(val revision: HslTargetRevision, val availability: HslTargetAvailability,
    rgb: List<Float>, weights: List<Float>, val preview: Boolean) {
    val rgb = rgb.toList()
    val weights = weights.toList()
    val usable get() = availability == HslTargetAvailability.AVAILABLE && rgb.size == 3 && rgb.all(Float::isFinite) &&
        weights.size == 8 && weights.all { it.isFinite() && it in 0f..1f } && abs(weights.sum()-1) < .00001f
    val channels get() = if (usable) weights.indices.filter { weights[it] > 0 } else emptyList()
    companion object {
        fun unavailable(revision: HslTargetRevision, reason: HslTargetAvailability) = HslTargetSample(revision, reason, emptyList(), emptyList(), true)
    }
}

class HslTargetDrag(val before: HslSettings, val axis: Int, val sample: HslTargetSample) {
    init { require(axis in 0..2 && sample.usable) }
    fun value(delta: Float): HslSettings {
        if (!delta.isFinite()) return before
        return sample.channels.fold(before) { next, channel ->
            next.withValue(axis, channel, (before.value(axis, channel)+delta*sample.weights[channel]).coerceIn(-100f, 100f))
        }
    }
}

class HslTargetInteraction {
    private data class Pending(val token: Long, val before: HslSettings, val axis: Int, val revision: HslTargetRevision,
        var delta: Float = 0f, var released: Boolean = false, var drag: HslTargetDrag? = null)
    private var generation = 0L
    private var pending: Pending? = null
    var selection: HslTargetSample? = null
        private set
    val dragging get() = pending?.released == false
    val waiting get() = pending != null && pending?.drag == null
    fun matches(token: Long) = pending?.token == token
    fun begin(before: HslSettings, axis: Int, revision: HslTargetRevision): Long {
        require(axis in 0..2)
        generation++; selection = null; pending = Pending(generation, before, axis, revision)
        return generation
    }
    fun move(delta: Float): HslSettings? {
        val active = pending ?: return null
        if (!delta.isFinite() || active.released) return null
        active.delta = delta
        return active.drag?.value(delta)
    }
    fun accumulateReleased(delta: Float) {
        val active = pending ?: return
        if (active.released && active.drag == null && delta.isFinite() && (active.delta+delta).isFinite()) active.delta += delta
    }
    fun accept(sample: HslTargetSample, token: Long, current: HslTargetRevision?): HslSettings? {
        val active = pending?.takeIf { it.token == token } ?: return null
        if (active.revision != current || sample.revision != active.revision) { pending = null; selection = null; return null }
        selection = sample
        if (!sample.usable) { pending = null; return null }
        val drag = HslTargetDrag(active.before, active.axis, sample)
        active.drag = drag
        if (active.released) pending = null
        return drag.value(active.delta)
    }
    fun end() { if (pending?.drag != null) pending = null else pending?.released = true }
    fun cancel(): HslSettings? {
        val before = pending?.takeIf { it.drag != null }?.before
        pending = null; selection = null; return before
    }
}

data class HslTargetState(val enabled: Boolean = false, val axis: Int = 0, val x: Float? = null, val y: Float? = null,
    val sample: HslTargetSample? = null, val waiting: Boolean = false, val notice: HslTargetAvailability? = null)
