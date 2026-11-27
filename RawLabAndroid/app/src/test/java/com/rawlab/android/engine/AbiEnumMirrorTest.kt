package com.rawlab.android.engine

import com.rawlab.android.adjustments.resolveSharedFixture
import com.rawlab.android.camera.SonyCameraNative
import com.rawlab.android.camera.protocol.SonyTetherSession
import com.rawlab.android.editor.inspection.InspectionOverlayMode
import com.rawlab.android.editor.render.SONY2FUJI_HDR_DISPLAY_FALSE_COLOR
import com.rawlab.android.editor.render.SONY2FUJI_HDR_DISPLAY_SDR
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.looks.DcpFailureReason
import com.rawlab.android.settings.HslTargetAvailability
import com.rawlab.android.settings.ToneCurveMode
import com.rawlab.android.settings.X3fMode
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin/Java 侧手写的 C ABI 枚举取值经 JNI 原样传给核心，这里对照
 * Shared/fixtures/abi-layout-v1.json 的 enums 段核对，避免取值写错后静默传错。
 */
class AbiEnumMirrorTest {
    // 整套镜像某个 C 枚举的客户端枚举：C 取值名去掉前缀即客户端成员名，双向核对。
    // clientOnly 是不来自核心的客户端成员，unmirrored 是客户端有意不接收的 C 取值。
    private class EnumMirror(
        val cEnum: String,
        val cPrefix: String,
        val members: Map<String, Int>,
        val clientOnly: Set<String> = emptySet(),
        val unmirrored: Set<String> = emptySet(),
    )

    private class ConstantMirror(val cName: String, val value: Int, val source: String)

    private inline fun <reified E : Enum<E>> members(value: (E) -> Int): Map<String, Int> =
        enumValues<E>().associate { it.name to value(it) }

    private val enumMirrors = listOf(
        EnumMirror("sony2fuji_x3f_mode", "SONY2FUJI_X3F_", members<X3fMode> { it.nativeValue }),
        EnumMirror("sony2fuji_curve_mode", "SONY2FUJI_CURVE_", members<ToneCurveMode> { it.nativeValue }),
        EnumMirror(
            "sony2fuji_dcp_error", "SONY2FUJI_DCP_ERROR_", members<DcpFailureReason> { it.code },
            unmirrored = setOf("SONY2FUJI_DCP_ERROR_NONE"),
        ),
        EnumMirror(
            "sony2fuji_output_format", "SONY2FUJI_OUTPUT_", members<ExportFormat> { it.nativeValue },
            clientOnly = setOf(ExportFormat.HDR_JPEG.name),
            unmirrored = setOf("SONY2FUJI_OUTPUT_RGB8", "SONY2FUJI_OUTPUT_RGBA8"),
        ),
        // 以下客户端枚举按 ordinal 与核心取值互转。
        EnumMirror(
            "sony2fuji_wb_probe_availability", "SONY2FUJI_WB_PROBE_",
            members<NativeProcessor.WbProbeAvailability> { it.ordinal },
        ),
        EnumMirror(
            "sony2fuji_hsl_probe_availability", "SONY2FUJI_HSL_PROBE_", members<HslTargetAvailability> { it.ordinal },
            clientOnly = setOf(HslTargetAvailability.FAILED.name),
        ),
        EnumMirror(
            "sony2fuji_inspection_overlay_mode", "SONY2FUJI_INSPECTION_OVERLAY_",
            members<InspectionOverlayMode> { it.ordinal },
        ),
        EnumMirror(
            "sony2fuji_sony_live_view_frame_kind", "SONY2FUJI_SONY_LIVE_FRAME_",
            members<SonyTetherSession.LiveViewFrameKind> { it.ordinal },
        ),
    )

    private val constantMirrors = listOf(
        ConstantMirror("SONY2FUJI_STATUS_UNSUPPORTED", NativeProcessingException.UNSUPPORTED, "NativeProcessingException.UNSUPPORTED"),
        ConstantMirror("SONY2FUJI_STATUS_IO_ERROR", NativeProcessingException.IO_ERROR, "NativeProcessingException.IO_ERROR"),
        ConstantMirror("SONY2FUJI_STATUS_OUTPUT_IO_ERROR", NativeProcessingException.OUTPUT_IO_ERROR, "NativeProcessingException.OUTPUT_IO_ERROR"),
        ConstantMirror("SONY2FUJI_STATUS_CANCELLED", NativeProcessingException.CANCELLED, "NativeProcessingException.CANCELLED"),
        ConstantMirror("SONY2FUJI_UNSUPPORTED_NONE", NativeProcessingException.UNSUPPORTED_NONE, "NativeProcessingException.UNSUPPORTED_NONE"),
        ConstantMirror("SONY2FUJI_UNSUPPORTED_FORCE_GPU", NativeProcessingException.UNSUPPORTED_FORCE_GPU, "NativeProcessingException.UNSUPPORTED_FORCE_GPU"),
        ConstantMirror("SONY2FUJI_GPU_OFF", NativeProcessor.CPU, "NativeProcessor.CPU"),
        ConstantMirror("SONY2FUJI_GPU_AUTO", NativeProcessor.AUTO, "NativeProcessor.AUTO"),
        ConstantMirror("SONY2FUJI_GPU_FORCE", NativeProcessor.FORCE, "NativeProcessor.FORCE"),
        ConstantMirror("SONY2FUJI_LENS_OFF", LensInfo.STATE_OFF, "LensInfo.STATE_OFF"),
        ConstantMirror("SONY2FUJI_LENS_MATCHED", LensInfo.STATE_APPLIED, "LensInfo.STATE_APPLIED"),
        ConstantMirror("SONY2FUJI_LENS_NO_DATABASE", LensInfo.STATE_DATABASE_UNAVAILABLE, "LensInfo.STATE_DATABASE_UNAVAILABLE"),
        ConstantMirror("SONY2FUJI_LENS_NO_CAMERA", LensInfo.STATE_CAMERA_INFO_MISSING, "LensInfo.STATE_CAMERA_INFO_MISSING"),
        ConstantMirror("SONY2FUJI_LENS_NO_LENS", LensInfo.STATE_NO_MATCH, "LensInfo.STATE_NO_MATCH"),
        ConstantMirror("SONY2FUJI_LENS_AMBIGUOUS", LensInfo.STATE_AMBIGUOUS, "LensInfo.STATE_AMBIGUOUS"),
        ConstantMirror("SONY2FUJI_LENS_NO_CALIBRATION", LensInfo.STATE_NO_CALIBRATION, "LensInfo.STATE_NO_CALIBRATION"),
        ConstantMirror("SONY2FUJI_LENS_MISSING_FOCAL_LENGTH", LensInfo.STATE_FOCAL_LENGTH_MISSING, "LensInfo.STATE_FOCAL_LENGTH_MISSING"),
        ConstantMirror("SONY2FUJI_LENS_EMBEDDED_GEOMETRY", LensInfo.STATE_EMBEDDED_GEOMETRY, "LensInfo.STATE_EMBEDDED_GEOMETRY"),
        ConstantMirror("SONY2FUJI_LENS_UNSUPPORTED_INPUT", LensInfo.STATE_INPUT_UNSUPPORTED, "LensInfo.STATE_INPUT_UNSUPPORTED"),
        ConstantMirror("SONY2FUJI_HDR_DISPLAY_SDR", SONY2FUJI_HDR_DISPLAY_SDR, "HDRBitmapAdapter SONY2FUJI_HDR_DISPLAY_SDR"),
        ConstantMirror("SONY2FUJI_HDR_DISPLAY_FALSE_COLOR", SONY2FUJI_HDR_DISPLAY_FALSE_COLOR, "HDRBitmapAdapter SONY2FUJI_HDR_DISPLAY_FALSE_COLOR"),
        ConstantMirror("SONY2FUJI_STATUS_OK", SonyCameraNative.STATUS_OK, "SonyCameraNative.STATUS_OK"),
        ConstantMirror("SONY2FUJI_STATUS_UNSUPPORTED", SonyCameraNative.STATUS_UNSUPPORTED, "SonyCameraNative.STATUS_UNSUPPORTED"),
        ConstantMirror("SONY2FUJI_SONY_PROP_NUMBER", SonyCameraNative.VALUE_KIND_NUMBER, "SonyCameraNative.VALUE_KIND_NUMBER"),
        ConstantMirror("SONY2FUJI_SONY_PROP_TEXT", SonyCameraNative.VALUE_KIND_TEXT, "SonyCameraNative.VALUE_KIND_TEXT"),
        ConstantMirror("SONY2FUJI_SONY_PROP_OPAQUE", SonyCameraNative.VALUE_KIND_OPAQUE, "SonyCameraNative.VALUE_KIND_OPAQUE"),
        ConstantMirror("SONY2FUJI_SONY_FOCUS_RENDER_NONE", SonyCameraNative.RENDER_MODE_NONE, "SonyCameraNative.RENDER_MODE_NONE"),
        ConstantMirror("SONY2FUJI_SONY_FOCUS_RENDER_LIVE_FRAMES", SonyCameraNative.RENDER_MODE_LIVE_FRAMES, "SonyCameraNative.RENDER_MODE_LIVE_FRAMES"),
        ConstantMirror("SONY2FUJI_SONY_FOCUS_RENDER_TAP_RETICLE", SonyCameraNative.RENDER_MODE_TAP_RETICLE, "SonyCameraNative.RENDER_MODE_TAP_RETICLE"),
    )

    private fun fixtureEnums(): Map<String, List<Pair<String, Long>>> {
        val root = JSONObject(resolveSharedFixture("abi-layout-v1.json").readText())
        val enums = root.getJSONArray("enums")
        return (0 until enums.length()).associate { index ->
            val entry = enums.getJSONObject(index)
            val values = entry.getJSONArray("values")
            entry.getString("enum") to (0 until values.length()).map {
                val value = values.getJSONObject(it)
                value.getString("name") to value.getLong("value")
            }
        }
    }

    @Test
    fun mirroredEnumValuesMatchAbiFixture() {
        val enums = fixtureEnums()
        val valueByName = enums.values.flatten().toMap()
        val errors = mutableListOf<String>()

        for (mirror in enumMirrors) {
            val cValues = enums[mirror.cEnum]
            if (cValues == null) {
                errors += "${mirror.cEnum}: C enum absent from abi-layout-v1.json enums"
                continue
            }
            val matched = mutableSetOf<String>()
            for ((cName, cValue) in cValues) {
                if (cName in mirror.unmirrored) continue
                if (!cName.startsWith(mirror.cPrefix)) {
                    errors += "${mirror.cEnum}: $cName lacks the expected prefix ${mirror.cPrefix}"
                    continue
                }
                val member = cName.removePrefix(mirror.cPrefix)
                val clientValue = mirror.members[member]
                if (clientValue == null) {
                    errors += "${mirror.cEnum}: fixture value $cName=$cValue has no client member $member"
                    continue
                }
                matched += member
                if (clientValue.toLong() != cValue) {
                    errors += "${mirror.cEnum}: $cName=$cValue but client $member=$clientValue"
                }
            }
            for ((member, clientValue) in mirror.members) {
                if (member in matched) continue
                if (member in mirror.clientOnly) {
                    if (cValues.any { it.second == clientValue.toLong() }) {
                        errors += "${mirror.cEnum}: client-only member $member=$clientValue collides with a fixture value"
                    }
                    continue
                }
                errors += "${mirror.cEnum}: client member $member=$clientValue has no fixture counterpart"
            }
        }

        for (mirror in constantMirrors) {
            val cValue = valueByName[mirror.cName]
            if (cValue == null) {
                errors += "${mirror.source}: mirrors ${mirror.cName}, which is absent from abi-layout-v1.json enums"
            } else if (mirror.value.toLong() != cValue) {
                errors += "${mirror.source}=${mirror.value} but fixture ${mirror.cName}=$cValue"
            }
        }

        assertTrue("C ABI enum mirror drift:\n" + errors.joinToString("\n"), errors.isEmpty())
    }
}
