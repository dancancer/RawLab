package com.rawlab.android.adjustments

import com.rawlab.android.adjustments.AdjustmentField.*
import java.math.RoundingMode
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.abs

class AdjustmentSummary(val payload: AdjustmentPayload, private val locale: Locale = Locale.getDefault(),
    private val text: (String) -> String = { it }) {
    data class Group(val id: String, val fields: List<AdjustmentField>)

    // 保持共享摘要顺序，不改变本端参数枚举的 ordinal。
    private val fieldOrder = AdjustmentField.entries.filterNot { it.isHDRRelative || it == CLARITY || it == DEHAZE }.flatMap {
        when (it) {
            SATURATION -> listOf(it, HDR_TEMPERATURE, HDR_TINT)
            GRAIN_AMOUNT -> listOf(it, CLARITY, DEHAZE)
            else -> listOf(it)
        }
    }
    val groups get() = listOf("looks", "light", "color", "effects", "detail", "geometry").mapNotNull { id ->
        fieldOrder.filter { it.group == id && it in payload.fields }.takeIf { it.isNotEmpty() }?.let { Group(id, it) }
    }
    val count get() = payload.fields.size
    val includesGeometry get() = payload.fields.any { it.group == "geometry" }
    val recipeNote get() = payload.source.recipe?.let {
        format("以下为配方逻辑值；强度为 %s。部分范围会按此强度换算。", number(it.strength * 100) + "%")
    }

    fun valueText(field: AdjustmentField, lookName: (String, String) -> String? = { _, _ -> null }): String {
        val value = payload[field] ?: return ""
        val number = value.number ?: 0.0
        return when (field) {
            LOOK -> lookText(value, lookName)
            STRENGTH -> number(number * 100) + "%"
            EXPOSURE -> number(number, minimum = 2, signed = true) + " EV"
            EXPOSURE_MODE -> text(when (value.text) { "scene" -> "场景"; "preview" -> "预览"; else -> "传感器基准" })
            CONTRAST, SATURATION -> percent(number - 1, true)
            HIGHLIGHTS -> percent(-number, true)
            SHADOWS, S_CURVE -> percent(number, true)
            BLACK_POINT, WHITE_POINT, VIBRANCE, CLARITY, DEHAZE -> number(number, signed = true) + "%"
            HDR_TEMPERATURE -> number(number) + " K（" + text("相对白平衡") + "）"
            HDR_TINT -> number(number, signed = true) + "（" + text("相对白平衡") + "）"
            WHITE_BALANCE_MODE -> text(when (value.text) { "camera" -> "相机白平衡（按目标照片）"; "temperature" -> "自定义"; else -> "不适用" })
            TEMPERATURE, TINT -> if (value == AdjustmentValue.Null) {
                text(if (payload[WHITE_BALANCE_MODE]?.text == "camera") "相机白平衡（按目标照片）" else "不适用")
            } else number(number, signed = field == TINT) + if (field == TEMPERATURE) " K" else ""
            CURVE -> curveText(value)
            GRADING_SHADOWS, GRADING_MIDTONES, GRADING_HIGHLIGHTS -> {
                val wheel = value.objectValue!!
                text("色相") + " " + number(wheel.getValue("hue").number!!) + "° · " +
                    text("饱和度") + " " + number(wheel.getValue("saturation").number!!) + "%"
            }
            VIGNETTE_AMOUNT, VIGNETTE_ROUNDNESS -> number(number, signed = true)
            PERSPECTIVE_HORIZONTAL, PERSPECTIVE_VERTICAL -> number(number * 100, signed = true)
            VIGNETTE_MIDPOINT, VIGNETTE_FEATHER, VIGNETTE_HIGHLIGHTS,
            GRAIN_AMOUNT, GRAIN_SIZE, GRAIN_ROUGHNESS, RAW_DENOISE, POST_RGB_DENOISE -> number(number)
            CHROMA_DENOISE -> if (value == AdjustmentValue.Null) text("默认降噪设置") else text(when (number.toInt()) {
                0 -> "停用"; 1 -> "细节优先"; else -> "去噪优先"
            })
            WAVELET_DENOISE -> waveletText(value)
            SHARPENING -> percent(number, false)
            CROP_X, CROP_Y, CROP_WIDTH, CROP_HEIGHT -> number(number * 100) + "%"
            QUARTER_TURNS -> number(number * 90) + "°"
            FLIP_HORIZONTAL, FLIP_VERTICAL, LENS_DISTORTION, LENS_TCA, LENS_AUTO_CROP -> text(if (value.boolean == true) "开启" else "停用")
            STRAIGHTEN -> number(number, signed = true) + "°"
            LENS_PROFILE -> if (value == AdjustmentValue.Null) text("自动（按目标照片）")
                else if (value.text == "__rawlab_manual_selection_required__") text("待选择的镜头配置") else value.text.orEmpty()
            else -> number(number, signed = true)
        }
    }

    private fun lookText(value: AdjustmentValue, lookName: (String, String) -> String?): String {
        val look = value.objectValue!!
        val kind = look.getValue("kind").text!!
        if (kind == "neutral") return text("中性")
        val id = look.getValue("id").text!!
        val type = text(when (kind) { "builtin" -> "内置"; "managed" -> "已保存"; "recipe" -> "配方"; else -> "配方 LUT" })
        val name = lookName(kind, id)?.takeIf { it.isNotEmpty() }
        return type + " · " + (name ?: (id + " · " + text("外观不可用。")))
    }

    private fun curveText(value: AdjustmentValue): String {
        val curve = value.objectValue!!
        if (curve.getValue("mode").text != "custom") return text("S 曲线")
        val points = (curve.getValue("points") as AdjustmentValue.Array).value
        return format("多点曲线（%d 个控制点）", points.size) + "：" + points.joinToString(" · ") {
            val point = (it as AdjustmentValue.Array).value
            number(point[0].number!!, minimum = 2) + " → " + number(point[1].number!!, minimum = 2)
        }
    }

    private fun waveletText(value: AdjustmentValue): String {
        if (value == AdjustmentValue.Null) return text("默认降噪设置")
        val data = value.objectValue!!
        val preset = text(when (data.getValue("preset").text) { "detail" -> "细节优先"; "clean" -> "去噪优先"; else -> "自定义" })
        return text(if (data.getValue("enabled").boolean == true) "开启" else "停用") + " · " +
            text("亮度降噪") + " " + number(data.getValue("luma").number!!) + " · " +
            text("色彩降噪") + " " + number(data.getValue("chroma").number!!) + " · " +
            text("粗色斑抑制") + " " + number(data.getValue("coarse").number!!) + " · " + preset
    }

    private fun format(key: String, vararg arguments: Any) = String.format(locale, text(key), *arguments)
    private fun percent(value: Double, signed: Boolean) = number(value * 100, signed = signed) + "%"
    private fun number(value: Double, minimum: Int = 0, signed: Boolean = false): String {
        val formatter = NumberFormat.getNumberInstance(locale).apply {
            isGroupingUsed = false; minimumFractionDigits = minimum; maximumFractionDigits = 2
            roundingMode = RoundingMode.HALF_UP
        }
        val threshold = if (minimum > 0) Math.pow(10.0, (-minimum - 1).toDouble()) else 0.0000001
        val normalized = if (abs(value) < threshold) 0.0 else value
        return (if (signed && normalized > 0) "+" else "") + formatter.format(normalized)
    }
}
