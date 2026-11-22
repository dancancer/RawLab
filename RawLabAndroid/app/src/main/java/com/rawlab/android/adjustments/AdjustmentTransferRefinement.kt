package com.rawlab.android.adjustments

import com.rawlab.android.settings.*
import kotlin.math.abs

internal object AdjustmentTransferRefinement {
    fun apply(payload: AdjustmentPayload, original: EditSettings, target: EditSettings, fullRecipe: Boolean): EditSettings {
        val sourceScale = if ((payload.source.recipe?.settingsVersion ?: 3) >= 4) payload.source.recipe!!.strength else 1.0
        val selectedCurve = payload[AdjustmentField.CURVE]?.let(AdjustmentPayload::curve)
        val selectedApply = payload[AdjustmentField.CURVE_APPLY_TO_LUMINOSITY]?.boolean
        val selectedParametric = payload[AdjustmentField.CURVE_PARAMETRIC]?.let(AdjustmentPayload::parametricCurve)
        val baseDesiredCurve = selectedCurve?.scaled(sourceScale) ?: original.renderCurve
        val desiredCurve = ToneCurveSettings(
            baseDesiredCurve.mode,
            baseDesiredCurve.points,
            baseDesiredCurve.channels,
            selectedApply ?: original.renderCurve.applyToLuminosity,
            selectedParametric?.scaled(sourceScale) ?: original.renderCurve.parametric,
        )
        var curve = if (fullRecipe && selectedCurve != null) {
            ToneCurveSettings(
                selectedCurve.mode,
                selectedCurve.points,
                selectedCurve.channels,
                selectedApply ?: original.curve.applyToLuminosity,
                selectedParametric ?: original.curve.parametric,
            )
        } else {
            ToneCurveSettings(
                original.curve.mode,
                original.curve.points,
                original.curve.channels,
                selectedApply ?: original.curve.applyToLuminosity,
                selectedParametric ?: original.curve.parametric,
            )
        }
        if (!equivalent(curve.scaled(target.refinementScale), desiredCurve))
            curve = logicalCurve(desiredCurve, target.refinementScale.toDouble())
        if (!equivalent(curve.scaled(target.refinementScale), desiredCurve)) unrepresentable(AdjustmentField.CURVE)
        var grading = original.colorGrading
        fun wheelFromObject(selected: Map<String, AdjustmentValue>): ColorGradingWheel = ColorGradingWheel.fromNumbers(
            selected["hue"]!!.number!!,
            selected["saturation"]!!.number!!,
            selected["luminance"]?.number ?: 0.0,
        )
        fun desiredWheel(selected: Map<String, AdjustmentValue>?, fallback: ColorGradingWheel): ColorGradingWheel =
            if (selected == null) fallback else ColorGradingWheel.fromNumbers(
                selected["hue"]!!.number!!,
                (selected["saturation"]!!.number!! * sourceScale).coerceIn(0.0, 100.0),
                ((selected["luminance"]?.number ?: 0.0) * sourceScale).coerceIn(-100.0, 100.0),
            )
        for (field in AdjustmentField.REFINEMENT_OBJECTS) {
            val zone = field.gradingZone ?: continue
            val selected = payload[field]?.objectValue
            val desired = desiredWheel(selected, original.renderColorGrading[zone])
            val current = if (fullRecipe && selected != null) wheelFromObject(selected) else grading[zone]
            val logical = if (scaled(current, target.refinementScale) == desired) current else logicalWheel(desired, target.refinementScale, field)
            grading = grading.with(zone, logical)
        }
        val selectedGlobal = payload[AdjustmentField.GRADING_GLOBAL]?.objectValue
        val desiredGlobal = desiredWheel(selectedGlobal, original.renderColorGrading.global)
        val currentGlobal = if (fullRecipe && selectedGlobal != null) wheelFromObject(selectedGlobal) else grading.global
        val logicalGlobal = if (scaled(currentGlobal, target.refinementScale) == desiredGlobal) currentGlobal
            else logicalWheel(desiredGlobal, target.refinementScale, AdjustmentField.GRADING_GLOBAL)
        grading = grading.copy(
            global = logicalGlobal,
            blending = payload[AdjustmentField.GRADING_BLENDING]?.number?.toFloat() ?: grading.blending,
            balance = payload[AdjustmentField.GRADING_BALANCE]?.number?.toFloat() ?: grading.balance,
        )
        return target.copy(curve = curve, colorGrading = grading)
    }

    private fun logicalCurve(desired: ToneCurveSettings, strength: Double): ToneCurveSettings {
        if (desired.isDefault || strength == 0.0 && desired.isIdentity) return desired
        if (strength == 0.0) unrepresentable(AdjustmentField.CURVE)
        val scaledShape = ToneCurveChannel.entries.fold(desired) { result, channel ->
            val shape = desired.shape(channel)
            if (shape.mode == ToneCurveMode.LEGACY) result else result.replacing(channel,
                ToneCurveShape(ToneCurveMode.CUSTOM, shape.points.map { ToneCurvePoint(it.x, it.x + (it.y - it.x) / strength) }))
        }
        val p = desired.parametric
        val logicalParametric = if (p.isIdentity || strength == 1.0) p else {
            val h = p.highlights / strength
            val l = p.lights / strength
            val d = p.darks / strength
            val s = p.shadows / strength
            if (listOf(h, l, d, s).any { !it.isFinite() || it !in -100.0..100.0 }) unrepresentable(AdjustmentField.CURVE_PARAMETRIC)
            ToneCurveParametric(h, l, d, s, p.splitShadow, p.splitMidtone, p.splitHighlight)
        }
        return ToneCurveSettings(scaledShape.mode, scaledShape.points, scaledShape.channels, desired.applyToLuminosity, logicalParametric)
    }

    private fun logicalWheel(desired: ColorGradingWheel, strength: Float, field: AdjustmentField): ColorGradingWheel {
        if (strength == 0f) {
            if (!desired.isIdentity) unrepresentable(field)
            return desired
        }
        val sat = (desired.saturation.toDouble() / strength.toDouble()).toFloat()
        val lum = (desired.luminance.toDouble() / strength.toDouble()).toFloat()
        val satCandidates = listOf(sat, Math.nextDown(sat), Math.nextUp(sat)).filter { it in 0f..100f }
        val lumCandidates = listOf(lum, Math.nextDown(lum), Math.nextUp(lum)).filter { it in -100f..100f }
        for (sc in satCandidates) {
            for (lc in lumCandidates) {
                val value = desired.copy(saturation = sc.canonicalZero(), luminance = lc.canonicalZero())
                if (scaled(value, strength) == desired) return value
            }
        }
        unrepresentable(field)
    }

    private fun scaled(value: ColorGradingWheel, strength: Float) = value.scaled(strength)
    private fun equivalent(a: ToneCurveSettings, b: ToneCurveSettings) =
        a.applyToLuminosity == b.applyToLuminosity &&
        a.parametric.splitShadow == b.parametric.splitShadow &&
        a.parametric.splitMidtone == b.parametric.splitMidtone &&
        a.parametric.splitHighlight == b.parametric.splitHighlight &&
        abs(a.parametric.highlights - b.parametric.highlights) <= 1e-12 &&
        abs(a.parametric.lights - b.parametric.lights) <= 1e-12 &&
        abs(a.parametric.darks - b.parametric.darks) <= 1e-12 &&
        abs(a.parametric.shadows - b.parametric.shadows) <= 1e-12 &&
        ToneCurveChannel.entries.all { channel ->
            val first = a.shape(channel); val second = b.shape(channel)
            first.mode == second.mode && (first.isIdentity && second.isIdentity || first.points.size == second.points.size &&
                first.points.zip(second.points).all { it.first.x == it.second.x && abs(it.first.y - it.second.y) <= 1e-12 })
        }
    private fun unrepresentable(field: AdjustmentField): Nothing = throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, field.id)
}
