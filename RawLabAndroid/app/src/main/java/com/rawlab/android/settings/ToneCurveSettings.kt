package com.rawlab.android.settings

import com.rawlab.android.adjustments.AdjustmentFieldSpec
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

enum class ToneCurveMode(val id: String, val nativeValue: Int) { LEGACY("legacy", 0), CUSTOM("custom", 1) }
data class ToneCurvePoint(val x: Double, val y: Double)

class ToneCurveShape(val mode: ToneCurveMode = ToneCurveMode.LEGACY, points: List<ToneCurvePoint> = emptyList()) {
    val points: List<ToneCurvePoint> = java.util.Collections.unmodifiableList(points.map { ToneCurvePoint(it.x.canonicalZero(), it.y.canonicalZero()) })
    init {
        val validEndpoints = if (AdjustmentFieldSpec.SubFields.LightCurve.endpointsYUnpinned) {
            this.points.size in 2..33 && this.points.first().x == 0.0 && this.points.last().x == 1.0
        } else {
            this.points.size in 2..33 && this.points.first() == ToneCurvePoint(0.0, 0.0) &&
                this.points.last() == ToneCurvePoint(1.0, 1.0)
        }
        require(if (mode == ToneCurveMode.LEGACY) this.points.isEmpty() else
            validEndpoints &&
                this.points.all { it.x.isFinite() && it.y.isFinite() && it.x in 0.0..1.0 && it.y in 0.0..1.0 } &&
                this.points.zipWithNext().all { (a, b) -> a.x < b.x && a.y <= b.y })
    }
    val isDefault get() = mode == ToneCurveMode.LEGACY
    val isIdentity get() = isDefault || points.all { it.x == it.y }
    val hasUnpinnedEndpoints get() = mode == ToneCurveMode.CUSTOM && points.size >= 2 && (points.first().y != 0.0 || points.last().y != 1.0)
    val progress get() = points.maxOfOrNull { kotlin.math.abs(it.y - it.x) } ?: 0.0
    fun scaled(strength: Float): ToneCurveShape = scaled(strength.toDouble())
    fun scaled(strength: Double): ToneCurveShape {
        if (mode != ToneCurveMode.CUSTOM || strength == 1.0) return this
        if (strength == 0.0) return identity
        var previous = 0.0
        return ToneCurveShape(mode, points.map { point ->
            val y = (point.x + (point.y - point.x) * strength).coerceIn(previous, 1.0)
            previous = y
            ToneCurvePoint(point.x, y)
        })
    }
    fun packed() = points.flatMap { listOf(it.x, it.y) }.toDoubleArray()
    fun isInterior(index: Int) = mode == ToneCurveMode.CUSTOM && index > 0 && index + 1 < points.size
    fun inserting(x: Double, y: Double): ToneCurveShape {
        if (mode != ToneCurveMode.CUSTOM || points.size >= 33 || !x.isFinite() || !y.isFinite() ||
            x <= 0 || x >= 1 || points.any { it.x == x }) return this
        val next = points.indexOfFirst { it.x > x }
        return ToneCurveShape(mode, points.toMutableList().also {
            it.add(next, ToneCurvePoint(x, y.coerceIn(points[next - 1].y, points[next].y)))
        })
    }
    fun moving(index: Int, x: Double, y: Double): ToneCurveShape {
        if (!isInterior(index) || !x.isFinite() || !y.isFinite()) return this
        val low = Math.nextUp(points[index - 1].x); val high = Math.nextDown(points[index + 1].x)
        if (low > high) return this
        return ToneCurveShape(mode, points.toMutableList().also {
            it[index] = ToneCurvePoint(x.coerceIn(low, high), y.coerceIn(points[index - 1].y, points[index + 1].y))
        })
    }
    fun removing(index: Int) = if (!isInterior(index)) this else
        ToneCurveShape(mode, points.toMutableList().also { it.removeAt(index) })
    fun json(): JSONObject = JSONObject().put("mode", mode.id).put("points", JSONArray().also { array ->
        points.forEach { array.put(JSONArray(listOf(it.x, it.y))) }
    })
    override fun equals(other: Any?) = other is ToneCurveShape && mode == other.mode && points == other.points
    override fun hashCode() = 31 * mode.hashCode() + points.hashCode()
    companion object {
        val identity = ToneCurveShape(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.0, 0.0), ToneCurvePoint(1.0, 1.0)))
        fun decode(json: JSONObject): ToneCurveShape {
            require(json.keys().asSequence().toSet() == setOf("mode", "points"))
            val mode = ToneCurveMode.entries.single { it.id == json.get("mode") }
            val points = json.getJSONArray("points")
            require(points.length() <= 33)
            return ToneCurveShape(mode, (0 until points.length()).map { index ->
                val point = points.getJSONArray(index)
                require(point.length() == 2 && point.get(0) is Number && point.get(1) is Number)
                ToneCurvePoint((point.get(0) as Number).toDouble(), (point.get(1) as Number).toDouble())
            })
        }
    }
}

enum class ToneCurveChannel { RGB, RED, GREEN, BLUE }
data class ToneCurveChannels(
    val red: ToneCurveShape = ToneCurveShape(),
    val green: ToneCurveShape = ToneCurveShape(),
    val blue: ToneCurveShape = ToneCurveShape()
) {
    val isDefault get() = red.isDefault && green.isDefault && blue.isDefault
    val isIdentity get() = red.isIdentity && green.isIdentity && blue.isIdentity
    val hasUnpinnedEndpoints get() = red.hasUnpinnedEndpoints || green.hasUnpinnedEndpoints || blue.hasUnpinnedEndpoints
    val progress get() = maxOf(red.progress, green.progress, blue.progress)
    fun scaled(strength: Double) = ToneCurveChannels(red.scaled(strength), green.scaled(strength), blue.scaled(strength))
    fun json() = JSONObject().put("red", red.json()).put("green", green.json()).put("blue", blue.json())
    companion object {
        fun decode(json: JSONObject): ToneCurveChannels {
            require(json.keys().asSequence().all { it in setOf("red", "green", "blue") })
            fun shape(key: String) = if (json.has(key)) ToneCurveShape.decode(json.getJSONObject(key)) else ToneCurveShape()
            return ToneCurveChannels(shape("red"), shape("green"), shape("blue"))
        }
    }
}

data class ToneCurveParametric(
    val highlights: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault,
    val lights: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault,
    val darks: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault,
    val shadows: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault,
    val splitShadow: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.splitShadowDefault,
    val splitMidtone: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.splitMidtoneDefault,
    val splitHighlight: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.splitHighlightDefault,
) {
    init {
        val sub = AdjustmentFieldSpec.SubFields.LightCurveParametric
        require(listOf(highlights, lights, darks, shadows).all { it.isFinite() && it in sub.bandMin..sub.bandMax })
        require(splitShadow.isFinite() && splitShadow in sub.splitShadowMin..sub.splitShadowMax)
        require(splitMidtone.isFinite() && splitMidtone in sub.splitMidtoneMin..sub.splitMidtoneMax)
        require(splitHighlight.isFinite() && splitHighlight in sub.splitHighlightMin..sub.splitHighlightMax)
        require(splitShadow + sub.splitMinGap <= splitMidtone + 1e-12 && splitMidtone + sub.splitMinGap <= splitHighlight + 1e-12)
    }

    val isDefault get() =
        highlights == AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault &&
        lights == AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault &&
        darks == AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault &&
        shadows == AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault &&
        splitShadow == AdjustmentFieldSpec.SubFields.LightCurveParametric.splitShadowDefault &&
        splitMidtone == AdjustmentFieldSpec.SubFields.LightCurveParametric.splitMidtoneDefault &&
        splitHighlight == AdjustmentFieldSpec.SubFields.LightCurveParametric.splitHighlightDefault

    val isIdentity get() = highlights == 0.0 && lights == 0.0 && darks == 0.0 && shadows == 0.0
    val progress get() = maxOf(abs(highlights), abs(lights), abs(darks), abs(shadows)) / 100.0

    fun scaled(strength: Double): ToneCurveParametric {
        if (strength == 1.0) return this
        val sub = AdjustmentFieldSpec.SubFields.LightCurveParametric
        return copy(
            highlights = (highlights * strength).coerceIn(sub.bandMin, sub.bandMax).canonicalZero(),
            lights = (lights * strength).coerceIn(sub.bandMin, sub.bandMax).canonicalZero(),
            darks = (darks * strength).coerceIn(sub.bandMin, sub.bandMax).canonicalZero(),
            shadows = (shadows * strength).coerceIn(sub.bandMin, sub.bandMax).canonicalZero(),
        )
    }

    fun json(): JSONObject = JSONObject()
        .put("highlights", highlights.canonicalZero())
        .put("lights", lights.canonicalZero())
        .put("darks", darks.canonicalZero())
        .put("shadows", shadows.canonicalZero())
        .put("split_shadow", splitShadow)
        .put("split_midtone", splitMidtone)
        .put("split_highlight", splitHighlight)

    companion object {
        private val allowedKeys = setOf(
            "highlights", "lights", "darks", "shadows",
            "split_shadow", "split_midtone", "split_highlight",
        )

        fun decode(json: JSONObject): ToneCurveParametric {
            val keys = json.keys().asSequence().toSet()
            require(keys == allowedKeys) { "Invalid parametric curve fields" }
            fun number(key: String): Double {
                val value = json.get(key)
                require(value is Number)
                return value.toDouble().canonicalZero()
            }
            return ToneCurveParametric(
                highlights = number("highlights"),
                lights = number("lights"),
                darks = number("darks"),
                shadows = number("shadows"),
                splitShadow = number("split_shadow"),
                splitMidtone = number("split_midtone"),
                splitHighlight = number("split_highlight"),
            )
        }
    }
}

class ToneCurveSettings(
    val mode: ToneCurveMode = ToneCurveMode.LEGACY,
    points: List<ToneCurvePoint> = emptyList(),
    val channels: ToneCurveChannels = ToneCurveChannels(),
    val applyToLuminosity: Boolean = false,
    val parametric: ToneCurveParametric = ToneCurveParametric(),
) {
    val master = ToneCurveShape(mode, points)
    val points get() = master.points
    val isDefault get() = master.isDefault && channels.isDefault && !applyToLuminosity && parametric.isDefault
    val isIdentity get() = master.isIdentity && channels.isIdentity && parametric.isIdentity
    val hasChannelCurves get() = !channels.isDefault
    val hasV2Extensions get() = applyToLuminosity || !parametric.isDefault || master.hasUnpinnedEndpoints || channels.hasUnpinnedEndpoints
    val progress get() = maxOf(master.progress, channels.progress, parametric.progress)
    fun shape(channel: ToneCurveChannel) = when (channel) {
        ToneCurveChannel.RGB -> master; ToneCurveChannel.RED -> channels.red
        ToneCurveChannel.GREEN -> channels.green; ToneCurveChannel.BLUE -> channels.blue
    }
    fun replacing(channel: ToneCurveChannel, shape: ToneCurveShape): ToneCurveSettings = when (channel) {
        ToneCurveChannel.RGB -> ToneCurveSettings(shape.mode, shape.points, channels, applyToLuminosity, parametric)
        ToneCurveChannel.RED -> ToneCurveSettings(mode, points, channels.copy(red = shape), applyToLuminosity, parametric)
        ToneCurveChannel.GREEN -> ToneCurveSettings(mode, points, channels.copy(green = shape), applyToLuminosity, parametric)
        ToneCurveChannel.BLUE -> ToneCurveSettings(mode, points, channels.copy(blue = shape), applyToLuminosity, parametric)
    }
    fun scaled(strength: Float) = scaled(strength.toDouble())
    fun scaled(strength: Double): ToneCurveSettings {
        val next = master.scaled(strength)
        return ToneCurveSettings(next.mode, next.points, channels.scaled(strength), applyToLuminosity, parametric.scaled(strength))
    }
    fun packed() = master.packed()
    fun isInterior(index: Int) = master.isInterior(index)
    fun inserting(x: Double, y: Double) = replacing(ToneCurveChannel.RGB, master.inserting(x, y))
    fun moving(index: Int, x: Double, y: Double) = replacing(ToneCurveChannel.RGB, master.moving(index, x, y))
    fun removing(index: Int) = replacing(ToneCurveChannel.RGB, master.removing(index))
    fun json(): JSONObject = master.json().also {
        if (hasChannelCurves) it.put("channels", channels.json())
        if (applyToLuminosity) it.put("apply_to_luminosity", true)
        if (!parametric.isDefault) it.put("parametric", parametric.json())
    }
    override fun equals(other: Any?) = other is ToneCurveSettings &&
        master == other.master && channels == other.channels &&
        applyToLuminosity == other.applyToLuminosity && parametric == other.parametric
    override fun hashCode(): Int {
        var result = master.hashCode()
        result = 31 * result + channels.hashCode()
        result = 31 * result + applyToLuminosity.hashCode()
        result = 31 * result + parametric.hashCode()
        return result
    }
    companion object {
        val identity = ToneCurveSettings(ToneCurveMode.CUSTOM, ToneCurveShape.identity.points)
        fun decode(json: JSONObject): ToneCurveSettings {
            val keys = json.keys().asSequence().toSet()
            val allowed = setOf("mode", "points", "channels", "apply_to_luminosity", "parametric")
            require(keys.containsAll(setOf("mode", "points")) && keys.all { it in allowed })
            val master = ToneCurveShape.decode(JSONObject().put("mode", json.get("mode")).put("points", json.get("points")))
            val applyToLuminosity = if (json.has("apply_to_luminosity")) {
                val v = json.get("apply_to_luminosity")
                require(v is Boolean)
                v
            } else false
            val parametric = if (json.has("parametric")) {
                ToneCurveParametric.decode(json.getJSONObject("parametric"))
            } else ToneCurveParametric()
            return ToneCurveSettings(
                master.mode, master.points,
                if (json.has("channels")) ToneCurveChannels.decode(json.getJSONObject("channels")) else ToneCurveChannels(),
                applyToLuminosity, parametric,
            )
        }
    }
}
