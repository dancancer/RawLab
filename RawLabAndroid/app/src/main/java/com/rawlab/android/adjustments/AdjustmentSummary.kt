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
            HDR_LOOK -> value.hdrLook()?.let { look -> look.name?.let { it + " · " + percent(look.strength.toDouble(), false) } }
                ?: text("中性")
            HDR_CAMERA_DEVELOPMENT -> value.hdrCameraDevelopment()?.let { camera ->
                val whiteBalance = if (camera.customWhiteBalance) number(camera.temperature.toDouble()) + " K · " +
                    text("色调") + " " + number(camera.tint.toDouble(), signed = true) else text("相机白平衡（按目标照片）")
                val exposure = text(if (camera.sensorExposure) "传感器基准" else "场景")
                val denoise = if (camera.fbddLevel == 0) text("关闭") else "FBDD ${camera.fbddLevel}"
                listOf(whiteBalance, exposure, denoise).joinToString(" · ")
            }.orEmpty()
            STRENGTH -> number(number * 100) + "%"
            EXPOSURE, HDR_SDR_EXPOSURE -> number(number, minimum = 2, signed = true) + " EV"
            HDR_PEAK_LIMIT -> if (number == 0.0) text("不限") else number(number, signed = true) + " EV"
            EXPOSURE_MODE -> text(when (value.text) { "scene" -> "场景"; "preview" -> "预览"; else -> "传感器基准" })
            CONTRAST, SATURATION -> percent(number - 1, true)
            HIGHLIGHTS -> percent(-number, true)
            SHADOWS, S_CURVE -> percent(number, true)
            BLACK_POINT, WHITE_POINT, VIBRANCE, CLARITY, DEHAZE, TEXTURE, HDR_SDR_CONTRAST, HDR_SDR_SATURATION -> number(number, signed = true) + "%"
            HDR_TEMPERATURE -> number(number) + " K（" + text("相对白平衡") + "）"
            HDR_TINT -> number(number, signed = true) + "（" + text("相对白平衡") + "）"
            WHITE_BALANCE_MODE -> text(when (value.text) { "camera" -> "相机白平衡（按目标照片）"; "temperature" -> "自定义"; "relative" -> "相对白平衡"; else -> "不适用" })
            TEMPERATURE, TINT -> if (value == AdjustmentValue.Null) {
                text(if (payload[WHITE_BALANCE_MODE]?.text == "camera") "相机白平衡（按目标照片）" else "不适用")
            } else number(number, signed = field == TINT) + if (field == TEMPERATURE) " K" else ""
            CURVE -> curveText(value)
            CURVE_APPLY_TO_LUMINOSITY, BW_ENABLED, SHARPENING_LUMINANCE_V2 -> text(if (value.boolean == true) "开启" else "停用")
            CALIBRATION_SHADOW_TINT, CALIBRATION_RED_HUE, CALIBRATION_RED_SATURATION,
            CALIBRATION_GREEN_HUE, CALIBRATION_GREEN_SATURATION,
            CALIBRATION_BLUE_HUE, CALIBRATION_BLUE_SATURATION, HALATION_HUE -> number(number, signed = true)
            POINT_COLOR -> {
                val count = value.pointColor()?.swatches?.size ?: 0
                if (count == 0) text("停用") else number(count.toDouble()) + " " + text("色板")
            }
            SELECTIVE_COLOR -> text(if (value.selectiveColor()?.method?.wireValue == "absolute") "绝对" else "相对")
            BW_MIXER -> {
                val nonZero = value.bwMixerWeights()?.asMap()?.count { it.value != 0f } ?: 0
                if (nonZero == 0) text("停用") else number(nonZero.toDouble())
            }
            GRAIN_TONE_CURVE -> text(if (value.text == "negative_asymmetric") "负片非对称" else "传统曲线")
            GRAIN_FORMAT_PRESET -> text(when (value.text) { "135" -> "135 胶片"; "120" -> "120 中画幅"; else -> "自定义" })
            SHARPENING_RADIUS -> number(number) + " px"
            SHARPENING_DETAIL, SHARPENING_MASKING,
            HALATION_AMOUNT, HALATION_THRESHOLD, HALATION_RADIUS,
            BLOOM_AMOUNT, BLOOM_THRESHOLD, BLOOM_RADIUS -> number(number) + "%"
            LENS_DEFRINGE_PURPLE_AMOUNT, LENS_DEFRINGE_PURPLE_HUE,
            LENS_DEFRINGE_GREEN_AMOUNT, LENS_DEFRINGE_GREEN_HUE -> number(number)
            CURVE_PARAMETRIC -> {
                val p = value.objectValue!!
                listOf(
                    text("高光") + " " + number(p.getValue("highlights").number!!, signed = true),
                    text("亮部") + " " + number(p.getValue("lights").number!!, signed = true),
                    text("暗部") + " " + number(p.getValue("darks").number!!, signed = true),
                    text("阴影") + " " + number(p.getValue("shadows").number!!, signed = true),
                ).joinToString(" · ")
            }
            GRADING_SHADOWS, GRADING_MIDTONES, GRADING_HIGHLIGHTS, GRADING_GLOBAL -> {
                val wheel = value.objectValue!!
                val base = text("色相") + " " + number(wheel.getValue("hue").number!!) + "° · " +
                    text("饱和度") + " " + number(wheel.getValue("saturation").number!!) + "%"
                val lum = wheel["luminance"]?.number ?: 0.0
                if (lum != 0.0) base + " · " + text("明亮度") + " " + number(lum, signed = true) + "%" else base
            }
            GRADING_BLENDING -> number(number) + "%"
            GRADING_BALANCE -> number(number, signed = true) + "%"
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
            FLIP_HORIZONTAL, FLIP_VERTICAL, LENS_DISTORTION, LENS_TCA, LENS_VIGNETTING, LENS_AUTO_CROP -> text(if (value.boolean == true) "开启" else "停用")
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
        fun shapeText(fields: Map<String, AdjustmentValue>): String {
            if (fields.getValue("mode").text != "custom") return text("S 曲线")
            val points = (fields.getValue("points") as AdjustmentValue.Array).value
            return format("多点曲线（%d 个控制点）", points.size) + "：" + points.joinToString(" · ") {
                val point = (it as AdjustmentValue.Array).value
                number(point[0].number!!, minimum = 2) + " → " + number(point[1].number!!, minimum = 2)
            }
        }
        val curve = value.objectValue!!
        val parts = mutableListOf(shapeText(curve))
        val channels = curve["channels"]?.objectValue.orEmpty()
        for (name in listOf("red", "green", "blue")) {
            val fields = channels[name]?.objectValue ?: continue
            if (fields.getValue("mode").text == "custom") parts += name.first().uppercase() + " · " + shapeText(fields)
        }
        return parts.joinToString("\n")
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
