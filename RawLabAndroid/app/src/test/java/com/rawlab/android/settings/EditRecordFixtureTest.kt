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
    private data class EditRecordDivergence(
        val ledgerId: String,
        val reason: String,
        val expectedObservedSubstring: String? = null,
    )

    private class ExpectationMismatchException(message: String) : AssertionError(message)
    private class StoreRejectionException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)
    private class HarnessSetupException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)

    private enum class EvalCatchScope {
        EXPECTATION_ONLY,
        EXPECTATION_OR_PERSISTENCE_REJECTION,
    }

    // -----------------------------------------------------------------------
    // Divergence ledger (populated ONLY from observed red anchors)
    // -----------------------------------------------------------------------
    private val maxKnownEditRecordDivergences = 10

    private val knownEditRecordDivergences: Map<String, EditRecordDivergence> = mapOf(
        "x1-store-root-unknown-field" to EditRecordDivergence(
            ledgerId = "EDIT-DIV-AND-X1-01",
            reason = "EditStore.read rejects unrecognized top-level .properties keys instead of tolerating Tier 1 outer store extensions (EditPersistence.kt:209).",
            expectedObservedSubstring = "Unknown edit store property",
        ),
        "x1-record-root-unknown-field" to EditRecordDivergence(
            ledgerId = "EDIT-DIV-AND-X1-02",
            reason = "EditStore.read rejects unknown per-record property suffixes outside recordSuffixes instead of tolerating Tier 1 record-level extensions.",
            expectedObservedSubstring = "Unknown edit record field",
        ),
        "x1-settings-root-unknown-field" to EditRecordDivergence(
            ledgerId = "EDIT-DIV-AND-X1-03",
            reason = "StructuredSettingsCodec enforces closed keys on v2 settings root instead of tolerating Tier 1 unknown settings keys.",
            expectedObservedSubstring = "Unknown or missing settings field",
        ),
        "x1-tone-controls-unknown-field" to EditRecordDivergence(
            ledgerId = "EDIT-DIV-AND-X1-04",
            reason = "StructuredSettingsCodec enforces closed keys on tone extension object.",
            expectedObservedSubstring = "Unknown or missing settings field",
        ),
        "x1-atmosphere-unknown-field" to EditRecordDivergence(
            ledgerId = "EDIT-DIV-AND-X1-05",
            reason = "StructuredSettingsCodec enforces closed keys on atmosphere extension object.",
            expectedObservedSubstring = "Unknown or missing settings field",
        ),
        "x1-geometry-unknown-field" to EditRecordDivergence(
            ledgerId = "EDIT-DIV-AND-X1-06",
            reason = "StructuredSettingsCodec enforces closed keys on geometry extension object.",
            expectedObservedSubstring = "Unknown or missing settings field",
        ),
        "x1-lens-unknown-field" to EditRecordDivergence(
            ledgerId = "EDIT-DIV-AND-X1-07",
            reason = "StructuredSettingsCodec enforces closed keys on lens extension object.",
            expectedObservedSubstring = "Unknown or missing settings field",
        ),
        "x1-denoise-unknown-field" to EditRecordDivergence(
            ledgerId = "EDIT-DIV-AND-X1-08",
            reason = "StructuredSettingsCodec enforces closed keys on denoise extension object.",
            expectedObservedSubstring = "Unknown or missing settings field",
        ),
        "x1-effects-unknown-field" to EditRecordDivergence(
            ledgerId = "EDIT-DIV-AND-X1-09",
            reason = "StructuredSettingsCodec enforces closed keys on effects extension object.",
            expectedObservedSubstring = "Unknown or missing settings field",
        ),
        "compat-legacy-omitted-extensions" to EditRecordDivergence(
            ledgerId = "EDIT-DIV-AND-COMPAT-01",
            reason = "EditPersistence.kt:223-225 Base64-decodes the default string 'neutral' when record.<id>.film is omitted in legacy .properties, and StructuredSettingsCodec rejects stripped v2 JSON without processing/tone keys.",
            expectedObservedSubstring = "wire film_id",
        ),
    )

    private fun resolveRepoFile(relativePath: String): File {
        var dir: File? = File(".").canonicalFile
        while (dir != null) {
            val candidate = File(dir, relativePath)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw HarnessSetupException("Could not locate $relativePath from ${File(".").canonicalPath}")
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
        if (!condition) throw ExpectationMismatchException(message)
    }

    private fun checkSetup(condition: Boolean, message: String) {
        if (!condition) throw HarnessSetupException(message)
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

    private fun verifySettings(s: EditSettings, record: JSONObject) {
        val id = record.getString("id")
        val photo = record.optJSONObject("photo") ?: JSONObject()
        val isRaw = photo.optBoolean("is_raw", true)
        val metadata = record.optJSONObject("metadata") ?: JSONObject()
        val sdrValues = record.optJSONObject("sdr_values") ?: JSONObject()
        val hdrValues = record.optJSONObject("hdr_values") ?: JSONObject()
        val dormantHdr = record.optJSONObject("dormant_hdr_values")
        val hdrEditing = metadata.optBoolean("hdr_editing", false)

        val mismatches = mutableListOf<String>()
        fun verify(ok: Boolean, detail: String) {
            if (!ok) mismatches += detail
        }
        fun verifyCurveInto(expected: JSONObject, actual: ToneCurveSettings, label: String) {
            val expMode = expected.optString("mode", "legacy")
            verify(actual.mode.id == expMode, "$label.curve.mode(exp=$expMode,got=${actual.mode.id})")
            val pts = expected.optJSONArray("points") ?: JSONArray()
            verify(actual.points.size == pts.length(), "$label.curve.points.size(exp=${pts.length()},got=${actual.points.size})")
            if (actual.points.size == pts.length()) {
                for (i in 0 until pts.length()) {
                    val pair = pts.getJSONArray(i)
                    verify(
                        approx(actual.points[i].x, pair.getDouble(0)) && approx(actual.points[i].y, pair.getDouble(1)),
                        "$label.curve[$i]",
                    )
                }
            }
            if (expected.has("channels") && !expected.isNull("channels")) {
                val ch = expected.getJSONObject("channels")
                mapOf("red" to actual.channels.red, "green" to actual.channels.green, "blue" to actual.channels.blue).forEach { (k, shape) ->
                    if (ch.has(k) && !ch.isNull(k)) {
                        val es = ch.getJSONObject(k)
                        verify(shape.mode.id == es.optString("mode", "legacy"), "$label.curve.$k.mode")
                        val ep = es.optJSONArray("points") ?: JSONArray()
                        verify(shape.points.size == ep.length(), "$label.curve.$k.points.size")
                        if (shape.points.size == ep.length()) {
                            for (i in 0 until ep.length()) {
                                val pair = ep.getJSONArray(i)
                                verify(
                                    approx(shape.points[i].x, pair.getDouble(0)) && approx(shape.points[i].y, pair.getDouble(1)),
                                    "$label.curve.$k[$i]",
                                )
                            }
                        }
                    }
                }
            }
        }
        fun verifyHslInto(values: JSONObject, actual: HslSettings, label: String) {
            val channels = listOf("red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta")
            for ((i, ch) in channels.withIndex()) {
                num(values.opt("color.hsl.hue.$ch"))?.let { verify(approx(actual.value(0, i).toDouble(), it), "$label.hsl.hue.$ch") }
                num(values.opt("color.hsl.saturation.$ch"))?.let { verify(approx(actual.value(1, i).toDouble(), it), "$label.hsl.sat.$ch") }
                num(values.opt("color.hsl.lightness.$ch"))?.let { verify(approx(actual.value(2, i).toDouble(), it), "$label.hsl.lit.$ch") }
            }
        }
        fun verifyGradingInto(values: JSONObject, actual: ColorGradingSettings, label: String) {
            val zones = listOf("shadows" to actual.shadows, "midtones" to actual.midtones, "highlights" to actual.highlights)
            for ((zoneName, wheel) in zones) {
                values.optJSONObject("color.grading.$zoneName")?.let {
                    verify(
                        approx(wheel.hue.toDouble(), it.getDouble("hue")) &&
                            approx(wheel.saturation.toDouble(), it.getDouble("saturation")),
                        "$label.grading.$zoneName",
                    )
                }
            }
        }
        fun verifyEffectsInto(values: JSONObject, actual: PhotoEffectsSettings, label: String) {
            num(values.opt("effects.vignette.amount"))?.let { verify(approx(actual.vignetteAmount.toDouble(), it), "$label.effects.vignette.amount") }
            num(values.opt("effects.vignette.midpoint"))?.let { verify(approx(actual.vignetteMidpoint.toDouble(), it), "$label.effects.vignette.midpoint") }
            num(values.opt("effects.vignette.roundness"))?.let { verify(approx(actual.vignetteRoundness.toDouble(), it), "$label.effects.vignette.roundness") }
            num(values.opt("effects.vignette.feather"))?.let { verify(approx(actual.vignetteFeather.toDouble(), it), "$label.effects.vignette.feather") }
            num(values.opt("effects.vignette.highlights"))?.let { verify(approx(actual.vignetteHighlights.toDouble(), it), "$label.effects.vignette.highlights") }
            num(values.opt("effects.grain.amount"))?.let { verify(approx(actual.grainAmount.toDouble(), it), "$label.effects.grain.amount") }
            num(values.opt("effects.grain.size"))?.let { verify(approx(actual.grainSize.toDouble(), it), "$label.effects.grain.size") }
            num(values.opt("effects.grain.roughness"))?.let { verify(approx(actual.grainRoughness.toDouble(), it), "$label.effects.grain.roughness") }
        }
        fun verifyGeomInto(values: JSONObject, actual: GeometrySettings, label: String) {
            num(values.opt("geometry.crop.x"))?.let { verify(approx(actual.cropX.toDouble(), it), "$label.cropX") }
            num(values.opt("geometry.crop.y"))?.let { verify(approx(actual.cropY.toDouble(), it), "$label.cropY") }
            num(values.opt("geometry.crop.width"))?.let { verify(approx(actual.cropWidth.toDouble(), it), "$label.cropWidth") }
            num(values.opt("geometry.crop.height"))?.let { verify(approx(actual.cropHeight.toDouble(), it), "$label.cropHeight") }
            intVal(values.opt("geometry.quarter_turns"))?.let { verify(actual.quarterTurns == it, "$label.quarterTurns") }
            if (values.has("geometry.flip_horizontal")) verify(actual.flipHorizontal == values.getBoolean("geometry.flip_horizontal"), "$label.flipH")
            if (values.has("geometry.flip_vertical")) verify(actual.flipVertical == values.getBoolean("geometry.flip_vertical"), "$label.flipV")
            num(values.opt("geometry.straighten_degrees"))?.let { verify(approx(actual.straightenDegrees.toDouble(), it), "$label.straighten") }
            num(values.opt("geometry.perspective.horizontal"))?.let { verify(approx(actual.perspectiveHorizontal.toDouble(), it), "$label.perspH") }
            num(values.opt("geometry.perspective.vertical"))?.let { verify(approx(actual.perspectiveVertical.toDouble(), it), "$label.perspV") }
        }

        val expFilmRaw = metadata.optString("film_id", "")
        val expFilm = if (expFilmRaw.isEmpty()) "neutral" else expFilmRaw
        verify(s.film == expFilm, "film(exp=$expFilm,got=${s.film})")
        val expRecipe = if (metadata.has("master_recipe_id") && !metadata.isNull("master_recipe_id")) metadata.getString("master_recipe_id") else null
        verify(s.recipeID == expRecipe, "recipeID(exp=$expRecipe,got=${s.recipeID})")
        sdrValues.optJSONObject("looks.reference")?.let { lookRef ->
            when (lookRef.optString("kind")) {
                "recipe" -> verify(s.recipeID == lookRef.optString("id"), "looks.reference.recipe")
                "builtin", "managed" -> verify(s.film == expFilm && s.film != "neutral", "looks.reference.${lookRef.optString("kind")}")
                "neutral" -> verify(s.film == "neutral" && s.recipeID == null, "looks.reference.neutral")
            }
        }
        metadata.optJSONObject("processing")?.let { verify(s.processing.version == it.getInt("version"), "processing.version") }
        metadata.optString("x3f_mode", "").takeIf { it.isNotEmpty() }?.let { verify(s.x3fMode.id == it, "x3fMode") }
        if (metadata.has("master_recipe_settings_version") && !metadata.isNull("master_recipe_settings_version")) {
            verify(s.masterRecipeSettingsVersion == metadata.getInt("master_recipe_settings_version"), "masterRecipeSettingsVersion")
        }
        if (metadata.has("pro_raw_decode_version")) {
            val expPro = if (metadata.isNull("pro_raw_decode_version")) null else metadata.getInt("pro_raw_decode_version")
            verify(s.proRAWDecodeVersion == expPro, "proRAWDecodeVersion")
        }
        verify(s.isHDREditing == hdrEditing, "isHDREditing")

        num(sdrValues.opt("looks.strength"))?.let { verify(approx(s.strength.toDouble(), it), "looks.strength") }
        num(sdrValues.opt("light.exposure"))?.let { verify(approx(s.exposure.toDouble(), it), "light.exposure") }
        sdrValues.optString("light.exposure_mode", "").takeIf { it.isNotEmpty() }?.let { em ->
            val actualEm = listOf("scene", "preview", "sensor")[s.exposureMode]
            verify(actualEm == em, "light.exposure_mode")
        }
        num(sdrValues.opt("light.contrast"))?.let { verify(approx(1.0 + s.contrast, it), "light.contrast") }
        num(sdrValues.opt("light.highlights"))?.let { verify(approx(-s.highlights.toDouble(), it), "light.highlights") }
        num(sdrValues.opt("light.shadows"))?.let { verify(approx(s.shadows.toDouble(), it), "light.shadows") }
        num(sdrValues.opt("light.s_curve"))?.let { verify(approx(s.toneCurve.toDouble(), it), "light.s_curve") }
        sdrValues.optJSONObject("light.curve")?.let { verifyCurveInto(it, s.curve, "sdr") }
        num(sdrValues.opt("tone.black_point"))?.let { verify(approx(s.blackPoint.toDouble(), it), "tone.black_point") }
        num(sdrValues.opt("tone.white_point"))?.let { verify(approx(s.whitePoint.toDouble(), it), "tone.white_point") }
        num(sdrValues.opt("color.vibrance"))?.let { verify(approx(s.vibrance.toDouble(), it), "color.vibrance") }
        verifyGradingInto(sdrValues, s.colorGrading, "sdr")
        sdrValues.optString("color.white_balance.mode", "").takeIf { it.isNotEmpty() }?.let { wb ->
            val actualWb = if (!isRaw) "none" else if (s.customWb) "temperature" else "camera"
            verify(actualWb == wb, "wb.mode")
        }
        num(sdrValues.opt("color.white_balance.temperature_kelvin"))?.let { verify(approx(s.temperature.toDouble(), it), "wb.temp") }
        num(sdrValues.opt("color.white_balance.tint"))?.let { verify(approx(s.tint.toDouble(), it), "wb.tint") }
        num(sdrValues.opt("color.saturation"))?.let { verify(approx(1.0 + s.saturation, it), "color.saturation") }
        verifyHslInto(sdrValues, s.hsl, "sdr")

        verifyEffectsInto(sdrValues, s.effects, "sdr")
        num(sdrValues.opt("effects.clarity"))?.let { verify(approx(s.clarity.toDouble(), it), "effects.clarity") }
        num(sdrValues.opt("effects.dehaze"))?.let { verify(approx(s.dehaze.toDouble(), it), "effects.dehaze") }
        num(sdrValues.opt("detail.sharpening"))?.let { verify(approx(s.sharpening.toDouble(), it), "detail.sharpening") }
        intVal(sdrValues.opt("detail.denoise.chroma_mode"))?.let { verify(s.displayChromaDenoise == it, "detail.denoise.chroma_mode") }
        sdrValues.optJSONObject("detail.denoise.wavelet")?.let { w ->
            verify(s.denoise.enabled == w.getBoolean("enabled"), "wavelet.enabled")
            verify(approx(s.denoise.luma.toDouble(), w.getDouble("luma")), "wavelet.luma")
            verify(approx(s.denoise.chroma.toDouble(), w.getDouble("chroma")), "wavelet.chroma")
            verify(approx(s.denoise.coarse.toDouble(), w.getDouble("coarse")), "wavelet.coarse")
            w.optString("preset", "").takeIf { it.isNotEmpty() }?.let { verify(s.denoise.preset.name.lowercase() == it, "wavelet.preset") }
        }
        verifyGeomInto(sdrValues, s.geometry, "sdr")
        if (sdrValues.has("geometry.lens.distortion")) {
            verify(s.lens.distortion == sdrValues.getBoolean("geometry.lens.distortion"), "lens.dist")
            verify(s.lens.tca == sdrValues.getBoolean("geometry.lens.tca"), "lens.tca")
            verify(s.lens.vignetting == sdrValues.getBoolean("geometry.lens.vignetting"), "lens.vig")
            verify(s.lens.autoCrop == sdrValues.getBoolean("geometry.lens.auto_crop"), "lens.autoCrop")
            val expProfile = if (sdrValues.isNull("geometry.lens.profile_id")) null else sdrValues.optString("geometry.lens.profile_id")
            verify(s.lens.profileId == expProfile, "lens.profile")
            metadata.optJSONObject("lens_extra")?.let { extra ->
                num(extra.opt("focal_length"))?.let { verify(approx(s.lens.focalLength?.toDouble() ?: -1.0, it), "lens.focalLength") }
                num(extra.opt("crop_factor"))?.let { verify(approx(s.lens.cropFactor?.toDouble() ?: -1.0, it), "lens.cropFactor") }
            }
        }

        val hdrCheck = if (hdrEditing) hdrValues else dormantHdr
        if (hdrCheck != null && hdrCheck.length() > 0) {
            val hdr = s.hdr ?: throw ExpectationMismatchException("$id: expected hdr subtree preserved")
            verify((hdr.mode == HDRMode.HDR) == hdrEditing, "hdr.mode")
            num(hdrCheck.opt("light.exposure"))?.let { verify(approx(hdr.exposure.toDouble(), it), "hdr.exposure") }
            num(hdrCheck.opt("hdr.relative_temperature"))?.let { verify(approx(hdr.temperature.toDouble(), it), "hdr.temp") }
            num(hdrCheck.opt("hdr.relative_tint"))?.let { verify(approx(hdr.tint.toDouble(), it), "hdr.tint") }
            num(hdrCheck.opt("light.contrast"))?.let { verify(approx(1.0 + hdr.contrast / 100.0, it), "hdr.contrast") }
            num(hdrCheck.opt("light.highlights"))?.let { verify(approx(-hdr.highlights / 100.0, it), "hdr.highlights") }
            num(hdrCheck.opt("light.shadows"))?.let { verify(approx(hdr.shadows / 100.0, it), "hdr.shadows") }
            num(hdrCheck.opt("color.saturation"))?.let { verify(approx(1.0 + hdr.saturation / 100.0, it), "hdr.saturation") }
            num(hdrCheck.opt("tone.black_point"))?.let { verify(approx(hdr.toneSettings.blackPoint.toDouble(), it), "hdr.blackPoint") }
            num(hdrCheck.opt("tone.white_point"))?.let { verify(approx(hdr.toneSettings.whitePoint.toDouble(), it), "hdr.whitePoint") }
            num(hdrCheck.opt("light.s_curve"))?.let { verify(approx(hdr.toneSettings.curveStrength.toDouble() / 100.0, it), "hdr.sCurve") }
            hdrCheck.optJSONObject("light.curve")?.let { verifyCurveInto(it, hdr.toneSettings.curve, "hdr") }
            num(hdrCheck.opt("color.vibrance"))?.let { verify(approx(hdr.colorSettings.vibrance.toDouble(), it), "hdr.vibrance") }
            verifyHslInto(hdrCheck, hdr.colorSettings.hsl, "hdr")
            verifyGradingInto(hdrCheck, hdr.colorSettings.grading, "hdr")
            num(hdrCheck.opt("hdr.peak_limit_ev"))?.let { verify(approx(hdr.renditionSettings.peakLimitEV.toDouble(), it), "hdr.peakLimit") }
            num(hdrCheck.opt("hdr.sdr_exposure_ev"))?.let { verify(approx(hdr.renditionSettings.sdrExposureEV.toDouble(), it), "hdr.sdrExp") }
            num(hdrCheck.opt("hdr.sdr_contrast"))?.let { verify(approx(hdr.renditionSettings.sdrContrast.toDouble(), it), "hdr.sdrCon") }
            num(hdrCheck.opt("hdr.sdr_saturation"))?.let { verify(approx(hdr.renditionSettings.sdrSaturation.toDouble(), it), "hdr.sdrSat") }
            verifyEffectsInto(hdrCheck, hdr.effectSettings, "hdr")
            num(hdrCheck.opt("detail.sharpening"))?.let { verify(approx(hdr.detailSettings.sharpening.toDouble(), it), "hdr.detail.sharpening") }
            num(hdrCheck.opt("effects.clarity"))?.let { verify(approx(hdr.detailSettings.clarity * 100.0, it), "hdr.clarity") }
            num(hdrCheck.opt("effects.dehaze"))?.let { verify(approx(hdr.detailSettings.dehaze * 100.0, it), "hdr.dehaze") }
            num(hdrCheck.opt("detail.denoise.post_rgb"))?.let { verify(approx(hdr.detailSettings.denoise.toDouble(), it), "hdr.denoise") }
            hdrCheck.optJSONObject("hdr.look")?.let {
                val expSha = if (it.isNull("sha256")) null else it.getString("sha256")
                val expName = if (it.isNull("name")) null else it.getString("name")
                verify(hdr.lookSettings.sha256 == expSha, "hdr.look.sha")
                verify(hdr.lookSettings.name == expName, "hdr.look.name")
                verify(approx(hdr.lookSettings.strength.toDouble(), it.getDouble("strength")), "hdr.look.strength")
            }
            hdrCheck.optJSONObject("hdr.camera_development")?.let { cam ->
                val dev = hdr.cameraDevelopment
                verify(dev != null, "hdr.cameraDevelopment.present")
                if (dev != null) {
                    val wbStr = if (dev.customWhiteBalance) "temperature" else "as_shot"
                    verify(wbStr == cam.getString("white_balance_mode"), "hdr.cam.wb")
                    num(cam.opt("temperature"))?.let { verify(approx(dev.temperature.toDouble(), it), "hdr.cam.temp") }
                    num(cam.opt("tint"))?.let { verify(approx(dev.tint.toDouble(), it), "hdr.cam.tint") }
                    val expRef = if (dev.sensorExposure) "sensor" else "metadata"
                    verify(expRef == cam.getString("exposure_reference"), "hdr.cam.expRef")
                    verify(dev.fbddLevel == cam.getInt("fbdd_level"), "hdr.cam.fbdd")
                    metadata.optJSONObject("hdr_camera_development_extra")?.let { extra ->
                        if (extra.has("lens_distortion")) verify(dev.lensDistortion == extra.getBoolean("lens_distortion"), "hdr.cam.lensDistortion")
                        if (extra.has("lens_tca")) verify(dev.lensTca == extra.getBoolean("lens_tca"), "hdr.cam.lensTca")
                        if (extra.has("lens_vignetting")) verify(dev.lensVignetting == extra.getBoolean("lens_vignetting"), "hdr.cam.lensVignetting")
                        if (extra.has("lens_auto_crop")) verify(dev.lensAutoCrop == extra.getBoolean("lens_auto_crop"), "hdr.cam.lensAutoCrop")
                        val expLp = if (extra.isNull("lens_profile")) null else extra.optString("lens_profile")
                        verify(dev.lensProfile == expLp, "hdr.cam.lensProfile")
                        extra.optJSONObject("camera_profile")?.let { cp ->
                            verify(dev.cameraProfile?.sha256 == cp.getString("sha256"), "hdr.cam.profile.sha256")
                            verify(dev.cameraProfile?.name == cp.getString("name"), "hdr.cam.profile.name")
                        }
                    }
                }
            }
            verifyGeomInto(hdrCheck, hdr.geometry, "hdr")
        }
        if (mismatches.isNotEmpty()) {
            throw ExpectationMismatchException("$id: mismatched=${mismatches.size} [${mismatches.joinToString("; ")}]")
        }
    }

    private fun openStoreChecked(dir: File): EditStore = try {
        EditStore(dir)
    } catch (e: IllegalArgumentException) {
        throw StoreRejectionException("${e.javaClass.simpleName}: ${e.message}", e)
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
        val rawVal = props.getProperty(encKey) ?: throw HarnessSetupException("Missing $encKey")
        if (!rawVal.startsWith("v2:")) throw HarnessSetupException("Expected v2 prefix on $encKey")
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
                else -> throw HarnessSetupException("Unhandled target_scope: $scope")
            }
        }
    }

    @Test
    fun editRecordGoldenFixtureSuite() {
        val fixture = JSONObject(resolveRepoFile("Shared/fixtures/edit-records-v1.json").readText())
        checkSetup(fixture.getInt("fixture_version") == 1, "fixture_version must be 1")
        checkSetup(fixture.getInt("spec_version") == 1, "spec_version must be 1")

        val recipesArr = JSONArray(resolveRepoFile("Shared/master-recipes.json").readText())
        val knownRecipeIds = (0 until recipesArr.length()).map { MasterRecipe.decode(recipesArr.getJSONObject(it)).id }.toSet()

        val tempRoot = Files.createTempDirectory("rawlab-android-edit-fixture").toFile()
        val failures = mutableListOf<String>()
        val evaluatedIds = linkedSetOf<String>()

        fun evaluate(
            id: String,
            scope: EvalCatchScope = EvalCatchScope.EXPECTATION_ONLY,
            block: () -> Unit,
        ) {
            evaluatedIds += id
            var caught: Throwable? = null
            try {
                block()
            } catch (e: ExpectationMismatchException) {
                caught = e
            } catch (e: UnusableEditRecordException) {
                if (scope != EvalCatchScope.EXPECTATION_OR_PERSISTENCE_REJECTION) throw e
                caught = e
            } catch (e: StoreRejectionException) {
                if (scope != EvalCatchScope.EXPECTATION_OR_PERSISTENCE_REJECTION) throw e
                caught = e
            }
            if (caught == null) {
                knownEditRecordDivergences[id]?.let { reg ->
                    fail("Stale divergence ledger entry '$id' (${reg.ledgerId}): scenario now passed")
                }
                println("PASS: $id")
                return
            }
            val reg = knownEditRecordDivergences[id]
            if (reg != null) {
                checkSetup(reg.ledgerId.isNotBlank() && reg.reason.isNotBlank(), "Blank divergence entry for $id")
                val observedText = "${caught.javaClass.simpleName}: ${caught.message}"
                reg.expectedObservedSubstring?.let { expectedSub ->
                    checkSetup(
                        observedText.contains(expectedSub),
                        "Divergence [$id] (${reg.ledgerId}) observed '$observedText' missing expected substring '$expectedSub'",
                    )
                }
                println("KNOWN DIVERGENCE [$id] (${reg.ledgerId}): ${reg.reason} | observed: $observedText")
            } else {
                val msg = "RED ANCHOR [$id]: ${caught.javaClass.simpleName}: ${caught.message}"
                System.err.println(msg)
                failures += msg
            }
        }

        try {
            val byId = linkedMapOf<String, JSONObject>()
            val roundtrip = fixture.getJSONArray("roundtrip_records")
            for (i in 0 until roundtrip.length()) {
                val rec = roundtrip.getJSONObject(i)
                val id = rec.getString("id")
                byId[id] = rec
                val scenarioId = "roundtrip:$id"
                val dir = File(tempRoot, "rt-$id").apply { mkdirs() }
                val store = EditStore(dir)
                val pid = PhotoIdentity("content://test/${rec.getJSONObject("photo").getString("name")}")
                val built = buildSettings(rec)
                store.save(pid, built)
                val meta = rec.optJSONObject("metadata")
                val receipt = meta?.optJSONObject("migration_receipt")
                val keepReceipt = receipt?.optString("status") == "kept"
                if (keepReceipt) {
                    val quality = ProcessingMigrationQuality(0.01f, 0.02f, 0.02f, 0.01f, 10)
                    store.commitProcessingMigration(store.readState(pid), null, quality)
                }

                evaluate(scenarioId) {
                    val reopened = openStoreChecked(dir)
                    val loaded = reopened.readState(pid).settings ?: throw ExpectationMismatchException("$id: null reloaded settings")
                    verifySettings(loaded, rec)
                    if (keepReceipt) {
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
                val expectPolicy = sc.getString("expect")
                val preserveRawDiskEntry = sc.optBoolean("preserve_raw_disk_entry", false)

                val dir = File(tempRoot, "x1-$id").apply { mkdirs() }
                val store = EditStore(dir)
                val targetId = PhotoIdentity("content://test/t-$id")
                val sibId = PhotoIdentity("content://test/s-$id")
                val sibBuilt = buildSettings(byId.getValue("raster-sdr-neutral"))
                store.save(targetId, buildSettings(baseRec))
                store.save(sibId, sibBuilt)
                val file = File(dir, "edits.properties")
                mutateUnknownScope(file, targetId, scope, key, value)

                when (expectPolicy) {
                    "load_preserving_values" -> evaluate(id, EvalCatchScope.EXPECTATION_OR_PERSISTENCE_REJECTION) {
                        val reopened = openStoreChecked(dir)
                        val loaded = reopened.readState(targetId).settings ?: throw ExpectationMismatchException("$id: target null")
                        check(reopened.readState(sibId).settings != null, "$id: sibling null")
                        if (preserveRawDiskEntry) {
                            reopened.save(sibId, sibBuilt.copy(exposure = 1.25f))
                            val futureSibEnc = encodeB64(PhotoIdentity("content://test/future_sibling"))
                            check(
                                loadProperties(file).getProperty("record.$futureSibEnc.values") != null,
                                "$id: unknown sibling entry must remain preserved across sibling save",
                            )
                        }
                        verifySettings(loaded, baseRec)
                    }
                    "reject_isolating_record" -> evaluate(id, EvalCatchScope.EXPECTATION_ONLY) {
                        val reopened = openStoreChecked(dir)
                        var threw = false
                        try { reopened.readState(targetId) } catch (_: UnusableEditRecordException) { threw = true }
                        check(threw, "$id: Tier 2 unknown field in '$scope' must throw UnusableEditRecordException")
                        check(reopened.readState(sibId).settings != null, "$id: healthy sibling must stay readable")
                        if (preserveRawDiskEntry) {
                            reopened.save(sibId, sibBuilt.copy(exposure = 1.25f))
                            val afterProps = loadProperties(file)
                            check(
                                afterProps.getProperty("record.${encodeB64(targetId)}.values") != null,
                                "$id: rejected Tier 2 raw entry must remain preserved on disk across sibling save",
                            )
                        }
                    }
                    else -> throw HarnessSetupException("Unknown X1 expect policy '$expectPolicy' for $id")
                }
            }

            val compats = fixture.getJSONArray("compatibility_scenarios")
            for (i in 0 until compats.length()) {
                val sc = compats.getJSONObject(i)
                val id = sc.getString("id")
                val kind = sc.getString("kind")
                val baseRec = byId.getValue(sc.getString("base_record_id"))
                when (kind) {
                    "legacy_omitted_extensions" -> {
                        val dir = File(tempRoot, "c-$id").apply { mkdirs() }
                        val pid = PhotoIdentity("content://test/leg-$id")
                        EditStore(dir).save(pid, buildSettings(baseRec))
                        mutateV2Record(File(dir, "edits.properties"), pid) { _, s ->
                            listOf("processing", "x3fMode", "masterRecipeSettingsVersion", "tone", "toneControls",
                                "atmosphere", "colorGrading", "curve", "hdr", "proRAWDecodeVersion").forEach { s.remove(it) }
                        }

                        val samples = sc.getJSONObject("legacy_wire_samples")
                        val andSample = samples.getJSONObject("android_properties")
                        val wirePhotoId = PhotoIdentity(andSample.getString("photo_id"))
                        val wireDir = File(tempRoot, "c-wire-$id").apply { mkdirs() }
                        File(wireDir, "edits.properties").writeText(andSample.getString("properties_text"), StandardCharsets.UTF_8)
                        val wireExpect = andSample.getJSONObject("expect_decoded")

                        evaluate(id, EvalCatchScope.EXPECTATION_OR_PERSISTENCE_REJECTION) {
                            val wireStore = openStoreChecked(wireDir)
                            val wireLoaded = wireStore.readState(wirePhotoId).settings
                                ?: throw ExpectationMismatchException("$id: frozen android_properties legacy wire sample decoded nil")
                            check(wireLoaded.film == wireExpect.getString("film_id"), "$id: wire film_id")
                            check(approx(wireLoaded.strength.toDouble(), wireExpect.getDouble("strength")), "$id: wire strength")
                            check(approx(wireLoaded.exposure.toDouble(), wireExpect.getDouble("exposure")), "$id: wire exposure")
                            check(approx(wireLoaded.highlights.toDouble(), wireExpect.getDouble("highlights")), "$id: wire highlights")
                            check(approx(wireLoaded.shadows.toDouble(), wireExpect.getDouble("shadows")), "$id: wire shadows")
                            check(approx(wireLoaded.contrast.toDouble(), wireExpect.getDouble("contrast")), "$id: wire contrast")
                            check(approx(wireLoaded.toneCurve.toDouble(), wireExpect.getDouble("tone_curve")), "$id: wire tone_curve")
                            check(approx(wireLoaded.saturation.toDouble(), wireExpect.getDouble("saturation")), "$id: wire saturation")
                            check(wireLoaded.customWb == wireExpect.getBoolean("custom_wb"), "$id: wire custom_wb")
                            check(approx(wireLoaded.temperature.toDouble(), wireExpect.getDouble("temperature")), "$id: wire temperature")
                            check(approx(wireLoaded.tint.toDouble(), wireExpect.getDouble("tint")), "$id: wire tint")
                            check(approx(wireLoaded.sharpening.toDouble(), wireExpect.getDouble("sharpening")), "$id: wire sharpening")
                            check(wireLoaded.processing.version == wireExpect.getInt("processing_version"), "$id: wire processing.version")
                            check(wireLoaded.x3fMode.id == wireExpect.getString("x3f_mode"), "$id: wire x3fMode")

                            val loaded = openStoreChecked(dir).readState(pid).settings!!
                            check(loaded.processing == ProcessingIdentity.LEGACY, "$id: expected legacy processing")
                            check(loaded.x3fMode == X3fMode.LEGACY, "$id: expected legacy x3fMode")
                        }
                    }
                    "sdr_reset_preserves_dormant_hdr" -> {
                        val dir = File(tempRoot, "c-$id").apply { mkdirs() }
                        val pid = PhotoIdentity("content://test/rst-$id")
                        val built = buildSettings(baseRec)
                        val store = EditStore(dir)
                        store.save(pid, built)
                        evaluate(id) {
                            val ctx = EditorResetContext(
                                input = PhotoInputKind.RAW,
                                defaults = EditSettings(exposureMode = 1, temperature = 5400f, tint = -4f),
                                asShot = AsShotWhiteBalance(5400f, -4f),
                                knownRecipeIds = knownRecipeIds,
                            )
                            val res = EditorAdjustmentRules.prepareReset(EditorResetScope.All, built, ctx)
                            check(res is EditorResetResult.Ready, "$id: expected Ready, got $res")
                            val candidate = (res as EditorResetResult.Ready).candidate
                            EditStore(dir).save(pid, candidate)
                            val reloaded = EditStore(dir).readState(pid).settings!!
                            check(approx(reloaded.hdr?.exposure?.toDouble() ?: -99.0, -0.5) && reloaded.hdr?.mode == HDRMode.SDR, "$id: dormant HDR preserved")
                            check(reloaded.proRAWDecodeVersion == 2, "$id: proRAWDecodeVersion preserved")
                            check(reloaded.processing.version == 2, "$id: processing.version preserved")
                            check(reloaded.x3fMode == X3fMode.LEGACY, "$id: x3fMode preserved")
                        }
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
                        evaluate(id) {
                            val reopened = openStoreChecked(dir)
                            var threw = false
                            try { reopened.readState(targetId) } catch (_: UnusableEditRecordException) { threw = true }
                            check(threw, "$id: processing.version=99 must throw UnusableEditRecordException")
                            check(reopened.readState(sibId).settings != null, "$id: healthy sibling must stay readable")
                            reopened.save(sibId, sibBuilt.copy(exposure = 1.5f))
                            val afterProps = loadProperties(file)
                            check(afterProps.getProperty("record.${encodeB64(targetId)}.values") != null, "$id: future record preserved")
                        }
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
                        evaluate(id) {
                            val reopened = openStoreChecked(dir)
                            var threw = false
                            try { reopened.readState(targetId) } catch (_: UnusableEditRecordException) { threw = true }
                            check(threw, "$id: corrupt entry must throw UnusableEditRecordException")
                            check(reopened.readState(sibId).settings != null, "$id: healthy sibling readable")
                            reopened.save(sibId, sibBuilt.copy(exposure = 1.1f))
                            check(file.readText().contains("corrupt-entry-payload"), "$id: corrupt bytes preserved across sibling save")
                        }
                    }
                    "negative_zero" -> {
                        val dir = File(tempRoot, "c-$id").apply { mkdirs() }
                        val pid = PhotoIdentity("content://test/nz-$id")
                        EditStore(dir).save(pid, buildSettings(baseRec).copy(exposure = 0f))
                        val file = File(dir, "edits.properties")
                        val props = loadProperties(file)
                        val key = "record.${encodeB64(pid)}.values"
                        val raw = props.getProperty(key) ?: throw HarnessSetupException("Missing $key")
                        val mutated = raw.replace("\"exposure\":0,", "\"exposure\":-0.0,")
                        checkSetup(mutated.contains("\"exposure\":-0.0,"), "$id: test setup failed to inject -0.0")
                        props.setProperty(key, mutated)
                        storeProperties(file, props)
                        val expectObj = sc.getJSONObject("expect")
                        val assertSignBit = expectObj.optBoolean("assert_sign_bit_positive", false)
                        evaluate(id) {
                            val loaded = openStoreChecked(dir).readState(pid).settings!!
                            check(loaded.exposure == 0f, "$id: -0.0 must compare equal to 0f")
                            if (assertSignBit) {
                                check(java.lang.Float.floatToRawIntBits(loaded.exposure) == 0, "$id: -0.0 must canonicalize to +0.0f")
                            }
                        }
                    }
                    else -> throw HarnessSetupException("Unhandled compat kind: $kind")
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
                            else -> throw HarnessSetupException("Unhandled field: $field")
                        }
                        "crop_overflow" -> s.getJSONObject("geometry")
                            .put("cropX", mut.getDouble("cropX")).put("cropWidth", mut.getDouble("cropWidth"))
                        "invalid_exposure_mode" -> s.put("exposureMode", "future_unknown_mode")
                        "non_monotonic_curve" -> s.put("curve", JSONObject().put("mode", "custom").put(
                            "points", JSONArray().put(JSONArray(listOf(0.0, 0.0))).put(JSONArray(listOf(0.6, 0.5)))
                                .put(JSONArray(listOf(0.4, 0.8))).put(JSONArray(listOf(1.0, 1.0)))
                        ))
                        else -> throw HarnessSetupException("Unhandled boundary mutation: $mKind")
                    }
                }
                evaluate(id) {
                    val reopened = openStoreChecked(dir)
                    var threw = false
                    try { reopened.readState(targetId) } catch (_: UnusableEditRecordException) { threw = true }
                    check(threw, "$id: out-of-range/invalid boundary record must throw UnusableEditRecordException")
                    check(reopened.readState(sibId).settings != null, "$id: sibling must remain readable")
                }
            }
        } finally {
            tempRoot.deleteRecursively()
        }

        val orphanKeys = knownEditRecordDivergences.keys - evaluatedIds
        checkSetup(orphanKeys.isEmpty(), "Orphan divergence ledger keys not evaluated: ${orphanKeys.sorted()}")
        checkSetup(
            knownEditRecordDivergences.size <= maxKnownEditRecordDivergences,
            "Divergence count ${knownEditRecordDivergences.size} exceeds cap $maxKnownEditRecordDivergences",
        )
        if (failures.isNotEmpty()) {
            fail("${failures.size} Android edit-record scenario(s) failed:\n${failures.joinToString("\n")}")
        }
        println("PASS: Android edit-record fixture suite finished with ${knownEditRecordDivergences.size} registered divergences (cap $maxKnownEditRecordDivergences, evaluated ${evaluatedIds.size})")
    }
}
