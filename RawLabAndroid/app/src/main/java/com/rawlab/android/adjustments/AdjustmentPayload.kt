package com.rawlab.android.adjustments

import org.json.JSONObject
import org.json.JSONArray
import com.rawlab.android.settings.ColorGradingWheel
import com.rawlab.android.settings.ToneCurveSettings
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
    val recipe: AdjustmentRecipeContext? = null)

@ConsistentCopyVisibility
data class AdjustmentPayload private constructor(val source: AdjustmentSource,
    val values: Map<AdjustmentField, AdjustmentValue>, val payloadVersion: Int, val scopeVersion: Int) {
    constructor(source: AdjustmentSource, values: Map<AdjustmentField, AdjustmentValue>) :
        this(source, values.mapValues { it.value.frozen() }, 1, 1)
    val fields get() = values.keys
    operator fun get(field: AdjustmentField) = values[field]
    init { validate() }

    fun validate() {
        if (payloadVersion != 1 || scopeVersion != 1) throw AdjustmentTransferException(AdjustmentFailure.UNSUPPORTED_VERSION)
        if (values.isEmpty()) throw AdjustmentTransferException(AdjustmentFailure.EMPTY_SCOPE)
        valid(source.identifier.isNotEmpty() && source.processingVersion in 1..2, "source")
        source.recipe?.let {
            valid(it.id.isNotEmpty() && it.strength.isFinite() && it.strength in 0.0..2.0 && it.settingsVersion in 2..3, "recipe")
            valid(this[AdjustmentField.STRENGTH]?.number?.let { strength -> strength == it.strength } != false, "recipe.strength")
        }
        values.forEach { (field, value) -> valid(validValue(field, value), field.id) }
        val look = this[AdjustmentField.LOOK]?.objectValue
        if (look?.get("kind")?.text == "recipe") valid(look["id"]?.text == source.recipe?.id, "recipe.look")
        val mode = this[AdjustmentField.WHITE_BALANCE_MODE]?.text
        val temperature = this[AdjustmentField.TEMPERATURE]
        val tint = this[AdjustmentField.TINT]
        if (mode != null) valid(if (source.isRaw) mode != "none" else mode == "none", "white_balance.mode")
        if (!source.isRaw) {
            valid(temperature?.number == null && (source.recipe != null || tint?.number == null), "raster.white_balance")
            valid(this[AdjustmentField.EXPOSURE_MODE].let { it == null || it == AdjustmentValue.Text("sensor") } &&
                this[AdjustmentField.RAW_DENOISE].let { it == null || it == AdjustmentValue.Number(0.0) } &&
                this[AdjustmentField.POST_RGB_DENOISE].let { it == null || it == AdjustmentValue.Number(0.0) } &&
                this[AdjustmentField.LENS_DISTORTION]?.boolean != true && this[AdjustmentField.LENS_TCA]?.boolean != true, "raster request")
        }
        if (source.recipe != null) valid(tint != AdjustmentValue.Null, "recipe.white_balance.tint")
        if (mode == "camera") valid(temperature?.number == null && (source.recipe != null || tint?.number == null), "white_balance values conflict with mode")
        if (mode == "temperature") valid(temperature != AdjustmentValue.Null && tint != AdjustmentValue.Null, "white_balance values conflict with mode")
    }

    fun encode(): String {
        val sourceJSON = JSONObject().put("identifier", source.identifier).put("is_raw", source.isRaw)
            .put("processing_version", source.processingVersion)
        source.recipe?.let { sourceJSON.put("recipe", JSONObject().put("id", it.id).put("strength", it.strength).put("settings_version", it.settingsVersion)) }
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
            rejectUnknown(source, setOf("identifier", "is_raw", "processing_version", "recipe"))
            val recipe = source.opt("recipe").takeUnless { it == null || it == JSONObject.NULL }?.let { raw ->
                val value = objectValue(raw)
                rejectUnknown(value, setOf("id", "strength", "settings_version"))
                AdjustmentRecipeContext(text(value.get("id")), number(value.get("strength")), integer(value.get("settings_version")))
            }
            val values = objectValue(root.get("values"))
            AdjustmentPayload(AdjustmentSource(text(source.get("identifier")), bool(source.get("is_raw")),
                integer(source.get("processing_version")), recipe), keys(values).associate { id ->
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
            if (field == AdjustmentField.CURVE) return runCatching { curve(value) }.isSuccess
            if (field.gradingZone != null) {
                val wheel = value.objectValue ?: return false
                if (wheel.keys != setOf("hue", "saturation")) return false
                return ColorGradingWheel.valid(wheel["hue"]?.number ?: return false, wheel["saturation"]?.number ?: return false)
            }
            field.scalarRange?.let { range ->
                val number = value.number ?: return false
                return number.isFinite() && number in range &&
                    (field != AdjustmentField.QUARTER_TURNS || number == number.toInt().toDouble()) &&
                    (field !in setOf(AdjustmentField.CROP_WIDTH, AdjustmentField.CROP_HEIGHT) || number > 0)
            }
            return when (field) {
                AdjustmentField.FLIP_HORIZONTAL, AdjustmentField.FLIP_VERTICAL, AdjustmentField.LENS_DISTORTION,
                AdjustmentField.LENS_TCA, AdjustmentField.LENS_AUTO_CROP -> value.boolean != null
                AdjustmentField.EXPOSURE_MODE -> value.text in setOf("scene", "preview", "sensor")
                AdjustmentField.WHITE_BALANCE_MODE -> value.text in setOf("camera", "temperature", "none")
                AdjustmentField.TEMPERATURE -> value == AdjustmentValue.Null || value.number?.let { it.isFinite() && it in 2000.0..50000.0 } == true
                AdjustmentField.TINT -> value == AdjustmentValue.Null || value.number?.let { it.isFinite() && it in -150.0..150.0 } == true
                AdjustmentField.LENS_PROFILE -> value == AdjustmentValue.Null || value.text?.isNotEmpty() == true
                AdjustmentField.RAW_DENOISE -> value.number in setOf(0.0, 1.0, 2.0)
                AdjustmentField.CHROMA_DENOISE -> value == AdjustmentValue.Null || value.number in setOf(0.0, 1.0, 2.0)
                AdjustmentField.LOOK -> {
                    val look = value.objectValue ?: return false
                    if (look.keys != setOf("kind", "id")) return false
                    if (look["kind"]?.text == "neutral") return look["id"] == AdjustmentValue.Null
                    val id = look["id"]?.text ?: return false
                    look["kind"]?.text in setOf("builtin", "managed", "recipe", "recipe_lut") &&
                        id.isNotEmpty() && '/' !in id && '\\' !in id && id !in setOf(".", "..")
                }
                AdjustmentField.WAVELET_DENOISE -> {
                    if (value == AdjustmentValue.Null) return true
                    val wavelet = value.objectValue ?: return false
                    wavelet.keys == setOf("enabled", "luma", "chroma", "coarse", "preset") &&
                        wavelet["enabled"]?.boolean != null && wavelet["preset"]?.text in setOf("detail", "clean", "custom") &&
                        listOf("luma", "chroma", "coarse").all { wavelet[it]?.number?.let { n -> n.isFinite() && n in 0.0..100.0 } == true }
                }
                else -> false
            }
        }
        internal fun curve(value: AdjustmentValue): ToneCurveSettings = ToneCurveSettings.decode(jsonValue(value) as JSONObject)
        internal fun curveValue(curve: ToneCurveSettings): AdjustmentValue = decodeValue(curve.json())
    }
}
