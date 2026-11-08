package com.rawlab.android.adjustments

import com.rawlab.android.settings.*
import java.io.File

data class AdjustmentTransferContext(val identifier: String, val isRaw: Boolean,
    val availableLookIDs: Set<String> = emptySet(), val builtinLookIDs: Map<String, String> = emptyMap(),
    val cameraTemperature: Float? = null, val cameraTint: Float? = null, val defaultExposureMode: Int = 1,
    val hasUncommittedDraft: Boolean = false, val validateLens: ((LensSettings) -> Unit)? = null,
    val sourceSupportsCameraHDR: Boolean = false, val sourceIsProRAW: Boolean = false, val hdrLookDirectory: File? = null,
    val validateHDRCamera: ((EditSettings) -> Unit)? = null, val recipeTintDefaults: Map<String, Float> = emptyMap()) {
    val supportsHDRCameraDevelopment get() = isRaw && sourceSupportsCameraHDR && !sourceIsProRAW
}

object AdjustmentTransfer {
    fun previewCapture(scope: AdjustmentScope, settings: EditSettings, committed: EditSettings,
        context: AdjustmentTransferContext): AdjustmentPayload {
        if (!sameAdjustments(settings, committed, context.isRaw)) throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        return capture(scope, committed, context)
    }

    fun captureHDRBatch(settings: EditSettings, context: AdjustmentTransferContext, targetIsHDR: Boolean): AdjustmentPayload {
        require(settings.isHDREditing)
        val active=settings.synchronizeHDR()
        val hdr = requireNotNull(active.hdr)
        val fields = AdjustmentField.hdrSupported(hdr.processingVersion).toMutableSet()
        if (!targetIsHDR) {
            if (hdr.temperature == 6500f && hdr.tint == 0f)
                fields.removeAll(setOf(AdjustmentField.HDR_TEMPERATURE, AdjustmentField.HDR_TINT))
            if (hdr.toneSettings.isDefault) fields.removeAll(AdjustmentField.HDR_TONE)
            if (hdr.colorSettings.isDefault) fields.removeAll(AdjustmentField.HDR_COLOR)
            if (hdr.renditionSettings.isDefault) fields.removeAll(AdjustmentField.HDR_RENDITION)
            if (hdr.effectSettings == PhotoEffectsSettings()) fields.removeAll(AdjustmentField.HDR_EFFECTS)
            if (hdr.detailSettings.isDefault) fields.removeAll(AdjustmentField.HDR_DETAIL)
            if (hdr.lookSettings.isDefault) fields.remove(AdjustmentField.HDR_LOOK)
        }
        return capture(AdjustmentScope.Custom(fields),active,context)
    }
    fun sameAdjustments(left: EditSettings, right: EditSettings, isRaw: Boolean): Boolean {
        if (left.isHDREditing || right.isHDREditing) {
            return left.synchronizeHDR() == right.synchronizeHDR()
        }
        val context = AdjustmentTransferContext("comparison", isRaw)
        return left.processing == right.processing && left.x3fMode == right.x3fMode && left.masterRecipeSettingsVersion == right.masterRecipeSettingsVersion &&
            AdjustmentTransferValues.values(left, context) == AdjustmentTransferValues.values(right, context)
    }
    fun capture(scope: AdjustmentScope, settings: EditSettings, context: AdjustmentTransferContext): AdjustmentPayload {
        if (context.hasUncommittedDraft) throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        if (settings.isHDREditing) return captureHDR(scope, settings.synchronizeHDR(), context)
        val original = AdjustmentTransferValues.values(settings, context)
        val defaults = AdjustmentTransferValues.values(EditSettings(exposureMode = if (context.isRaw) context.defaultExposureMode else 2), context)
        val selected = when (scope) {
            AdjustmentScope.All -> AdjustmentField.entries.filterTo(linkedSetOf()) { !it.isHDROnly }
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
                    if(payload.fields.any {it in AdjustmentField.HDR_TONE})throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.tone")
                    if(payload.fields.any {it in AdjustmentField.HDR_COLOR})throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.color")
                    if(payload.fields.any {it.isHDRRendition})throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.rendition")
                    if(payload.fields.any {it in AdjustmentField.HDR_EFFECTS})throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.effects")
                    if(payload.fields.any {it in AdjustmentField.HDR_DETAIL})throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.detail")
                    if(AdjustmentField.HDR_LOOK in payload.fields)throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.look")
                    if(AdjustmentField.HDR_CAMERA_DEVELOPMENT in payload.fields)
                        throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.camera_development")
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
            // 普通图片没有 RAW 曝光基准，选中任何来源模式均保持 sensor。
            result = result.copy(exposureMode = if (!context.isRaw) 2 else listOf("scene", "preview", "sensor").indexOf(mode))
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
        if (context.isRaw && !context.sourceSupportsCameraHDR) throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "hdr.source")
        settings.requireHDRDecodeVersion(context.sourceIsProRAW)
        val values = hdrValues(settings).toMutableMap()
        val defaults = hdrValues(EditSettings().withHDRMode(true, true)).toMutableMap()
        val hdr = requireNotNull(settings.hdr)
        val version = hdr.processingVersion
        val camera = AdjustmentField.HDR_CAMERA_DEVELOPMENT
        val allowed = AdjustmentField.hdrTransferFields(context.supportsHDRCameraDevelopment)
        if (context.supportsHDRCameraDevelopment) {
            values[camera] = cameraValue(hdr.cameraSettings)
            defaults[camera] = cameraValue(HDRCameraDevelopmentSettings())
        }
        val selected = when (scope) {
            AdjustmentScope.All -> if (values[camera] != defaults[camera]) AdjustmentField.hdrSupported(version) + camera
                else AdjustmentField.hdrSupported(version)
            AdjustmentScope.Modified -> (allowed - AdjustmentField.HDR_GEOMETRY)
                .filterTo(linkedSetOf()) { values[it] != defaults[it] }
            is AdjustmentScope.Custom -> scope.fields
        }
        if (selected.isEmpty()) throw AdjustmentTransferException(AdjustmentFailure.EMPTY_SCOPE)
        if (!allowed.containsAll(selected))
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "hdr.fields")
        val requiredVersion = when {
            AdjustmentField.HDR_LOOK in selected -> 7
            selected.any { it in AdjustmentField.HDR_DETAIL } -> 6
            selected.any { it in AdjustmentField.HDR_EFFECTS } -> 5
            selected.any { it.isHDRRendition } -> 4
            selected.any { it in AdjustmentField.HDR_COLOR } -> 3
            selected.any { it in AdjustmentField.HDR_TONE } -> 2
            else -> 1
        }
        return AdjustmentPayload(AdjustmentSource(context.identifier, isRaw = false,
            processingVersion = settings.processing.version, recipe = null,
            hdrProcessingVersion = maxOf(version, requiredVersion)),
            values.filterKeys { it in selected })
    }

    private fun prepareHDR(payload: AdjustmentPayload, target: EditSettings, context: AdjustmentTransferContext): EditSettings {
        if (!target.isHDREditing || context.isRaw && !context.sourceSupportsCameraHDR) throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "hdr.target")
        target.requireHDRDecodeVersion(context.sourceIsProRAW)
        payload.validate()
        if(!AdjustmentField.hdrTransferFields(context.supportsHDRCameraDevelopment).containsAll(payload.fields))
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.fields")
        if(!payload.source.isHDR && payload.fields.any {it in AdjustmentField.HDR_TONE})
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.tone")
        if(!payload.source.isHDR && payload.fields.any {it in AdjustmentField.HDR_COLOR})
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.color")
        if(!payload.source.isHDR && payload.fields.any {it in AdjustmentField.HDR_EFFECTS})
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.effects")
        if(!payload.source.isHDR && payload.fields.any {it in AdjustmentField.HDR_DETAIL})
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.detail")
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
        val tone = hdr.toneSettings
        val nextTone = tone.copy(blackPoint = number(AdjustmentField.BLACK_POINT)?.toFloat() ?: tone.blackPoint,
            whitePoint = number(AdjustmentField.WHITE_POINT)?.toFloat() ?: tone.whitePoint,
            curveStrength = number(AdjustmentField.S_CURVE)?.let { (it * 100).toFloat() } ?: tone.curveStrength,
            curve = payload[AdjustmentField.CURVE]?.let { AdjustmentPayload.curve(it) } ?: tone.curve)
        var color = hdr.colorSettings
        number(AdjustmentField.VIBRANCE)?.let { color = color.copy(vibrance = it.toFloat().canonicalZero()) }
        for (field in payload.fields) {
            field.hslLocation?.let { (axis, channel) ->
                color = color.copy(hsl = color.hsl.withValue(axis, channel, requireNotNull(number(field)).toFloat()))
            }
            field.gradingZone?.let { zone ->
                val wheel = requireNotNull(payload[field]?.objectValue)
                color = color.copy(grading = color.grading.with(zone, ColorGradingWheel.fromNumbers(
                    requireNotNull(wheel["hue"]?.number), requireNotNull(wheel["saturation"]?.number))))
            }
        }
        val rendition = hdr.renditionSettings
        val nextRendition = rendition.copy(
            peakLimitEV = number(AdjustmentField.HDR_PEAK_LIMIT)?.toFloat()?.canonicalZero() ?: rendition.peakLimitEV,
            sdrExposureEV = number(AdjustmentField.HDR_SDR_EXPOSURE)?.toFloat()?.canonicalZero() ?: rendition.sdrExposureEV,
            sdrContrast = number(AdjustmentField.HDR_SDR_CONTRAST)?.toFloat()?.canonicalZero() ?: rendition.sdrContrast,
            sdrSaturation = number(AdjustmentField.HDR_SDR_SATURATION)?.toFloat()?.canonicalZero() ?: rendition.sdrSaturation)
        val fx = hdr.effectSettings
        val effects = fx.copy(
            vignetteAmount = number(AdjustmentField.VIGNETTE_AMOUNT)?.toFloat()?.canonicalZero() ?: fx.vignetteAmount,
            vignetteMidpoint = number(AdjustmentField.VIGNETTE_MIDPOINT)?.toFloat()?.canonicalZero() ?: fx.vignetteMidpoint,
            vignetteRoundness = number(AdjustmentField.VIGNETTE_ROUNDNESS)?.toFloat()?.canonicalZero() ?: fx.vignetteRoundness,
            vignetteFeather = number(AdjustmentField.VIGNETTE_FEATHER)?.toFloat()?.canonicalZero() ?: fx.vignetteFeather,
            vignetteHighlights = number(AdjustmentField.VIGNETTE_HIGHLIGHTS)?.toFloat()?.canonicalZero() ?: fx.vignetteHighlights,
            grainAmount = number(AdjustmentField.GRAIN_AMOUNT)?.toFloat()?.canonicalZero() ?: fx.grainAmount,
            grainSize = number(AdjustmentField.GRAIN_SIZE)?.toFloat()?.canonicalZero() ?: fx.grainSize,
            grainRoughness = number(AdjustmentField.GRAIN_ROUGHNESS)?.toFloat()?.canonicalZero() ?: fx.grainRoughness)
        val detail = hdr.detailSettings
        val nextDetail = detail.copy(
            sharpening = number(AdjustmentField.SHARPENING)?.toFloat()?.canonicalZero() ?: detail.sharpening,
            clarity = number(AdjustmentField.CLARITY)?.let { (it / 100).toFloat().canonicalZero() } ?: detail.clarity,
            dehaze = number(AdjustmentField.DEHAZE)?.let { (it / 100).toFloat().canonicalZero() } ?: detail.dehaze,
            denoise = number(AdjustmentField.POST_RGB_DENOISE)?.toFloat()?.canonicalZero() ?: detail.denoise)
        val look = payload[AdjustmentField.HDR_LOOK]?.hdrLook() ?: hdr.lookSettings
        if (!look.assetIsAvailable(context.hdrLookDirectory))
            throw AdjustmentTransferException(AdjustmentFailure.MISSING_LOOK, look.name ?: "HDR LUT")
        var editedHDR = hdr.withTone(nextTone).withColor(color).withRendition(nextRendition).withEffects(effects)
            .withDetail(nextDetail).withLook(look).copy(geometry = geometry)
        val camera = payload[AdjustmentField.HDR_CAMERA_DEVELOPMENT]?.hdrCameraDevelopment()
        if (camera != null) {
            val old = hdr.cameraSettings
            editedHDR = editedHDR.withCameraDevelopment(old.copy(customWhiteBalance = camera.customWhiteBalance,
                temperature = camera.temperature, tint = camera.tint, sensorExposure = camera.sensorExposure, fbddLevel = camera.fbddLevel))
        }
        result = result.copy(geometry = geometry, hdr = editedHDR).synchronizeHDR()
        if (camera != null) {
            val validate = context.validateHDRCamera ?: throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.camera_development")
            validate(result)
        }
        return result
    }

    private fun cameraValue(camera: HDRCameraDevelopmentSettings) = AdjustmentValue.Object(mapOf(
        "version" to AdjustmentValue.Number(1.0),
        "white_balance_mode" to AdjustmentValue.Text(if (camera.customWhiteBalance) "temperature" else "as_shot"),
        "temperature" to AdjustmentValue.Number(camera.temperature.canonicalZero().toDouble()),
        "tint" to AdjustmentValue.Number(camera.tint.canonicalZero().toDouble()),
        "exposure_reference" to AdjustmentValue.Text(if (camera.sensorExposure) "sensor" else "metadata"),
        "fbdd_level" to AdjustmentValue.Number(camera.fbddLevel.toDouble())))

    private fun hdrValues(settings: EditSettings): Map<AdjustmentField, AdjustmentValue> = buildMap {
        put(AdjustmentField.EXPOSURE, AdjustmentValue.Number(settings.exposure.toDouble()))
        val hdr = settings.hdr ?: throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "hdr.settings")
        val look = hdr.lookSettings
        put(AdjustmentField.HDR_LOOK, if (look.isDefault) AdjustmentValue.Null else AdjustmentValue.Object(mapOf(
            "name" to AdjustmentValue.Text(look.name!!), "sha256" to AdjustmentValue.Text(look.sha256!!),
            "strength" to AdjustmentValue.Number(look.strength.toDouble()))))
        val fx = hdr.effectSettings
        put(AdjustmentField.VIGNETTE_AMOUNT, AdjustmentValue.Number(fx.vignetteAmount.toDouble()))
        put(AdjustmentField.VIGNETTE_MIDPOINT, AdjustmentValue.Number(fx.vignetteMidpoint.toDouble()))
        put(AdjustmentField.VIGNETTE_ROUNDNESS, AdjustmentValue.Number(fx.vignetteRoundness.toDouble()))
        put(AdjustmentField.VIGNETTE_FEATHER, AdjustmentValue.Number(fx.vignetteFeather.toDouble()))
        put(AdjustmentField.VIGNETTE_HIGHLIGHTS, AdjustmentValue.Number(fx.vignetteHighlights.toDouble()))
        put(AdjustmentField.GRAIN_AMOUNT, AdjustmentValue.Number(fx.grainAmount.toDouble()))
        put(AdjustmentField.GRAIN_SIZE, AdjustmentValue.Number(fx.grainSize.toDouble()))
        put(AdjustmentField.GRAIN_ROUGHNESS, AdjustmentValue.Number(fx.grainRoughness.toDouble()))
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
        val tone = hdr.toneSettings
        put(AdjustmentField.BLACK_POINT, AdjustmentValue.Number(tone.blackPoint.toDouble()))
        put(AdjustmentField.WHITE_POINT, AdjustmentValue.Number(tone.whitePoint.toDouble()))
        put(AdjustmentField.S_CURVE, AdjustmentValue.Number(tone.curveStrength / 100.0))
        put(AdjustmentField.CURVE, AdjustmentPayload.curveValue(tone.curve))
        val color = hdr.colorSettings
        put(AdjustmentField.VIBRANCE, AdjustmentValue.Number(color.vibrance.toDouble()))
        for (field in AdjustmentField.HDR_COLOR) {
            field.hslLocation?.let { (axis, channel) ->
                put(field, AdjustmentValue.Number(color.hsl.value(axis, channel).toDouble()))
            }
            field.gradingZone?.let { zone ->
                val wheel = color.grading[zone]
                put(field, AdjustmentValue.Object(mapOf("hue" to AdjustmentValue.Number(wheel.hue.toDouble()),
                    "saturation" to AdjustmentValue.Number(wheel.saturation.toDouble()))))
            }
        }
        val rendition = hdr.renditionSettings
        put(AdjustmentField.HDR_PEAK_LIMIT, AdjustmentValue.Number(rendition.peakLimitEV.toDouble()))
        put(AdjustmentField.HDR_SDR_EXPOSURE, AdjustmentValue.Number(rendition.sdrExposureEV.toDouble()))
        put(AdjustmentField.HDR_SDR_CONTRAST, AdjustmentValue.Number(rendition.sdrContrast.toDouble()))
        put(AdjustmentField.HDR_SDR_SATURATION, AdjustmentValue.Number(rendition.sdrSaturation.toDouble()))
        val detail = hdr.detailSettings
        put(AdjustmentField.SHARPENING, AdjustmentValue.Number(detail.sharpening.toDouble()))
        put(AdjustmentField.CLARITY, AdjustmentValue.Number(detail.clarity * 100.0))
        put(AdjustmentField.DEHAZE, AdjustmentValue.Number(detail.dehaze * 100.0))
        put(AdjustmentField.POST_RGB_DENOISE, AdjustmentValue.Number(detail.denoise.toDouble()))
    }
}
