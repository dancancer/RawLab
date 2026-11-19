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
        XCTAssertEqual(fields.count, 83)

        let transferFields = fields.filter { (($0["protocol"] as? [String: Any])?["transferable"] as? Bool) == true }
        let localFields = fields.filter { (($0["protocol"] as? [String: Any])?["transferable"] as? Bool) == false }
        XCTAssertEqual(transferFields.count, 81)
        XCTAssertEqual(localFields.count, 2)

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
        XCTAssertNil(mac.chromaNoiseReduction)
        XCTAssertNil(mac.waveletNoiseReduction)
        XCTAssertEqual(mac.aiDenoiseEnabled, try XCTUnwrap(try model("local.ai_denoise_enabled", platform: "macos")["default"] as? Bool))
        XCTAssertEqual(mac.hdrCameraAIEnabled, try XCTUnwrap(try model("local.hdr_camera_ai_enabled", platform: "macos")["default"] as? Bool))

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
        XCTAssertEqual(ios.noiseReduction, try XCTUnwrap((try model("detail.denoise.post_rgb", platform: "ios")["default"] as? NSNumber)?.doubleValue))
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
