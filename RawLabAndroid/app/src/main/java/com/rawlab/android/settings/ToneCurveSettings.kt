package com.rawlab.android.settings

import org.json.JSONArray
import org.json.JSONObject

enum class ToneCurveMode(val id: String, val nativeValue: Int) { LEGACY("legacy", 0), CUSTOM("custom", 1) }
data class ToneCurvePoint(val x: Double, val y: Double)

class ToneCurveSettings(val mode: ToneCurveMode = ToneCurveMode.LEGACY, points: List<ToneCurvePoint> = emptyList()) {
    val points: List<ToneCurvePoint> = java.util.Collections.unmodifiableList(points.map { ToneCurvePoint(it.x.canonicalZero(), it.y.canonicalZero()) })
    init {
        require(if (mode == ToneCurveMode.LEGACY) this.points.isEmpty() else
            this.points.size in 2..33 && this.points.first() == ToneCurvePoint(0.0, 0.0) &&
                this.points.last() == ToneCurvePoint(1.0, 1.0) &&
                this.points.all { it.x.isFinite() && it.y.isFinite() && it.x in 0.0..1.0 && it.y in 0.0..1.0 } &&
                this.points.zipWithNext().all { (a, b) -> a.x < b.x && a.y <= b.y })
    }
    val isDefault get() = mode == ToneCurveMode.LEGACY
    val isIdentity get() = isDefault || points.all { it.x == it.y }
    val progress get() = points.maxOfOrNull { kotlin.math.abs(it.y - it.x) } ?: 0.0
    fun packed() = points.flatMap { listOf(it.x, it.y) }.toDoubleArray()
    fun isInterior(index: Int) = mode == ToneCurveMode.CUSTOM && index > 0 && index + 1 < points.size
    fun inserting(x: Double, y: Double): ToneCurveSettings {
        if (mode != ToneCurveMode.CUSTOM || points.size >= 33 || !x.isFinite() || !y.isFinite() ||
            x <= 0 || x >= 1 || points.any { it.x == x }) return this
        val next = points.indexOfFirst { it.x > x }
        return ToneCurveSettings(mode, points.toMutableList().also {
            it.add(next, ToneCurvePoint(x, y.coerceIn(points[next - 1].y, points[next].y)))
        })
    }
    fun moving(index: Int, x: Double, y: Double): ToneCurveSettings {
        if (!isInterior(index) || !x.isFinite() || !y.isFinite()) return this
        val low = Math.nextUp(points[index - 1].x); val high = Math.nextDown(points[index + 1].x)
        if (low > high) return this
        return ToneCurveSettings(mode, points.toMutableList().also {
            it[index] = ToneCurvePoint(x.coerceIn(low, high), y.coerceIn(points[index - 1].y, points[index + 1].y))
        })
    }
    fun removing(index: Int) = if (!isInterior(index)) this else
        ToneCurveSettings(mode, points.toMutableList().also { it.removeAt(index) })
    fun json(): JSONObject = JSONObject().put("mode", mode.id).put("points", JSONArray().also { array ->
        points.forEach { array.put(JSONArray(listOf(it.x, it.y))) }
    })
    override fun equals(other: Any?) = other is ToneCurveSettings && mode == other.mode && points == other.points
    override fun hashCode() = 31 * mode.hashCode() + points.hashCode()
    companion object {
        val identity = ToneCurveSettings(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.0, 0.0), ToneCurvePoint(1.0, 1.0)))
        fun decode(json: JSONObject): ToneCurveSettings {
            require(json.keys().asSequence().toSet() == setOf("mode", "points"))
            val mode = ToneCurveMode.entries.single { it.id == json.get("mode") }
            val points = json.getJSONArray("points")
            require(points.length() <= 33)
            return ToneCurveSettings(mode, (0 until points.length()).map { index ->
                val point = points.getJSONArray(index)
                require(point.length() == 2 && point.get(0) is Number && point.get(1) is Number)
                ToneCurvePoint((point.get(0) as Number).toDouble(), (point.get(1) as Number).toDouble())
            })
        }
    }
}
