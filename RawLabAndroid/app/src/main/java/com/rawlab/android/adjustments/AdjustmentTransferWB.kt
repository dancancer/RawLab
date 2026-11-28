package com.rawlab.android.adjustments

import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.*

internal object AdjustmentTransferWB {
    private data class Resolved(val camera: Boolean, val temperature: Float = 6500f, val tint: Float = 0f)
    private fun camera(context: AdjustmentTransferContext): Resolved {
        var temperature = context.cameraTemperature
        var tint = context.cameraTint
        if (temperature == null || tint == null) {
            val resolved = context.cameraWhiteBalanceProvider?.invoke()
            if (resolved != null) {
                temperature = resolved.first
                tint = resolved.second
            }
        }
        if (temperature == null || tint == null || !temperature.isFinite() || !tint.isFinite() ||
            temperature !in 2000f..50000f || tint !in -150f..150f)
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "target camera white balance unavailable")
        return Resolved(false, nativeRound(temperature), nativeRound(tint))
    }
    private fun render(settings: EditSettings, context: AdjustmentTransferContext): Resolved {
        val effective = settings.effectiveFor(if (context.isRaw) PhotoInputKind.RAW else PhotoInputKind.RASTER)
        val calibration = if (context.isRaw && effective.recipeID != null && (effective.customWb || effective.tint * effective.strength != 0f)) {
            camera(context)
        } else null
        val values = settings.resetRenderValues(
            if (context.isRaw) PhotoInputKind.RAW else PhotoInputKind.RASTER,
            calibration?.temperature ?: context.cameraTemperature,
            calibration?.tint ?: context.cameraTint,
        ) ?: throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "target camera white balance unavailable")
        return Resolved(values.core[8] == 0f, values.core[9], values.core[10])
    }
    private fun representable(condition: Boolean, field: String = "color.white_balance") {
        if (!condition) throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, field)
    }
    private fun resolved(cameraMode: Boolean, temperature: Double?, tint: Double, relative: Boolean,
        recipe: AdjustmentRecipeContext?, context: AdjustmentTransferContext): Resolved {
        if (!context.isRaw) return Resolved(true)
        val tintFloat = tint.toFloat().canonicalZero()
        val offset = if (relative) tintFloat * (recipe?.strength?.toFloat()?.canonicalZero() ?: 1f) else tintFloat
        if (cameraMode && offset == 0f) return Resolved(true)
        val calibration = if (cameraMode || relative) camera(context) else null
        val finalTint = if (relative) calibration!!.tint + offset else offset
        representable(finalTint in -150f..150f, AdjustmentField.TINT.id)
        return Resolved(false, if (cameraMode) calibration!!.temperature else temperature!!.toFloat(), finalTint)
    }
    private fun applyResolved(
        desired: Resolved,
        original: EditSettings,
        context: AdjustmentTransferContext,
        preferredTint: Float? = null,
    ): EditSettings {
        if (desired.camera) return if (render(original, context) == desired) original else original.copy(customWb = false, temperature = 6500f, tint = 0f)
        var result = original.copy(customWb = true, temperature = desired.temperature)
        if (result.recipeID == null) result = result.copy(tint = desired.tint) else {
            val delta = desired.tint.toDouble() - camera(context).tint
            val scale = result.recipeScale.toDouble()
            representable(scale != 0.0 || delta == 0.0)
            if (render(result, context) != desired) {
                val preferred = preferredTint?.let { tint ->
                    runCatching { result.copy(tint = tint.canonicalZero()) }.getOrNull()
                }
                if (preferred != null && render(preferred, context) == desired) {
                    result = preferred
                } else {
                    val range = AdjustmentField.TINT.spec.androidModel.floatRange!!
                    val logical = (if (scale == 0.0) 0f else (delta / scale).toFloat())
                        .coerceIn(range.start, range.endInclusive).canonicalZero()
                    val candidate = result.copy(tint = logical)
                    result = if (render(candidate, context) == desired) candidate else {
                        listOf(Math.nextDown(logical), Math.nextUp(logical)).mapNotNull {
                            runCatching { result.copy(tint = it.canonicalZero()) }.getOrNull()
                        }.firstOrNull { render(it, context) == desired } ?: candidate
                    }
                }
            }
        }
        representable(render(result, context) == desired)
        return result
    }

    fun apply(payload: AdjustmentPayload, target: EditSettings, original: EditSettings,
        context: AdjustmentTransferContext, fullRecipe: Boolean, contextChanged: Boolean): EditSettings {
        val selected = payload.fields.intersect(AdjustmentField.WHITE_BALANCE).toMutableSet()
        // 非 RAW 来源没有独立白平衡，none/null 占位值不覆盖 RAW 目标白平衡；配方相对 tint 仍跨 RAW 复用。
        if (!payload.source.isRaw && context.isRaw && (payload.source.recipe == null || AdjustmentField.TINT !in selected)) {
            selected.clear()
        }
        var result = original
        if (selected.isEmpty()) {
            if (context.isRaw && contextChanged && render(result, context) != render(target, context))
                result = applyResolved(render(target, context), result, context)
            return result
        }
        if (!context.isRaw && payload.source.isRaw) {
            // 完整配方保留可复用的默认相对 tint；单独 WB 请求仍只接受中性值。
            val recipeTint = payload.source.recipe?.id?.let { context.recipeTintDefaults[it]?.toDouble() }
            val defaultRecipeTint = fullRecipe && recipeTint != null && payload[AdjustmentField.TINT]?.number == recipeTint
            val neutral = selected.all { field -> when (field) {
                AdjustmentField.WHITE_BALANCE_MODE -> payload[field]?.text == "camera"
                AdjustmentField.TEMPERATURE -> payload[field] == AdjustmentValue.Null
                AdjustmentField.TINT -> if (payload.source.recipe == null) payload[field] == AdjustmentValue.Null
                    else payload[field]?.number == 0.0 || defaultRecipeTint
                else -> false
            } }
            if (!neutral) throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "color.white_balance")
            if (!fullRecipe) return result
        }
        val previousValues = AdjustmentTransferValues.values(target, context)
        if (!contextChanged && context.isRaw == payload.source.isRaw && AdjustmentTransfer.recipe(target) == payload.source.recipe &&
            selected.all { payload[it] == previousValues[it] }) return result
        val mode = payload[AdjustmentField.WHITE_BALANCE_MODE]?.text
        val temperature = payload[AdjustmentField.TEMPERATURE]
        val tint = payload[AdjustmentField.TINT]
        if (selected == AdjustmentField.WHITE_BALANCE) {
            if (!context.isRaw && !payload.source.isRaw) {
                val temp = temperature?.number?.toFloat()
                val t = tint?.number?.toFloat()
                return if (mode == "relative" && temp != null && t != null) {
                    result.copy(customWb = false, temperature = temp, tint = t)
                } else {
                    result.copy(customWb = false, temperature = 6500f, tint = 0f)
                }
            }
            val cameraMode = mode == "camera" || mode == "none" && payload.source.recipe != null
            val desired = resolved(cameraMode, temperature!!.number, tint!!.number ?: 0.0,
                payload.source.recipe != null || mode == "camera", payload.source.recipe, context)
            if (fullRecipe) {
                result = result.copy(customWb = mode == "temperature", temperature = temperature.number?.toFloat() ?: 6500f,
                    tint = tint.number?.toFloat() ?: 0f)
                if (context.isRaw && render(result, context) != desired) {
                    result = applyResolved(desired, result, context, tint.number?.toFloat())
                    if (cameraMode) result = result.copy(customWb = false)
                }
            } else if (context.isRaw) result = applyResolved(desired, result, context, tint.number?.toFloat())
            return result
        }
        if (!context.isRaw) {
            if (payload.source.isRaw) return result
            if (mode == "none") {
                if (temperature?.number != null || tint?.number != null) {
                    throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "select white balance mode with temperature/tint")
                }
                return result.copy(customWb = false, temperature = 6500f, tint = 0f)
            }
            return result.copy(
                customWb = false,
                temperature = temperature?.number?.toFloat() ?: result.temperature,
                tint = tint?.number?.toFloat() ?: result.tint,
            )
        }
        val cameraMode = mode?.let { it != "temperature" } ?: !target.customWb
        if (temperature != null && if (cameraMode) temperature != AdjustmentValue.Null else temperature.number == null)
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "select white balance mode with temperature")
        if (tint != null && if (cameraMode) tint.number != null && payload.source.recipe == null else tint == AdjustmentValue.Null)
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "select white balance mode with tint")
        val previous = render(target, context)
        val desired: Resolved
        if (cameraMode) {
            val offset = when {
                tint != null -> (tint.number?.toFloat() ?: 0f).canonicalZero() * (payload.source.recipe?.strength?.toFloat()?.canonicalZero() ?: 1f)
                target.recipeID != null -> target.tint * target.recipeScale
                !target.customWb -> 0f
                else -> previous.tint - camera(context).tint
            }
            if (temperature == null && target.customWb) representable(previous.temperature == camera(context).temperature, "unselected white balance temperature")
            desired = if (offset == 0f) Resolved(true) else {
                val calibration = camera(context)
                val finalTint = if (tint == null && target.recipeID == null && target.customWb) previous.tint else calibration.tint + offset
                representable(finalTint in -150f..150f, AdjustmentField.TINT.id)
                Resolved(false, calibration.temperature, finalTint)
            }
            if (result.recipeID == null && offset != 0f && mode == null && !contextChanged)
                throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "select white balance mode with relative tint")
            if (result.recipeID == null && offset != 0f && mode != null && tint == null)
                throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, "unselected white balance tint")
        } else {
            val fixedTemperature = temperature?.number?.toFloat() ?: if (previous.camera) camera(context).temperature else previous.temperature
            val fixedTint = tint?.number?.let { value ->
                val v = value.toFloat().canonicalZero()
                payload.source.recipe?.let { camera(context).tint + v * it.strength.toFloat().canonicalZero() } ?: v
            } ?: if (previous.camera) camera(context).tint else previous.tint
            representable(fixedTint in -150f..150f, AdjustmentField.TINT.id)
            desired = Resolved(false, fixedTemperature, fixedTint)
        }
        result = applyResolved(desired, result, context, tint?.number?.toFloat())
        if (cameraMode && result.recipeID != null) result = result.copy(customWb = false)
        if (!contextChanged) result = result.copy(temperature = if (temperature == null) target.temperature else result.temperature,
            tint = if (tint == null) target.tint else result.tint, customWb = if (mode == null) target.customWb else result.customWb)
        representable(render(result, context) == desired)
        return result
    }
}
