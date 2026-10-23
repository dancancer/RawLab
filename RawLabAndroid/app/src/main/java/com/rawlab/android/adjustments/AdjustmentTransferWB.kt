package com.rawlab.android.adjustments

import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.*

internal object AdjustmentTransferWB {
    private data class Resolved(val camera: Boolean, val temperature: Float = 6500f, val tint: Float = 0f)
    private fun camera(context: AdjustmentTransferContext): Resolved {
        val temperature = context.cameraTemperature; val tint = context.cameraTint
        if (temperature == null || tint == null || !temperature.isFinite() || !tint.isFinite() ||
            temperature !in 2000f..50000f || tint !in -150f..150f)
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "target camera white balance unavailable")
        return Resolved(false, nativeRound(temperature), nativeRound(tint))
    }
    private fun render(settings: EditSettings, context: AdjustmentTransferContext): Resolved {
        val values = settings.resetRenderValues(if (context.isRaw) PhotoInputKind.RAW else PhotoInputKind.RASTER,
            context.cameraTemperature, context.cameraTint)
            ?: throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "target camera white balance unavailable")
        return Resolved(values.core[8] == 0f, values.core[9], values.core[10])
    }
    private fun representable(condition: Boolean, field: String = "color.white_balance") {
        if (!condition) throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, field)
    }
    private fun resolved(cameraMode: Boolean, temperature: Double?, tint: Double, relative: Boolean,
        recipe: AdjustmentRecipeContext?, sourceIsRaw: Boolean, context: AdjustmentTransferContext): Resolved {
        if (!context.isRaw || (!sourceIsRaw && recipe == null)) return Resolved(true)
        val offset = tint * if (relative) recipe?.strength ?: 1.0 else 1.0
        if (cameraMode && offset == 0.0) return Resolved(true)
        val calibration = if (cameraMode || relative) camera(context) else null
        val finalTint = if (relative) calibration!!.tint + offset else offset
        representable(finalTint in -150.0..150.0, AdjustmentField.TINT.id)
        return Resolved(false, if (cameraMode) calibration!!.temperature else temperature!!.toFloat(), finalTint.toFloat())
    }
    private fun applyResolved(desired: Resolved, original: EditSettings, context: AdjustmentTransferContext): EditSettings {
        if (desired.camera) return original.copy(customWb = false, temperature = 6500f, tint = 0f)
        var result = original.copy(customWb = true, temperature = desired.temperature)
        if (result.recipeID == null) result = result.copy(tint = desired.tint) else {
            val delta = desired.tint.toDouble() - camera(context).tint
            val scale = result.recipeScale.toDouble()
            representable(scale != 0.0 || delta == 0.0)
            val logical = if (scale == 0.0) 0f else (delta / scale).toFloat()
            result = result.copy(tint = logical)
            if (render(result, context) != desired) {
                val exact = listOf(Math.nextDown(logical), Math.nextUp(logical)).mapNotNull {
                    runCatching { result.copy(tint = it) }.getOrNull()
                }.firstOrNull { render(it, context) == desired }
                if (exact != null) result = exact
            }
        }
        representable(render(result, context) == desired)
        return result
    }

    fun apply(payload: AdjustmentPayload, target: EditSettings, original: EditSettings,
        context: AdjustmentTransferContext, fullRecipe: Boolean, contextChanged: Boolean): EditSettings {
        val selected = payload.fields.intersect(AdjustmentField.WHITE_BALANCE)
        var result = original
        if (selected.isEmpty()) {
            if (context.isRaw && contextChanged && render(result, context) != render(target, context))
                result = applyResolved(render(target, context), result, context)
            return result
        }
        if (!context.isRaw && payload.source.isRaw) throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "color.white_balance")
        val previousValues = AdjustmentTransferValues.values(target, context)
        if (!contextChanged && context.isRaw == payload.source.isRaw && AdjustmentTransfer.recipe(target) == payload.source.recipe &&
            selected.all { payload[it] == previousValues[it] }) return result
        val mode = payload[AdjustmentField.WHITE_BALANCE_MODE]?.text
        val temperature = payload[AdjustmentField.TEMPERATURE]
        val tint = payload[AdjustmentField.TINT]
        if (selected == AdjustmentField.WHITE_BALANCE) {
            val cameraMode = mode == "camera" || mode == "none" && payload.source.recipe != null
            val desired = resolved(cameraMode, temperature!!.number, tint!!.number ?: 0.0,
                payload.source.recipe != null || mode == "camera", payload.source.recipe, payload.source.isRaw, context)
            if (fullRecipe) {
                result = result.copy(customWb = mode == "temperature", temperature = temperature.number?.toFloat() ?: 6500f,
                    tint = tint.number?.toFloat() ?: 0f)
                if (context.isRaw && render(result, context) != desired) {
                    result = applyResolved(desired, result, context)
                    if (cameraMode) result = result.copy(customWb = false)
                }
            } else if (context.isRaw) result = applyResolved(desired, result, context)
            return result
        }
        if (!context.isRaw) return result
        val cameraMode = mode?.let { it != "temperature" } ?: !target.customWb
        if (temperature != null && if (cameraMode) temperature != AdjustmentValue.Null else temperature.number == null)
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "select white balance mode with temperature")
        if (tint != null && if (cameraMode) tint.number != null && payload.source.recipe == null else tint == AdjustmentValue.Null)
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "select white balance mode with tint")
        val previous = render(target, context)
        val desired: Resolved
        if (cameraMode) {
            val offset = when {
                tint != null -> (tint.number ?: 0.0) * (payload.source.recipe?.strength ?: 1.0)
                target.recipeID != null -> (target.tint * target.recipeScale).toDouble()
                !target.customWb -> 0.0
                else -> (previous.tint - camera(context).tint).toDouble()
            }
            if (temperature == null && target.customWb) representable(previous.temperature == camera(context).temperature, "unselected white balance temperature")
            desired = if (offset == 0.0) Resolved(true) else {
                val calibration = camera(context); val finalTint = calibration.tint + offset
                representable(finalTint in -150.0..150.0, AdjustmentField.TINT.id)
                Resolved(false, calibration.temperature, finalTint.toFloat())
            }
            if (result.recipeID == null && offset != 0.0 && mode == null && !contextChanged)
                throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "select white balance mode with relative tint")
            if (result.recipeID == null && offset != 0.0 && mode != null && tint == null)
                throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, "unselected white balance tint")
        } else {
            val fixedTemperature = temperature?.number?.toFloat() ?: if (previous.camera) camera(context).temperature else previous.temperature
            val fixedTint = tint?.number?.let { value ->
                payload.source.recipe?.let { camera(context).tint + value * it.strength } ?: value
            } ?: (if (previous.camera) camera(context).tint else previous.tint).toDouble()
            representable(fixedTint in -150.0..150.0, AdjustmentField.TINT.id)
            desired = Resolved(false, fixedTemperature, fixedTint.toFloat())
        }
        result = applyResolved(desired, result, context)
        if (cameraMode && result.recipeID != null) result = result.copy(customWb = false)
        if (!contextChanged) result = result.copy(temperature = if (temperature == null) target.temperature else result.temperature,
            tint = if (tint == null) target.tint else result.tint, customWb = if (mode == null) target.customWb else result.customWb)
        representable(render(result, context) == desired)
        return result
    }
}
