package com.rawlab.android.settings

import kotlin.math.abs
import kotlin.math.log2

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
    val sample: HslTargetSample? = null, val waiting: Boolean = false, val notice: HslTargetAvailability? = null,
    val curveMode: Boolean = false, val curveChannel: ToneCurveChannel = ToneCurveChannel.RGB)

class CurveTargetDrag private constructor(
    val before: ToneCurveSettings,
    val channel: ToneCurveChannel,
    val initial: ToneCurveSettings,
    val pointIndex: Int,
    val sample: HslTargetSample,
) {
    fun value(delta: Float): ToneCurveSettings {
        if (!delta.isFinite()) return before
        val shape = initial.shape(channel)
        if (pointIndex !in shape.points.indices) return before
        val p = shape.points[pointIndex]
        return initial.replacing(channel, shape.moving(pointIndex, p.x, p.y + delta / 200.0))
    }

    companion object {
        fun targetValue(sample: HslTargetSample, channel: ToneCurveChannel, isHdr: Boolean = false): Double? {
            if ((sample.availability != HslTargetAvailability.AVAILABLE && sample.availability != HslTargetAvailability.NEAR_GRAY) ||
                sample.rgb.size != 3 || !sample.rgb.all(Float::isFinite)) {
                return null
            }
            val raw = when (channel) {
                ToneCurveChannel.RGB -> 0.2126 * sample.rgb[0] + 0.7152 * sample.rgb[1] + 0.0722 * sample.rgb[2]
                ToneCurveChannel.RED -> sample.rgb[0].toDouble()
                ToneCurveChannel.GREEN -> sample.rgb[1].toDouble()
                ToneCurveChannel.BLUE -> sample.rgb[2].toDouble()
            }
            if (isHdr) {
                if (raw <= 0.0) return 0.0
                return ((log2(raw) + 8.0) / 16.0).coerceIn(0.0, 1.0)
            }
            return raw.coerceIn(0.0, 1.0)
        }

        fun invertSampledCurve(yOut: Double, samples: List<ToneCurvePoint>): Double {
            if (samples.size < 2) return yOut.coerceIn(0.0, 1.0)
            if (yOut <= samples.first().y) return samples.first().x
            if (yOut >= samples.last().y) return samples.last().x
            for (i in 0 until samples.lastIndex) {
                val a = samples[i]
                val b = samples[i + 1]
                if (yOut >= a.y && yOut <= b.y) {
                    val spanY = b.y - a.y
                    return if (spanY <= 1e-12) (a.x + b.x) * 0.5 else a.x + (b.x - a.x) * ((yOut - a.y) / spanY)
                }
            }
            return yOut.coerceIn(0.0, 1.0)
        }

        fun create(
            before: ToneCurveSettings,
            channel: ToneCurveChannel,
            sample: HslTargetSample,
            sampledCurve: List<ToneCurvePoint>,
            isHdr: Boolean = false,
            parametricEvaluator: ((Double) -> Double)? = null,
            toleranceX: Double = 0.04,
        ): CurveTargetDrag? {
            val yOut = targetValue(sample, channel, isHdr) ?: return null
            val existingShape = before.shape(channel)
            val workingShape = if (existingShape.mode == ToneCurveMode.LEGACY) ToneCurveShape.identity else existingShape
            val xIn = invertSampledCurve(yOut, sampledCurve)
            val targetX = if (channel == ToneCurveChannel.RGB && !before.parametric.isIdentity && parametricEvaluator != null) {
                parametricEvaluator(xIn).coerceIn(0.0, 1.0)
            } else {
                xIn
            }
            val nearestIdx = workingShape.points.indices.minBy { abs(workingShape.points[it].x - targetX) }
            if (abs(workingShape.points[nearestIdx].x - targetX) <= toleranceX) {
                return CurveTargetDrag(before, channel, before.replacing(channel, workingShape), nearestIdx, sample)
            }
            if (targetX > 0.0 && targetX < 1.0 && workingShape.points.size < 33) {
                val yAtX = if (existingShape.mode == ToneCurveMode.LEGACY) targetX else yOut
                val inserted = workingShape.inserting(targetX, yAtX)
                val idx = inserted.points.indexOfFirst { it.x == targetX }
                if (idx >= 0) {
                    return CurveTargetDrag(before, channel, before.replacing(channel, inserted), idx, sample)
                }
            }
            return CurveTargetDrag(before, channel, before.replacing(channel, workingShape), nearestIdx, sample)
        }
    }
}

class CurveTargetInteraction {
    private data class Pending(
        val token: Long,
        val before: ToneCurveSettings,
        val channel: ToneCurveChannel,
        val revision: HslTargetRevision,
        val sampledCurve: List<ToneCurvePoint>,
        val isHdr: Boolean,
        val parametricEvaluator: ((Double) -> Double)?,
        var delta: Float = 0f,
        var released: Boolean = false,
        var drag: CurveTargetDrag? = null,
    )
    private var generation = 0L
    private var pending: Pending? = null
    var selection: HslTargetSample? = null
        private set
    val dragging get() = pending?.released == false
    val waiting get() = pending != null && pending?.drag == null
    fun matches(token: Long) = pending?.token == token

    fun begin(
        before: ToneCurveSettings,
        channel: ToneCurveChannel,
        revision: HslTargetRevision,
        sampledCurve: List<ToneCurvePoint>,
        isHdr: Boolean = false,
        parametricEvaluator: ((Double) -> Double)? = null,
    ): Long {
        generation++
        selection = null
        pending = Pending(generation, before, channel, revision, sampledCurve, isHdr, parametricEvaluator)
        return generation
    }

    fun move(delta: Float): ToneCurveSettings? {
        val active = pending ?: return null
        if (!delta.isFinite() || active.released) return null
        active.delta = delta
        return active.drag?.value(delta)
    }

    fun accumulateReleased(delta: Float) {
        val active = pending ?: return
        if (active.released && active.drag == null && delta.isFinite() && (active.delta + delta).isFinite()) {
            active.delta += delta
        }
    }

    fun accept(sample: HslTargetSample, token: Long, current: HslTargetRevision?): ToneCurveSettings? {
        val active = pending?.takeIf { it.token == token } ?: return null
        if (active.revision != current || sample.revision != active.revision) {
            pending = null; selection = null; return null
        }
        selection = sample
        val drag = CurveTargetDrag.create(
            active.before, active.channel, sample, active.sampledCurve, active.isHdr, active.parametricEvaluator,
        )
        if (drag == null) {
            pending = null; return null
        }
        active.drag = drag
        if (active.released) pending = null
        return drag.value(active.delta)
    }

    fun end() {
        if (pending?.drag != null) pending = null else pending?.released = true
    }

    fun cancel(): ToneCurveSettings? {
        val before = pending?.takeIf { it.drag != null }?.before
        pending = null
        selection = null
        return before
    }
}
