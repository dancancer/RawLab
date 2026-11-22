package com.rawlab.android.adjustments

import org.json.JSONObject
import org.json.JSONArray
import com.rawlab.android.settings.ColorGradingWheel
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.HDRLookSettings
import com.rawlab.android.settings.ToneCurveParametric
import com.rawlab.android.settings.ToneCurveSettings
import com.rawlab.android.settings.canonicalZero
import com.rawlab.android.json.validateStrictJSON

enum class AdjustmentFailure { INVALID_PAYLOAD, UNSUPPORTED_VERSION, EMPTY_SCOPE, DRAFT, INCOMPATIBLE, MISSING_LOOK, UNREPRESENTABLE }
class AdjustmentTransferException(val reason: AdjustmentFailure, val field: String = "") : Exception("$reason: $field")

sealed interface AdjustmentValue {
    data class Number(val value: Double) : AdjustmentValue
    data class Text(val value: String) : AdjustmentValue
    data class Boolean(val value: kotlin.Boolean) : AdjustmentValue
    data class Object(val value: Map<String, AdjustmentValue>) : AdjustmentValue
    data class Array(val value: List<AdjustmentValue>) : AdjustmentValue
    data object Null : AdjustmentValue
    val number get() = (this as? Number)?.value
    val text get() = (this as? Text)?.value
    val boolean get() = (this as? Boolean)?.value
    val objectValue get() = (this as? Object)?.value
    fun frozen(): AdjustmentValue = when (this) {
        is Object -> Object(value.mapValues { it.value.frozen() })
        is Array -> Array(value.map { it.frozen() })
        else -> this
    }
}

data class AdjustmentRecipeContext(val id: String, val strength: Double, val settingsVersion: Int = 3)
data class AdjustmentSource(val identifier: String, val isRaw: Boolean, val processingVersion: Int,
    val recipe: AdjustmentRecipeContext? = null, val hdrProcessingVersion: Int? = null) {
    val isHDR get() = hdrProcessingVersion != null
}

@ConsistentCopyVisibility
data class AdjustmentPayload private constructor(val source: AdjustmentSource,
    val values: Map<AdjustmentField, AdjustmentValue>, val payloadVersion: Int, val scopeVersion: Int) {
    constructor(source: AdjustmentSource, values: Map<AdjustmentField, AdjustmentValue>) :
        this(source, values.mapValues { it.value.frozen() }, if (source.isHDR) 2 else 1, if (source.isHDR) 2 else 1)
    val fields get() = values.keys
    operator fun get(field: AdjustmentField) = values[field]
    init { validate() }

    fun validate() {
        if (!((payloadVersion == 1 && scopeVersion == 1 && !source.isHDR) ||
                (payloadVersion == 2 && scopeVersion == 2 && source.isHDR)))
            throw AdjustmentTransferException(AdjustmentFailure.UNSUPPORTED_VERSION)
        if (source.isHDR) {
            val version = source.hdrProcessingVersion?.takeIf { it in 1..9 }
                ?: throw AdjustmentTransferException(AdjustmentFailure.UNSUPPORTED_VERSION)
            val supported = AdjustmentField.hdrSupported(version) + AdjustmentField.HDR_CAMERA_DEVELOPMENT
            valid(!source.isRaw && source.recipe == null && supported.containsAll(fields), "hdr context")
        } else {
            valid(fields.none { it.isHDROnly }, "hdr context")
        }
        if (values.isEmpty()) throw AdjustmentTransferException(AdjustmentFailure.EMPTY_SCOPE)
        valid(source.identifier.isNotEmpty() && source.processingVersion in 1..3, "source")
        source.recipe?.let {
            valid(it.id.isNotEmpty() && it.strength.isFinite() && it.strength in 0.0..2.0 && it.settingsVersion in 2..4, "recipe")
            valid(this[AdjustmentField.STRENGTH]?.number?.let { strength -> strength == it.strength } != false, "recipe.strength")
        }
        values.forEach { (field, value) -> valid(validValue(field, value), field.id) }
        val look = this[AdjustmentField.LOOK]?.objectValue
        if (look?.get("kind")?.text == "recipe") valid(look["id"]?.text == source.recipe?.id, "recipe.look")
        val mode = this[AdjustmentField.WHITE_BALANCE_MODE]?.text
        val temperature = this[AdjustmentField.TEMPERATURE]
        val tint = this[AdjustmentField.TINT]
        if (mode != null) valid(if (source.isRaw) mode in setOf("camera", "temperature") else mode == "none", "white_balance.mode")
        if (!source.isRaw) {
            valid(temperature?.number == null && (source.recipe != null || tint?.number == null), "raster.white_balance")
            valid(this[AdjustmentField.EXPOSURE_MODE].let { it == null || it == AdjustmentValue.Text("sensor") } &&
                this[AdjustmentField.RAW_DENOISE].let { it == null || it == AdjustmentValue.Number(0.0) } &&
                (source.isHDR || this[AdjustmentField.POST_RGB_DENOISE].let { it == null || it == AdjustmentValue.Number(0.0) }), "raster request")
        }
        if (source.recipe != null) valid(tint != AdjustmentValue.Null, "recipe.white_balance.tint")
        if (mode == "camera") valid(temperature?.number == null && (source.recipe != null || tint?.number == null), "white_balance values conflict with mode")
        if (mode == "temperature") valid(temperature != AdjustmentValue.Null && tint != AdjustmentValue.Null, "white_balance values conflict with mode")
    }

    fun encode(): String {
        val sourceJSON = JSONObject().put("identifier", source.identifier).put("is_raw", source.isRaw)
            .put("processing_version", source.processingVersion)
        source.recipe?.let { sourceJSON.put("recipe", JSONObject().put("id", it.id).put("strength", it.strength).put("settings_version", it.settingsVersion)) }
        if (source.isHDR) sourceJSON.put("hdr_processing_version", source.hdrProcessingVersion)
        return JSONObject().put("payload_version", payloadVersion).put("scope_version", scopeVersion)
            .put("source", sourceJSON).put("values", JSONObject().also { objectValue ->
                values.forEach { (field, value) -> objectValue.put(field.id, jsonValue(value)) }
            }).toString()
    }

    companion object {
        private fun valid(condition: Boolean, field: String) {
            if (!condition) throw AdjustmentTransferException(AdjustmentFailure.INVALID_PAYLOAD, field)
        }
        private fun keys(value: JSONObject) = value.keys().asSequence().toSet()
        private fun rejectUnknown(value: JSONObject, allowed: Set<String>) = valid(allowed.containsAll(keys(value)), "unknown field")
        private fun number(value: Any?): Double {
            valid(value is kotlin.Number && value.toDouble().isFinite(), "number")
            return (value as kotlin.Number).toDouble()
        }
        private fun integer(value: Any?): Int {
            val result = number(value)
            valid(result == result.toInt().toDouble(), "integer")
            return result.toInt()
        }
        private fun text(value: Any?): String { valid(value is String, "string"); return value as String }
        private fun bool(value: Any?): Boolean { valid(value is Boolean, "boolean"); return value as Boolean }
        private fun objectValue(value: Any?): JSONObject { valid(value is JSONObject, "object"); return value as JSONObject }
        fun decode(json: String): AdjustmentPayload = try {
            validateStrictJSON(json, setOf("payload_version", "scope_version", "processing_version", "settings_version"))
            val root = JSONObject(json)
            rejectUnknown(root, setOf("payload_version", "scope_version", "source", "values"))
            val source = objectValue(root.get("source"))
            rejectUnknown(source, setOf("identifier", "is_raw", "processing_version", "recipe", "hdr_processing_version"))
            val recipe = source.opt("recipe").takeUnless { it == null || it == JSONObject.NULL }?.let { raw ->
                val value = objectValue(raw)
                rejectUnknown(value, setOf("id", "strength", "settings_version"))
                AdjustmentRecipeContext(text(value.get("id")), number(value.get("strength")), integer(value.get("settings_version")))
            }
            val values = objectValue(root.get("values"))
            AdjustmentPayload(AdjustmentSource(text(source.get("identifier")), bool(source.get("is_raw")),
                integer(source.get("processing_version")), recipe,
                source.opt("hdr_processing_version")?.takeUnless { it == JSONObject.NULL }?.let(::integer)), keys(values).associate { id ->
                val field = AdjustmentField.fromID(id) ?: throw AdjustmentTransferException(AdjustmentFailure.INVALID_PAYLOAD, id)
                field to decodeValue(values.get(id))
            }, integer(root.get("payload_version")), integer(root.get("scope_version")))
        } catch (error: AdjustmentTransferException) { throw error }
          catch (error: Exception) { throw AdjustmentTransferException(AdjustmentFailure.INVALID_PAYLOAD, error.message.orEmpty()) }

        private fun decodeValue(value: Any?): AdjustmentValue = when (value) {
            JSONObject.NULL, null -> AdjustmentValue.Null
            is Boolean -> AdjustmentValue.Boolean(value)
            is kotlin.Number -> AdjustmentValue.Number(number(value))
            is String -> AdjustmentValue.Text(value)
            is JSONObject -> AdjustmentValue.Object(keys(value).associateWith { decodeValue(value.get(it)) })
            is JSONArray -> AdjustmentValue.Array((0 until value.length()).map { decodeValue(value.get(it)) })
            else -> throw AdjustmentTransferException(AdjustmentFailure.INVALID_PAYLOAD, "value")
        }
        private fun jsonValue(value: AdjustmentValue): Any = when (value) {
            is AdjustmentValue.Number -> value.value
            is AdjustmentValue.Text -> value.value
            is AdjustmentValue.Boolean -> value.value
            is AdjustmentValue.Object -> JSONObject().also { json -> value.value.forEach { (key, nested) -> json.put(key, jsonValue(nested)) } }
            is AdjustmentValue.Array -> JSONArray(value.value.map { jsonValue(it) })
            AdjustmentValue.Null -> JSONObject.NULL
        }

        private fun validValue(field: AdjustmentField, value: AdjustmentValue): Boolean {
            val proto = field.spec.protocol
            if (value == AdjustmentValue.Null) return proto.nullable
            if (field == AdjustmentField.CURVE) return runCatching { curve(value) }.isSuccess
            if (field == AdjustmentField.CURVE_PARAMETRIC) return runCatching { parametricCurve(value) }.isSuccess
            if (field == AdjustmentField.HDR_LOOK) return value.hdrLook() != null
            if (field == AdjustmentField.HDR_CAMERA_DEVELOPMENT) return value.hdrCameraDevelopment() != null
            if (field.gradingZone != null || field == AdjustmentField.GRADING_GLOBAL) {
                val wheel = value.objectValue ?: return false
                val allowed = setOf("hue", "saturation", "luminance")
                if (!wheel.keys.containsAll(setOf("hue", "saturation")) || !allowed.containsAll(wheel.keys)) return false
                val luminance = if ("luminance" in wheel.keys) (wheel["luminance"]?.number ?: return false) else 0.0
                return ColorGradingWheel.valid(wheel["hue"]?.number ?: return false, wheel["saturation"]?.number ?: return false, luminance)
            }
            if (field == AdjustmentField.LOOK) {
                val look = value.objectValue ?: return false
                val sub = AdjustmentFieldSpec.SubFields.LookReference
                if (look.keys != proto.objectKeys.toSet()) return false
                val kind = look["kind"]?.text ?: return false
                if (kind !in sub.allowedKinds) return false
                if (kind == sub.idNullableWhenKind) return look["id"] == AdjustmentValue.Null
                val id = look["id"]?.text ?: return false
                return id.isNotEmpty() && '/' !in id && '\\' !in id && id !in setOf(".", "..")
            }
            if (field == AdjustmentField.WAVELET_DENOISE) {
                val wavelet = value.objectValue ?: return false
                val sub = AdjustmentFieldSpec.SubFields.WaveletDenoise
                return wavelet.keys == proto.objectKeys.toSet() &&
                    wavelet["enabled"]?.boolean != null &&
                    wavelet["preset"]?.text in sub.allowedPresets &&
                    wavelet["luma"]?.number?.let { it.isFinite() && it in sub.lumaMin..sub.lumaMax } == true &&
                    wavelet["chroma"]?.number?.let { it.isFinite() && it in sub.chromaMin..sub.chromaMax } == true &&
                    wavelet["coarse"]?.number?.let { it.isFinite() && it in sub.coarseMin..sub.coarseMax } == true
            }
            return when (proto.valueType) {
                AdjustmentProtocolValueType.BOOLEAN -> value.boolean != null
                AdjustmentProtocolValueType.STRING -> {
                    val text = value.text ?: return false
                    if (proto.nonEmpty && text.isEmpty()) return false
                    proto.allowedStringValues.isEmpty() || text in proto.allowedStringValues
                }
                AdjustmentProtocolValueType.INTEGER -> {
                    val number = value.number ?: return false
                    if (!number.isFinite() || number != number.toInt().toDouble()) return false
                    val rangeOk = proto.doubleRange?.let { number in it } ?: true
                    val allowedOk = proto.allowedIntValues.isEmpty() || number.toInt() in proto.allowedIntValues
                    rangeOk && allowedOk
                }
                AdjustmentProtocolValueType.NUMBER -> {
                    val number = value.number ?: return false
                    if (!number.isFinite()) return false
                    val minOk = proto.min?.let { if (proto.exclusiveMin) number > it else number >= it } ?: true
                    val maxOk = proto.max?.let { number <= it } ?: true
                    minOk && maxOk
                }
                AdjustmentProtocolValueType.OBJECT -> false
            }
        }
        internal fun curve(value: AdjustmentValue): ToneCurveSettings {
            val obj = jsonValue(value) as JSONObject
            val keys = obj.keys().asSequence().toSet()
            require(keys.containsAll(setOf("mode", "points")) && keys.all { it in setOf("mode", "points", "channels") })
            return ToneCurveSettings.decode(obj)
        }
        internal fun curveValue(curve: ToneCurveSettings): AdjustmentValue = decodeValue(
            curve.master.json().also {
                if (curve.hasChannelCurves) it.put("channels", curve.channels.json())
            }
        )
        internal fun parametricCurve(value: AdjustmentValue): ToneCurveParametric = ToneCurveParametric.decode(jsonValue(value) as JSONObject)
        internal fun parametricCurveValue(parametric: ToneCurveParametric): AdjustmentValue = decodeValue(parametric.json())
    }
}

internal fun AdjustmentValue.hdrCameraDevelopment(): HDRCameraDevelopmentSettings? {
    val camera = objectValue ?: return null
    val sub = AdjustmentFieldSpec.SubFields.HDRCameraDevelopment
    val expectedKeys = AdjustmentFieldSpec.Fields.HDR_CAMERA_DEVELOPMENT.protocol.objectKeys.toSet()
    val version = camera["version"]?.number
    if (camera.keys != expectedKeys || version == null || version != version.toInt().toDouble() ||
        version.toInt() !in sub.allowedVersions) return null
    val mode = camera["white_balance_mode"]?.text
    val exposure = camera["exposure_reference"]?.text
    val temperature = camera["temperature"]?.number ?: return null
    val tint = camera["tint"]?.number ?: return null
    val fbdd = camera["fbdd_level"]?.number ?: return null
    if (mode !in sub.allowedWhiteBalanceModes || exposure !in sub.allowedExposureReferences ||
        fbdd != fbdd.toInt().toDouble() || fbdd.toInt() !in sub.allowedFbddLevels) return null
    if (mode == "as_shot" && (temperature != sub.asShotTemperature || tint != sub.asShotTint) ||
        mode == "temperature" && (temperature !in sub.temperatureMin..sub.temperatureMax || tint !in sub.tintMin..sub.tintMax)) return null
    return HDRCameraDevelopmentSettings(mode == "temperature", temperature.toFloat().canonicalZero(), tint.toFloat().canonicalZero(),
        exposure == "sensor", fbdd.toInt())
}

internal fun AdjustmentValue.hdrLook(): HDRLookSettings? {
    if (this == AdjustmentValue.Null) return HDRLookSettings()
    val look = objectValue ?: return null
    val sub = AdjustmentFieldSpec.SubFields.HDRLook
    if (look.keys != AdjustmentFieldSpec.Fields.HDR_LOOK.protocol.objectKeys.toSet()) return null
    val name = look["name"]?.text ?: return null
    val sha256 = look["sha256"]?.text ?: return null
    val strength = look["strength"]?.number?.takeIf { it in sub.strengthMin..sub.strengthMax } ?: return null
    return runCatching { HDRLookSettings(sha256, name, strength.toFloat()) }.getOrNull()
}
