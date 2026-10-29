package com.rawlab.android.adjustments

import com.rawlab.android.settings.*
import kotlin.math.abs

internal object AdjustmentTransferRefinement {
    fun apply(payload: AdjustmentPayload, original: EditSettings, target: EditSettings, fullRecipe: Boolean): EditSettings {
        val sourceScale = if ((payload.source.recipe?.settingsVersion ?: 3) >= 4) payload.source.recipe!!.strength else 1.0
        val selectedCurve = payload[AdjustmentField.CURVE]?.let(AdjustmentPayload::curve)
        val desiredCurve = selectedCurve?.scaled(sourceScale) ?: original.renderCurve
        var curve = if (fullRecipe && selectedCurve != null) selectedCurve else original.curve
        if (!equivalent(curve.scaled(target.refinementScale), desiredCurve))
            curve = logicalCurve(desiredCurve, target.refinementScale.toDouble())
        if (!equivalent(curve.scaled(target.refinementScale), desiredCurve)) unrepresentable(AdjustmentField.CURVE)
        var grading = original.colorGrading
        for (field in AdjustmentField.REFINEMENT_OBJECTS) {
            val zone = field.gradingZone ?: continue
            val selected = payload[field]?.objectValue
            val desired = if (selected == null) original.renderColorGrading[zone] else ColorGradingWheel.fromNumbers(
                selected["hue"]!!.number!!, (selected["saturation"]!!.number!! * sourceScale).coerceIn(0.0, 100.0))
            val current = if (fullRecipe && selected != null)
                ColorGradingWheel.fromNumbers(selected["hue"]!!.number!!, selected["saturation"]!!.number!!) else grading[zone]
            val logical = if (scaled(current, target.refinementScale) == desired) current else logicalWheel(desired, target.refinementScale, field)
            grading = grading.with(zone, logical)
        }
        return target.copy(curve = curve, colorGrading = grading)
    }

    private fun logicalCurve(desired: ToneCurveSettings, strength: Double): ToneCurveSettings {
        if (desired.mode == ToneCurveMode.LEGACY || strength == 0.0 && desired.isIdentity) return desired
        if (strength == 0.0) unrepresentable(AdjustmentField.CURVE)
        return ToneCurveSettings(ToneCurveMode.CUSTOM, desired.points.map { ToneCurvePoint(it.x, it.x + (it.y - it.x) / strength) })
    }

    private fun logicalWheel(desired: ColorGradingWheel, strength: Float, field: AdjustmentField): ColorGradingWheel {
        if (strength == 0f) {
            if (!desired.isIdentity) unrepresentable(field)
            return desired
        }
        val amount = (desired.saturation.toDouble() / strength.toDouble()).toFloat()
        for (candidate in listOf(amount, Math.nextDown(amount), Math.nextUp(amount))) {
            if (candidate !in 0f..100f) continue
            val value = desired.copy(saturation = candidate)
            if (scaled(value, strength) == desired) return value
        }
        unrepresentable(field)
    }

    private fun scaled(value: ColorGradingWheel, strength: Float) = value.copy(saturation = (value.saturation * strength).coerceIn(0f, 100f))
    private fun equivalent(a: ToneCurveSettings, b: ToneCurveSettings) = a.mode == b.mode &&
        (a.isIdentity && b.isIdentity || a.points.size == b.points.size && a.points.zip(b.points).all {
            it.first.x == it.second.x && abs(it.first.y - it.second.y) <= 1e-12
        })
    private fun unrepresentable(field: AdjustmentField): Nothing = throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, field.id)
}
