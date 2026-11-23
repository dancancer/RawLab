import XCTest
@testable import RawLabKit

final class AdjustmentFieldsSpecTests: XCTestCase {
    private func loadSpecJSON() throws -> [String: Any] {
        let url = RawLabKitTestSupport.repoRoot.appendingPathComponent("Shared/specs/adjustment-fields-v1.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return root
    }

    func testGeneratedSpecsAndTransferProtocolMatchRuntimeJSON() throws {
        let root = try loadSpecJSON()
        XCTAssertEqual(root["spec_version"] as? Int, 1)
        let fields = try XCTUnwrap(root["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.count, 89)

        let transferFields = fields.filter { (($0["protocol"] as? [String: Any])?["transferable"] as? Bool) == true }
        let localFields = fields.filter { (($0["protocol"] as? [String: Any])?["transferable"] as? Bool) == false }
        XCTAssertEqual(transferFields.count, 86)
        XCTAssertEqual(localFields.count, 3)

        // Canonical order & complete AdjustmentTransferField coverage
        XCTAssertEqual(
            AdjustmentTransferField.allCases.map(\.rawValue),
            transferFields.compactMap { $0["field_id"] as? String }
        )
        XCTAssertEqual(
            AdjustmentFieldSpec.localOnlyFieldIds,
            localFields.compactMap { $0["field_id"] as? String }
        )

        for entry in fields {
            let fid = try XCTUnwrap(entry["field_id"] as? String)
            let group = try XCTUnwrap(entry["group"] as? String)
            let proto = try XCTUnwrap(entry["protocol"] as? [String: Any])
            let model = try XCTUnwrap(entry["model"] as? [String: Any])
            let macSpec = try XCTUnwrap(model["macos"] as? [String: Any])
            let iosSpec = try XCTUnwrap(model["ios"] as? [String: Any])

            let generated = try XCTUnwrap(AdjustmentFieldSpec.forId(fid), "Missing generated spec for \(fid)")
            XCTAssertEqual(generated.group, group, fid)
            XCTAssertEqual(generated.protocolSpec.transferable, proto["transferable"] as? Bool, fid)
            XCTAssertEqual(generated.protocolSpec.nullable, proto["nullable"] as? Bool, fid)
            XCTAssertEqual(generated.protocolSpec.exclusiveMin, proto["exclusive_min"] as? Bool, fid)
            XCTAssertEqual(generated.protocolSpec.isHDROnly, proto["hdr_only"] as? Bool, fid)
            XCTAssertEqual(generated.protocolSpec.min, (proto["min"] as? NSNumber)?.doubleValue, fid)
            XCTAssertEqual(generated.protocolSpec.max, (proto["max"] as? NSNumber)?.doubleValue, fid)

            assertModelSpecMatchesJSON(generated.macosModel, macSpec, label: "\(fid).macos")
            assertModelSpecMatchesJSON(generated.iosModel, iosSpec, label: "\(fid).ios")

            if generated.protocolSpec.transferable {
                let enumField = try XCTUnwrap(AdjustmentTransferField(rawValue: fid))
                XCTAssertEqual(enumField.group, group, fid)
                XCTAssertEqual(enumField.isHDROnly, proto["hdr_only"] as? Bool, fid)
                try assertProtocolRuntimeAcceptance(enumField, proto: proto)
            }
        }
    }

    func testRuntimeModelObjectsMatchAppleSpecJSON() throws {
        let root = try loadSpecJSON()
        let fields = try XCTUnwrap(root["fields"] as? [[String: Any]])
        var specById: [String: [String: Any]] = [:]
        for entry in fields {
            if let fid = entry["field_id"] as? String {
                specById[fid] = entry
            }
        }

        func model(_ fid: String, platform: String) throws -> [String: Any] {
            let entry = try XCTUnwrap(specById[fid], fid)
            let m = try XCTUnwrap(entry["model"] as? [String: Any])
            return try XCTUnwrap(m[platform] as? [String: Any])
        }

        // macOS Adjustments runtime object assertions
        let mac = Adjustments()
        XCTAssertEqual(mac.strength, try XCTUnwrap((try model("looks.strength", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.exposure, try XCTUnwrap((try model("light.exposure", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.contrast, try XCTUnwrap((try model("light.contrast", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.highlights, try XCTUnwrap((try model("light.highlights", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.shadows, try XCTUnwrap((try model("light.shadows", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.toneCurve, try XCTUnwrap((try model("light.s_curve", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.temperature, try XCTUnwrap((try model("color.white_balance.temperature_kelvin", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.tint, try XCTUnwrap((try model("color.white_balance.tint", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.saturation, try XCTUnwrap((try model("color.saturation", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.sharpening, try XCTUnwrap((try model("detail.sharpening", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.rawNoiseReduction, try XCTUnwrap((try model("detail.denoise.raw_level", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.chromaNoiseReduction, try XCTUnwrap((try model("detail.denoise.chroma_mode", platform: "macos")["default"] as? NSNumber)?.intValue))
        let macWaveletDefault = try XCTUnwrap(try model("detail.denoise.wavelet", platform: "macos")["default"] as? [String: Any])
        XCTAssertEqual(mac.waveletNoiseReduction.enabled, macWaveletDefault["enabled"] as? Bool)
        XCTAssertEqual(mac.waveletNoiseReduction.luma, (macWaveletDefault["luma"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(mac.waveletNoiseReduction.chroma, (macWaveletDefault["chroma"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(mac.waveletNoiseReduction.coarse, (macWaveletDefault["coarse"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(mac.waveletNoiseReduction.preset.rawValue, macWaveletDefault["preset"] as? String)
        XCTAssertEqual(mac.aiDenoiseEnabled, try XCTUnwrap(try model("local.ai_denoise_enabled", platform: "macos")["default"] as? Bool))
        XCTAssertEqual(mac.aiDenoiseStrength, try XCTUnwrap((try model("local.ai_denoise_strength", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.hdrCameraAIEnabled, try XCTUnwrap(try model("local.hdr_camera_ai_enabled", platform: "macos")["default"] as? Bool))
        XCTAssertEqual(mac.curveSettings.applyToLuminosity, try XCTUnwrap(try model("light.curve.apply_to_luminosity", platform: "macos")["default"] as? Bool))
        XCTAssertEqual(mac.gradingSettings.blending, try XCTUnwrap((try model("color.grading.blending", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(mac.gradingSettings.balance, try XCTUnwrap((try model("color.grading.balance", platform: "macos")["default"] as? NSNumber)?.doubleValue))

        // iOS RawSettings runtime object assertions
        let ios = RawSettings.default
        XCTAssertEqual(ios.lutStrength, try XCTUnwrap((try model("looks.strength", platform: "ios")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(ios.exposure, try XCTUnwrap((try model("light.exposure", platform: "ios")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(ios.contrast, try XCTUnwrap((try model("light.contrast", platform: "ios")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(ios.highlights, try XCTUnwrap((try model("light.highlights", platform: "ios")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(ios.shadows, try XCTUnwrap((try model("light.shadows", platform: "ios")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(ios.toneCurve, try XCTUnwrap((try model("light.s_curve", platform: "ios")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(ios.temperature, try XCTUnwrap((try model("color.white_balance.temperature_kelvin", platform: "ios")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(ios.tint, try XCTUnwrap((try model("color.white_balance.tint", platform: "ios")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(ios.saturation, try XCTUnwrap((try model("color.saturation", platform: "ios")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(ios.sharpening, try XCTUnwrap((try model("detail.sharpening", platform: "ios")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(try model("detail.denoise.post_rgb", platform: "ios")["modes"] as? [String], ["hdr"])
        XCTAssertEqual(HDRSettings().detailSettings.denoise, try XCTUnwrap((try model("detail.denoise.post_rgb", platform: "ios")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(try model("detail.denoise.raw_level", platform: "ios")["supported"] as? Bool, false)
        XCTAssertEqual(ios.displayChromaDenoise, try XCTUnwrap((try model("detail.denoise.chroma_mode", platform: "ios")["default"] as? NSNumber)?.intValue))

        // Shared PhotoEffectsSettings runtime defaults & clamping against spec.model.macos / ios
        let effects = PhotoEffectsSettings()
        let effectBindings: [(PhotoEffectParameter, String)] = [
            (.vignetteAmount, "effects.vignette.amount"),
            (.vignetteMidpoint, "effects.vignette.midpoint"),
            (.vignetteRoundness, "effects.vignette.roundness"),
            (.vignetteFeather, "effects.vignette.feather"),
            (.vignetteHighlights, "effects.vignette.highlights"),
            (.grainAmount, "effects.grain.amount"),
            (.grainSize, "effects.grain.size"),
            (.grainRoughness, "effects.grain.roughness"),
        ]
        for (param, fid) in effectBindings {
            for plat in ["macos", "ios"] {
                let m = try model(fid, platform: plat)
                let minV = try XCTUnwrap((m["min"] as? NSNumber)?.doubleValue)
                let maxV = try XCTUnwrap((m["max"] as? NSNumber)?.doubleValue)
                let defV = try XCTUnwrap((m["default"] as? NSNumber)?.doubleValue)
                XCTAssertEqual(effects[keyPath: param.keyPath], defV, "\(fid).\(plat)")
                XCTAssertEqual(param.range, minV...maxV, "\(fid).\(plat)")
            }
            var probe = RawSettings.default
            probe.setExactEditingEffect(param, to: param.range.lowerBound - 10)
            XCTAssertEqual(probe.editingEffectValue(param), param.range.lowerBound)
            probe.setExactEditingEffect(param, to: param.range.upperBound + 10)
            XCTAssertEqual(probe.editingEffectValue(param), param.range.upperBound)
        }

        // ToneControlsSettings & AtmosphereSettings runtime defaults & validation
        let tone = ToneControlsSettings()
        XCTAssertEqual(tone.blackPoint, try XCTUnwrap((try model("tone.black_point", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(tone.whitePoint, try XCTUnwrap((try model("tone.white_point", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(tone.vibrance, try XCTUnwrap((try model("color.vibrance", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertTrue(tone.isValid)
        XCTAssertFalse(ToneControlsSettings(blackPoint: -101).isValid)
        XCTAssertFalse(ToneControlsSettings(whitePoint: 101).isValid)

        let atmosphere = AtmosphereSettings()
        XCTAssertEqual(atmosphere.clarity, try XCTUnwrap((try model("effects.clarity", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(atmosphere.dehaze, try XCTUnwrap((try model("effects.dehaze", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertTrue(atmosphere.isValid)
        XCTAssertFalse(AtmosphereSettings(clarity: 101).isValid)

        // GeometrySettings runtime defaults & validation
        let geometry = GeometrySettings()
        XCTAssertEqual(geometry.cropX, try XCTUnwrap((try model("geometry.crop.x", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(geometry.cropY, try XCTUnwrap((try model("geometry.crop.y", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(geometry.cropWidth, try XCTUnwrap((try model("geometry.crop.width", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(geometry.cropHeight, try XCTUnwrap((try model("geometry.crop.height", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(geometry.quarterTurns, try XCTUnwrap((try model("geometry.quarter_turns", platform: "macos")["default"] as? NSNumber)?.intValue))
        XCTAssertEqual(geometry.flipHorizontal, try XCTUnwrap(try model("geometry.flip_horizontal", platform: "macos")["default"] as? Bool))
        XCTAssertEqual(geometry.flipVertical, try XCTUnwrap(try model("geometry.flip_vertical", platform: "macos")["default"] as? Bool))
        XCTAssertEqual(geometry.straightenDegrees, try XCTUnwrap((try model("geometry.straighten_degrees", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(geometry.perspectiveHorizontal, try XCTUnwrap((try model("geometry.perspective.horizontal", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(geometry.perspectiveVertical, try XCTUnwrap((try model("geometry.perspective.vertical", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertTrue(geometry.isValid)
        XCTAssertFalse(GeometrySettings(cropWidth: 0).isValid)
        XCTAssertFalse(GeometrySettings(quarterTurns: 4).isValid)

        // ColorGradingSettings, ToneCurveSettings, RawDenoiseSettings, HDRSettings runtime checks
        let grading = ColorGradingSettings()
        XCTAssertTrue(grading.isValid)
        XCTAssertFalse(ColorGradingWheel(hue: 360, saturation: 0).isValid)
        XCTAssertFalse(ColorGradingWheel(hue: 0, saturation: 101).isValid)

        let curve = ToneCurveSettings()
        XCTAssertTrue(curve.isDefault)
        XCTAssertTrue(curve.isValid)
        XCTAssertFalse(ToneCurveShape(mode: .custom, points: []).isValid)

        let denoise = RawDenoiseSettings()
        let waveletDefault = try XCTUnwrap(try model("detail.denoise.wavelet", platform: "ios")["default"] as? [String: Any])
        XCTAssertEqual(denoise.enabled, waveletDefault["enabled"] as? Bool)
        XCTAssertEqual(denoise.luma, (waveletDefault["luma"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(denoise.chroma, (waveletDefault["chroma"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(denoise.coarse, (waveletDefault["coarse"] as? NSNumber)?.doubleValue)
        XCTAssertTrue(denoise.isValid)
        XCTAssertFalse(RawDenoiseSettings(luma: 101).isValid)

        let hdr = HDRSettings()
        XCTAssertEqual(hdr.renditionSettings.peakLimitEV, try XCTUnwrap((try model("hdr.peak_limit_ev", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(hdr.renditionSettings.sdrExposureEV, try XCTUnwrap((try model("hdr.sdr_exposure_ev", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(hdr.renditionSettings.sdrContrast, try XCTUnwrap((try model("hdr.sdr_contrast", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(hdr.renditionSettings.sdrSaturation, try XCTUnwrap((try model("hdr.sdr_saturation", platform: "macos")["default"] as? NSNumber)?.doubleValue))
        XCTAssertTrue(hdr.isValid)
        XCTAssertFalse(HDRRenditionSettings(peakLimitEV: 6.1).isValid)
    }

    func testMacAdjustmentParameterSpecsMatchSpecJSON() throws {
        let root = try loadSpecJSON()
        let fields = try XCTUnwrap(root["fields"] as? [[String: Any]])
        var entryById: [String: [String: Any]] = [:]
        for entry in fields {
            if let fid = entry["field_id"] as? String {
                entryById[fid] = entry
            }
        }

        func fieldId(for parameter: AdjustmentParameter) -> String {
            switch parameter {
            case .strength: return "looks.strength"
            case .exposure: return "light.exposure"
            case .temperature: return "color.white_balance.temperature_kelvin"
            case .tint: return "color.white_balance.tint"
            case .blackPoint: return "tone.black_point"
            case .whitePoint: return "tone.white_point"
            case .vibrance: return "color.vibrance"
            case .clarity: return "effects.clarity"
            case .dehaze: return "effects.dehaze"
            case .contrast: return "light.contrast"
            case .highlights: return "light.highlights"
            case .shadows: return "light.shadows"
            case .toneCurve: return "light.s_curve"
            case .saturation: return "color.saturation"
            case .sharpening: return "detail.sharpening"
            case .rawNoiseReduction: return "detail.denoise.raw_level"
            case .denoiseMode: return "detail.denoise.chroma_mode"
            case .vignetteAmount: return "effects.vignette.amount"
            case .grainAmount: return "effects.grain.amount"
            }
        }

        func expectedDecimals(forUIStep uiStep: Double) -> Int {
            if abs(uiStep - 0.01) < 1e-9 { return 2 }
            if abs(uiStep - 0.1) < 1e-9 { return 1 }
            return 0
        }

        XCTAssertEqual(AdjustmentParameter.allCases.count, 19)
        for parameter in AdjustmentParameter.allCases {
            let fid = fieldId(for: parameter)
            let entry = try XCTUnwrap(entryById[fid], fid)
            let model = try XCTUnwrap(entry["model"] as? [String: Any], fid)
            let macModel = try XCTUnwrap(model["macos"] as? [String: Any], fid)
            let ui = try XCTUnwrap(entry["ui"] as? [String: Any], fid)
            let macUI = try XCTUnwrap(ui["macos"] as? [String: Any], fid)

            let minV = try XCTUnwrap((macModel["min"] as? NSNumber)?.doubleValue, fid)
            let maxV = try XCTUnwrap((macModel["max"] as? NSNumber)?.doubleValue, fid)
            let defaultV = try XCTUnwrap(
                ((macModel["default"] as? NSNumber) ?? (macUI["default"] as? NSNumber))?.doubleValue,
                fid
            )
            let spec = parameter.spec
            XCTAssertEqual(spec.range, minV...maxV, "\(parameter.rawValue) range")
            XCTAssertEqual(spec.defaultValue, defaultV, "\(parameter.rawValue) default")
            XCTAssertEqual(spec.reciprocalScale, parameter == .temperature, "\(parameter.rawValue) reciprocalScale")
            if (macUI["exposed"] as? Bool) == true {
                let uiStep = try XCTUnwrap((macUI["step"] as? NSNumber)?.doubleValue, fid)
                let expectedUnit = (macUI["unit"] as? String) ?? ""
                XCTAssertEqual(spec.step * spec.displayScale, uiStep, accuracy: 1e-9, "\(parameter.rawValue) UI step")
                XCTAssertEqual(spec.unit, expectedUnit, "\(parameter.rawValue) unit")
                XCTAssertEqual(spec.decimals, expectedDecimals(forUIStep: uiStep), "\(parameter.rawValue) decimals")
            } else {
                XCTAssertEqual(parameter, .denoiseMode)
                XCTAssertNil(macUI["step"] as? NSNumber)
            }
        }

        var hdrSettings = Adjustments()
        hdrSettings.hdr = HDRSettings()

        let exposureEntry = try XCTUnwrap(entryById["light.exposure"])
        let exposureMacModel = try XCTUnwrap((exposureEntry["model"] as? [String: Any])?["macos"] as? [String: Any])
        let hdrExpMin = try XCTUnwrap((exposureMacModel["hdr_min"] as? NSNumber)?.doubleValue)
        let hdrExpMax = try XCTUnwrap((exposureMacModel["hdr_max"] as? NSNumber)?.doubleValue)
        let hdrExpSpec = AdjustmentParameter.exposure.spec(for: hdrSettings)
        XCTAssertEqual(hdrExpSpec.range, hdrExpMin...hdrExpMax)
        XCTAssertEqual(hdrExpSpec.defaultValue, try XCTUnwrap((exposureMacModel["default"] as? NSNumber)?.doubleValue))
        XCTAssertEqual(hdrExpSpec.step, AdjustmentParameter.exposure.spec.step)
        XCTAssertEqual(hdrExpSpec.decimals, AdjustmentParameter.exposure.spec.decimals)

        let postRgbEntry = try XCTUnwrap(entryById["detail.denoise.post_rgb"])
        let postRgbMacModel = try XCTUnwrap((postRgbEntry["model"] as? [String: Any])?["macos"] as? [String: Any])
        let postRgbMin = try XCTUnwrap((postRgbMacModel["min"] as? NSNumber)?.doubleValue)
        let postRgbMax = try XCTUnwrap((postRgbMacModel["max"] as? NSNumber)?.doubleValue)
        let postRgbDefault = try XCTUnwrap((postRgbMacModel["default"] as? NSNumber)?.doubleValue)
        let hdrDenoiseSpec = AdjustmentParameter.denoiseMode.spec(for: hdrSettings)
        XCTAssertEqual(hdrDenoiseSpec.range, postRgbMin...postRgbMax)
        XCTAssertEqual(hdrDenoiseSpec.defaultValue, postRgbDefault)
        XCTAssertEqual(hdrDenoiseSpec.step, 0.01, accuracy: 1e-9)
        XCTAssertEqual(hdrDenoiseSpec.displayScale, 100)
        XCTAssertEqual(hdrDenoiseSpec.unit, "%")

        for parameter in [AdjustmentParameter.contrast, .highlights, .shadows, .toneCurve, .saturation] {
            let hdrSpec = parameter.spec(for: hdrSettings)
            XCTAssertEqual(hdrSpec.range, -100...100, "\(parameter.rawValue) HDR range")
            XCTAssertEqual(hdrSpec.displayRange, -100...100, "\(parameter.rawValue) HDR displayRange")
            XCTAssertEqual(hdrSpec.defaultValue, 0, "\(parameter.rawValue) HDR default")
            XCTAssertEqual(hdrSpec.displayScale, 1.0, "\(parameter.rawValue) HDR displayScale")
        }

        let lensVignettingEntry = try XCTUnwrap(entryById["geometry.lens.vignetting"])
        let lensVignettingMacUI = try XCTUnwrap((lensVignettingEntry["ui"] as? [String: Any])?["macos"] as? [String: Any])
        XCTAssertEqual(lensVignettingMacUI["exposed"] as? Bool, true)
        XCTAssertEqual(lensVignettingMacUI["modes"] as? [String], ["sdr", "hdr"])

        var sdrWithAsShot = Adjustments()
        sdrWithAsShot.resolveWhiteBalance(WhiteBalance(temperature: 5200, tint: 12))
        XCTAssertEqual(AdjustmentParameter.temperature.spec(for: sdrWithAsShot).defaultValue, 5200)
        XCTAssertEqual(AdjustmentParameter.tint.spec(for: sdrWithAsShot).defaultValue, 12)
        sdrWithAsShot.setTransferRecipe(MasterRecipe.hamadaDaylightV2.id)
        XCTAssertEqual(AdjustmentParameter.tint.spec(for: sdrWithAsShot).defaultValue, 0)
    }

    private func assertModelSpecMatchesJSON(_ actual: AdjustmentFieldModelSpec, _ json: [String: Any], label: String) {
        XCTAssertEqual(actual.supported, json["supported"] as? Bool, label)
        XCTAssertEqual(actual.modes, json["modes"] as? [String], label)
        XCTAssertEqual(actual.storageType, json["storage_type"] as? String, label)
        XCTAssertEqual(actual.nullable, json["nullable"] as? Bool, label)
        XCTAssertEqual(actual.min, (json["min"] as? NSNumber)?.doubleValue, label)
        XCTAssertEqual(actual.max, (json["max"] as? NSNumber)?.doubleValue, label)
        XCTAssertEqual(actual.scaleFromProtocol, json["scale_from_protocol"] as? String, label)
        XCTAssertEqual(actual.quantization.rawValue, json["quantization"] as? String, label)
        XCTAssertEqual(actual.hdrMin, (json["hdr_min"] as? NSNumber)?.doubleValue, label)
        XCTAssertEqual(actual.hdrMax, (json["hdr_max"] as? NSNumber)?.doubleValue, label)
        XCTAssertEqual(actual.hdrDefaultNumber, (json["hdr_default"] as? NSNumber)?.doubleValue, label)
        XCTAssertEqual(actual.hdrScaleFromProtocol, json["hdr_scale_from_protocol"] as? String, label)
    }

    private func assertProtocolRuntimeAcceptance(_ field: AdjustmentTransferField, proto: [String: Any]) throws {
        let isHDR = (proto["hdr_only"] as? Bool) == true
        let source = AdjustmentTransferSource(
            identifier: "spec-probe",
            isRaw: !isHDR,
            processingVersion: 3,
            recipe: nil,
            hdrProcessingVersion: isHDR ? 7 : nil
        )
        let nullable = (proto["nullable"] as? Bool) == true
        if nullable && field != .tint {
            XCTAssertNoThrow(try AdjustmentTransferPayload(source: source, values: [field.rawValue: .null]), field.rawValue)
        } else if !nullable {
            XCTAssertThrowsError(try AdjustmentTransferPayload(source: source, values: [field.rawValue: .null]), field.rawValue)
        }

        if let valueType = proto["value_type"] as? String,
           (valueType == "number" || valueType == "integer"),
           let minV = (proto["min"] as? NSNumber)?.doubleValue,
           let maxV = (proto["max"] as? NSNumber)?.doubleValue {
            let exclusiveMin = (proto["exclusive_min"] as? Bool) == true
            if field != .temperature && field != .tint {
                let loTest = exclusiveMin ? minV : minV - 1
                XCTAssertThrowsError(
                    try AdjustmentTransferPayload(source: source, values: [field.rawValue: .number(loTest)]),
                    "\(field.rawValue) should reject below-min \(loTest)"
                )
                XCTAssertThrowsError(
                    try AdjustmentTransferPayload(source: source, values: [field.rawValue: .number(maxV + 1)]),
                    "\(field.rawValue) should reject above-max \(maxV + 1)"
                )
                if !exclusiveMin {
                    XCTAssertNoThrow(
                        try AdjustmentTransferPayload(source: source, values: [field.rawValue: .number(minV)]),
                        "\(field.rawValue) should accept min \(minV)"
                    )
                }
                XCTAssertNoThrow(
                    try AdjustmentTransferPayload(source: source, values: [field.rawValue: .number(maxV)]),
                    "\(field.rawValue) should accept max \(maxV)"
                )
            }
        }
    }
}
