package com.rawlab.android.settings

import com.rawlab.android.editor.AsShotWhiteBalance
import com.rawlab.android.editor.EditorAdjustmentRules
import com.rawlab.android.editor.EditorResetContext
import com.rawlab.android.editor.EditorResetResult
import com.rawlab.android.editor.EditorResetScope
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.looks.MasterRecipe
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.util.Base64
import java.util.Properties
import kotlin.math.abs

/**
 * P2-01 (S1): Android 消费共享持久化编辑记录 golden fixture (`Shared/fixtures/edit-records-v1.json`)。
 * 先以空差异台账跑出真行为红锚；不静默修改实现或压低 fixture 期望以迎合现实现状。
 */
class EditRecordFixtureTest {
    private data class EditRecordDivergence(val ledgerId: String, val reason: String)

    // -----------------------------------------------------------------------
    // Divergence ledger (empty initially to capture genuine red anchors)
    // -----------------------------------------------------------------------
    private val maxKnownEditRecordDivergences = 24

    private val knownEditRecordDivergences: Map<String, EditRecordDivergence> = mapOf(
        "x1-store-root-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-01",
            reason = "EditStore.readSnapshot throws Unknown edit store property for unrecognized top-level properties keys",
        ),
        "x1-record-root-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-02",
            reason = "EditStore.readSnapshot rejects unknown per-record property suffixes outside recordSuffixes",
        ),
        "x1-settings-root-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-03",
            reason = "StructuredSettingsCodec.decode uses keysWithOptional closed-key check on v2 settings root",
        ),
        "x1-processing-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-04",
            reason = "StructuredSettingsCodec.decode uses keysExactly on processing object",
        ),
        "x1-tone-controls-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-05",
            reason = "StructuredSettingsCodec.decode uses keysExactly on tone object",
        ),
        "x1-atmosphere-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-06",
            reason = "StructuredSettingsCodec.decode uses keysExactly on atmosphere object",
        ),
        "x1-color-grading-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-07",
            reason = "StructuredSettingsCodec.grading uses keysExactly on colorGrading object",
        ),
        "x1-color-grading-zone-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-08",
            reason = "StructuredSettingsCodec.grading uses keysExactly on grading zone wheel object",
        ),
        "x1-tone-curve-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-09",
            reason = "ToneCurveSettings.decode rejects unknown keys outside {mode,points,channels}",
        ),
        "x1-tone-curve-channels-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-10",
            reason = "ToneCurveChannels.decode rejects unknown keys outside {red,green,blue}",
        ),
        "x1-geometry-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-11",
            reason = "StructuredSettingsCodec.decode uses keysExactly on geometry object",
        ),
        "x1-lens-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-12",
            reason = "StructuredSettingsCodec.decode uses closed keysWithOptional on lens object",
        ),
        "x1-denoise-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-13",
            reason = "StructuredSettingsCodec.decode uses keysExactly on denoise object",
        ),
        "x1-effects-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-14",
            reason = "StructuredSettingsCodec.decode uses keysExactly on effects object",
        ),
        "x1-hdr-root-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-15",
            reason = "StructuredSettingsCodec.decodeHDR uses closed keysWithOptional on hdr root",
        ),
        "x1-hdr-tone-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-16",
            reason = "StructuredSettingsCodec.decodeHDR uses keysExactly on hdr.tone",
        ),
        "x1-hdr-color-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-17",
            reason = "StructuredSettingsCodec.decodeHDR uses keysExactly on hdr.color",
        ),
        "x1-hdr-rendition-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-18",
            reason = "StructuredSettingsCodec.decodeHDR uses keysExactly on hdr.rendition",
        ),
        "x1-hdr-effects-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-19",
            reason = "StructuredSettingsCodec.decodeHDR uses keysExactly on hdr.effects",
        ),
        "x1-hdr-detail-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-20",
            reason = "StructuredSettingsCodec.decodeHDR uses keysExactly on hdr.detail",
        ),
        "x1-hdr-look-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-21",
            reason = "StructuredSettingsCodec.decodeHDR uses keysExactly on hdr.look",
        ),
        "x1-hdr-camera-development-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-22",
            reason = "StructuredSettingsCodec.decodeHDRCamera uses closed keysWithOptional on camera_development",
        ),
        "x1-hdr-camera-profile-unknown-field" to EditRecordDivergence(
            ledgerId = "P2-01-AND-X1-23",
            reason = "StructuredSettingsCodec.decodeHDRCamera uses keysExactly on camera_profile",
        ),
        "compat-legacy-omitted-extensions" to EditRecordDivergence(
            ledgerId = "P2-01-AND-COMPAT-01",
            reason = "StructuredSettingsCodec v2 JSON requires processing and tone keys instead of applying legacy defaults when omitted",
        ),
    )

    private fun resolveRepoFile(relativePath: String): File {
        var dir: File? = File(".").canonicalFile
        while (dir != null) {
            val candidate = File(dir, relativePath)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        error("Could not locate $relativePath from ${File(".").canonicalPath}")
    }

    private fun num(v: Any?): Double? = when (v) {
        is Number -> v.toDouble()
        else -> null
    }

    private fun intVal(v: Any?): Int? = when (v) {
        is Number -> v.toInt()
        else -> null
    }

    private fun approx(a: Double, b: Double, tol: Double = 1e-4): Boolean = abs(a - b) <= tol

    private fun check(condition: Boolean, message: String) {
        if (!condition) error(message)
    }

    private fun parseCurve(obj: JSONObject): ToneCurveSettings {
        val mode = if (obj.optString("mode", "legacy") == "custom") ToneCurveMode.CUSTOM else ToneCurveMode.LEGACY
        val ptsRaw = obj.optJSONArray("points") ?: JSONArray()
        val points = (0 until ptsRaw.length()).map { idx ->
            val p = ptsRaw.getJSONArray(idx)
            ToneCurvePoint(p.getDouble(0), p.getDouble(1))
        }
        var channels = ToneCurveChannels()
        if (obj.has("channels") && !obj.isNull("channels")) {
            val ch = obj.getJSONObject("channels")
            fun shape(name: String): ToneCurveShape {
                if (!ch.has(name) || ch.isNull(name)) return ToneCurveShape()
                val sObj = ch.getJSONObject(name)
                val sm = if (sObj.optString("mode", "legacy") == "custom") ToneCurveMode.CUSTOM else ToneCurveMode.LEGACY
                val sPts = sObj.optJSONArray("points") ?: JSONArray()
                return ToneCurveShape(sm, (0 until sPts.length()).map { i ->
                    val pair = sPts.getJSONArray(i)
                    ToneCurvePoint(pair.getDouble(0), pair.getDouble(1))
                })
            }
            channels = ToneCurveChannels(red = shape("red"), green = shape("green"), blue = shape("blue"))
        }
        return ToneCurveSettings(mode = mode, points = points, channels = channels)
    }

    private fun parseGrading(values: JSONObject): ColorGradingSettings {
        fun wheel(key: String): ColorGradingWheel {
            if (!values.has(key) || values.isNull(key)) return ColorGradingWheel()
            val w = values.getJSONObject(key)
            return ColorGradingWheel(w.optDouble("hue", 0.0).toFloat(), w.optDouble("saturation", 0.0).toFloat())
        }
        return ColorGradingSettings(
            shadows = wheel("color.grading.shadows"),
            midtones = wheel("color.grading.midtones"),
            highlights = wheel("color.grading.highlights"),
        )
    }

    private fun parseHSL(values: JSONObject): HslSettings {
        val channels = listOf("red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta")
        val packed = MutableList(24) { 0f }
        for ((idx, ch) in channels.withIndex()) {
            num(values.opt("color.hsl.hue.$ch"))?.let { packed[idx] = it.toFloat() }
            num(values.opt("color.hsl.saturation.$ch"))?.let { packed[8 + idx] = it.toFloat() }
            num(values.opt("color.hsl.lightness.$ch"))?.let { packed[16 + idx] = it.toFloat() }
        }
        return HslSettings(packed)
    }

    private fun buildHDR(values: JSONObject, metadata: JSONObject, activeMode: Boolean): HDRSettings {
        val exposure = (num(values.opt("light.exposure")) ?: 0.0).toFloat()
        val temp = (num(values.opt("hdr.relative_temperature")) ?: 6500.0).toFloat()
        val tint = (num(values.opt("hdr.relative_tint")) ?: 0.0).toFloat()
        val contrast = ((num(values.opt("light.contrast")) ?: 1.0) - 1.0).toFloat() * 100f
        val highlights = -(num(values.opt("light.highlights")) ?: 0.0).toFloat() * 100f
        val shadows = (num(values.opt("light.shadows")) ?: 0.0).toFloat() * 100f
        val saturation = ((num(values.opt("color.saturation")) ?: 1.0) - 1.0).toFloat() * 100f

        val hasLook = values.has("hdr.look") && !values.isNull("hdr.look")
        val hasDetail = values.has("detail.sharpening") || values.has("detail.denoise.post_rgb") ||
            values.has("effects.clarity") || values.has("effects.dehaze") || hasLook
        val hasEffects = hasDetail || values.has("effects.vignette.amount") || values.has("effects.grain.amount")
        val hasRendition = hasEffects || values.has("hdr.peak_limit_ev") || values.has("hdr.sdr_exposure_ev") ||
            values.has("hdr.sdr_contrast") || values.has("hdr.sdr_saturation")
        val hasColor = hasRendition || values.has("color.vibrance") || values.has("color.grading.shadows") ||
            values.keys().asSequence().any { it.startsWith("color.hsl.") }
        val hasTone = hasColor || values.has("tone.black_point") || values.has("tone.white_point") ||
            values.has("light.s_curve") || values.has("light.curve")

        val tone = if (hasTone) {
            HDRToneSettings(
                blackPoint = (num(values.opt("tone.black_point")) ?: 0.0).toFloat(),
                whitePoint = (num(values.opt("tone.white_point")) ?: 0.0).toFloat(),
                curveStrength = ((num(values.opt("light.s_curve")) ?: 0.0) * 100.0).toFloat(),
                curve = if (values.has("light.curve") && !values.isNull("light.curve")) parseCurve(values.getJSONObject("light.curve")) else ToneCurveSettings(),
            )
        } else null

        val color = if (hasColor) {
            HDRColorSettings(
                vibrance = (num(values.opt("color.vibrance")) ?: 0.0).toFloat(),
                hsl = parseHSL(values),
                grading = parseGrading(values),
            )
        } else null

        val rendition = if (hasRendition) {
            HDRRenditionSettings(
                peakLimitEV = (num(values.opt("hdr.peak_limit_ev")) ?: 0.0).toFloat(),
                sdrExposureEV = (num(values.opt("hdr.sdr_exposure_ev")) ?: 0.0).toFloat(),
                sdrContrast = (num(values.opt("hdr.sdr_contrast")) ?: 0.0).toFloat(),
                sdrSaturation = (num(values.opt("hdr.sdr_saturation")) ?: 0.0).toFloat(),
            )
        } else null

        val fx = if (hasEffects) {
            PhotoEffectsSettings(
                vignetteAmount = (num(values.opt("effects.vignette.amount")) ?: 0.0).toFloat(),
                vignetteMidpoint = (num(values.opt("effects.vignette.midpoint")) ?: 50.0).toFloat(),
                vignetteRoundness = (num(values.opt("effects.vignette.roundness")) ?: 0.0).toFloat(),
                vignetteFeather = (num(values.opt("effects.vignette.feather")) ?: 50.0).toFloat(),
                vignetteHighlights = (num(values.opt("effects.vignette.highlights")) ?: 0.0).toFloat(),
                grainAmount = (num(values.opt("effects.grain.amount")) ?: 0.0).toFloat(),
                grainSize = (num(values.opt("effects.grain.size")) ?: 25.0).toFloat(),
                grainRoughness = (num(values.opt("effects.grain.roughness")) ?: 50.0).toFloat(),
            )
        } else null

        val detail = if (hasDetail) {
            HDRDetailSettings(
                sharpening = (num(values.opt("detail.sharpening")) ?: 0.0).toFloat(),
                clarity = ((num(values.opt("effects.clarity")) ?: 0.0) / 100.0).toFloat(),
                dehaze = ((num(values.opt("effects.dehaze")) ?: 0.0) / 100.0).toFloat(),
                denoise = (num(values.opt("detail.denoise.post_rgb")) ?: 0.0).toFloat(),
            )
        } else null

        val look = if (hasLook) {
            val lObj = values.getJSONObject("hdr.look")
            HDRLookSettings(
                sha256 = if (lObj.isNull("sha256")) null else lObj.getString("sha256"),
                name = if (lObj.isNull("name")) null else lObj.getString("name"),
                strength = (num(lObj.opt("strength")) ?: 0.0).toFloat(),
            )
        } else null

        val cam = if (values.has("hdr.camera_development") && !values.isNull("hdr.camera_development")) {
            val cObj = values.getJSONObject("hdr.camera_development")
            val customWB = cObj.optString("white_balance_mode", "as_shot") == "temperature"
            val extra = metadata.optJSONObject("hdr_camera_development_extra")
            val cpObj = extra?.optJSONObject("camera_profile")
            val cp = cpObj?.let { HDRCameraProfile(it.getString("sha256"), it.getString("name")) }
            HDRCameraDevelopmentSettings(
                customWhiteBalance = customWB,
                temperature = (num(cObj.opt("temperature")) ?: 0.0).toFloat(),
                tint = (num(cObj.opt("tint")) ?: 0.0).toFloat(),
                sensorExposure = cObj.optString("exposure_reference", "metadata") == "sensor",
                fbddLevel = intVal(cObj.opt("fbdd_level")) ?: 0,
                lensDistortion = extra?.optBoolean("lens_distortion", false) ?: false,
                lensTca = extra?.optBoolean("lens_tca", false) ?: false,
                lensAutoCrop = extra?.optBoolean("lens_auto_crop", true) ?: true,
                lensProfile = if (extra != null && extra.has("lens_profile") && !extra.isNull("lens_profile")) extra.getString("lens_profile") else null,
                cameraProfile = cp,
                lensVignetting = extra?.optBoolean("lens_vignetting", false) ?: false,
            )
        } else null

        val geom = GeometrySettings(
            cropX = (num(values.opt("geometry.crop.x")) ?: 0.0).toFloat(),
            cropY = (num(values.opt("geometry.crop.y")) ?: 0.0).toFloat(),
            cropWidth = (num(values.opt("geometry.crop.width")) ?: 1.0).toFloat(),
            cropHeight = (num(values.opt("geometry.crop.height")) ?: 1.0).toFloat(),
            quarterTurns = intVal(values.opt("geometry.quarter_turns")) ?: 0,
            flipHorizontal = values.optBoolean("geometry.flip_horizontal", false),
            flipVertical = values.optBoolean("geometry.flip_vertical", false),
            straightenDegrees = (num(values.opt("geometry.straighten_degrees")) ?: 0.0).toFloat(),
            perspectiveHorizontal = (num(values.opt("geometry.perspective.horizontal")) ?: 0.0).toFloat(),
            perspectiveVertical = (num(values.opt("geometry.perspective.vertical")) ?: 0.0).toFloat(),
        )

        return HDRSettings(
            mode = if (activeMode) HDRMode.HDR else HDRMode.SDR,
            exposure = exposure,
            temperature = temp,
            tint = tint,
            contrast = contrast,
            highlights = highlights,
            shadows = shadows,
            saturation = saturation,
            geometry = geom,
            tone = tone,
            color = color,
            rendition = rendition,
            effects = fx,
            detail = detail,
            look = look,
            cameraDevelopment = cam,
        )
    }

    private fun buildSettings(record: JSONObject): EditSettings {
        val metadata = record.optJSONObject("metadata") ?: JSONObject()
        val sdrValues = record.optJSONObject("sdr_values") ?: JSONObject()
        val hdrValues = record.optJSONObject("hdr_values") ?: JSONObject()
        val dormantHdr = record.optJSONObject("dormant_hdr_values")
        val hdrEditing = metadata.optBoolean("hdr_editing", false)

        val proc = metadata.optJSONObject("processing")?.let {
            ProcessingIdentity(it.optString("family", "rawlab"), it.optInt("version", 3), it.optString("quality", "standard"))
        } ?: ProcessingIdentity.CURRENT
        val x3f = if (metadata.optString("x3f_mode", "normal-v1") == "legacy") X3fMode.LEGACY else X3fMode.NORMAL
        val mVer = if (metadata.has("master_recipe_settings_version") && !metadata.isNull("master_recipe_settings_version")) {
            metadata.getInt("master_recipe_settings_version")
        } else 3
        val proRawVer = if (metadata.has("pro_raw_decode_version") && !metadata.isNull("pro_raw_decode_version")) {
            metadata.getInt("pro_raw_decode_version")
        } else null

        val filmRaw = metadata.optString("film_id", "")
        val film = if (filmRaw.isEmpty()) "neutral" else filmRaw
        var recipeID = if (metadata.has("master_recipe_id") && !metadata.isNull("master_recipe_id")) metadata.getString("master_recipe_id") else null
        sdrValues.optJSONObject("looks.reference")?.let {
            if (it.optString("kind") == "recipe" && !it.isNull("id")) recipeID = it.getString("id")
        }

        val exposureMode = when (sdrValues.optString("light.exposure_mode", "preview")) {
            "scene" -> 0
            "sensor" -> 2
            else -> 1
        }
        val customWb = sdrValues.optString("color.white_balance.mode", "camera") == "temperature"

        val wObj = sdrValues.optJSONObject("detail.denoise.wavelet")
        val denoise = if (wObj != null) {
            DenoiseSettings(
                enabled = wObj.optBoolean("enabled", false),
                luma = wObj.optDouble("luma", 0.0).toFloat(),
                chroma = wObj.optDouble("chroma", 46.0).toFloat(),
                coarse = wObj.optDouble("coarse", 50.0).toFloat(),
            )
        } else DenoiseSettings()

        val effects = PhotoEffectsSettings(
            vignetteAmount = (num(sdrValues.opt("effects.vignette.amount")) ?: 0.0).toFloat(),
            vignetteMidpoint = (num(sdrValues.opt("effects.vignette.midpoint")) ?: 50.0).toFloat(),
            vignetteRoundness = (num(sdrValues.opt("effects.vignette.roundness")) ?: 0.0).toFloat(),
            vignetteFeather = (num(sdrValues.opt("effects.vignette.feather")) ?: 50.0).toFloat(),
            vignetteHighlights = (num(sdrValues.opt("effects.vignette.highlights")) ?: 0.0).toFloat(),
            grainAmount = (num(sdrValues.opt("effects.grain.amount")) ?: 0.0).toFloat(),
            grainSize = (num(sdrValues.opt("effects.grain.size")) ?: 25.0).toFloat(),
            grainRoughness = (num(sdrValues.opt("effects.grain.roughness")) ?: 50.0).toFloat(),
        )

        val lensExtra = metadata.optJSONObject("lens_extra")
        val lens = if (sdrValues.keys().asSequence().any { it.startsWith("geometry.lens.") }) {
            val pid = if (sdrValues.has("geometry.lens.profile_id") && !sdrValues.isNull("geometry.lens.profile_id")) {
                sdrValues.getString("geometry.lens.profile_id")
            } else null
            LensSettings(
                distortion = sdrValues.optBoolean("geometry.lens.distortion", false),
                tca = sdrValues.optBoolean("geometry.lens.tca", false),
                autoCrop = sdrValues.optBoolean("geometry.lens.auto_crop", true),
                manual = pid != null,
                profileId = pid,
                focalLength = lensExtra?.let { num(it.opt("focal_length"))?.toFloat() },
                cropFactor = lensExtra?.let { num(it.opt("crop_factor"))?.toFloat() },
                vignetting = sdrValues.optBoolean("geometry.lens.vignetting", false),
            )
        } else LensSettings()

        val geom = GeometrySettings(
            cropX = (num(sdrValues.opt("geometry.crop.x")) ?: 0.0).toFloat(),
            cropY = (num(sdrValues.opt("geometry.crop.y")) ?: 0.0).toFloat(),
            cropWidth = (num(sdrValues.opt("geometry.crop.width")) ?: 1.0).toFloat(),
            cropHeight = (num(sdrValues.opt("geometry.crop.height")) ?: 1.0).toFloat(),
            quarterTurns = intVal(sdrValues.opt("geometry.quarter_turns")) ?: 0,
            flipHorizontal = sdrValues.optBoolean("geometry.flip_horizontal", false),
            flipVertical = sdrValues.optBoolean("geometry.flip_vertical", false),
            straightenDegrees = (num(sdrValues.opt("geometry.straighten_degrees")) ?: 0.0).toFloat(),
            perspectiveHorizontal = (num(sdrValues.opt("geometry.perspective.horizontal")) ?: 0.0).toFloat(),
            perspectiveVertical = (num(sdrValues.opt("geometry.perspective.vertical")) ?: 0.0).toFloat(),
        )

        val hdr = when {
            hdrEditing -> buildHDR(hdrValues, metadata, activeMode = true)
            dormantHdr != null -> buildHDR(dormantHdr, metadata, activeMode = false)
            else -> null
        }

        return EditSettings(
            film = film,
            strength = (num(sdrValues.opt("looks.strength")) ?: 1.0).toFloat(),
            exposure = (num(sdrValues.opt("light.exposure")) ?: 0.0).toFloat(),
            highlights = -(num(sdrValues.opt("light.highlights")) ?: 0.0).toFloat(),
            shadows = (num(sdrValues.opt("light.shadows")) ?: 0.0).toFloat(),
            contrast = ((num(sdrValues.opt("light.contrast")) ?: 1.0) - 1.0).toFloat(),
            toneCurve = (num(sdrValues.opt("light.s_curve")) ?: 0.0).toFloat(),
            saturation = ((num(sdrValues.opt("color.saturation")) ?: 1.0) - 1.0).toFloat(),
            customWb = customWb,
            temperature = (num(sdrValues.opt("color.white_balance.temperature_kelvin")) ?: 6500.0).toFloat(),
            tint = (num(sdrValues.opt("color.white_balance.tint")) ?: 0.0).toFloat(),
            denoise = denoise,
            sharpening = (num(sdrValues.opt("detail.sharpening")) ?: 0.0).toFloat(),
            effects = effects,
            displayChromaDenoise = intVal(sdrValues.opt("detail.denoise.chroma_mode")) ?: 0,
            exposureMode = exposureMode,
            hsl = parseHSL(sdrValues),
            recipeID = recipeID,
            lens = lens,
            geometry = geom,
            processing = proc,
            x3fMode = x3f,
            blackPoint = (num(sdrValues.opt("tone.black_point")) ?: 0.0).toFloat(),
            whitePoint = (num(sdrValues.opt("tone.white_point")) ?: 0.0).toFloat(),
            vibrance = (num(sdrValues.opt("color.vibrance")) ?: 0.0).toFloat(),
            clarity = (num(sdrValues.opt("effects.clarity")) ?: 0.0).toFloat(),
            dehaze = (num(sdrValues.opt("effects.dehaze")) ?: 0.0).toFloat(),
            colorGrading = parseGrading(sdrValues),
            curve = sdrValues.optJSONObject("light.curve")?.let { parseCurve(it) } ?: ToneCurveSettings(),
            masterRecipeSettingsVersion = mVer,
            hdr = hdr,
            proRAWDecodeVersion = proRawVer,
        )
    }

    private fun verifyCurve(expected: JSONObject, actual: ToneCurveSettings, label: String) {
        val expMode = expected.optString("mode", "legacy")
        check(actual.mode.id == expMode, "$label: curve.mode")
        val pts = expected.optJSONArray("points") ?: JSONArray()
        check(actual.points.size == pts.length(), "$label: curve.points.size")
        for (i in 0 until pts.length()) {
            val pair = pts.getJSONArray(i)
            check(approx(actual.points[i].x, pair.getDouble(0)) && approx(actual.points[i].y, pair.getDouble(1)), "$label: curve[$i]")
        }
        if (expected.has("channels") && !expected.isNull("channels")) {
            val ch = expected.getJSONObject("channels")
            mapOf("red" to actual.channels.red, "green" to actual.channels.green, "blue" to actual.channels.blue).forEach { (k, shape) ->
                if (ch.has(k) && !ch.isNull(k)) {
                    val es = ch.getJSONObject(k)
                    check(shape.mode.id == es.optString("mode", "legacy"), "$label.$k.mode")
                    val ep = es.optJSONArray("points") ?: JSONArray()
                    check(shape.points.size == ep.length(), "$label.$k.points.size")
                }
            }
        }
    }

    private fun verifyHSL(values: JSONObject, actual: HslSettings, label: String) {
        val channels = listOf("red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta")
        for ((i, ch) in channels.withIndex()) {
            num(values.opt("color.hsl.hue.$ch"))?.let { check(approx(actual.value(0, i).toDouble(), it), "$label.hue.$ch") }
            num(values.opt("color.hsl.saturation.$ch"))?.let { check(approx(actual.value(1, i).toDouble(), it), "$label.sat.$ch") }
            num(values.opt("color.hsl.lightness.$ch"))?.let { check(approx(actual.value(2, i).toDouble(), it), "$label.luma.$ch") }
        }
    }

    private fun verifySettings(s: EditSettings, record: JSONObject) {
        val id = record.getString("id")
        val photo = record.optJSONObject("photo") ?: JSONObject()
        val isRaw = photo.optBoolean("is_raw", true)
        val metadata = record.optJSONObject("metadata") ?: JSONObject()
        val sdrValues = record.optJSONObject("sdr_values") ?: JSONObject()
        val hdrValues = record.optJSONObject("hdr_values") ?: JSONObject()
        val dormantHdr = record.optJSONObject("dormant_hdr_values")
        val hdrEditing = metadata.optBoolean("hdr_editing", false)

        val expFilmRaw = metadata.optString("film_id", "")
        check(s.film == (if (expFilmRaw.isEmpty()) "neutral" else expFilmRaw), "$id: film mismatch")
        val expRecipe = if (metadata.has("master_recipe_id") && !metadata.isNull("master_recipe_id")) metadata.getString("master_recipe_id") else null
        check(s.recipeID == expRecipe, "$id: recipeID mismatch")
        metadata.optJSONObject("processing")?.let { check(s.processing.version == it.getInt("version"), "$id: processing.version") }
        metadata.optString("x3f_mode", "").takeIf { it.isNotEmpty() }?.let { check(s.x3fMode.id == it, "$id: x3fMode") }
        if (metadata.has("master_recipe_settings_version") && !metadata.isNull("master_recipe_settings_version")) {
            check(s.masterRecipeSettingsVersion == metadata.getInt("master_recipe_settings_version"), "$id: masterRecipeSettingsVersion")
        }
        if (metadata.has("pro_raw_decode_version")) {
            val expPro = if (metadata.isNull("pro_raw_decode_version")) null else metadata.getInt("pro_raw_decode_version")
            check(s.proRAWDecodeVersion == expPro, "$id: proRAWDecodeVersion")
        }
        check(s.isHDREditing == hdrEditing, "$id: isHDREditing")

        num(sdrValues.opt("looks.strength"))?.let { check(approx(s.strength.toDouble(), it), "$id: strength") }
        num(sdrValues.opt("light.exposure"))?.let { check(approx(s.exposure.toDouble(), it), "$id: exposure") }
        sdrValues.optString("light.exposure_mode", "").takeIf { it.isNotEmpty() }?.let { em ->
            val actualEm = listOf("scene", "preview", "sensor")[s.exposureMode]
            check(actualEm == em, "$id: exposureMode")
        }
        num(sdrValues.opt("light.contrast"))?.let { check(approx(1.0 + s.contrast, it), "$id: contrast") }
        num(sdrValues.opt("light.highlights"))?.let { check(approx(-s.highlights.toDouble(), it), "$id: highlights") }
        num(sdrValues.opt("light.shadows"))?.let { check(approx(s.shadows.toDouble(), it), "$id: shadows") }
        num(sdrValues.opt("light.s_curve"))?.let { check(approx(s.toneCurve.toDouble(), it), "$id: s_curve") }
        sdrValues.optJSONObject("light.curve")?.let { verifyCurve(it, s.curve, "$id.sdr") }
        num(sdrValues.opt("tone.black_point"))?.let { check(approx(s.blackPoint.toDouble(), it), "$id: blackPoint") }
        num(sdrValues.opt("tone.white_point"))?.let { check(approx(s.whitePoint.toDouble(), it), "$id: whitePoint") }
        num(sdrValues.opt("color.vibrance"))?.let { check(approx(s.vibrance.toDouble(), it), "$id: vibrance") }
        sdrValues.optJSONObject("color.grading.shadows")?.let {
            check(approx(s.colorGrading.shadows.hue.toDouble(), it.getDouble("hue")), "$id: grading.shadows.hue")
            check(approx(s.colorGrading.shadows.saturation.toDouble(), it.getDouble("saturation")), "$id: grading.shadows.sat")
        }
        sdrValues.optString("color.white_balance.mode", "").takeIf { it.isNotEmpty() }?.let { wb ->
            val actualWb = if (!isRaw) "none" else if (s.customWb) "temperature" else "camera"
            check(actualWb == wb, "$id: wb.mode")
        }
        num(sdrValues.opt("color.white_balance.temperature_kelvin"))?.let { check(approx(s.temperature.toDouble(), it), "$id: temp") }
        num(sdrValues.opt("color.white_balance.tint"))?.let { check(approx(s.tint.toDouble(), it), "$id: tint") }
        num(sdrValues.opt("color.saturation"))?.let { check(approx(1.0 + s.saturation, it), "$id: saturation") }
        verifyHSL(sdrValues, s.hsl, "$id.sdr")

        num(sdrValues.opt("effects.vignette.amount"))?.let { check(approx(s.effects.vignetteAmount.toDouble(), it), "$id: v.amount") }
        num(sdrValues.opt("effects.clarity"))?.let { check(approx(s.clarity.toDouble(), it), "$id: clarity") }
        num(sdrValues.opt("effects.dehaze"))?.let { check(approx(s.dehaze.toDouble(), it), "$id: dehaze") }
        num(sdrValues.opt("detail.sharpening"))?.let { check(approx(s.sharpening.toDouble(), it), "$id: sharpening") }
        intVal(sdrValues.opt("detail.denoise.chroma_mode"))?.let { check(s.displayChromaDenoise == it, "$id: chroma_mode") }
        sdrValues.optJSONObject("detail.denoise.wavelet")?.let { w ->
            check(s.denoise.enabled == w.getBoolean("enabled"), "$id: wavelet.enabled")
            check(approx(s.denoise.luma.toDouble(), w.getDouble("luma")), "$id: wavelet.luma")
            check(approx(s.denoise.chroma.toDouble(), w.getDouble("chroma")), "$id: wavelet.chroma")
            check(approx(s.denoise.coarse.toDouble(), w.getDouble("coarse")), "$id: wavelet.coarse")
        }
        if (sdrValues.has("geometry.lens.distortion")) {
            check(s.lens.distortion == sdrValues.getBoolean("geometry.lens.distortion"), "$id: lens.dist")
            check(s.lens.tca == sdrValues.getBoolean("geometry.lens.tca"), "$id: lens.tca")
            check(s.lens.vignetting == sdrValues.getBoolean("geometry.lens.vignetting"), "$id: lens.vig")
            check(s.lens.autoCrop == sdrValues.getBoolean("geometry.lens.auto_crop"), "$id: lens.autoCrop")
            val expProfile = if (sdrValues.isNull("geometry.lens.profile_id")) null else sdrValues.optString("geometry.lens.profile_id")
            check(s.lens.profileId == expProfile, "$id: lens.profile")
        }

        val hdrCheck = if (hdrEditing) hdrValues else dormantHdr
        if (hdrCheck != null && hdrCheck.length() > 0) {
            val hdr = requireNotNull(s.hdr) { "$id: expected hdr subtree preserved" }
            num(hdrCheck.opt("light.exposure"))?.let { check(approx(hdr.exposure.toDouble(), it), "$id: hdr.exposure") }
            num(hdrCheck.opt("hdr.relative_temperature"))?.let { check(approx(hdr.temperature.toDouble(), it), "$id: hdr.temp") }
            num(hdrCheck.opt("hdr.relative_tint"))?.let { check(approx(hdr.tint.toDouble(), it), "$id: hdr.tint") }
            num(hdrCheck.opt("light.contrast"))?.let { check(approx(1.0 + hdr.contrast / 100.0, it), "$id: hdr.contrast") }
            num(hdrCheck.opt("light.highlights"))?.let { check(approx(-hdr.highlights / 100.0, it), "$id: hdr.highlights") }
            num(hdrCheck.opt("light.shadows"))?.let { check(approx(hdr.shadows / 100.0, it), "$id: hdr.shadows") }
            num(hdrCheck.opt("color.saturation"))?.let { check(approx(1.0 + hdr.saturation / 100.0, it), "$id: hdr.saturation") }
            num(hdrCheck.opt("hdr.peak_limit_ev"))?.let { check(approx(hdr.renditionSettings.peakLimitEV.toDouble(), it), "$id: hdr.peakLimit") }
            num(hdrCheck.opt("effects.clarity"))?.let { check(approx(hdr.detailSettings.clarity * 100.0, it), "$id: hdr.clarity") }
            num(hdrCheck.opt("detail.denoise.post_rgb"))?.let { check(approx(hdr.detailSettings.denoise.toDouble(), it), "$id: hdr.denoise") }
            hdrCheck.optJSONObject("hdr.look")?.let {
                check(hdr.lookSettings.sha256 == it.getString("sha256"), "$id: hdr.look.sha")
                check(approx(hdr.lookSettings.strength.toDouble(), it.getDouble("strength")), "$id: hdr.look.strength")
            }
            hdrCheck.optJSONObject("hdr.camera_development")?.let { cam ->
                val dev = requireNotNull(hdr.cameraDevelopment) { "$id: expected hdr.cameraDevelopment" }
                val wbStr = if (dev.customWhiteBalance) "temperature" else "as_shot"
                check(wbStr == cam.getString("white_balance_mode"), "$id: hdr.cam.wb")
                check(dev.fbddLevel == cam.getInt("fbdd_level"), "$id: hdr.cam.fbdd")
                metadata.optJSONObject("hdr_camera_development_extra")?.let { extra ->
                    val expLp = if (extra.isNull("lens_profile")) null else extra.optString("lens_profile")
                    check(dev.lensProfile == expLp, "$id: hdr.cam.lensProfile")
                    extra.optJSONObject("camera_profile")?.let { cp ->
                        check(dev.cameraProfile?.sha256 == cp.getString("sha256"), "$id: hdr.cam.profile")
                    }
                }
            }
        }
    }

    private fun encodeB64(identity: PhotoIdentity): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(identity.value.toByteArray(StandardCharsets.UTF_8))

    private fun loadProperties(file: File): Properties = Properties().apply {
        file.inputStream().use(::load)
    }

    private fun storeProperties(file: File, props: Properties) {
        file.outputStream().use { props.store(it, null) }
    }

    private fun mutateV2Record(file: File, identity: PhotoIdentity, transform: (JSONObject, JSONObject) -> Unit) {
        val props = loadProperties(file)
        val encKey = "record.${encodeB64(identity)}.values"
        val rawVal = props.getProperty(encKey) ?: error("Missing $encKey")
        require(rawVal.startsWith("v2:")) { "Expected v2 prefix" }
        val root = JSONObject(rawVal.removePrefix("v2:"))
        val settings = root.getJSONObject("settings")
        transform(root, settings)
        props.setProperty(encKey, "v2:$root")
        storeProperties(file, props)
    }

    private fun mutateUnknownScope(file: File, identity: PhotoIdentity, scope: String, key: String, value: Any) {
        val props = loadProperties(file)
        val encoded = encodeB64(identity)
        when (scope) {
            "store_root" -> {
                props.setProperty(key, value.toString())
                storeProperties(file, props)
                return
            }
            "store_sibling_entry" -> {
                val sibId = PhotoIdentity("content://test/future_sibling")
                val sibEnc = encodeB64(sibId)
                props.setProperty("record.$sibEnc.values", JSONObject().put(key, value).toString())
                storeProperties(file, props)
                return
            }
            "record_root" -> {
                props.setProperty("record.$encoded.$key", value.toString())
                storeProperties(file, props)
                return
            }
        }
        mutateV2Record(file, identity) { _, s ->
            when (scope) {
                "settings_root" -> s.put(key, value)
                "processing" -> s.getJSONObject("processing").put(key, value)
                "tone_controls" -> s.getJSONObject("tone").put(key, value)
                "atmosphere" -> s.getJSONObject("atmosphere").put(key, value)
                "color_grading" -> s.getJSONObject("colorGrading").put(key, value)
                "color_grading_zone" -> s.getJSONObject("colorGrading").getJSONObject("shadows").put(key, value)
                "tone_curve" -> s.getJSONObject("curve").put(key, value)
                "tone_curve_channels" -> s.getJSONObject("curve").getJSONObject("channels").put(key, value)
                "geometry" -> s.getJSONObject("geometry").put(key, value)
                "lens" -> s.getJSONObject("lens").put(key, value)
                "denoise" -> s.getJSONObject("denoise").put(key, value)
                "effects" -> s.getJSONObject("effects").put(key, value)
                "hdr" -> s.getJSONObject("hdr").put(key, value)
                "hdr_tone" -> s.getJSONObject("hdr").getJSONObject("tone").put(key, value)
                "hdr_color" -> s.getJSONObject("hdr").getJSONObject("color").put(key, value)
                "hdr_rendition" -> s.getJSONObject("hdr").getJSONObject("rendition").put(key, value)
                "hdr_effects" -> s.getJSONObject("hdr").getJSONObject("effects").put(key, value)
                "hdr_detail" -> s.getJSONObject("hdr").getJSONObject("detail").put(key, value)
                "hdr_look" -> s.getJSONObject("hdr").getJSONObject("look").put(key, value)
                "hdr_camera_development" -> s.getJSONObject("hdr").getJSONObject("camera_development").put(key, value)
                "hdr_camera_profile" -> s.getJSONObject("hdr").getJSONObject("camera_development").getJSONObject("camera_profile").put(key, value)
                else -> error("Unhandled target_scope: $scope")
            }
        }
    }

    @Test
    fun editRecordGoldenFixtureSuite() {
        check(
            knownEditRecordDivergences.size <= maxKnownEditRecordDivergences,
            "Divergence count ${knownEditRecordDivergences.size} exceeds cap $maxKnownEditRecordDivergences",
        )

        val fixture = JSONObject(resolveRepoFile("Shared/fixtures/edit-records-v1.json").readText())
        check(fixture.getInt("fixture_version") == 1, "fixture_version must be 1")
        check(fixture.getInt("spec_version") == 1, "spec_version must be 1")

        val recipesArr = JSONArray(resolveRepoFile("Shared/master-recipes.json").readText())
        val knownRecipeIds = (0 until recipesArr.length()).map { MasterRecipe.decode(recipesArr.getJSONObject(it)).id }.toSet()

        val tempRoot = Files.createTempDirectory("rawlab-android-edit-fixture").toFile()
        val failures = mutableListOf<String>()

        fun evaluate(id: String, block: () -> Unit) {
            try {
                block()
                knownEditRecordDivergences[id]?.let { reg ->
                    fail("Stale divergence ledger entry '$id' (${reg.ledgerId}): scenario now passed")
                }
                println("PASS: $id")
            } catch (t: Throwable) {
                val reg = knownEditRecordDivergences[id]
                if (reg != null) {
                    require(reg.ledgerId.isNotBlank() && reg.reason.isNotBlank()) { "Blank divergence entry for $id" }
                    println("KNOWN DIVERGENCE [$id] (${reg.ledgerId}): ${reg.reason} | observed: ${t.message}")
                } else {
                    val msg = "RED ANCHOR [$id]: ${t.javaClass.simpleName}: ${t.message}"
                    System.err.println(msg)
                    failures += msg
                }
            }
        }

        try {
            val byId = linkedMapOf<String, JSONObject>()
            val roundtrip = fixture.getJSONArray("roundtrip_records")
            for (i in 0 until roundtrip.length()) {
                val rec = roundtrip.getJSONObject(i)
                val id = rec.getString("id")
                byId[id] = rec
                evaluate("roundtrip:$id") {
                    val dir = File(tempRoot, "rt-$id").apply { mkdirs() }
                    val store = EditStore(dir)
                    val pid = PhotoIdentity("content://test/${rec.getJSONObject("photo").getString("name")}")
                    val built = buildSettings(rec)
                    store.save(pid, built)
                    val meta = rec.optJSONObject("metadata")
                    val receipt = meta?.optJSONObject("migration_receipt")
                    if (receipt?.optString("status") == "kept") {
                        val quality = ProcessingMigrationQuality(0.01f, 0.02f, 0.02f, 0.01f, 10)
                        store.commitProcessingMigration(store.readState(pid), null, quality)
                    }
                    val reopened = EditStore(dir)
                    val loaded = reopened.readState(pid).settings ?: error("$id: null reloaded settings")
                    verifySettings(loaded, rec)
                    if (receipt?.optString("status") == "kept") {
                        check(reopened.processingMigration(pid)?.status == ProcessingMigrationStatus.KEPT, "$id: kept receipt")
                    }
                }
            }

            val unknowns = fixture.getJSONArray("unknown_field_scenarios")
            for (i in 0 until unknowns.length()) {
                val sc = unknowns.getJSONObject(i)
                val id = sc.getString("id")
                val baseRec = byId.getValue(sc.getString("base_record_id"))
                val scope = sc.getString("target_scope")
                val key = sc.getString("inject_key")
                val value = sc.get("inject_value")
                evaluate(id) {
                    val dir = File(tempRoot, "x1-$id").apply { mkdirs() }
                    val store = EditStore(dir)
                    val targetId = PhotoIdentity("content://test/t-$id")
                    val sibId = PhotoIdentity("content://test/s-$id")
                    store.save(targetId, buildSettings(baseRec))
                    store.save(sibId, buildSettings(byId.getValue("raster-sdr-neutral")))

                    val file = File(dir, "edits.properties")
                    mutateUnknownScope(file, targetId, scope, key, value)

                    val reopened = EditStore(dir)
                    val loaded = reopened.readState(targetId).settings ?: error("$id: target null")
                    verifySettings(loaded, baseRec)
                    check(reopened.readState(sibId).settings != null, "$id: sibling null")
                }
            }

            val compats = fixture.getJSONArray("compatibility_scenarios")
            for (i in 0 until compats.length()) {
                val sc = compats.getJSONObject(i)
                val id = sc.getString("id")
                val kind = sc.getString("kind")
                val baseRec = byId.getValue(sc.getString("base_record_id"))
                evaluate(id) {
                    when (kind) {
                        "legacy_omitted_extensions" -> {
                            val dir = File(tempRoot, "c-$id").apply { mkdirs() }
                            val pid = PhotoIdentity("content://test/leg-$id")
                            EditStore(dir).save(pid, buildSettings(baseRec))
                            mutateV2Record(File(dir, "edits.properties"), pid) { _, s ->
                                listOf("processing", "x3fMode", "masterRecipeSettingsVersion", "tone", "toneControls",
                                    "atmosphere", "colorGrading", "curve", "hdr", "proRAWDecodeVersion").forEach { s.remove(it) }
                            }
                            val loaded = EditStore(dir).readState(pid).settings!!
                            check(loaded.processing == ProcessingIdentity.LEGACY, "$id: expected legacy processing")
                            check(loaded.x3fMode == X3fMode.LEGACY, "$id: expected legacy x3fMode")
                        }
                        "sdr_reset_preserves_dormant_hdr" -> {
                            val dir = File(tempRoot, "c-$id").apply { mkdirs() }
                            val pid = PhotoIdentity("content://test/rst-$id")
                            val built = buildSettings(baseRec)
                            val store = EditStore(dir)
                            store.save(pid, built)
                            val ctx = EditorResetContext(
                                input = PhotoInputKind.RAW,
                                defaults = EditSettings(exposureMode = 1, temperature = 5400f, tint = -4f),
                                asShot = AsShotWhiteBalance(5400f, -4f),
                                knownRecipeIds = knownRecipeIds,
                            )
                            val res = EditorAdjustmentRules.prepareReset(EditorResetScope.All, built, ctx)
                            require(res is EditorResetResult.Ready) { "$id: expected Ready, got $res" }
                            store.save(pid, res.candidate)
                            val reloaded = EditStore(dir).readState(pid).settings!!
                            check(reloaded.hdr?.exposure == -0.5f && reloaded.hdr?.mode == HDRMode.SDR, "$id: dormant HDR preserved")
                            check(reloaded.proRAWDecodeVersion == 2, "$id: proRAWDecodeVersion preserved")
                            check(reloaded.processing.version == 2, "$id: processing.version preserved")
                            check(reloaded.x3fMode == X3fMode.LEGACY, "$id: x3fMode preserved")
                        }
                        "future_processing_version" -> {
                            val sibRec = byId.getValue(sc.getString("sibling_record_id"))
                            val dir = File(tempRoot, "c-$id").apply { mkdirs() }
                            val targetId = PhotoIdentity("content://test/fut-$id")
                            val sibId = PhotoIdentity("content://test/sib-$id")
                            val store = EditStore(dir)
                            val sibBuilt = buildSettings(sibRec)
                            store.save(targetId, buildSettings(baseRec))
                            store.save(sibId, sibBuilt)
                            val file = File(dir, "edits.properties")
                            mutateV2Record(file, targetId) { _, s ->
                                s.put("processing", JSONObject().put("family", "rawlab").put("version", 99).put("quality", "standard"))
                            }
                            val reopened = EditStore(dir)
                            var threw = false
                            try { reopened.readState(targetId) } catch (_: UnusableEditRecordException) { threw = true }
                            check(threw, "$id: processing.version=99 must throw UnusableEditRecordException")
                            check(reopened.readState(sibId).settings != null, "$id: healthy sibling must stay readable")
                            reopened.save(sibId, sibBuilt.copy(exposure = 1.5f))
                            val afterProps = loadProperties(file)
                            check(afterProps.getProperty("record.${encodeB64(targetId)}.values") != null, "$id: future record preserved")
                        }
                        "corrupt_entry" -> {
                            val sibRec = byId.getValue(sc.getString("sibling_record_id"))
                            val dir = File(tempRoot, "c-$id").apply { mkdirs() }
                            val targetId = PhotoIdentity("content://test/bad-$id")
                            val sibId = PhotoIdentity("content://test/sib2-$id")
                            val store = EditStore(dir)
                            val sibBuilt = buildSettings(sibRec)
                            store.save(targetId, buildSettings(baseRec))
                            store.save(sibId, sibBuilt)
                            val file = File(dir, "edits.properties")
                            val props = loadProperties(file)
                            props.setProperty("record.${encodeB64(targetId)}.values", "corrupt-entry-payload")
                            storeProperties(file, props)

                            val reopened = EditStore(dir)
                            var threw = false
                            try { reopened.readState(targetId) } catch (_: UnusableEditRecordException) { threw = true }
                            check(threw, "$id: corrupt entry must throw UnusableEditRecordException")
                            check(reopened.readState(sibId).settings != null, "$id: healthy sibling readable")
                            reopened.save(sibId, sibBuilt.copy(exposure = 1.1f))
                            check(file.readText().contains("corrupt-entry-payload"), "$id: corrupt bytes preserved across sibling save")
                        }
                        "negative_zero" -> {
                            val dir = File(tempRoot, "c-$id").apply { mkdirs() }
                            val pid = PhotoIdentity("content://test/nz-$id")
                            EditStore(dir).save(pid, buildSettings(baseRec).copy(exposure = 0f))
                            val file = File(dir, "edits.properties")
                            val props = loadProperties(file)
                            val key = "record.${encodeB64(pid)}.values"
                            val raw = props.getProperty(key)!!
                            val mutated = raw.replace("\"exposure\":0,", "\"exposure\":-0.0,")
                            check(mutated.contains("\"exposure\":-0.0,"), "$id: test setup failed to inject -0.0")
                            props.setProperty(key, mutated)
                            storeProperties(file, props)
                            val loaded = EditStore(dir).readState(pid).settings!!
                            check(java.lang.Float.floatToRawIntBits(loaded.exposure) == 0, "$id: -0.0 must canonicalize to +0.0f")
                        }
                        else -> error("Unhandled compat kind: $kind")
                    }
                }
            }

            val boundaries = fixture.getJSONArray("boundary_scenarios")
            for (i in 0 until boundaries.length()) {
                val sc = boundaries.getJSONObject(i)
                val id = sc.getString("id")
                val baseRec = byId.getValue(sc.getString("base_record_id"))
                val sibRec = byId.getValue(sc.getString("sibling_record_id"))
                val mut = sc.getJSONObject("mutation")
                val mKind = mut.getString("kind")
                evaluate(id) {
                    val dir = File(tempRoot, "b-$id").apply { mkdirs() }
                    val targetId = PhotoIdentity("content://test/bt-$id")
                    val sibId = PhotoIdentity("content://test/bs-$id")
                    val store = EditStore(dir)
                    store.save(targetId, buildSettings(baseRec))
                    store.save(sibId, buildSettings(sibRec))
                    val file = File(dir, "edits.properties")
                    mutateV2Record(file, targetId) { _, s ->
                        when (mKind) {
                            "out_of_range" -> when (val field = mut.getString("field")) {
                                "light.exposure" -> s.put("exposure", mut.getDouble("value"))
                                "color.white_balance.temperature_kelvin" -> s.put("temperature", mut.getDouble("value"))
                                "effects.vignette.amount" -> s.getJSONObject("effects").put("vignetteAmount", mut.getDouble("value"))
                                "color.hsl.hue.red" -> s.getJSONArray("hsl").put(0, mut.getDouble("value"))
                                "color.grading.shadows.hue" -> s.getJSONObject("colorGrading").getJSONObject("shadows").put("hue", mut.getDouble("value"))
                                "hdr.peak_limit_ev" -> s.getJSONObject("hdr").getJSONObject("rendition").put("peak_limit_ev", mut.getDouble("value"))
                                else -> error("Unhandled field: $field")
                            }
                            "crop_overflow" -> s.getJSONObject("geometry")
                                .put("cropX", mut.getDouble("cropX")).put("cropWidth", mut.getDouble("cropWidth"))
                            "invalid_exposure_mode" -> s.put("exposureMode", "future_unknown_mode")
                            "non_monotonic_curve" -> s.put("curve", JSONObject().put("mode", "custom").put(
                                "points", JSONArray().put(JSONArray(listOf(0.0, 0.0))).put(JSONArray(listOf(0.6, 0.5)))
                                    .put(JSONArray(listOf(0.4, 0.8))).put(JSONArray(listOf(1.0, 1.0)))
                            ))
                            else -> error("Unhandled boundary mutation: $mKind")
                        }
                    }
                    val reopened = EditStore(dir)
                    var threw = false
                    try { reopened.readState(targetId) } catch (_: UnusableEditRecordException) { threw = true }
                    check(threw, "$id: out-of-range/invalid boundary record must throw UnusableEditRecordException")
                    check(reopened.readState(sibId).settings != null, "$id: sibling must remain readable")
                }
            }
        } finally {
            tempRoot.deleteRecursively()
        }

        if (failures.isNotEmpty()) {
            fail("${failures.size} Android edit-record scenario(s) failed:\n${failures.joinToString("\n")}")
        }
        println("PASS: Android edit-record fixture suite finished with ${knownEditRecordDivergences.size} registered divergences (cap $maxKnownEditRecordDivergences)")
    }
}
