package com.rawlab.android.adjustments

import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AdjustmentFieldsSpecTest {
    private fun loadSpecJSON(): JSONObject {
        val file = resolveSharedPath("Shared/specs/adjustment-fields-v1.json")
        return JSONObject(file.readText())
    }

    @Test
    fun generatedSpecAndTransferProtocolMatchRuntimeJSON() {
        val root = loadSpecJSON()
        assertEquals(1, root.getInt("spec_version"))
        val fields = root.getJSONArray("fields")
        assertEquals(118, fields.length())

        val transferIds = mutableListOf<String>()
        val localIds = mutableListOf<String>()

        for (i in 0 until fields.length()) {
            val entry = fields.getJSONObject(i)
            val fid = entry.getString("field_id")
            val group = entry.getString("group")
            val proto = entry.getJSONObject("protocol")
            val androidModel = entry.getJSONObject("model").getJSONObject("android")

            val generated = AdjustmentFieldSpec.forId(fid)
            assertNotNull("Missing generated spec for $fid", generated)
            generated!!
            assertEquals(fid, group, generated.group)
            assertEquals(fid, proto.getBoolean("transferable"), generated.protocol.transferable)
            assertEquals(fid, proto.getBoolean("nullable"), generated.protocol.nullable)
            assertEquals(fid, proto.getBoolean("exclusive_min"), generated.protocol.exclusiveMin)
            assertEquals(fid, proto.getBoolean("hdr_only"), generated.protocol.isHDROnly)
            assertEquals(fid, optDouble(proto, "min"), generated.protocol.min)
            assertEquals(fid, optDouble(proto, "max"), generated.protocol.max)

            assertModelSpecMatchesJSON(fid, generated.androidModel, androidModel)

            if (proto.getBoolean("transferable")) {
                transferIds += fid
                val enumField = AdjustmentField.fromID(fid)
                assertNotNull("Missing AdjustmentField enum for $fid", enumField)
                enumField!!
                assertEquals(fid, group, enumField.group)
                assertEquals(fid, proto.getBoolean("hdr_only"), enumField.isHDROnly)
                assertProtocolRuntimeAcceptance(enumField, proto)
            } else {
                localIds += fid
            }
        }

        assertEquals(115, transferIds.size)
        assertEquals(3, localIds.size)
        assertEquals(transferIds.toSet(), AdjustmentField.entries.map { it.id }.toSet())
        assertEquals(AdjustmentField.entries.size, transferIds.size)
        assertEquals(localIds, AdjustmentFieldSpec.localOnlyFieldIds)
    }

    @Test
    fun runtimeModelObjectsMatchAndroidSpecJSON() {
        val fields = loadSpecJSON().getJSONArray("fields")
        val specById = (0 until fields.length()).associate { i ->
            val obj = fields.getJSONObject(i)
            obj.getString("field_id") to obj
        }
        fun androidModel(fid: String): JSONObject =
            specById.getValue(fid).getJSONObject("model").getJSONObject("android")

        // EditSettings defaults & bounds
        val settings = EditSettings()
        assertEquals(androidModel("looks.strength").getDouble("default").toFloat(), settings.strength, 0f)
        assertEquals(androidModel("light.exposure").getDouble("default").toFloat(), settings.exposure, 0f)
        assertEquals(androidModel("light.contrast").getDouble("default").toFloat(), settings.contrast, 0f)
        assertEquals(androidModel("light.highlights").getDouble("default").toFloat(), settings.highlights, 0f)
        assertEquals(androidModel("light.shadows").getDouble("default").toFloat(), settings.shadows, 0f)
        assertEquals(androidModel("light.s_curve").getDouble("default").toFloat(), settings.toneCurve, 0f)
        assertEquals(androidModel("color.saturation").getDouble("default").toFloat(), settings.saturation, 0f)
        assertEquals(androidModel("color.white_balance.temperature_kelvin").getDouble("default").toFloat(), settings.temperature, 0f)
        assertEquals(androidModel("color.white_balance.tint").getDouble("default").toFloat(), settings.tint, 0f)
        assertEquals(androidModel("detail.sharpening").getDouble("default").toFloat(), settings.sharpening, 0f)
        assertEquals(androidModel("detail.denoise.chroma_mode").getInt("default"), settings.displayChromaDenoise)
        assertEquals(androidModel("tone.black_point").getDouble("default").toFloat(), settings.blackPoint, 0f)
        assertEquals(androidModel("tone.white_point").getDouble("default").toFloat(), settings.whitePoint, 0f)
        assertEquals(androidModel("color.vibrance").getDouble("default").toFloat(), settings.vibrance, 0f)
        assertEquals(androidModel("effects.clarity").getDouble("default").toFloat(), settings.clarity, 0f)
        assertEquals(androidModel("effects.dehaze").getDouble("default").toFloat(), settings.dehaze, 0f)

        val expMin = androidModel("light.exposure").getDouble("min").toFloat()
        val expMax = androidModel("light.exposure").getDouble("max").toFloat()
        assertThrows(IllegalArgumentException::class.java) { EditSettings(exposure = expMin - 0.1f) }
        assertThrows(IllegalArgumentException::class.java) { EditSettings(exposure = expMax + 0.1f) }

        // PhotoEffectsSettings & PhotoEffectParameter
        val effects = PhotoEffectsSettings()
        val effectMap = listOf(
            PhotoEffectParameter.VIGNETTE_AMOUNT to "effects.vignette.amount",
            PhotoEffectParameter.VIGNETTE_MIDPOINT to "effects.vignette.midpoint",
            PhotoEffectParameter.VIGNETTE_ROUNDNESS to "effects.vignette.roundness",
            PhotoEffectParameter.VIGNETTE_FEATHER to "effects.vignette.feather",
            PhotoEffectParameter.VIGNETTE_HIGHLIGHTS to "effects.vignette.highlights",
            PhotoEffectParameter.GRAIN_AMOUNT to "effects.grain.amount",
            PhotoEffectParameter.GRAIN_SIZE to "effects.grain.size",
            PhotoEffectParameter.GRAIN_ROUGHNESS to "effects.grain.roughness",
        )
        for ((param, fid) in effectMap) {
            val m = androidModel(fid)
            assertEquals(fid, m.getDouble("default").toFloat(), effects.value(param), 0f)
            assertEquals(fid, m.getDouble("min").toFloat()..m.getDouble("max").toFloat(), param.range)
        }
        assertThrows(IllegalArgumentException::class.java) { PhotoEffectsSettings(vignetteMidpoint = -1f) }

        // GeometrySettings
        val geo = GeometrySettings()
        assertEquals(androidModel("geometry.crop.x").getDouble("default").toFloat(), geo.cropX, 0f)
        assertEquals(androidModel("geometry.crop.y").getDouble("default").toFloat(), geo.cropY, 0f)
        assertEquals(androidModel("geometry.crop.width").getDouble("default").toFloat(), geo.cropWidth, 0f)
        assertEquals(androidModel("geometry.crop.height").getDouble("default").toFloat(), geo.cropHeight, 0f)
        assertEquals(androidModel("geometry.quarter_turns").getInt("default"), geo.quarterTurns)
        assertEquals(androidModel("geometry.flip_horizontal").getBoolean("default"), geo.flipHorizontal)
        assertEquals(androidModel("geometry.flip_vertical").getBoolean("default"), geo.flipVertical)
        assertEquals(androidModel("geometry.straighten_degrees").getDouble("default").toFloat(), geo.straightenDegrees, 0f)
        assertEquals(androidModel("geometry.perspective.horizontal").getDouble("default").toFloat(), geo.perspectiveHorizontal, 0f)
        assertEquals(androidModel("geometry.perspective.vertical").getDouble("default").toFloat(), geo.perspectiveVertical, 0f)
        assertThrows(IllegalArgumentException::class.java) { GeometrySettings(quarterTurns = 4) }

        // ColorGradingSettings, ToneCurveSettings, DenoiseSettings, HDRSettings
        val grading = ColorGradingSettings()
        assertTrue(grading.isDefault)
        assertEquals(0f, grading.global.luminance, 0f)
        assertEquals(androidModel("color.grading.blending").getDouble("default").toFloat(), grading.blending, 0f)
        assertEquals(androidModel("color.grading.balance").getDouble("default").toFloat(), grading.balance, 0f)
        assertThrows(IllegalArgumentException::class.java) { ColorGradingWheel(hue = 360f, saturation = 0f) }

        val curve = ToneCurveSettings()
        assertTrue(curve.isDefault)
        assertEquals(androidModel("light.curve.apply_to_luminosity").getBoolean("default"), curve.applyToLuminosity)
        assertTrue(curve.parametric.isDefault)
        assertEquals(OutputSharpening.OFF, OutputSharpening.fromWireValue(null))
        assertThrows(IllegalArgumentException::class.java) { ToneCurveShape(mode = ToneCurveMode.CUSTOM, points = emptyList()) }

        val denoise = DenoiseSettings()
        val waveletDef = androidModel("detail.denoise.wavelet").getJSONObject("default")
        assertEquals(waveletDef.getBoolean("enabled"), denoise.enabled)
        assertEquals(waveletDef.getDouble("luma").toFloat(), denoise.luma, 0f)
        assertEquals(waveletDef.getDouble("chroma").toFloat(), denoise.chroma, 0f)
        assertEquals(waveletDef.getDouble("coarse").toFloat(), denoise.coarse, 0f)
        assertThrows(IllegalArgumentException::class.java) { DenoiseSettings(luma = 101f) }

        val hdr = HDRSettings()
        assertEquals(androidModel("hdr.peak_limit_ev").getDouble("default").toFloat(), hdr.renditionSettings.peakLimitEV, 0f)
        assertEquals(androidModel("hdr.sdr_exposure_ev").getDouble("default").toFloat(), hdr.renditionSettings.sdrExposureEV, 0f)
        assertEquals(androidModel("hdr.sdr_contrast").getDouble("default").toFloat(), hdr.renditionSettings.sdrContrast, 0f)
        assertEquals(androidModel("hdr.sdr_saturation").getDouble("default").toFloat(), hdr.renditionSettings.sdrSaturation, 0f)
        assertThrows(IllegalArgumentException::class.java) { HDRRenditionSettings(peakLimitEV = 6.1f) }

        // v0.14.0 models & SubFields
        assertEquals(androidModel("effects.texture").getDouble("default").toFloat(), settings.texture, 0f)
        assertThrows(IllegalArgumentException::class.java) { EditSettings(texture = 101f) }
        val cal = CameraCalibrationSettings()
        assertEquals(androidModel("color.calibration.shadow_tint").getDouble("default").toFloat(), cal.shadowTint, 0f)
        assertEquals(androidModel("color.calibration.blue_saturation").getDouble("default").toFloat(), cal.blueSaturation, 0f)
        assertThrows(IllegalArgumentException::class.java) { CameraCalibrationSettings(shadowTint = -101f) }

        assertTrue(PointColorSettings().isDefault)
        assertThrows(IllegalArgumentException::class.java) { PointColorSwatch(srcHue = 360f) }
        assertThrows(IllegalArgumentException::class.java) { PointColorSwatch(srcSaturation = 1.1f) }
        assertThrows(IllegalArgumentException::class.java) {
            PointColorSettings(List(AdjustmentFieldSpec.SubFields.PointColor.maxSwatches + 1) { PointColorSwatch() })
        }

        val sc = SelectiveColorSettings()
        assertEquals("relative", sc.method.wireValue)
        assertThrows(IllegalArgumentException::class.java) { SelectiveColorBand(cyan = 101f) }

        val bw = BwMixerSettings()
        assertEquals(androidModel("color.bw.enabled").getBoolean("default"), bw.enabled)
        assertThrows(IllegalArgumentException::class.java) { BwMixerWeights(red = -101f) }

        val sv2 = SharpenV2Settings()
        assertEquals(androidModel("detail.sharpening.luminance_v2").getBoolean("default"), sv2.luminanceV2)
        assertEquals(androidModel("detail.sharpening.radius").getDouble("default").toFloat(), sv2.radius, 0f)
        assertEquals(androidModel("detail.sharpening.detail").getDouble("default").toFloat(), sv2.detail, 0f)
        assertEquals(androidModel("detail.sharpening.masking").getDouble("default").toFloat(), sv2.masking, 0f)
        assertThrows(IllegalArgumentException::class.java) { SharpenV2Settings(radius = 0.4f) }

        val fo = FilmOpticsSettings()
        assertEquals(androidModel("effects.halation.amount").getDouble("default").toFloat(), fo.halationAmount, 0f)
        assertEquals(androidModel("effects.halation.threshold").getDouble("default").toFloat(), fo.halationThreshold, 0f)
        assertEquals(androidModel("effects.halation.radius").getDouble("default").toFloat(), fo.halationRadius, 0f)
        assertEquals(androidModel("effects.halation.hue").getDouble("default").toFloat(), fo.halationHue, 0f)
        assertEquals(androidModel("effects.bloom.amount").getDouble("default").toFloat(), fo.bloomAmount, 0f)
        assertEquals(androidModel("effects.bloom.threshold").getDouble("default").toFloat(), fo.bloomThreshold, 0f)
        assertEquals(androidModel("effects.bloom.radius").getDouble("default").toFloat(), fo.bloomRadius, 0f)
        assertThrows(IllegalArgumentException::class.java) { FilmOpticsSettings(bloomRadius = 101f) }

        assertEquals(androidModel("effects.grain.tone_curve").getString("default"), effects.grainToneCurve.wireValue)
        assertEquals(androidModel("effects.grain.format_preset").getString("default"), effects.grainFormatPreset.wireValue)

        val lens = LensSettings()
        assertEquals(androidModel("geometry.lens.defringe_purple_amount").getDouble("default").toFloat(), lens.defringePurpleAmount, 0f)
        assertEquals(androidModel("geometry.lens.defringe_purple_hue").getDouble("default").toFloat(), lens.defringePurpleHue, 0f)
        assertEquals(androidModel("geometry.lens.defringe_green_amount").getDouble("default").toFloat(), lens.defringeGreenAmount, 0f)
        assertEquals(androidModel("geometry.lens.defringe_green_hue").getDouble("default").toFloat(), lens.defringeGreenHue, 0f)
        assertThrows(IllegalArgumentException::class.java) { LensSettings(defringePurpleAmount = 21f) }
    }

    private fun assertModelSpecMatchesJSON(fid: String, actual: AdjustmentFieldModelSpec, json: JSONObject) {
        assertEquals("$fid.supported", json.getBoolean("supported"), actual.supported)
        val modes = json.getJSONArray("modes")
        assertEquals("$fid.modes", (0 until modes.length()).map { modes.getString(it) }, actual.modes)
        assertEquals("$fid.storageType", json.getString("storage_type"), actual.storageType)
        assertEquals("$fid.nullable", json.getBoolean("nullable"), actual.nullable)
        assertEquals("$fid.min", optDouble(json, "min"), actual.min)
        assertEquals("$fid.max", optDouble(json, "max"), actual.max)
        assertEquals("$fid.scale", json.getString("scale_from_protocol"), actual.scaleFromProtocol)
        assertEquals("$fid.quantization", json.getString("quantization"), actual.quantization.name.lowercase())
        assertEquals("$fid.hdrMin", optDouble(json, "hdr_min"), actual.hdrMin)
        assertEquals("$fid.hdrMax", optDouble(json, "hdr_max"), actual.hdrMax)
        assertEquals("$fid.hdrDefault", optDouble(json, "hdr_default"), actual.hdrDefaultNumber)
        assertEquals("$fid.hdrScale", if (json.has("hdr_scale_from_protocol") && !json.isNull("hdr_scale_from_protocol")) json.getString("hdr_scale_from_protocol") else null, actual.hdrScaleFromProtocol)
    }

    private fun assertProtocolRuntimeAcceptance(field: AdjustmentField, proto: JSONObject) {
        val isHDR = proto.getBoolean("hdr_only")
        val source = AdjustmentSource(
            identifier = "spec-probe",
            isRaw = !isHDR,
            processingVersion = 3,
            recipe = null,
            hdrProcessingVersion = if (isHDR) 7 else null,
        )
        val nullable = proto.getBoolean("nullable")
        if (nullable && field != AdjustmentField.TINT) {
            AdjustmentPayload(source, mapOf(field to AdjustmentValue.Null))
        } else if (!nullable) {
            assertThrows(field.id, AdjustmentTransferException::class.java) {
                AdjustmentPayload(source, mapOf(field to AdjustmentValue.Null))
            }
        }
        val valueType = proto.getString("value_type")
        if ((valueType == "number" || valueType == "integer") && !proto.isNull("min") && !proto.isNull("max")) {
            val minV = proto.getDouble("min")
            val maxV = proto.getDouble("max")
            val exclusiveMin = proto.getBoolean("exclusive_min")
            if (field != AdjustmentField.TEMPERATURE && field != AdjustmentField.TINT) {
                val loTest = if (exclusiveMin) minV else minV - 1.0
                assertThrows(field.id, AdjustmentTransferException::class.java) {
                    AdjustmentPayload(source, mapOf(field to AdjustmentValue.Number(loTest)))
                }
                assertThrows(field.id, AdjustmentTransferException::class.java) {
                    AdjustmentPayload(source, mapOf(field to AdjustmentValue.Number(maxV + 1.0)))
                }
                if (!exclusiveMin) {
                    AdjustmentPayload(source, mapOf(field to AdjustmentValue.Number(minV)))
                }
                AdjustmentPayload(source, mapOf(field to AdjustmentValue.Number(maxV)))
            }
        }
    }

    private fun optDouble(obj: JSONObject, key: String): Double? =
        if (!obj.has(key) || obj.isNull(key)) null else obj.getDouble(key)
}
