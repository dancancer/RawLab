package com.rawlab.android.adjustments

import com.rawlab.android.settings.*

data class AdjustmentTransferContext(val identifier: String, val isRaw: Boolean,
    val availableLookIDs: Set<String> = emptySet(), val builtinLookIDs: Map<String, String> = emptyMap(),
    val cameraTemperature: Float? = null, val cameraTint: Float? = null, val defaultExposureMode: Int = 1,
    val hasUncommittedDraft: Boolean = false, val validateLens: ((LensSettings) -> Unit)? = null)

object AdjustmentTransfer {
    fun sameAdjustments(left: EditSettings, right: EditSettings, isRaw: Boolean): Boolean {
        val context = AdjustmentTransferContext("comparison", isRaw)
        return left.processing == right.processing && AdjustmentTransferValues.values(left, context) == AdjustmentTransferValues.values(right, context)
    }
    fun capture(scope: AdjustmentScope, settings: EditSettings, context: AdjustmentTransferContext): AdjustmentPayload {
        if (context.hasUncommittedDraft) throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        val original = AdjustmentTransferValues.values(settings, context)
        val defaults = AdjustmentTransferValues.values(EditSettings(exposureMode = if (context.isRaw) context.defaultExposureMode else 2), context)
        val selected = when (scope) {
            AdjustmentScope.All -> AdjustmentField.entries.toSet()
            AdjustmentScope.Modified -> AdjustmentField.COMMON.filterTo(linkedSetOf()) { original[it] != defaults[it] }
            is AdjustmentScope.Custom -> scope.fields
        }
        return AdjustmentPayload(AdjustmentSource(context.identifier, context.isRaw, settings.processing.version,
            recipe(settings)), original.filterKeys { it in selected })
    }

    fun prepare(payload: AdjustmentPayload, target: EditSettings, context: AdjustmentTransferContext): EditSettings = try {
        prepareChecked(payload, target, context)
    } catch (error: AdjustmentTransferException) { throw error }
      catch (error: IllegalArgumentException) { throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, error.message.orEmpty()) }

    private fun prepareChecked(payload: AdjustmentPayload, target: EditSettings, context: AdjustmentTransferContext): EditSettings {
        if (context.hasUncommittedDraft) throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        payload.validate()
        var result = target
        val before = effectiveNumbers(target)
        val originalValues = AdjustmentTransferValues.values(target, context)
        val selected = payload.fields
        var fullRecipe = false
        payload[AdjustmentField.LOOK]?.objectValue?.let { look ->
            val kind = look["kind"]!!.text!!; val id = look["id"]!!.text
            val lookup = when (kind) { "recipe_lut" -> "recipe:$id"; "managed" -> id!!; else -> "$kind:${id.orEmpty()}" }
            if (kind != "neutral" && lookup !in context.availableLookIDs) throw AdjustmentTransferException(AdjustmentFailure.MISSING_LOOK, lookup)
            fullRecipe = kind == "recipe" && selected.containsAll(AdjustmentField.RECIPE_DEPENDENCIES)
            result = if (fullRecipe) result.copy(recipeID = id, film = "neutral") else result.copy(recipeID = null, film = when (kind) {
                "neutral" -> "neutral"
                "recipe", "recipe_lut" -> "recipe-lut:$id"
                "managed" -> id!!
                else -> context.builtinLookIDs[id] ?: throw AdjustmentTransferException(AdjustmentFailure.MISSING_LOOK, lookup)
            })
        }
        payload[AdjustmentField.STRENGTH]?.number?.let { result = result.copy(strength = it.toFloat()) }
        val contextChanged = result.recipeID != target.recipeID || result.recipeScale != target.recipeScale
        val numericFields = AdjustmentTransferValues.scalars - AdjustmentField.STRENGTH +
            AdjustmentField.entries.filter { it.hslLocation != null }
        fun expected(field: AdjustmentField): Float {
            val value = payload[field]?.number ?: return before[field]!!
            // 相同逻辑值和配方上下文复用现有 Float 请求，避免把读取本身变成一个微小编辑。
            if (!contextChanged && context.isRaw == payload.source.isRaw && recipe(target) == payload.source.recipe &&
                payload[field] == originalValues[field]) return before[field]!!
            return sourceEffective(value, field, payload.source.recipe).toFloat()
        }
        for (field in numericFields) {
            val value = payload[field]?.number
            if (value != null) {
                result = if (fullRecipe && (field.hslLocation == null || payload.source.recipe?.settingsVersion == 3))
                    AdjustmentTransferValues.setLogical(result, field, value)
                else assignEffective(result, field, expected(field))
            } else if (contextChanged && effectiveNumbers(result)[field] != before[field]) {
                result = assignEffective(result, field, before[field]!!)
            }
        }
        for (field in numericFields) if (effectiveNumbers(result)[field] != expected(field)) {
            result = assignEffective(result, field, expected(field))
        }
        result = AdjustmentTransferWB.apply(payload, target, result, context, fullRecipe, contextChanged)
        payload[AdjustmentField.EXPOSURE_MODE]?.text?.let { mode ->
            if (!context.isRaw && payload.source.isRaw && mode != "sensor") throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, AdjustmentField.EXPOSURE_MODE.id)
            result = result.copy(exposureMode = listOf("scene", "preview", "sensor").indexOf(mode))
        }
        result = AdjustmentTransferValues.applyObjects(payload, result, context)
        val actual = effectiveNumbers(result)
        for (field in numericFields) if (actual[field] != expected(field)) throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, field.id)
        return if (AdjustmentTransferValues.values(result, context) == originalValues) target else result
    }

    internal fun recipe(settings: EditSettings) = settings.recipeID?.let { AdjustmentRecipeContext(it, settings.strength.toDouble()) }
    fun effectiveNumbers(s: EditSettings): Map<AdjustmentField, Float> = buildMap {
        put(AdjustmentField.STRENGTH, s.strength); put(AdjustmentField.EXPOSURE, s.exposure * s.recipeScale)
        put(AdjustmentField.CONTRAST, 1f + s.contrast * s.recipeScale); put(AdjustmentField.HIGHLIGHTS, -s.highlights * s.recipeScale)
        put(AdjustmentField.SHADOWS, s.shadows * s.recipeScale); put(AdjustmentField.S_CURVE, s.toneCurve)
        put(AdjustmentField.SATURATION, 1f + s.saturation * s.recipeScale); put(AdjustmentField.SHARPENING, s.sharpening)
        for (field in AdjustmentField.entries) field.hslLocation?.let { (axis, channel) -> put(field, s.renderHsl.value(axis, channel)) }
    }
    internal fun sourceEffective(value: Double, field: AdjustmentField, recipe: AdjustmentRecipeContext?): Double {
        val scale = recipe?.strength ?: 1.0
        if (field.hslLocation != null) return (value * if ((recipe?.settingsVersion ?: 2) >= 3) scale else 1.0).coerceIn(-100.0, 100.0)
        if (field == AdjustmentField.CONTRAST || field == AdjustmentField.SATURATION) return 1 + (value - 1) * scale
        return if (field in AdjustmentTransferValues.scaled) value * scale else value
    }
    private fun assignEffective(settings: EditSettings, field: AdjustmentField, value: Float): EditSettings {
        val scaled = field in AdjustmentTransferValues.scaled || field.hslLocation != null
        val identity = if (field == AdjustmentField.CONTRAST || field == AdjustmentField.SATURATION) 1.0 else 0.0
        val scale = settings.recipeScale.toDouble()
        if (scaled && scale == 0.0 && value.toDouble() != identity) throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, field.id)
        val logical = if (!scaled) value.toDouble() else if (scale == 0.0) identity else identity + (value - identity) / scale
        val candidate = AdjustmentTransferValues.setLogical(settings, field, logical)
        if (effectiveNumbers(candidate)[field] == value) return candidate
        // 反解后只尝试相邻的本端 Float 表示；只有实际 JNI 请求完全一致才接受。
        val native = (AdjustmentTransferValues.logical(candidate, field) - identity).toFloat()
        for (neighbor in listOf(Math.nextDown(native), Math.nextUp(native))) {
            val alternative = runCatching { AdjustmentTransferValues.setLogical(settings, field, identity + neighbor.toDouble()) }.getOrNull()
            if (alternative != null && effectiveNumbers(alternative)[field] == value) return alternative
        }
        throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, field.id)
    }
}
