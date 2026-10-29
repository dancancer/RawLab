package com.rawlab.android.adjustments

import com.rawlab.android.settings.*

data class AdjustmentTransferContext(val identifier: String, val isRaw: Boolean,
    val availableLookIDs: Set<String> = emptySet(), val builtinLookIDs: Map<String, String> = emptyMap(),
    val cameraTemperature: Float? = null, val cameraTint: Float? = null, val defaultExposureMode: Int = 1,
    val hasUncommittedDraft: Boolean = false, val validateLens: ((LensSettings) -> Unit)? = null)

object AdjustmentTransfer {
    fun sameAdjustments(left: EditSettings, right: EditSettings, isRaw: Boolean): Boolean {
        if (left.isHDREditing || right.isHDREditing) {
            return left.synchronizeHDR() == right.synchronizeHDR()
        }
        val context = AdjustmentTransferContext("comparison", isRaw)
        return left.processing == right.processing && left.masterRecipeSettingsVersion == right.masterRecipeSettingsVersion &&
            AdjustmentTransferValues.values(left, context) == AdjustmentTransferValues.values(right, context)
    }
    fun capture(scope: AdjustmentScope, settings: EditSettings, context: AdjustmentTransferContext): AdjustmentPayload {
        if (context.hasUncommittedDraft) throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        if (settings.isHDREditing) return captureHDR(scope, settings.synchronizeHDR(), context)
        val original = AdjustmentTransferValues.values(settings, context)
        val defaults = AdjustmentTransferValues.values(EditSettings(exposureMode = if (context.isRaw) context.defaultExposureMode else 2), context)
        val selected = when (scope) {
            AdjustmentScope.All -> AdjustmentField.entries.filterTo(linkedSetOf()) { !it.isHDRRelative }
            AdjustmentScope.Modified -> AdjustmentField.COMMON.filterTo(linkedSetOf()) { original[it] != defaults[it] }
            is AdjustmentScope.Custom -> scope.fields
        }
        return AdjustmentPayload(AdjustmentSource(context.identifier, context.isRaw, settings.processing.version,
            recipe(settings)), original.filterKeys { it in selected })
    }

    fun prepare(payload: AdjustmentPayload, target: EditSettings, context: AdjustmentTransferContext): EditSettings {
        return try {
            if(context.hasUncommittedDraft)throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
            if (target.isHDREditing) prepareHDR(payload, target, context) else {
                val legacy=if(payload.source.isHDR) {
                    payload.validate()
                    if(payload.fields.any {it.isHDRRelative})throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.relative_white_balance")
                    AdjustmentPayload(payload.source.copy(hdrProcessingVersion=null),payload.values)
                } else payload
                prepareChecked(legacy, target, context)
            }
        } catch (error: AdjustmentTransferException) { throw error }
          catch (error: IllegalArgumentException) { throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, error.message.orEmpty()) }
    }

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
            fullRecipe = kind == "recipe" && selected.containsAll(AdjustmentField.recipeDependencies(payload.source.recipe?.settingsVersion ?: 3))
            result = if (fullRecipe) result.copy(recipeID = id, film = "neutral", masterRecipeSettingsVersion = payload.source.recipe!!.settingsVersion)
            else result.copy(recipeID = null, masterRecipeSettingsVersion = 3, film = when (kind) {
                "neutral" -> "neutral"
                "recipe", "recipe_lut" -> "recipe-lut:$id"
                "managed" -> id!!
                else -> context.builtinLookIDs[id] ?: throw AdjustmentTransferException(AdjustmentFailure.MISSING_LOOK, lookup)
            })
        }
        payload[AdjustmentField.STRENGTH]?.number?.let { result = result.copy(strength = it.toFloat()) }
        val contextChanged = result.recipeID != target.recipeID || result.recipeScale != target.recipeScale ||
            result.masterRecipeSettingsVersion != target.masterRecipeSettingsVersion
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
                result = if (fullRecipe)
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
        result = AdjustmentTransferRefinement.apply(payload, target, result, fullRecipe)
        val actual = effectiveNumbers(result)
        for (field in numericFields) if (actual[field] != expected(field)) throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, field.id)
        return if (AdjustmentTransferValues.values(result, context) == originalValues && result.masterRecipeSettingsVersion == target.masterRecipeSettingsVersion) target else result
    }

    internal fun recipe(settings: EditSettings) = settings.recipeID?.let { AdjustmentRecipeContext(it, settings.strength.toDouble(), settings.masterRecipeSettingsVersion) }
    fun effectiveNumbers(s: EditSettings): Map<AdjustmentField, Float> = buildMap {
        put(AdjustmentField.STRENGTH, s.strength); put(AdjustmentField.EXPOSURE, s.exposure * s.recipeScale)
        put(AdjustmentField.CONTRAST, 1f + s.contrast * s.recipeScale); put(AdjustmentField.HIGHLIGHTS, -s.highlights * s.recipeScale)
        put(AdjustmentField.SHADOWS, s.shadows * s.recipeScale); put(AdjustmentField.S_CURVE, (s.toneCurve * s.refinementScale).coerceIn(-1f, 1f))
        put(AdjustmentField.SATURATION, 1f + s.saturation * s.recipeScale); put(AdjustmentField.SHARPENING, s.sharpening)
        put(AdjustmentField.BLACK_POINT, s.renderBlackPoint); put(AdjustmentField.WHITE_POINT, s.renderWhitePoint)
        put(AdjustmentField.VIBRANCE, s.renderVibrance)
        put(AdjustmentField.CLARITY, s.renderClarity)
        put(AdjustmentField.DEHAZE, s.renderDehaze)
        for (field in AdjustmentField.entries) field.hslLocation?.let { (axis, channel) -> put(field, s.renderHsl.value(axis, channel)) }
    }.mapValues { it.value.canonicalZero() }
    internal fun sourceEffective(value: Double, field: AdjustmentField, recipe: AdjustmentRecipeContext?): Double {
        val scale = recipe?.strength ?: 1.0
        if (field.hslLocation != null) return (value * if ((recipe?.settingsVersion ?: 2) >= 3) scale else 1.0).coerceIn(-100.0, 100.0)
        if (field == AdjustmentField.CONTRAST || field == AdjustmentField.SATURATION) return 1 + (value - 1) * scale
        if ((recipe?.settingsVersion ?: 3) >= 4 && field in AdjustmentField.REFINEMENT_SCALARS) {
            val limit = if (field == AdjustmentField.S_CURVE) 1.0 else 100.0
            return (value * scale).coerceIn(-limit, limit)
        }
        return if (field in AdjustmentTransferValues.scaled) value * scale else value
    }
    private fun assignEffective(settings: EditSettings, field: AdjustmentField, value: Float): EditSettings {
        val scaled = field in AdjustmentTransferValues.scaled || field.hslLocation != null && settings.masterRecipeSettingsVersion >= 3 ||
            settings.masterRecipeSettingsVersion >= 4 && field in AdjustmentField.REFINEMENT_SCALARS
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

    private fun captureHDR(scope: AdjustmentScope, settings: EditSettings, context: AdjustmentTransferContext): AdjustmentPayload {
        if (context.isRaw) throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "hdr.source")
        val values = hdrValues(settings)
        val defaults = hdrValues(EditSettings().withHDRMode(true, true))
        val selected = when (scope) {
            AdjustmentScope.All -> AdjustmentField.HDR_SUPPORTED
            AdjustmentScope.Modified -> AdjustmentField.HDR_COMMON.filterTo(linkedSetOf()) { values[it] != defaults[it] }
            is AdjustmentScope.Custom -> scope.fields
        }
        if (selected.isEmpty()) throw AdjustmentTransferException(AdjustmentFailure.EMPTY_SCOPE)
        return AdjustmentPayload(AdjustmentSource(context.identifier, isRaw = false,
            processingVersion = settings.processing.version, recipe = null, hdrProcessingVersion = 1),
            values.filterKeys { it in selected })
    }

    private fun prepareHDR(payload: AdjustmentPayload, target: EditSettings, context: AdjustmentTransferContext): EditSettings {
        if (context.isRaw || !target.isHDREditing) throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "hdr.target")
        payload.validate()
        if(!AdjustmentField.HDR_SUPPORTED.containsAll(payload.fields))
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.fields")
        var result = target.synchronizeHDR()
        var hdr = result.hdr ?: throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "hdr.target")
        fun number(field: AdjustmentField): Double? = payload[field]?.number
        number(AdjustmentField.EXPOSURE)?.let { result = result.copy(exposure = it.toFloat()); hdr = hdr.copy(exposure = it.toFloat()) }
        number(AdjustmentField.CONTRAST)?.let { result = result.copy(contrast = (it - 1).toFloat()); hdr = hdr.copy(contrast = ((it - 1) * 100).toFloat()) }
        number(AdjustmentField.HIGHLIGHTS)?.let { result = result.copy(highlights = (-it).toFloat()); hdr = hdr.copy(highlights = (-it * 100).toFloat()) }
        number(AdjustmentField.SHADOWS)?.let { result = result.copy(shadows = it.toFloat()); hdr = hdr.copy(shadows = (it * 100).toFloat()) }
        number(AdjustmentField.SATURATION)?.let { result = result.copy(saturation = (it - 1).toFloat()); hdr = hdr.copy(saturation = ((it - 1) * 100).toFloat()) }
        number(AdjustmentField.HDR_TEMPERATURE)?.let { result = result.copy(temperature = it.toFloat()); hdr = hdr.copy(temperature = it.toFloat()) }
        number(AdjustmentField.HDR_TINT)?.let { result = result.copy(tint = it.toFloat()); hdr = hdr.copy(tint = it.toFloat()) }
        var geometry = result.geometry
        number(AdjustmentField.CROP_X)?.let { geometry = geometry.copy(cropX = it.toFloat()) }
        number(AdjustmentField.CROP_Y)?.let { geometry = geometry.copy(cropY = it.toFloat()) }
        number(AdjustmentField.CROP_WIDTH)?.let { geometry = geometry.copy(cropWidth = it.toFloat()) }
        number(AdjustmentField.CROP_HEIGHT)?.let { geometry = geometry.copy(cropHeight = it.toFloat()) }
        number(AdjustmentField.QUARTER_TURNS)?.let { geometry = geometry.copy(quarterTurns = it.toInt()) }
        payload[AdjustmentField.FLIP_HORIZONTAL]?.boolean?.let { geometry = geometry.copy(flipHorizontal = it) }
        payload[AdjustmentField.FLIP_VERTICAL]?.boolean?.let { geometry = geometry.copy(flipVertical = it) }
        number(AdjustmentField.STRAIGHTEN)?.let { geometry = geometry.copy(straightenDegrees = it.toFloat()) }
        number(AdjustmentField.PERSPECTIVE_HORIZONTAL)?.let { geometry = geometry.copy(perspectiveHorizontal = it.toFloat()) }
        number(AdjustmentField.PERSPECTIVE_VERTICAL)?.let { geometry = geometry.copy(perspectiveVertical = it.toFloat()) }
        result = result.copy(geometry = geometry, hdr = hdr.copy(geometry = geometry)).synchronizeHDR()
        return result
    }

    private fun hdrValues(settings: EditSettings): Map<AdjustmentField, AdjustmentValue> = buildMap {
        put(AdjustmentField.EXPOSURE, AdjustmentValue.Number(settings.exposure.toDouble()))
        val hdr = settings.hdr ?: throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "hdr.settings")
        put(AdjustmentField.CONTRAST, AdjustmentValue.Number(1.0 + hdr.contrast / 100.0))
        put(AdjustmentField.HIGHLIGHTS, AdjustmentValue.Number(-hdr.highlights / 100.0))
        put(AdjustmentField.SHADOWS, AdjustmentValue.Number(hdr.shadows / 100.0))
        put(AdjustmentField.SATURATION, AdjustmentValue.Number(1.0 + hdr.saturation / 100.0))
        put(AdjustmentField.HDR_TEMPERATURE, AdjustmentValue.Number(hdr.temperature.toDouble()))
        put(AdjustmentField.HDR_TINT, AdjustmentValue.Number(hdr.tint.toDouble()))
        val geometry = hdr.geometry
        put(AdjustmentField.CROP_X, AdjustmentValue.Number(geometry.cropX.toDouble()))
        put(AdjustmentField.CROP_Y, AdjustmentValue.Number(geometry.cropY.toDouble()))
        put(AdjustmentField.CROP_WIDTH, AdjustmentValue.Number(geometry.cropWidth.toDouble()))
        put(AdjustmentField.CROP_HEIGHT, AdjustmentValue.Number(geometry.cropHeight.toDouble()))
        put(AdjustmentField.QUARTER_TURNS, AdjustmentValue.Number(geometry.quarterTurns.toDouble()))
        put(AdjustmentField.FLIP_HORIZONTAL, AdjustmentValue.Boolean(geometry.flipHorizontal))
        put(AdjustmentField.FLIP_VERTICAL, AdjustmentValue.Boolean(geometry.flipVertical))
        put(AdjustmentField.STRAIGHTEN, AdjustmentValue.Number(geometry.straightenDegrees.toDouble()))
        put(AdjustmentField.PERSPECTIVE_HORIZONTAL, AdjustmentValue.Number(geometry.perspectiveHorizontal.toDouble()))
        put(AdjustmentField.PERSPECTIVE_VERTICAL, AdjustmentValue.Number(geometry.perspectiveVertical.toDouble()))
    }
}
