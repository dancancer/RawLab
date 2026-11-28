import Foundation

public enum AdjustmentTransferError: Error, Equatable {
    case invalidPayload(String)
    case unsupportedVersion
    case emptyScope
    case draftRequiresPreflight
    case incompatible(String)
    case missingLook(String)
    case unrepresentable(String)
}

// Q3/Q4 粘贴提示：本平台不支持的键收到非 0 值时忽略并提示；处理版本与来源不同
// 时沿用目标处理版本并提示。两种情况都不拒绝粘贴，也不改动目标的其它字段。
public enum AdjustmentTransferNotice: Equatable, Hashable {
    case ignoredRawDenoise
    case ignoredPostRGBDenoise
    case ignoredTargetDenoise
    case retainedTargetProcessingVersion

    // 共享场景 fixture（adjustment-transfer-scenarios-v1.json expect.notices）的稳定标识。
    public var fixtureId: String {
        switch self {
        case .ignoredRawDenoise: return "ignored_raw_denoise"
        case .ignoredPostRGBDenoise: return "ignored_post_rgb_denoise"
        case .ignoredTargetDenoise: return "ignored_target_denoise"
        case .retainedTargetProcessingVersion: return "retained_target_processing_version"
        }
    }

    // 文案键登记在 Shared/strings；同一次粘贴把去重后的提示合并为一条一次性提示。
    public var promptKey: String {
        switch self {
        case .ignoredRawDenoise: return "已忽略旧版 RAW 降噪（FBDD）"
        case .ignoredPostRGBDenoise: return "已忽略渲染后 RGB 降噪"
        case .ignoredTargetDenoise: return "已忽略目标不支持的普通降噪设置"
        case .retainedTargetProcessingVersion: return "处理版本与来源不同，已沿用当前照片的处理版本"
        }
    }
}

public enum AdjustmentTransferField: String, CaseIterable, Codable, Hashable {
    case look = "looks.reference", strength = "looks.strength"
    case exposure = "light.exposure", exposureMode = "light.exposure_mode"
    case contrast = "light.contrast", highlights = "light.highlights", shadows = "light.shadows", sCurve = "light.s_curve"
    case curve = "light.curve"
    case curveApplyToLuminosity = "light.curve.apply_to_luminosity", curveParametric = "light.curve.parametric"
    case blackPoint = "tone.black_point", whitePoint = "tone.white_point", vibrance = "color.vibrance"
    case gradingShadows = "color.grading.shadows", gradingMidtones = "color.grading.midtones", gradingHighlights = "color.grading.highlights"
    case gradingGlobal = "color.grading.global", gradingBlending = "color.grading.blending", gradingBalance = "color.grading.balance"
    case whiteBalanceMode = "color.white_balance.mode", temperature = "color.white_balance.temperature_kelvin"
    case tint = "color.white_balance.tint", saturation = "color.saturation"
    case hdrTemperature = "hdr.relative_temperature", hdrTint = "hdr.relative_tint"
    case hdrPeakLimit = "hdr.peak_limit_ev", hdrSDRExposure = "hdr.sdr_exposure_ev"
    case hdrSDRContrast = "hdr.sdr_contrast", hdrSDRSaturation = "hdr.sdr_saturation"
    case hdrLook = "hdr.look"
    case hdrCameraDevelopment = "hdr.camera_development"
    case hslHueRed = "color.hsl.hue.red", hslHueOrange = "color.hsl.hue.orange", hslHueYellow = "color.hsl.hue.yellow"
    case hslHueGreen = "color.hsl.hue.green", hslHueAqua = "color.hsl.hue.aqua", hslHueBlue = "color.hsl.hue.blue"
    case hslHuePurple = "color.hsl.hue.purple", hslHueMagenta = "color.hsl.hue.magenta"
    case hslSaturationRed = "color.hsl.saturation.red", hslSaturationOrange = "color.hsl.saturation.orange"
    case hslSaturationYellow = "color.hsl.saturation.yellow", hslSaturationGreen = "color.hsl.saturation.green"
    case hslSaturationAqua = "color.hsl.saturation.aqua", hslSaturationBlue = "color.hsl.saturation.blue"
    case hslSaturationPurple = "color.hsl.saturation.purple", hslSaturationMagenta = "color.hsl.saturation.magenta"
    case hslLightnessRed = "color.hsl.lightness.red", hslLightnessOrange = "color.hsl.lightness.orange"
    case hslLightnessYellow = "color.hsl.lightness.yellow", hslLightnessGreen = "color.hsl.lightness.green"
    case hslLightnessAqua = "color.hsl.lightness.aqua", hslLightnessBlue = "color.hsl.lightness.blue"
    case hslLightnessPurple = "color.hsl.lightness.purple", hslLightnessMagenta = "color.hsl.lightness.magenta"
    case calibrationShadowTint = "color.calibration.shadow_tint"
    case calibrationRedHue = "color.calibration.red_hue", calibrationRedSaturation = "color.calibration.red_saturation"
    case calibrationGreenHue = "color.calibration.green_hue", calibrationGreenSaturation = "color.calibration.green_saturation"
    case calibrationBlueHue = "color.calibration.blue_hue", calibrationBlueSaturation = "color.calibration.blue_saturation"
    case pointColor = "color.point_color"
    case selectiveColor = "color.selective_color"
    case bwEnabled = "color.bw.enabled", bwMixer = "color.bw.mixer"
    case vignetteAmount = "effects.vignette.amount", vignetteMidpoint = "effects.vignette.midpoint"
    case vignetteRoundness = "effects.vignette.roundness", vignetteFeather = "effects.vignette.feather"
    case vignetteHighlights = "effects.vignette.highlights", grainAmount = "effects.grain.amount"
    case clarity = "effects.clarity", dehaze = "effects.dehaze", texture = "effects.texture"
    case grainSize = "effects.grain.size", grainRoughness = "effects.grain.roughness"
    case grainToneCurve = "effects.grain.tone_curve", grainFormatPreset = "effects.grain.format_preset"
    case halationAmount = "effects.halation.amount", halationThreshold = "effects.halation.threshold"
    case halationRadius = "effects.halation.radius", halationHue = "effects.halation.hue"
    case bloomAmount = "effects.bloom.amount", bloomThreshold = "effects.bloom.threshold", bloomRadius = "effects.bloom.radius"
    case sharpening = "detail.sharpening"
    case sharpeningLuminanceV2 = "detail.sharpening.luminance_v2", sharpeningRadius = "detail.sharpening.radius"
    case sharpeningDetail = "detail.sharpening.detail", sharpeningMasking = "detail.sharpening.masking"
    case rawDenoise = "detail.denoise.raw_level"
    case postRGBDenoise = "detail.denoise.post_rgb"
    case chromaDenoise = "detail.denoise.chroma_mode", waveletDenoise = "detail.denoise.wavelet"
    case cropX = "geometry.crop.x", cropY = "geometry.crop.y"
    case cropWidth = "geometry.crop.width", cropHeight = "geometry.crop.height", quarterTurns = "geometry.quarter_turns"
    case flipHorizontal = "geometry.flip_horizontal", flipVertical = "geometry.flip_vertical"
    case straighten = "geometry.straighten_degrees"
    case perspectiveHorizontal = "geometry.perspective.horizontal", perspectiveVertical = "geometry.perspective.vertical"
    case lensDistortion = "geometry.lens.distortion", lensTCA = "geometry.lens.tca"
    case lensVignetting = "geometry.lens.vignetting"
    case lensAutoCrop = "geometry.lens.auto_crop", lensProfile = "geometry.lens.profile_id"
    case lensDefringePurpleAmount = "geometry.lens.defringe_purple_amount", lensDefringePurpleHue = "geometry.lens.defringe_purple_hue"
    case lensDefringeGreenAmount = "geometry.lens.defringe_green_amount", lensDefringeGreenHue = "geometry.lens.defringe_green_hue"

    public var spec: AdjustmentFieldDefinition { AdjustmentFieldSpec.forId(rawValue)! }
    public var isHDRRelative: Bool { spec.protocolSpec.isHDRRelative }
    public var isHDROnly: Bool { spec.protocolSpec.isHDROnly }
    public var group: String { spec.group }
    public var gradingZone: ColorGradingZone? {
        switch self {
        case .gradingShadows: return .shadows
        case .gradingMidtones: return .midtones
        case .gradingHighlights: return .highlights
        default: return nil
        }
    }
    public static var legacyFields: Set<Self> { Set(allCases.filter { !$0.isHDROnly }) }
    public static var common: Set<Self> { Set(legacyFields.filter { $0.group != "geometry" }) }
    public static let hdrCommon: Set<Self> = [.exposure, .contrast, .highlights, .shadows, .saturation, .hdrTemperature, .hdrTint]
    public static let hdrGeometry: Set<Self> = [.cropX, .cropY, .cropWidth, .cropHeight, .quarterTurns,
        .flipHorizontal, .flipVertical, .straighten, .perspectiveHorizontal, .perspectiveVertical]
    public static let hdrTone: Set<Self> = [.blackPoint, .whitePoint, .sCurve, .curve]
    public static let hdrColor = Set(allCases.filter { $0 == .vibrance || $0.gradingZone != nil || $0.hslLocation != nil })
    public static let hdrRendition: Set<Self> = [.hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation]
    public static let hdrEffects: Set<Self> = [.vignetteAmount, .vignetteMidpoint, .vignetteRoundness,
        .vignetteFeather, .vignetteHighlights, .grainAmount, .grainSize, .grainRoughness]
    public static let hdrDetail: Set<Self> = [.sharpening, .clarity, .dehaze, .postRGBDenoise]
    public static let hdrV1Supported = hdrCommon.union(hdrGeometry)
    public static let hdrV2Supported = hdrV1Supported.union(hdrTone)
    public static let hdrV3Supported = hdrV2Supported.union(hdrColor)
    public static let hdrV4Supported = hdrV3Supported.union(hdrRendition)
    public static let hdrV5Supported = hdrV4Supported.union(hdrEffects)
    public static let hdrV6Supported = hdrV5Supported.union(hdrDetail)
    public static let hdrSupported = hdrV6Supported.union([.hdrLook])
    public static let hdrV9ToneExtensions: Set<Self> = [.curveApplyToLuminosity, .curveParametric]
    public static let hdrV9ColorExtensions: Set<Self> = [.gradingGlobal, .gradingBlending, .gradingBalance]
    public static let hdrV9Supported = hdrSupported.union(hdrV9ToneExtensions).union(hdrV9ColorExtensions)
    public static func hdrTransferFields(cameraRAW: Bool) -> Set<Self> {
        cameraRAW ? hdrV9Supported.union([.hdrCameraDevelopment]) : hdrV9Supported
    }
    public static func hdrSupported(version: Int) -> Set<Self> {
        if version == 1 { return hdrV1Supported }
        if version == 2 { return hdrV2Supported }
        if version == 3 { return hdrV3Supported }
        if version == 4 { return hdrV4Supported }
        if version == 5 { return hdrV5Supported }
        if version == 6 { return hdrV6Supported }
        return version >= 9 ? hdrV9Supported : hdrSupported
    }
    public static let whiteBalanceFields: Set<Self> = [.whiteBalanceMode, .temperature, .tint]
    public static let lensFields: Set<Self> = [.lensDistortion, .lensTCA, .lensVignetting, .lensAutoCrop, .lensProfile]
    public static let denoiseFields: Set<Self> = [.rawDenoise, .postRGBDenoise, .chromaDenoise, .waveletDenoise]
    public static var recipeDependencies: Set<Self> {
        Set([.look, .strength, .exposure, .contrast, .highlights, .shadows, .saturation]).union(whiteBalanceFields)
            .union(allCases.filter { $0.hslLocation != nil })
    }
    public static let refinementScalars: Set<Self> = [.sCurve, .blackPoint, .whitePoint, .vibrance, .clarity, .dehaze]
    public static let refinementObjects: Set<Self> = [.curve, .gradingShadows, .gradingMidtones, .gradingHighlights]
    public static func recipeDependencies(version: Int) -> Set<Self> {
        version >= 4 ? recipeDependencies.union(refinementScalars).union(refinementObjects) : recipeDependencies
    }
    public var hslLocation: (axis: String, channel: Int)? {
        let parts = rawValue.split(separator: ".").map(String.init)
        guard parts.count == 4, parts[1] == "hsl",
              let channel = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"].firstIndex(of: parts[3]) else { return nil }
        return (parts[2], channel)
    }
    public var scalarRange: ClosedRange<Double>? {
        let proto = spec.protocolSpec
        guard !proto.nullable, proto.valueType == .number || self == .quarterTurns else { return nil }
        return proto.closedRange
    }
}

public enum AdjustmentTransferScope {
    case all, modified, custom(Set<AdjustmentTransferField>)
    public static var standard: Self { .custom(AdjustmentTransferField.common) }
    public static func standard(isHDR: Bool) -> Self { .custom(isHDR ? AdjustmentTransferField.hdrCommon : AdjustmentTransferField.common) }
}

// 这是逻辑 payload 的 JSON 值，不是 native snapshot 或渲染 recipe。
public enum AdjustmentTransferValue: Codable, Equatable {
    case number(Double), string(String), boolean(Bool), object([String: Self]), array([Self]), null

    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var boolean: Bool? { if case .boolean(let v) = self { return v }; return nil }
    public var object: [String: Self]? { if case .object(let v) = self { return v }; return nil }
    public var array: [Self]? { if case .array(let v) = self { return v }; return nil }
    public var hdrLookSettings: HDRLookSettings? {
        if self == .null { return HDRLookSettings() }
        let expectedKeys = Set(AdjustmentFieldSpec.Fields.hdrLook.protocolSpec.objectKeys)
        guard let object, Set(object.keys) == expectedKeys, let sha256 = object["sha256"]?.string,
              let name = object["name"]?.string, let strength = object["strength"]?.number else { return nil }
        let value = HDRLookSettings(sha256: sha256, name: name, strength: strength); return value.isValid ? value : nil
    }
    public var hdrCameraDevelopment: HDRCameraDevelopmentSettings? {
        let expectedKeys = Set(AdjustmentFieldSpec.Fields.hdrCameraDevelopment.protocolSpec.objectKeys)
        guard let object, Set(object.keys) == expectedKeys,
              let rawVersion = object["version"]?.number, rawVersion.rounded() == rawVersion,
              AdjustmentFieldSpec.SubFields.HDRCameraDevelopment.allowedVersions.contains(Int(rawVersion)),
              let mode = object["white_balance_mode"]?.string.flatMap(HDRCameraDevelopmentSettings.WhiteBalance.init(rawValue:)),
              let temperature = object["temperature"]?.number, let tint = object["tint"]?.number,
              let exposure = object["exposure_reference"]?.string.flatMap(HDRCameraDevelopmentSettings.ExposureReference.init(rawValue:)),
              let level = object["fbdd_level"]?.number, level.rounded() == level,
              AdjustmentFieldSpec.SubFields.HDRCameraDevelopment.allowedFbddLevels.contains(Int(level)) else { return nil }
        var value = HDRCameraDevelopmentSettings(); value.whiteBalance = mode; value.temperature = temperature; value.tint = tint
        value.exposureReference = exposure; value.fbddLevel = Int(level); return value.isValid ? value : nil
    }
    public var curve: ToneCurveSettings? {
        guard let object, Set(object.keys).isSuperset(of: ["mode", "points"]),
              Set(object.keys).isSubset(of: ["mode", "points", "channels"]) else { return nil }
        func shape(_ object: [String: Self]) -> ToneCurveShape? {
            guard Set(object.keys) == ["mode", "points"],
                  let mode = object["mode"]?.string.flatMap(ToneCurveMode.init(rawValue:)),
                  let values = object["points"]?.array else { return nil }
            var points = [ToneCurvePoint]()
            for value in values {
                guard let pair = value.array, pair.count == 2, let x = pair[0].number, let y = pair[1].number else { return nil }
                points.append(.init(x: x, y: y))
            }
            let curve = ToneCurveShape(mode: mode, points: points)
            return curve.isValid ? curve : nil
        }
        guard let master = shape(object.filter { $0.key != "channels" }) else { return nil }
        var result = ToneCurveSettings(mode: master.mode, points: master.points)
        if let value = object["channels"] {
            guard let channels = value.object, Set(channels.keys).isSubset(of: ["red", "green", "blue"]) else { return nil }
            for channel in ToneCurveChannel.allCases where channel != .rgb {
                if let value = channels[channel.rawValue] {
                    guard let fields = value.object, let curve = shape(fields) else { return nil }
                    result = result.replacing(channel, with: curve)
                }
            }
        }
        return result
    }
    public var parametricCurve: ToneCurveParametric? {
        let expected = Set(AdjustmentFieldSpec.Fields.lightCurveParametric.protocolSpec.objectKeys)
        guard let object, Set(object.keys) == expected,
              let highlights = object["highlights"]?.number, let lights = object["lights"]?.number,
              let darks = object["darks"]?.number, let shadows = object["shadows"]?.number,
              let splitShadow = object["split_shadow"]?.number, let splitMidtone = object["split_midtone"]?.number,
              let splitHighlight = object["split_highlight"]?.number else { return nil }
        let value = ToneCurveParametric(highlights: highlights, lights: lights, darks: darks, shadows: shadows,
                                        splitShadow: splitShadow, splitMidtone: splitMidtone, splitHighlight: splitHighlight)
        return value.isValid ? value : nil
    }
    public var gradingWheel: ColorGradingWheel? {
        let proto = AdjustmentFieldSpec.Fields.colorGradingShadows.protocolSpec
        guard let wheel = object, Set(wheel.keys).isSuperset(of: proto.objectKeys),
              Set(wheel.keys).isSubset(of: Set(proto.objectKeys).union(proto.optionalKeys)),
              let hue = wheel["hue"]?.number, let saturation = wheel["saturation"]?.number else { return nil }
        let luminance: Double
        if let lumVal = wheel["luminance"] { guard let lum = lumVal.number else { return nil }; luminance = lum } else { luminance = 0 }
        let result = ColorGradingWheel(hue: hue, saturation: saturation, luminance: luminance)
        return result.isValid ? result : nil
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .boolean(bool) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = .object(try value.decode([String: Self].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .number(let n): try value.encode(n); case .string(let s): try value.encode(s); case .boolean(let b): try value.encode(b)
        case .object(let o): try value.encode(o); case .array(let a): try value.encode(a); case .null: try value.encodeNil()
        }
    }
}

public extension ToneCurveShape {
    var transferValue: AdjustmentTransferValue { .object(["mode": .string(mode.rawValue), "points": .array(points.map { .array([.number($0.x), .number($0.y)]) })]) }
}
public extension ToneCurveSettings {
    var transferValue: AdjustmentTransferValue {
        var value = master.transferValue.object!
        if hasChannelCurves { value["channels"] = .object(["red": channels.red.transferValue, "green": channels.green.transferValue, "blue": channels.blue.transferValue]) }
        return .object(value)
    }
}
public extension ToneCurveParametric {
    var transferValue: AdjustmentTransferValue {
        .object(["highlights": .number(highlights), "lights": .number(lights), "darks": .number(darks), "shadows": .number(shadows),
                 "split_shadow": .number(splitShadow), "split_midtone": .number(splitMidtone), "split_highlight": .number(splitHighlight)])
    }
}
public extension ColorGradingWheel {
    var transferValue: AdjustmentTransferValue {
        var obj: [String: AdjustmentTransferValue] = ["hue": .number(hue), "saturation": .number(saturation)]
        if luminance != 0.0 { obj["luminance"] = .number(luminance) }
        return .object(obj)
    }
}

public extension AdjustmentTransferValue {
    var pointColorSettings: PointColorSettings? {
        let sf = AdjustmentFieldSpec.SubFields.PointColor.self
        guard let object, Set(object.keys) == Set(AdjustmentFieldSpec.Fields.colorPointColor.protocolSpec.objectKeys),
              let rawSwatches = object["swatches"]?.array, rawSwatches.count <= sf.maxSwatches else { return nil }
        let expectedSwatchKeys = Set(["src_hue", "src_saturation", "src_luminance",
                                      "hue_shift", "saturation_shift", "luminance_shift",
                                      "range", "hue_range", "sat_range", "lum_range", "variance", "enabled"])
        var parsed: [PointColorSwatch] = []
        for item in rawSwatches {
            guard let sw = item.object, Set(sw.keys) == expectedSwatchKeys,
                  let srcHue = sw["src_hue"]?.number, let srcSat = sw["src_saturation"]?.number, let srcLum = sw["src_luminance"]?.number,
                  let hueShift = sw["hue_shift"]?.number, let satShift = sw["saturation_shift"]?.number, let lumShift = sw["luminance_shift"]?.number,
                  let range = sw["range"]?.number, let hueRange = sw["hue_range"]?.number, let satRange = sw["sat_range"]?.number,
                  let lumRange = sw["lum_range"]?.number, let variance = sw["variance"]?.number,
                  let enabled = sw["enabled"]?.boolean else { return nil }
            let s = PointColorSwatch(srcHue: srcHue, srcSaturation: srcSat, srcLuminance: srcLum,
                                     hueShift: hueShift, saturationShift: satShift, luminanceShift: lumShift,
                                     range: range, hueRange: hueRange, satRange: satRange, lumRange: lumRange,
                                     variance: variance, enabled: enabled)
            guard s.isValid else { return nil }
            parsed.append(s)
        }
        return PointColorSettings(swatches: parsed)
    }

    var selectiveColorSettings: SelectiveColorSettings? {
        let sf = AdjustmentFieldSpec.SubFields.SelectiveColor.self
        guard let object, Set(object.keys) == Set(AdjustmentFieldSpec.Fields.colorSelectiveColor.protocolSpec.objectKeys),
              let methodStr = object["method"]?.string, sf.allowedMethods.contains(methodStr),
              let method = SelectiveColorMethod(rawValue: methodStr),
              let bandsObj = object["bands"]?.object, Set(bandsObj.keys) == Set(sf.allowedBands) else { return nil }
        let compKeys = Set(sf.allowedComponents)
        func parseBand(_ name: String) -> SelectiveColorBand? {
            guard let b = bandsObj[name]?.object, Set(b.keys) == compKeys,
                  let c = b["cyan"]?.number, let m = b["magenta"]?.number,
                  let y = b["yellow"]?.number, let k = b["black"]?.number else { return nil }
            let band = SelectiveColorBand(cyan: c, magenta: m, yellow: y, black: k)
            return band.isValid ? band : nil
        }
        guard let reds = parseBand("reds"), let yellows = parseBand("yellows"), let greens = parseBand("greens"),
              let cyans = parseBand("cyans"), let blues = parseBand("blues"), let magentas = parseBand("magentas"),
              let whites = parseBand("whites"), let neutrals = parseBand("neutrals"), let blacks = parseBand("blacks") else { return nil }
        return SelectiveColorSettings(method: method, bands: .init(reds: reds, yellows: yellows, greens: greens, cyans: cyans,
                                                                   blues: blues, magentas: magentas, whites: whites, neutrals: neutrals, blacks: blacks))
    }

    var bwMixerWeights: BwMixerChannelWeights? {
        let sf = AdjustmentFieldSpec.SubFields.BwMixer.self
        guard let object, Set(object.keys) == Set(sf.allowedChannels),
              let r = object["red"]?.number, let o = object["orange"]?.number, let y = object["yellow"]?.number,
              let g = object["green"]?.number, let a = object["aqua"]?.number, let b = object["blue"]?.number,
              let p = object["purple"]?.number, let m = object["magenta"]?.number else { return nil }
        let w = BwMixerChannelWeights(red: r, orange: o, yellow: y, green: g, aqua: a, blue: b, purple: p, magenta: m)
        return w.isValid ? w : nil
    }
}

public extension PointColorSettings {
    var transferValue: AdjustmentTransferValue {
        .object(["swatches": .array(swatches.map { s in
            .object([
                "src_hue": .number(s.srcHue), "src_saturation": .number(s.srcSaturation), "src_luminance": .number(s.srcLuminance),
                "hue_shift": .number(s.hueShift), "saturation_shift": .number(s.saturationShift), "luminance_shift": .number(s.luminanceShift),
                "range": .number(s.range), "hue_range": .number(s.hueRange), "sat_range": .number(s.satRange),
                "lum_range": .number(s.lumRange), "variance": .number(s.variance), "enabled": .boolean(s.enabled)
            ])
        })])
    }
}

public extension SelectiveColorSettings {
    var transferValue: AdjustmentTransferValue {
        .object([
            "method": .string(method.rawValue),
            "bands": .object(Dictionary(uniqueKeysWithValues: bands.allBands.map { name, band in
                (name, .object(["cyan": .number(band.cyan), "magenta": .number(band.magenta),
                                "yellow": .number(band.yellow), "black": .number(band.black)]))
            }))
        ])
    }
}

public extension BwMixerChannelWeights {
    var transferValue: AdjustmentTransferValue {
        .object(Dictionary(uniqueKeysWithValues: allChannels.map { ($0.0, .number($0.1)) }))
    }
}

// 曲线和色轮在完整复制时保留逻辑值；部分复制只转换一次实际效果。
public enum AdjustmentTransferRefinement {
    public typealias Value = AdjustmentTransferValue
    public typealias Field = AdjustmentTransferField

    public static func values(curve: ToneCurveSettings, grading: ColorGradingSettings) -> [Field: Value] {
        var result: [Field: Value] = [.curve: curve.transferValue, .curveParametric: curve.parametric.transferValue,
                                      .gradingGlobal: grading.global.transferValue]
        for field in Field.refinementObjects { if let zone = field.gradingZone { result[field] = grading[zone].transferValue } }
        return result
    }

    public static func applying(_ payload: AdjustmentTransferPayload, original: [Field: Value],
                                previousScale: Double, targetScale: Double, fullRecipe: Bool) throws -> [Field: Value] {
        var result = original
        for field in Array(Field.refinementObjects) + [.curveParametric, .gradingGlobal] {
            guard let originalValue = original[field] ?? (field == .curveParametric ? ToneCurveParametric().transferValue : field == .gradingGlobal ? ColorGradingWheel().transferValue : nil) else { continue }
            let expected = try payload[field].map { try scaled($0, field: field, by: payload.source.recipe?.refinementScale ?? 1) } ?? scaled(originalValue, field: field, by: previousScale)
            let preferred = fullRecipe ? payload[field] ?? originalValue : originalValue
            let value = try logical(expected, field: field, strength: targetScale, preserving: preferred)
            guard equivalent(try scaled(value, field: field, by: targetScale), expected, field: field) else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            result[field] = value
        }
        return result
    }

    public static func scaled(_ value: Value, field: Field, by strength: Double) throws -> Value {
        if field == .curve, let curve = value.curve { return curve.scaled(by: strength).transferValue }
        if field == .curveParametric, let parametric = value.parametricCurve { return parametric.scaled(by: strength).transferValue }
        guard (field.gradingZone != nil || field == .gradingGlobal), let wheel = value.gradingWheel else { throw AdjustmentTransferError.invalidPayload(field.rawValue) }
        return ColorGradingWheel(hue: wheel.hue, saturation: min(100, max(0, wheel.saturation * strength)), luminance: min(100, max(-100, wheel.luminance * strength))).transferValue
    }

    public static func logical(_ effective: Value, field: Field, strength: Double, preserving current: Value) throws -> Value {
        if equivalent(try scaled(current, field: field, by: strength), effective, field: field) { return current }
        let result: Value
        if field == .curve, let curve = effective.curve {
            if curve.isDefault || strength == 0 && curve.isIdentity { return effective }
            guard strength != 0 else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            var inverse = curve
            for channel in ToneCurveChannel.allCases {
                let shape = curve.shape(channel)
                if shape.mode == .custom {
                    let last = shape.points.count - 1
                    let inverted = shape.points.enumerated().map { idx, pt in
                        let clamp01 = { (v: Double) in min(1, max(0, v)) }
                        if idx == 0 { return ToneCurvePoint(x: clamp01(pt.x / strength), y: clamp01(pt.y / strength)) }
                        if idx == last { return ToneCurvePoint(x: clamp01(1 + (pt.x - 1) / strength), y: clamp01(1 + (pt.y - 1) / strength)) }
                        return ToneCurvePoint(x: pt.x, y: clamp01(pt.x + (pt.y - pt.x) / strength))
                    }
                    inverse = inverse.replacing(channel, with: .init(mode: .custom, points: inverted))
                }
            }
            guard inverse.isValid else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            result = inverse.transferValue
        } else if field == .curveParametric, let p = effective.parametricCurve {
            if p.isIdentity { return effective }
            guard strength != 0 else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            let clampBand = { (v: Double) in min(100, max(-100, v)) }
            let inverse = ToneCurveParametric(highlights: clampBand(p.highlights / strength), lights: clampBand(p.lights / strength),
                                              darks: clampBand(p.darks / strength), shadows: clampBand(p.shadows / strength),
                                              splitShadow: p.splitShadow, splitMidtone: p.splitMidtone, splitHighlight: p.splitHighlight)
            guard inverse.isValid else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            result = inverse.transferValue
        } else if (field.gradingZone != nil || field == .gradingGlobal), let wheel = effective.gradingWheel {
            guard strength != 0 || (wheel.saturation == 0 && wheel.luminance == 0) else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            let sat = strength == 0 ? 0 : min(100, max(0, wheel.saturation / strength))
            let lum = strength == 0 ? 0 : min(100, max(-100, wheel.luminance / strength))
            let inverse = ColorGradingWheel(hue: wheel.hue, saturation: sat, luminance: lum)
            guard inverse.isValid else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            result = inverse.transferValue
        } else { throw AdjustmentTransferError.invalidPayload(field.rawValue) }
        guard equivalent(try scaled(result, field: field, by: strength), effective, field: field) else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
        return result
    }

    public static func equivalent(_ a: Value, _ b: Value, field: Field) -> Bool {
        if field == .curve, let first = a.curve, let second = b.curve {
            return ToneCurveChannel.allCases.allSatisfy { channel in
                let a = first.shape(channel), b = second.shape(channel)
                guard a.mode == b.mode else { return false }
                if a.isIdentity && b.isIdentity { return true }
                return a.points.count == b.points.count && zip(a.points, b.points).allSatisfy { abs($0.x - $1.x) <= 1e-12 && abs($0.y - $1.y) <= 1e-12 }
            }
        }
        if field == .curveParametric, let first = a.parametricCurve, let second = b.parametricCurve {
            return first.splitShadow == second.splitShadow && first.splitMidtone == second.splitMidtone && first.splitHighlight == second.splitHighlight &&
                [abs(first.highlights - second.highlights), abs(first.lights - second.lights), abs(first.darks - second.darks), abs(first.shadows - second.shadows)].allSatisfy { $0 <= 1e-12 }
        }
        guard let first = a.gradingWheel, let second = b.gradingWheel else { return false }
        return first.hue == second.hue && Float(first.saturation) == Float(second.saturation) && Float(first.luminance) == Float(second.luminance)
    }
}

public struct AdjustmentRecipeContext: Codable, Equatable {
    public let id: String; public let strength: Double; public let settingsVersion: Int
    public var refinementScale: Double { settingsVersion >= 4 ? strength : 1 }
    enum CodingKeys: String, CodingKey { case id, strength; case settingsVersion = "settings_version" }
    public init(id: String, strength: Double, settingsVersion: Int) { self.id = id; self.strength = strength; self.settingsVersion = settingsVersion }
    public init(from decoder: Decoder) throws {
        try TransferCodingKey.rejectUnknown(decoder, allowed: ["id", "strength", "settings_version"])
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decode(String.self, forKey: .id); strength = try v.decode(Double.self, forKey: .strength); settingsVersion = try v.decode(Int.self, forKey: .settingsVersion)
    }
}

public struct AdjustmentTransferSource: Codable, Equatable {
    public let identifier: String; public let isRaw: Bool; public let processingVersion: Int; public let recipe: AdjustmentRecipeContext?; public let hdrProcessingVersion: Int?
    public var isHDR: Bool { hdrProcessingVersion != nil }
    enum CodingKeys: String, CodingKey { case identifier, recipe; case isRaw = "is_raw", processingVersion = "processing_version", hdrProcessingVersion = "hdr_processing_version" }
    public init(identifier: String, isRaw: Bool, processingVersion: Int, recipe: AdjustmentRecipeContext?, hdrProcessingVersion: Int? = nil) {
        self.identifier = identifier; self.isRaw = isRaw; self.processingVersion = processingVersion; self.recipe = recipe; self.hdrProcessingVersion = hdrProcessingVersion
    }
    public init(from decoder: Decoder) throws {
        try TransferCodingKey.rejectUnknown(decoder, allowed: ["identifier", "is_raw", "processing_version", "recipe", "hdr_processing_version"])
        let v = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try v.decode(String.self, forKey: .identifier); isRaw = try v.decode(Bool.self, forKey: .isRaw)
        processingVersion = try v.decode(Int.self, forKey: .processingVersion); recipe = try v.decodeIfPresent(AdjustmentRecipeContext.self, forKey: .recipe)
        hdrProcessingVersion = v.contains(.hdrProcessingVersion) ? try v.decode(Int.self, forKey: .hdrProcessingVersion) : nil
    }
}

public struct AdjustmentTransferPayload: Codable, Equatable {
    public let payloadVersion: Int; public let scopeVersion: Int; public let source: AdjustmentTransferSource; public let values: [String: AdjustmentTransferValue]
    public var fields: Set<AdjustmentTransferField> { Set(values.keys.compactMap(AdjustmentTransferField.init(rawValue:))) }
    public subscript(_ field: AdjustmentTransferField) -> AdjustmentTransferValue? { values[field.rawValue] }
    enum CodingKeys: String, CodingKey { case payloadVersion = "payload_version", scopeVersion = "scope_version", source, values }

    public init(source: AdjustmentTransferSource, values: [String: AdjustmentTransferValue]) throws {
        payloadVersion = source.isHDR ? 2 : 1; scopeVersion = payloadVersion; self.source = source; self.values = values; try validate()
    }
    public init(from decoder: Decoder) throws {
        try TransferCodingKey.rejectUnknown(decoder, allowed: ["payload_version", "scope_version", "source", "values"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        payloadVersion = try c.decode(Int.self, forKey: .payloadVersion); scopeVersion = try c.decode(Int.self, forKey: .scopeVersion)
        source = try c.decode(AdjustmentTransferSource.self, forKey: .source); values = try c.decode([String: AdjustmentTransferValue].self, forKey: .values); try validate()
    }

    public func validate() throws {
        guard (payloadVersion == 1 && scopeVersion == 1 && !source.isHDR) ||
            (payloadVersion == 2 && scopeVersion == 2 && source.isHDR) else { throw AdjustmentTransferError.unsupportedVersion }
        if source.isHDR {
            guard let version = source.hdrProcessingVersion, (1...10).contains(version) else {
                throw AdjustmentTransferError.unsupportedVersion
            }
            let supported = AdjustmentTransferField.hdrSupported(version: version).union([.hdrCameraDevelopment])
            guard !source.isRaw, source.recipe == nil, fields.isSubset(of: supported) else {
                throw AdjustmentTransferError.invalidPayload("hdr context")
            }
        } else if fields.contains(where: \.isHDROnly) {
            throw AdjustmentTransferError.invalidPayload("hdr context")
        }
        guard !values.isEmpty else { throw AdjustmentTransferError.emptyScope }
        guard !source.identifier.isEmpty, [1, 2, 3].contains(source.processingVersion) else {
            throw AdjustmentTransferError.invalidPayload("source")
        }
        if let recipe = source.recipe {
            guard !recipe.id.isEmpty, recipe.strength.isFinite, (0...2).contains(recipe.strength),
                  [2, 3, 4].contains(recipe.settingsVersion) else { throw AdjustmentTransferError.invalidPayload("recipe") }
            if let strength = self[.strength]?.number, strength != recipe.strength {
                throw AdjustmentTransferError.invalidPayload("recipe.strength")
            }
        }
        for (id, value) in values {
            guard let field = AdjustmentTransferField(rawValue: id), Self.valid(value, for: field) else {
                throw AdjustmentTransferError.invalidPayload(id)
            }
        }
        if let look = self[.look]?.object, look["kind"]?.string == "recipe" {
            guard look["id"]?.string == source.recipe?.id else { throw AdjustmentTransferError.invalidPayload("recipe.look") }
        }
        try validateWhiteBalance()
        if !source.isRaw {
            guard self[.exposureMode] == nil || self[.exposureMode] == .string("sensor"),
                  self[.rawDenoise] == nil || self[.rawDenoise] == .number(0),
                  source.isHDR || self[.postRGBDenoise] == nil || self[.postRGBDenoise] == .number(0) else {
                throw AdjustmentTransferError.invalidPayload("raster request")
            }
        }
    }

    private func validateWhiteBalance() throws {
        let mode = self[.whiteBalanceMode]?.string
        if let mode, source.isRaw ? (mode == "none" || mode == "relative") : (mode != "none" && mode != "relative") {
            throw AdjustmentTransferError.invalidPayload("white_balance.mode")
        }
        if !source.isRaw {
            if mode == "relative" {
                if self[.temperature] == .null || self[.tint] == .null {
                    throw AdjustmentTransferError.invalidPayload("white_balance values conflict with mode")
                }
            } else if self[.temperature]?.number != nil || source.recipe == nil && self[.tint]?.number != nil {
                throw AdjustmentTransferError.invalidPayload("raster.white_balance")
            }
        }
        if source.recipe != nil && self[.tint] == .null {
            throw AdjustmentTransferError.invalidPayload("recipe.white_balance.tint")
        }
        if mode == "camera" && (self[.temperature]?.number != nil || source.recipe == nil && self[.tint]?.number != nil)
            || mode == "temperature" && (self[.temperature] == .null || self[.tint] == .null) {
            throw AdjustmentTransferError.invalidPayload("white_balance values conflict with mode")
        }
    }

    private static func valid(_ value: AdjustmentTransferValue, for field: AdjustmentTransferField) -> Bool {
        let proto = field.spec.protocolSpec
        if value == .null { return proto.nullable }
        if field == .curve { return value.curve != nil }
        if field == .curveParametric { return value.parametricCurve != nil }
        if field.gradingZone != nil || field == .gradingGlobal { return value.gradingWheel != nil }
        switch field {
        case .hdrLook: return value.hdrLookSettings != nil
        case .hdrCameraDevelopment: return value.hdrCameraDevelopment != nil
        case .pointColor: return value.pointColorSettings != nil
        case .selectiveColor: return value.selectiveColorSettings != nil
        case .bwMixer: return value.bwMixerWeights != nil
        case .look:
            guard let object = value.object, Set(object.keys) == Set(proto.objectKeys),
                  let kind = object["kind"]?.string, AdjustmentFieldSpec.SubFields.LookReference.allowedKinds.contains(kind) else { return false }
            if kind == AdjustmentFieldSpec.SubFields.LookReference.idNullableWhenKind { return object["id"] == .null }
            guard let id = object["id"]?.string, !id.isEmpty, !id.contains("/"), !id.contains("\\"), id != ".", id != ".." else { return false }
            return true
        case .waveletDenoise: return validWavelet(value)
        default: break
        }
        switch proto.valueType {
        case .boolean: return value.boolean != nil
        case .string:
            guard let text = value.string, !proto.nonEmpty || !text.isEmpty else { return false }
            return proto.allowedStringValues.isEmpty || proto.allowedStringValues.contains(text)
        case .integer:
            guard let number = value.number, number.isFinite, number.rounded() == number else { return false }
            return (proto.closedRange?.contains(number) ?? true) && (proto.allowedIntValues.isEmpty || proto.allowedIntValues.contains(Int(number)))
        case .number:
            guard let number = value.number, number.isFinite else { return false }
            return (proto.min.map { proto.exclusiveMin ? number > $0 : number >= $0 } ?? true) && (proto.max.map { number <= $0 } ?? true)
        case .object: return false
        }
    }

    private static func validWavelet(_ value: AdjustmentTransferValue) -> Bool {
        let proto = AdjustmentFieldSpec.Fields.detailDenoiseWavelet.protocolSpec
        if value == .null { return proto.nullable }
        guard let wavelet = value.object, Set(wavelet.keys) == Set(proto.objectKeys), wavelet["enabled"]?.boolean != nil,
              AdjustmentFieldSpec.SubFields.WaveletDenoise.allowedPresets.contains(wavelet["preset"]?.string ?? "") else { return false }
        let sub = AdjustmentFieldSpec.SubFields.WaveletDenoise.self
        return [("luma", sub.lumaRange), ("chroma", sub.chromaRange), ("coarse", sub.coarseRange)].allSatisfy { k, r in
            wavelet[k]?.number.map { $0.isFinite && r.contains($0) } == true
        }
    }

    public func encodeTransferJSONData(prettyPrinted: Bool = true) throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }
    public static func decodeTransferJSON(_ data: Data) throws -> AdjustmentTransferPayload { try JSONDecoder().decode(AdjustmentTransferPayload.self, from: data) }
}

private struct TransferCodingKey: CodingKey {
    let stringValue: String; var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { nil }
    static func rejectUnknown(_ decoder: Decoder, allowed: Set<String>) throws {
        guard try decoder.container(keyedBy: Self.self).allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw AdjustmentTransferError.invalidPayload("unknown field")
        }
    }
}

public struct AdjustmentTransferContext {
    public var identifier: String, isRaw: Bool
    public var sourceIsHDR = false, sourceSupportsCameraHDR = false, sourceIsBayerHDR = false
    public var availableLookIDs: Set<String> = [], builtinLookIDs: [String: String] = [:]
    public var cameraTemperature: Double? = nil, cameraTint: Double? = nil, defaultExposureMode = ExposureMode.preview, hasUncommittedDraft = false
    public var validateLensRequest: ((LensCorrectionSettings) throws -> Void)? = nil, validateHDRCameraRequest: ((Adjustments) throws -> Void)? = nil
    public var transferNotices: ((AdjustmentTransferNotice) -> Void)? = nil
    public var storesLookOnSettings: Bool, supportsAIDenoise: Bool, supportsRawDenoise: Bool, rejectsNonNeutralLensOnRaster: Bool, usesAsShotWhiteBalanceFromSettings: Bool
    public var neutralFilmID: String?

    public init(identifier: String, isRaw: Bool, sourceIsHDR: Bool = false, sourceSupportsCameraHDR: Bool = false, sourceIsBayerHDR: Bool = false,
                availableLookIDs: Set<String> = [], builtinLookIDs: [String: String] = [:], cameraTemperature: Double? = nil, cameraTint: Double? = nil,
                defaultExposureMode: ExposureMode = .preview, hasUncommittedDraft: Bool = false, validateLensRequest: ((LensCorrectionSettings) throws -> Void)? = nil,
                validateHDRCameraRequest: ((Adjustments) throws -> Void)? = nil, transferNotices: ((AdjustmentTransferNotice) -> Void)? = nil,
                storesLookOnSettings: Bool = false, supportsAIDenoise: Bool = true, supportsRawDenoise: Bool = true, rejectsNonNeutralLensOnRaster: Bool = true,
                usesAsShotWhiteBalanceFromSettings: Bool = true, neutralFilmID: String? = "") {
        self.identifier = identifier; self.isRaw = isRaw; self.sourceIsHDR = sourceIsHDR; self.sourceSupportsCameraHDR = sourceSupportsCameraHDR
        self.sourceIsBayerHDR = sourceIsBayerHDR; self.availableLookIDs = availableLookIDs; self.builtinLookIDs = builtinLookIDs
        self.cameraTemperature = cameraTemperature; self.cameraTint = cameraTint; self.defaultExposureMode = defaultExposureMode
        self.hasUncommittedDraft = hasUncommittedDraft; self.validateLensRequest = validateLensRequest; self.validateHDRCameraRequest = validateHDRCameraRequest
        self.transferNotices = transferNotices; self.storesLookOnSettings = storesLookOnSettings; self.supportsAIDenoise = supportsAIDenoise
        self.supportsRawDenoise = supportsRawDenoise; self.rejectsNonNeutralLensOnRaster = rejectsNonNeutralLensOnRaster
        self.usesAsShotWhiteBalanceFromSettings = usesAsShotWhiteBalanceFromSettings; self.neutralFilmID = neutralFilmID
    }
    public func withIOSCapabilities() -> Self {
        var c = self; c.storesLookOnSettings = true; c.supportsAIDenoise = false; c.supportsRawDenoise = false
        c.rejectsNonNeutralLensOnRaster = false; c.usesAsShotWhiteBalanceFromSettings = false; c.neutralFilmID = nil; return c
    }
    public func withMacCapabilities() -> Self {
        var c = self; c.storesLookOnSettings = false; c.supportsAIDenoise = true; c.supportsRawDenoise = true
        c.rejectsNonNeutralLensOnRaster = true; c.usesAsShotWhiteBalanceFromSettings = true; c.neutralFilmID = c.neutralFilmID ?? ""; return c
    }
}

public typealias IOSAdjustmentTransferContext = AdjustmentTransferContext
public typealias MacAdjustmentTransferContext = AdjustmentTransferContext

public enum AdjustmentTransfer {
    public typealias Field = AdjustmentTransferField
    public typealias Value = AdjustmentTransferValue

    public struct ResolvedWB: Equatable {
        public let camera: Bool; public let temperature: Double; public let tint: Double
        public init(camera: Bool, temperature: Double, tint: Double) { self.camera = camera; self.temperature = temperature; self.tint = tint }
        public static func == (l: Self, r: Self) -> Bool { l.camera == r.camera && Float(l.temperature) == Float(r.temperature) && Float(l.tint) == Float(r.tint) }
    }

    public static func previewCapture(scope: AdjustmentTransferScope, snapshot: PhotoEditState,
                                      committed: PhotoEditState?, context: AdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        if context.storesLookOnSettings {
            guard let committed, snapshot.hasSameAdjustments(as: committed) else { throw AdjustmentTransferError.draftRequiresPreflight }
            return try capture(scope: scope, snapshot: committed, context: context)
        }
        var defaults = Adjustments(); defaults.exposureMode = context.isRaw ? context.defaultExposureMode : .sensor
        if context.sourceIsHDR { defaults.hdr = HDRSettings() }
        let saved = committed ?? PhotoEditState(settings: defaults, filmID: context.neutralFilmID)
        guard snapshot.settings.hdr == saved.settings.hdr, snapshot.settings.processing == saved.settings.processing,
              snapshot.settings.aiDenoiseEnabled == saved.settings.aiDenoiseEnabled,
              snapshot.settings.recipeSettingsVersion == saved.settings.recipeSettingsVersion,
              snapshot.settings.waveletNoiseReduction == saved.settings.waveletNoiseReduction,
              snapshot.settings.chromaNoiseReduction == saved.settings.chromaNoiseReduction,
              values(snapshot, context: context) == values(saved, context: context) else { throw AdjustmentTransferError.draftRequiresPreflight }
        return try capture(scope: scope, snapshot: saved, context: context)
    }

    public static func capture(scope: AdjustmentTransferScope, snapshot: PhotoEditState,
                               context: AdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        guard !context.hasUncommittedDraft else { throw AdjustmentTransferError.draftRequiresPreflight }
        if snapshot.settings.isHDREditing {
            guard supportsHDRTransfer(context) else { throw AdjustmentTransferError.incompatible("hdr.source") }
            return try HDRAdjustmentTransfer.capture(settings: snapshot.settings.hdr!, identifier: context.identifier,
                processingVersion: snapshot.settings.processing.version, scope: scope, cameraRAW: context.sourceIsBayerHDR)
        }
        if context.supportsAIDenoise && snapshot.settings.aiDenoiseEnabled {
            if case .custom = scope {} else { throw AdjustmentTransferError.incompatible("ai.copy_scope") }
        }
        try validate(snapshot.settings)
        if !context.storesLookOnSettings {
            guard snapshot.masterRecipeID == snapshot.settings.masterRecipeID else { throw AdjustmentTransferError.invalidPayload("recipe identity") }
        }
        var defaults = Adjustments(); defaults.exposureMode = context.isRaw ? context.defaultExposureMode : .sensor
        let original = values(snapshot, context: context), neutral = values(PhotoEditState(settings: defaults, filmID: context.neutralFilmID), context: context)
        let selected: Set<Field>
        switch scope {
        case .all: selected = Field.legacyFields
        case .custom(let fields): selected = fields
        case .modified: selected = Set(Field.common.filter { original[$0.rawValue] != neutral[$0.rawValue] })
        }
        let s = snapshot.settings
        let recipe = s.masterRecipeID.map { AdjustmentRecipeContext(id: $0, strength: s.recipeScale, settingsVersion: s.recipeSettingsVersion) }
        return try AdjustmentTransferPayload(source: .init(identifier: context.identifier, isRaw: context.isRaw,
                                                           processingVersion: s.processing.version, recipe: recipe),
                                             values: original.filter { selected.contains(Field(rawValue: $0.key)!) })
    }

    public static func prepare(payload: AdjustmentTransferPayload, target: PhotoEditState,
                               context: AdjustmentTransferContext) throws -> PhotoEditState {
        guard !context.hasUncommittedDraft else { throw AdjustmentTransferError.draftRequiresPreflight }
        try payload.validate()
        if target.settings.isHDREditing {
            guard supportsHDRTransfer(context) else { throw AdjustmentTransferError.incompatible("hdr.source") }
            var result = target
            let hdr = try HDRAdjustmentTransfer.prepare(payload: payload, target: target.settings.hdr!, cameraRAW: context.sourceIsBayerHDR)
            guard hdr.lookSettings.assetIsAvailable() else { throw AdjustmentTransferError.missingLook(hdr.lookSettings.name ?? "HDR LUT") }
            result.settings.hdr = hdr
            if payload.fields.contains(.hdrCameraDevelopment) {
                guard let validateHDR = context.validateHDRCameraRequest else { throw AdjustmentTransferError.incompatible("hdr.camera_development") }
                if !context.storesLookOnSettings {
                    if hdr.cameraDevelopmentSettings.fbddLevel != 0 { result.settings.hdrCameraAIEnabled = false }
                    var dev = result.settings; dev.hdrCameraAIEnabled = false; try validateHDR(dev)
                } else { try validateHDR(result.settings) }
            }
            return result
        }
        if payload.source.isHDR { return try prepare(payload: HDRAdjustmentTransfer.legacyPayload(payload), target: target, context: context) }
        if payload.source.processingVersion != target.settings.processing.version { context.transferNotices?(.retainedTargetProcessingVersion) }
        try validate(target.settings)
        if !context.storesLookOnSettings {
            guard target.masterRecipeID == target.settings.masterRecipeID else { throw AdjustmentTransferError.invalidPayload("target recipe identity") }
        }
        var resultSettings = target.settings, filmID = target.filmID, masterRecipeID = target.masterRecipeID
        let selected = payload.fields, before = effectiveNumbers(target.settings, context: context)
        var fullRecipe = false
        if let look = payload[.look]?.object {
            let kind = look["kind"]!.string!, id = look["id"]!.string
            let lookup = kind == "recipe_lut" ? "recipe:\(id!)" : kind == "managed" ? id! : "\(kind):\(id ?? "")"
            guard kind == "neutral" || context.availableLookIDs.contains(lookup) else { throw AdjustmentTransferError.missingLook(lookup) }
            fullRecipe = kind == "recipe" && Field.recipeDependencies(version: payload.source.recipe?.settingsVersion ?? 3).isSubset(of: selected)
            if fullRecipe {
                guard let recipe = payload.source.recipe, MasterRecipe.recipe(for: recipe.id) != nil else { throw AdjustmentTransferError.missingLook(lookup) }
                resultSettings.setTransferRecipe(recipe.id, settingsVersion: recipe.settingsVersion)
                resultSettings.lutID = nil; masterRecipeID = recipe.id; filmID = context.neutralFilmID
            } else {
                resultSettings.setTransferRecipe(nil); masterRecipeID = nil
                if context.storesLookOnSettings {
                    switch kind {
                    case "neutral": resultSettings.lutID = nil
                    case "recipe", "recipe_lut": resultSettings.lutID = "recipe-lut:\(id!)"
                    case "managed": resultSettings.lutID = id!
                    default:
                        guard let native = context.builtinLookIDs[id!] else { throw AdjustmentTransferError.missingLook(lookup) }
                        resultSettings.lutID = native
                    }
                    filmID = resultSettings.lutID
                } else {
                    filmID = kind == "neutral" ? (context.neutralFilmID ?? "") : kind == "managed" ? id! : (kind == "recipe" || kind == "recipe_lut") ? "recipe-lut:\(id!)" : "builtin:\(id!)"
                }
            }
        }
        if let strength = payload[.strength]?.number { resultSettings.strength = strength }
        let contextChanged = resultSettings.masterRecipeID != target.settings.masterRecipeID
            || resultSettings.recipeSettingsVersion != target.settings.recipeSettingsVersion
            || resultSettings.recipeScale != target.settings.recipeScale

        for (field, key) in scalarKeys {
            if let value = payload[field]?.number {
                if fullRecipe { resultSettings[keyPath: key] = value }
                else { try assignEffective(sourceEffective(value, field: field, recipe: payload.source.recipe), field: field, to: &resultSettings, context: context) }
            } else if contextChanged && effectiveNumbers(resultSettings, context: context)[field] != before[field] {
                try assignEffective(before[field]!, field: field, to: &resultSettings, context: context)
            }
        }
        for field in Field.allCases where field.hslLocation != nil {
            if let value = payload[field]?.number {
                if fullRecipe { try assignHSL(value, field: field, to: &resultSettings) }
                else { try assignEffective(sourceEffective(value, field: field, recipe: payload.source.recipe), field: field, to: &resultSettings, context: context) }
            } else if contextChanged && effectiveNumbers(resultSettings, context: context)[field] != before[field] {
                try assignEffective(before[field]!, field: field, to: &resultSettings, context: context)
            }
        }
        if context.storesLookOnSettings {
            for field in before.keys where field != .strength {
                guard let value = payload[field]?.number else { continue }
                let expected = sourceEffective(value, field: field, recipe: payload.source.recipe)
                if Float(effectiveNumbers(resultSettings, context: context)[field]!) != Float(expected) {
                    try assignEffective(expected, field: field, to: &resultSettings, context: context)
                }
            }
        }
        try applyWhiteBalance(payload, target: target.settings, to: &resultSettings, context: context, fullRecipe: fullRecipe, contextChanged: contextChanged)
        if let mode = payload[.exposureMode]?.string, payload.source.isRaw || !context.isRaw {
            resultSettings.exposureMode = !context.isRaw || mode == "sensor" ? .sensor : mode == "scene" ? .scene : .preview
        }
        for (field, key) in effectKeys where payload[field]?.number != nil && resultSettings.effectSettings[keyPath: key] != payload[field]!.number! {
            var effects = resultSettings.effectSettings; effects[keyPath: key] = payload[field]!.number!; resultSettings.photoEffects = effects.isDefault ? nil : effects
        }
        try applyObjects(payload, to: &resultSettings, context: context)
        let refinements = try AdjustmentTransferRefinement.applying(
            payload, original: AdjustmentTransferRefinement.values(curve: target.settings.curveSettings, grading: target.settings.gradingSettings),
            previousScale: target.settings.refinementScale, targetScale: resultSettings.refinementScale, fullRecipe: fullRecipe
        )
        if let c = refinements[.curve]?.curve { resultSettings.curveSettings.master = c.master; resultSettings.curveSettings.channels = c.channels }
        if let lum = payload[.curveApplyToLuminosity]?.boolean { resultSettings.curveSettings.applyToLuminosity = lum }
        if let p = refinements[.curveParametric]?.parametricCurve { resultSettings.curveSettings.parametric = p }
        for field in Field.refinementObjects { if let z = field.gradingZone, let w = refinements[field]?.gradingWheel { resultSettings.gradingSettings[z] = w } }
        if let g = refinements[.gradingGlobal]?.gradingWheel { resultSettings.gradingSettings.global = g }
        if let b = payload[.gradingBlending]?.number { resultSettings.gradingSettings.blending = b }
        if let bal = payload[.gradingBalance]?.number { resultSettings.gradingSettings.balance = bal }
        try validate(resultSettings)
        let actual = effectiveNumbers(resultSettings, context: context)
        for field in before.keys where field != .strength {
            let expected = payload[field]?.number.map { sourceEffective($0, field: field, recipe: payload.source.recipe) } ?? before[field]!
            guard Float(actual[field]!) == Float(expected) else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
        }
        var candidate = target.replacing(settings: resultSettings, preservingFilmID: filmID)
        candidate.masterRecipeID = masterRecipeID
        if values(candidate, context: context) == values(target, context: context)
            && resultSettings.recipeSettingsVersion == target.settings.recipeSettingsVersion
            && resultSettings.waveletNoiseReduction == target.settings.waveletNoiseReduction
            && resultSettings.chromaNoiseReduction == target.settings.chromaNoiseReduction { return target }
        return candidate
    }

    public static func validate(_ settings: Adjustments) throws {
        do { try settings.validateResetValues() } catch { throw AdjustmentTransferError.unrepresentable("native range") }
        if let id = settings.masterRecipeID, MasterRecipe.recipe(for: id) == nil { throw AdjustmentTransferError.missingLook("recipe:\(id)") }
    }
    private static func supportsHDRTransfer(_ context: AdjustmentTransferContext) -> Bool {
        (!context.isRaw && context.sourceIsHDR) || (context.isRaw && context.sourceSupportsCameraHDR)
    }
    public static func isRecipeScaled(_ field: Field, version: Int = 3) -> Bool {
        [.exposure, .contrast, .highlights, .shadows, .saturation].contains(field) || (version >= 4 && Field.refinementScalars.contains(field))
    }
    public static func sourceEffective(_ value: Double, field: Field, recipe: AdjustmentRecipeContext?) -> Double {
        let scale = recipe?.strength ?? 1
        if field.hslLocation != nil { return min(100, max(-100, value * ((recipe?.settingsVersion ?? 2) >= 3 ? scale : 1))) }
        if field == .contrast || field == .saturation { return 1 + (value - 1) * scale }
        if (recipe?.settingsVersion ?? 3) >= 4 && Field.refinementScalars.contains(field) {
            let limit = field == .sCurve ? 1.0 : 100.0; return min(limit, max(-limit, value * scale))
        }
        return isRecipeScaled(field) ? value * scale : value
    }
    public static func assignEffective(_ value: Double, field: Field, to settings: inout Adjustments,
                                       context: AdjustmentTransferContext? = nil) throws {
        let scale = settings.recipeScale
        let range = (context?.storesLookOnSettings == true ? field.spec.iosModel : field.spec.macosModel).closedRange
        if field.hslLocation != nil {
            let hslScale = settings.recipeSettingsVersion >= 3 ? scale : 1
            guard hslScale != 0 || value == 0 else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            let raw = hslScale == 0 ? 0 : value / hslScale
            if hslScale != 1, raw.isFinite, let range, !range.contains(raw) {
                var candidate = settings
                try assignHSL(min(range.upperBound, max(range.lowerBound, raw)), field: field, to: &candidate)
                if Float(effectiveNumbers(candidate, context: context)[field]!) == Float(value) {
                    settings = candidate; return
                }
            }
            try assignHSL(raw, field: field, to: &settings); return
        }
        let identity: Double = [.contrast, .saturation].contains(field) ? 1 : 0
        if isRecipeScaled(field, version: settings.recipeSettingsVersion) {
            guard scale != 0 || value == identity else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            let raw = scale == 0 ? identity : identity + (value - identity) / scale
            if scale != 1, raw.isFinite, let range, !range.contains(raw) {
                var candidate = settings
                candidate[keyPath: scalarKeys[field]!] = min(range.upperBound, max(range.lowerBound, raw))
                if Float(effectiveNumbers(candidate, context: context)[field]!) == Float(value) {
                    settings = candidate; return
                }
            }
            settings[keyPath: scalarKeys[field]!] = raw
        } else { settings[keyPath: scalarKeys[field]!] = value }
    }
    public static func assignHSL(_ value: Double, field: Field, to settings: inout Adjustments) throws {
        let loc = field.hslLocation!; var hsl = settings.hslSettings
        if hsl.value(HSLAxis(rawValue: loc.axis)!, channel: loc.channel) == value { return }
        guard hsl.setExact(HSLAxis(rawValue: loc.axis)!, channel: loc.channel, value: value) else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
        settings.hsl = hsl.isIdentity ? nil : hsl
    }

    public static let scalarKeys: [Field: WritableKeyPath<Adjustments, Double>] = [
        .strength: \.strength, .exposure: \.exposure, .contrast: \.contrast, .highlights: \.highlights,
        .shadows: \.shadows, .sCurve: \.toneCurve, .saturation: \.saturation, .sharpening: \.sharpening,
        .blackPoint: \.blackPoint, .whitePoint: \.whitePoint, .vibrance: \.vibrance,
        .clarity: \.clarity, .dehaze: \.dehaze, .texture: \.texture
    ]
    public static let calibrationKeys: [Field: WritableKeyPath<CameraCalibrationSettings, Double>] = [
        .calibrationShadowTint: \.shadowTint,
        .calibrationRedHue: \.redHue, .calibrationRedSaturation: \.redSaturation,
        .calibrationGreenHue: \.greenHue, .calibrationGreenSaturation: \.greenSaturation,
        .calibrationBlueHue: \.blueHue, .calibrationBlueSaturation: \.blueSaturation
    ]
    public static let filmOpticsKeys: [Field: WritableKeyPath<FilmOpticsSettings, Double>] = [
        .halationAmount: \.halationAmount, .halationThreshold: \.halationThreshold,
        .halationRadius: \.halationRadius, .halationHue: \.halationHue,
        .bloomAmount: \.bloomAmount, .bloomThreshold: \.bloomThreshold, .bloomRadius: \.bloomRadius
    ]
    public static let sharpenV2Keys: [Field: WritableKeyPath<SharpenV2Settings, Double>] = [
        .sharpeningRadius: \.radius, .sharpeningDetail: \.detail, .sharpeningMasking: \.masking
    ]
    public static let defringeKeys: [Field: WritableKeyPath<LensCorrectionSettings, Double>] = [
        .lensDefringePurpleAmount: \.defringePurpleAmount, .lensDefringePurpleHue: \.defringePurpleHue,
        .lensDefringeGreenAmount: \.defringeGreenAmount, .lensDefringeGreenHue: \.defringeGreenHue
    ]
    public static let effectKeys: [Field: WritableKeyPath<PhotoEffectsSettings, Double>] = [
        .vignetteAmount: \.vignetteAmount, .vignetteMidpoint: \.vignetteMidpoint, .vignetteRoundness: \.vignetteRoundness,
        .vignetteFeather: \.vignetteFeather, .vignetteHighlights: \.vignetteHighlights,
        .grainAmount: \.grainAmount, .grainSize: \.grainSize, .grainRoughness: \.grainRoughness
    ]
    public static let geometryKeys: [Field: WritableKeyPath<GeometrySettings, Double>] = [
        .cropX: \.cropX, .cropY: \.cropY, .cropWidth: \.cropWidth, .cropHeight: \.cropHeight,
        .straighten: \.straightenDegrees, .perspectiveHorizontal: \.perspectiveHorizontal, .perspectiveVertical: \.perspectiveVertical
    ]

    public static func effectiveNumbers(_ settings: Adjustments, context: AdjustmentTransferContext? = nil) -> [Field: Double] {
        if context?.usesAsShotWhiteBalanceFromSettings == false {
            let rendered = settings.renderedRecipe(cameraTemperature: 6500, cameraTint: 0)
            var result = scalarKeys.mapValues { Double(Float(rendered[keyPath: $0])) }
            for f in Field.allCases { if let loc = f.hslLocation { result[f] = rendered.hslSettings.value(HSLAxis(rawValue: loc.axis)!, channel: loc.channel) } }
            return result
        }
        let r = settings.resolvedRenderValues()
        var result: [Field: Double] = [
            .strength: settings.strength, .exposure: Double(r.exposureEV), .contrast: Double(r.contrast),
            .highlights: Double(r.highlights), .shadows: Double(r.shadows),
            .sCurve: Double(Float(min(1, max(-1, settings.toneCurve * settings.refinementScale)))),
            .saturation: Double(r.saturation), .sharpening: Double(r.sharpening),
            .blackPoint: settings.renderToneSettings.blackPoint, .whitePoint: settings.renderToneSettings.whitePoint,
            .vibrance: settings.renderToneSettings.vibrance,
            .clarity: settings.renderAtmosphereSettings.clarity,
            .dehaze: settings.renderAtmosphereSettings.dehaze,
            .texture: settings.renderAtmosphereSettings.texture
        ]
        for f in Field.allCases { if let loc = f.hslLocation { result[f] = settings.renderHSLSettings.value(HSLAxis(rawValue: loc.axis)!, channel: loc.channel) } }
        return result
    }

    public static func values(_ snapshot: PhotoEditState, context: AdjustmentTransferContext) -> [String: Value] {
        let s = snapshot.settings, isRaw = context.isRaw
        var result = [String: Value]()
        result[Field.curve.rawValue] = s.curveSettings.transferValue
        result[Field.curveApplyToLuminosity.rawValue] = .boolean(s.curveSettings.applyToLuminosity)
        result[Field.curveParametric.rawValue] = s.curveSettings.parametric.transferValue
        for (field, key) in scalarKeys { result[field.rawValue] = .number(s[keyPath: key]) }
        if context.storesLookOnSettings { result[Field.strength.rawValue] = .number(s.masterRecipeID != nil ? s.recipeScale : Double(s.clampedLUTStrength)) }
        let look: [String: Value]
        if let recipe = s.masterRecipeID { look = ["kind": .string("recipe"), "id": .string(recipe)] }
        else if context.storesLookOnSettings {
            if let id = s.lutID {
                if id.hasPrefix("recipe-lut:") { look = ["kind": .string("recipe_lut"), "id": .string(String(id.dropFirst(11)))] }
                else if let filename = context.builtinLookIDs.first(where: { $0.value == id })?.key { look = ["kind": .string("builtin"), "id": .string(filename)] }
                else { look = ["kind": .string("managed"), "id": .string(id)] }
            } else { look = ["kind": .string("neutral"), "id": .null] }
        } else {
            let filmID = snapshot.filmID ?? ""
            if filmID.isEmpty { look = ["kind": .string("neutral"), "id": .null] }
            else if filmID.hasPrefix("builtin:") { look = ["kind": .string("builtin"), "id": .string(String(filmID.dropFirst(8)))] }
            else if filmID.hasPrefix("recipe-lut:") { look = ["kind": .string("recipe_lut"), "id": .string(String(filmID.dropFirst(11)))] }
            else { look = ["kind": .string("managed"), "id": .string(filmID)] }
        }
        result[Field.look.rawValue] = .object(look)
        result[Field.exposureMode.rawValue] = .string(!isRaw ? "sensor" : s.exposureMode == .scene ? "scene" : s.exposureMode == .preview ? "preview" : "sensor")
        let camera = !isRaw || (context.usesAsShotWhiteBalanceFromSettings ? s.usesAsShotWhiteBalance : s.whiteBalanceMode == .camera), hasRecipe = s.masterRecipeID != nil
        let rasterRelative = !isRaw && !hasRecipe && (s.temperature != 6500 || s.tint != 0)
        result[Field.whiteBalanceMode.rawValue] = .string(!isRaw ? (rasterRelative ? "relative" : "none") : camera ? "camera" : "temperature")
        result[Field.temperature.rawValue] = rasterRelative ? .number(s.temperature) : ((!isRaw || camera) ? .null : .number(s.temperature))
        result[Field.tint.rawValue] = hasRecipe ? .number(s.tint) : rasterRelative ? .number(s.tint) : ((!isRaw || camera) ? .null : .number(s.tint))
        for f in Field.allCases {
            if let loc = f.hslLocation { result[f.rawValue] = .number(s.hslSettings.value(HSLAxis(rawValue: loc.axis)!, channel: loc.channel)) }
            if let zone = f.gradingZone { result[f.rawValue] = s.gradingSettings[zone].transferValue }
        }
        result[Field.gradingGlobal.rawValue] = s.gradingSettings.global.transferValue
        result[Field.gradingBlending.rawValue] = .number(s.gradingSettings.blending)
        result[Field.gradingBalance.rawValue] = .number(s.gradingSettings.balance)
        for (field, key) in calibrationKeys { result[field.rawValue] = .number(s.calibrationSettings[keyPath: key]) }
        result[Field.pointColor.rawValue] = s.pointColorSettings.transferValue
        result[Field.selectiveColor.rawValue] = s.selectiveColorSettings.transferValue
        result[Field.bwEnabled.rawValue] = .boolean(s.bwMixerSettings.enabled)
        result[Field.bwMixer.rawValue] = s.bwMixerSettings.mixer.transferValue
        for (field, key) in effectKeys { result[field.rawValue] = .number(s.effectSettings[keyPath: key]) }
        result[Field.grainToneCurve.rawValue] = .string(s.effectSettings.grainToneCurve.rawValue)
        result[Field.grainFormatPreset.rawValue] = .string(s.effectSettings.grainFormatPreset.rawValue)
        for (field, key) in filmOpticsKeys { result[field.rawValue] = .number(s.filmOpticsSettings[keyPath: key]) }
        for (field, key) in sharpenV2Keys { result[field.rawValue] = .number(s.sharpenV2Settings[keyPath: key]) }
        result[Field.sharpeningLuminanceV2.rawValue] = .boolean(s.sharpenV2Settings.luminanceV2)
        let w = s.waveletNoiseReduction
        result[Field.rawDenoise.rawValue] = .number(context.supportsRawDenoise && isRaw ? s.rawNoiseReduction : 0)
        result[Field.postRGBDenoise.rawValue] = .number(0)
        result[Field.chromaDenoise.rawValue] = .number(Double(s.chromaNoiseReduction))
        result[Field.waveletDenoise.rawValue] = .object(["enabled": .boolean(w.enabled), "luma": .number(w.luma), "chroma": .number(w.chroma), "coarse": .number(w.coarse), "preset": .string(w.preset.rawValue)])
        let g = s.geometrySettings
        result[Field.quarterTurns.rawValue] = .number(Double(g.quarterTurns))
        result[Field.flipHorizontal.rawValue] = .boolean(g.flipHorizontal); result[Field.flipVertical.rawValue] = .boolean(g.flipVertical)
        for (field, key) in geometryKeys { result[field.rawValue] = .number(g[keyPath: key]) }
        let lens = (!context.rejectsNonNeutralLensOnRaster || isRaw) ? s.lensSettings : LensCorrectionSettings()
        result[Field.lensDistortion.rawValue] = .boolean(lens.distortion); result[Field.lensTCA.rawValue] = .boolean(lens.tca)
        result[Field.lensVignetting.rawValue] = .boolean(lens.vignetting); result[Field.lensAutoCrop.rawValue] = .boolean(lens.autoCrop)
        result[Field.lensProfile.rawValue] = lens.mode == .automatic ? .null : .string(lens.coreProfileID)
        for (field, key) in defringeKeys { result[field.rawValue] = .number(s.lensSettings[keyPath: key]) }
        return result
    }

    public static func applyObjects(_ payload: AdjustmentTransferPayload, to settings: inout Adjustments, context: AdjustmentTransferContext) throws {
        if !payload.fields.isDisjoint(with: Set(calibrationKeys.keys)) {
            var cal = settings.calibrationSettings
            for (field, key) in calibrationKeys { if let v = payload[field]?.number { cal[keyPath: key] = v } }
            settings.calibrationSettings = cal
        }
        if let pc = payload[.pointColor]?.pointColorSettings { settings.pointColorSettings = pc }
        if let sc = payload[.selectiveColor]?.selectiveColorSettings { settings.selectiveColorSettings = sc }
        if payload[.bwEnabled] != nil || payload[.bwMixer] != nil {
            var bw = settings.bwMixerSettings
            if let b = payload[.bwEnabled]?.boolean { bw.enabled = b }
            if let m = payload[.bwMixer]?.bwMixerWeights { bw.mixer = m }
            settings.bwMixerSettings = bw
        }
        if let rawCurve = payload[.grainToneCurve]?.string, let curve = GrainToneCurve(rawValue: rawCurve) {
            var effects = settings.effectSettings; effects.grainToneCurve = curve
            settings.photoEffects = effects.isDefault ? nil : effects
        }
        if let rawPreset = payload[.grainFormatPreset]?.string, let preset = GrainFormatPreset(rawValue: rawPreset) {
            var effects = settings.effectSettings; effects.grainFormatPreset = preset
            settings.photoEffects = effects.isDefault ? nil : effects
        }
        if !payload.fields.isDisjoint(with: Set(filmOpticsKeys.keys)) {
            var optics = settings.filmOpticsSettings
            for (field, key) in filmOpticsKeys { if let v = payload[field]?.number { optics[keyPath: key] = v } }
            settings.filmOpticsSettings = optics
        }
        if payload[.sharpeningLuminanceV2] != nil || !payload.fields.isDisjoint(with: Set(sharpenV2Keys.keys)) {
            var sh = settings.sharpenV2Settings
            if let b = payload[.sharpeningLuminanceV2]?.boolean { sh.luminanceV2 = b }
            for (field, key) in sharpenV2Keys { if let v = payload[field]?.number { sh[keyPath: key] = v } }
            settings.sharpenV2Settings = sh
        }
        if !context.supportsRawDenoise {
            if (payload[.rawDenoise]?.number ?? 0) != 0 { context.transferNotices?(.ignoredRawDenoise) }
        } else if let raw = payload[.rawDenoise]?.number, payload.source.isRaw || !context.isRaw {
            if raw != 0 && (settings.aiDenoiseEnabled || !context.isRaw || !settings.supportsRawNoiseReduction) { context.transferNotices?(.ignoredRawDenoise) }
            else if !settings.aiDenoiseEnabled {
                settings.rawNoiseReduction = raw
                if raw != 0, !settings.waveletNoiseReduction.enabled { settings.waveletNoiseReduction = WaveletDenoiseSettings() }
            }
        }
        if (payload[.postRGBDenoise]?.number ?? 0) != 0 { context.transferNotices?(.ignoredPostRGBDenoise) }
        if let value = payload[.chromaDenoise] {
            let chroma = Int((value.number ?? 0).rounded())
            if context.supportsAIDenoise && settings.aiDenoiseEnabled { if chroma != 0 { context.transferNotices?(.ignoredTargetDenoise) } }
            else {
                settings.chromaNoiseReduction = chroma
                if context.supportsRawDenoise && chroma != 0, !settings.waveletNoiseReduction.enabled { settings.waveletNoiseReduction = WaveletDenoiseSettings() }
            }
        }
        if let value = payload[.waveletDenoise] {
            let decoded: WaveletDenoiseSettings
            if let w = value.object {
                let luma = w["luma"]!.number!, chroma = w["chroma"]!.number!, coarse = w["coarse"]!.number!, ps = w["preset"]!.string!
                if context.storesLookOnSettings {
                    guard WaveletDenoiseSettings.computedPreset(luma: luma, chroma: chroma, coarse: coarse).rawValue == ps else {
                        throw AdjustmentTransferError.unrepresentable("detail.denoise.wavelet.preset")
                    }
                }
                decoded = WaveletDenoiseSettings(enabled: w["enabled"]!.boolean!, luma: luma, chroma: chroma, coarse: coarse, preset: DenoisePreset(rawValue: ps)!)
            } else { decoded = WaveletDenoiseSettings() }
            if context.supportsAIDenoise && settings.aiDenoiseEnabled { if decoded != WaveletDenoiseSettings() { context.transferNotices?(.ignoredTargetDenoise) } }
            else { settings.waveletNoiseReduction = decoded }
        }
        if payload.fields.contains(where: { $0.group == "geometry" && !Field.lensFields.contains($0) }) {
            var g = settings.geometrySettings
            if let t = payload[.quarterTurns]?.number { g.quarterTurns = Int(t) }
            if let f = payload[.flipHorizontal]?.boolean { g.flipHorizontal = f }
            if let f = payload[.flipVertical]?.boolean { g.flipVertical = f }
            for (field, key) in geometryKeys { if let v = payload[field]?.number { g[keyPath: key] = v } }
            guard g.isValid else { throw AdjustmentTransferError.unrepresentable("geometry.crop") }
            if g != settings.geometrySettings { settings.setGeometrySettings(g) }
        }
        if !payload.fields.isDisjoint(with: Field.lensFields) {
            let neutral: [Field: Value] = [.lensDistortion: .boolean(false), .lensTCA: .boolean(false), .lensVignetting: .boolean(false), .lensAutoCrop: .boolean(true), .lensProfile: .null]
            let isNeutralLens = neutral.allSatisfy { payload[$0.key] == nil || payload[$0.key] == $0.value }
            if context.rejectsNonNeutralLensOnRaster && !context.isRaw { guard isNeutralLens else { throw AdjustmentTransferError.incompatible("geometry.lens") } }
            if payload.source.isRaw || !context.isRaw || !isNeutralLens {
                var lens = settings.lensSettings
                if let v = payload[.lensDistortion]?.boolean { lens.distortion = v }
                if let v = payload[.lensTCA]?.boolean { lens.tca = v }
                if let v = payload[.lensVignetting]?.boolean { lens.vignetting = v }
                if let v = payload[.lensAutoCrop]?.boolean { lens.autoCrop = v }
                if let v = payload[.lensProfile] {
                    lens.mode = v == .null ? .automatic : .manual
                    lens.profileID = v.string == "__rawlab_manual_selection_required__" ? nil : v.string
                }
                if lens.isEnabled && lens.mode == .manual && lens.profileID == nil { throw AdjustmentTransferError.unrepresentable(Field.lensProfile.rawValue) }
                if context.rejectsNonNeutralLensOnRaster { guard context.isRaw || !lens.isEnabled else { throw AdjustmentTransferError.incompatible("geometry.lens") } }
                if lens.isEnabled {
                    guard let validate = context.validateLensRequest else { throw AdjustmentTransferError.incompatible("target lens calibration unavailable") }
                    try validate(lens)
                }
                let e = settings.lensSettings
                if lens.distortion != e.distortion || lens.tca != e.tca || lens.vignetting != e.vignetting || lens.autoCrop != e.autoCrop || lens.mode != e.mode || (lens.mode == .manual && lens.profileID != e.profileID) {
                    settings.lensCorrection = lens == LensCorrectionSettings() ? nil : lens
                }
            }
        }
        if !payload.fields.isDisjoint(with: Set(defringeKeys.keys)) {
            var lens = settings.lensSettings
            for (field, key) in defringeKeys { if let v = payload[field]?.number { lens[keyPath: key] = v } }
            settings.lensCorrection = lens == LensCorrectionSettings() ? nil : lens
        }
    }

    public static func renderWB(_ settings: Adjustments, context: AdjustmentTransferContext) -> ResolvedWB {
        if context.usesAsShotWhiteBalanceFromSettings {
            let r = settings.resolvedRenderValues()
            return ResolvedWB(camera: !r.usesTemperatureWB, temperature: Double(r.temperature), tint: Double(r.tint))
        }
        let r = settings.renderedRecipe(cameraTemperature: context.cameraTemperature ?? 6500, cameraTint: context.cameraTint ?? 0)
        let camera = r.whiteBalanceMode == .camera
        return ResolvedWB(camera: camera, temperature: camera ? 6500 : Double(Float(r.temperature)), tint: camera ? 0 : Double(Float(r.tint)))
    }

    private static func targetCamera(_ target: Adjustments, context: AdjustmentTransferContext) throws -> WhiteBalance {
        if context.usesAsShotWhiteBalanceFromSettings {
            guard let camera = target.asShotWhiteBalance else { throw AdjustmentTransferError.incompatible("target camera white balance unavailable") }
            return camera
        }
        guard let t = context.cameraTemperature, let n = context.cameraTint, t.isFinite, n.isFinite,
              Adjustments.temperatureRange.contains(t), Adjustments.tintRange.contains(n) else {
            throw AdjustmentTransferError.incompatible("target camera white balance unavailable")
        }
        return WhiteBalance(temperature: t, tint: n)
    }

    private static func requireTargetCalibration(_ target: Adjustments, context: AdjustmentTransferContext) throws {
        let usesAsShot = context.usesAsShotWhiteBalanceFromSettings ? target.usesAsShotWhiteBalance : (target.whiteBalanceMode == .camera)
        if target.masterRecipeID != nil && (target.tint * target.recipeScale != 0 || !usesAsShot) { _ = try targetCamera(target, context: context) }
    }

    public static func applyWhiteBalance(_ payload: AdjustmentTransferPayload, target: Adjustments, to result: inout Adjustments,
                                         context: AdjustmentTransferContext, fullRecipe: Bool, contextChanged: Bool) throws {
        var selected = payload.fields.intersection(Field.whiteBalanceFields)
        if !payload.source.isRaw && context.isRaw && (payload.source.recipe == nil || !selected.contains(.tint)) { selected.removeAll() }
        if selected.isEmpty {
            if context.isRaw && contextChanged && renderWB(result, context: context) != renderWB(target, context: context) {
                try requireTargetCalibration(target, context: context)
                let desired = renderWB(target, context: context)
                try applyResolvedWB(desired, to: &result, target: target, context: context)
                let targetIsAsShot = context.usesAsShotWhiteBalanceFromSettings ? target.usesAsShotWhiteBalance : (target.whiteBalanceMode == .camera)
                if targetIsAsShot && result.masterRecipeID != nil {
                    var camera = result
                    camera.whiteBalanceMode = .camera
                    camera.temperature = target.temperature
                    if renderWB(camera, context: context) == desired { result = camera }
                }
            }
            return
        }
        if !context.isRaw && payload.source.isRaw {
            let neutral: [Field: Value] = [.whiteBalanceMode: .string("camera"), .temperature: .null, .tint: payload.source.recipe == nil ? .null : .number(0)]
            let recipeTint = payload.source.recipe.flatMap { MasterRecipe.recipe(for: $0.id)?.tintDelta }
            let defaultRecipeTint = fullRecipe && recipeTint != nil && payload[.tint]?.number == recipeTint
            guard neutral.allSatisfy({ payload[$0.key] == nil || payload[$0.key] == $0.value || ($0.key == .tint && defaultRecipeTint) }) else {
                throw AdjustmentTransferError.incompatible("color.white_balance")
            }
            if !fullRecipe { return }
        }
        let targetValues = values(PhotoEditState(settings: target, filmID: context.neutralFilmID ?? "", masterRecipeID: target.masterRecipeID), context: context)
        let targetRecipe = target.masterRecipeID.map { AdjustmentRecipeContext(id: $0, strength: target.recipeScale, settingsVersion: target.recipeSettingsVersion) }
        if !contextChanged && payload.source.isRaw == context.isRaw && payload.source.recipe == targetRecipe && selected.allSatisfy({ payload[$0] == targetValues[$0.rawValue] }) { return }
        if selected == Field.whiteBalanceFields {
            let mode = payload[.whiteBalanceMode]!.string!
            if !context.isRaw && !payload.source.isRaw {
                if mode == "relative", let temp = payload[.temperature]?.number, let tint = payload[.tint]?.number {
                    result.whiteBalanceMode = .camera; result.temperature = temp; result.tint = tint
                } else if context.usesAsShotWhiteBalanceFromSettings { result.resetWhiteBalance() }
                else { result.whiteBalanceMode = .camera; result.temperature = 6500; result.tint = 0 }
                return
            }
            let balance: [String: Value] = [
                "mode": .string(mode == "none" && payload.source.recipe != nil ? "camera" : mode),
                "temperature": payload[.temperature]!, "tint": .number(payload[.tint]?.number ?? 0),
                "tint_mode": .string(payload.source.recipe != nil || mode == "camera" ? "camera_offset" : "absolute")
            ]
            let desired = try resolvedWB(balance, recipe: payload.source.recipe, target: target, context: context)
            if fullRecipe {
                applyLogicalWB(balance, to: &result, context: context)
                if !context.usesAsShotWhiteBalanceFromSettings && context.isRaw && renderWB(result, context: context) != desired {
                    try applyResolvedWB(desired, to: &result, target: target, context: context)
                    if balance["mode"]!.string == "camera" { result.whiteBalanceMode = .camera }
                }
            } else if context.isRaw { try applyResolvedWB(desired, to: &result, target: target, context: context) }
            return
        }
        if !context.isRaw {
            guard !payload.source.isRaw else { return }
            if payload[.whiteBalanceMode]?.string == "none" {
                if payload[.temperature]?.number != nil || payload[.tint]?.number != nil { throw AdjustmentTransferError.incompatible("select white balance mode with temperature/tint") }
                if context.usesAsShotWhiteBalanceFromSettings { result.resetWhiteBalance() } else { result.whiteBalanceMode = .camera; result.temperature = 6500; result.tint = 0 }
                return
            }
            if let temp = payload[.temperature]?.number { result.whiteBalanceMode = .camera; result.temperature = temp }
            if let tint = payload[.tint]?.number { result.whiteBalanceMode = .camera; result.tint = tint }
            return
        }
        let selectedMode = payload[.whiteBalanceMode]?.string
        let targetIsAsShot = context.usesAsShotWhiteBalanceFromSettings ? target.usesAsShotWhiteBalance : (target.whiteBalanceMode == .camera)
        let cameraMode = selectedMode.map { $0 != "temperature" } ?? targetIsAsShot
        let temperature = payload[.temperature], tint = payload[.tint]
        if temperature != nil && (cameraMode ? temperature != .null : temperature?.number == nil) { throw AdjustmentTransferError.incompatible("select white balance mode with temperature") }
        if let tint, cameraMode ? tint.number != nil && payload.source.recipe == nil : tint == .null { throw AdjustmentTransferError.incompatible("select white balance mode with tint") }
        try requireTargetCalibration(target, context: context)
        let previous = renderWB(target, context: context), desired: ResolvedWB
        if cameraMode {
            let offset: Double
            if let tint { offset = (tint.number ?? 0) * (payload.source.recipe?.strength ?? 1) }
            else if target.masterRecipeID != nil { offset = target.tint * target.recipeScale }
            else if targetIsAsShot { offset = 0 }
            else { offset = previous.tint - (try targetCamera(target, context: context)).tint }
            if temperature == nil && !targetIsAsShot {
                guard Float(previous.temperature) == Float(try targetCamera(target, context: context).temperature) else { throw AdjustmentTransferError.unrepresentable("unselected white balance temperature") }
            }
            if offset == 0 { desired = ResolvedWB(camera: true, temperature: 6500, tint: 0) }
            else {
                let cam = try targetCamera(target, context: context), value = cam.tint + offset
                guard Adjustments.tintRange.contains(value) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
                desired = ResolvedWB(camera: false, temperature: cam.temperature, tint: value)
            }
            if result.masterRecipeID == nil && offset != 0 && selectedMode == nil && !contextChanged { throw AdjustmentTransferError.incompatible("select white balance mode with relative tint") }
            if result.masterRecipeID == nil && offset != 0 && selectedMode != nil && tint == nil { throw AdjustmentTransferError.unrepresentable("unselected white balance tint") }
        } else {
            let fixedT = try temperature?.number ?? (previous.camera ? targetCamera(target, context: context).temperature : previous.temperature)
            let fixedTint = try tint?.number.map { v in try payload.source.recipe.map { (try targetCamera(target, context: context)).tint + v * $0.strength } ?? v }
                ?? (previous.camera ? targetCamera(target, context: context).tint : previous.tint)
            guard Adjustments.tintRange.contains(fixedTint) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
            desired = ResolvedWB(camera: false, temperature: fixedT, tint: fixedTint)
        }
        try applyResolvedWB(desired, to: &result, target: target, context: context)
        if cameraMode && result.masterRecipeID != nil { result.whiteBalanceMode = .camera }
        if !contextChanged {
            if temperature == nil { result.temperature = target.temperature }
            if tint == nil { result.tint = target.tint }
            if selectedMode == nil { result.whiteBalanceMode = target.whiteBalanceMode }
        }
        guard renderWB(result, context: context) == desired else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
    }

    public static func resolvedWB(_ value: [String: Value], recipe: AdjustmentRecipeContext?,
                                  target: Adjustments, context: AdjustmentTransferContext) throws -> ResolvedWB {
        guard context.isRaw else { return ResolvedWB(camera: true, temperature: 6500, tint: 0) }
        let camera = value["mode"]!.string == "camera", offset = value["tint_mode"]!.string == "camera_offset"
        let tint = value["tint"]!.number! * (offset ? recipe?.strength ?? 1 : 1)
        if camera && tint == 0 { return ResolvedWB(camera: true, temperature: 6500, tint: 0) }
        let calibration = (camera || offset) ? try targetCamera(target, context: context) : nil
        let resolvedTint = offset ? calibration!.tint + tint : tint
        guard resolvedTint.isFinite, Adjustments.tintRange.contains(resolvedTint) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
        return ResolvedWB(camera: false, temperature: camera ? calibration!.temperature : value["temperature"]!.number!, tint: resolvedTint)
    }

    public static func applyResolvedWB(_ desired: ResolvedWB, to settings: inout Adjustments, target: Adjustments? = nil, context: AdjustmentTransferContext) throws {
        if desired.camera {
            if context.usesAsShotWhiteBalanceFromSettings { settings.resetWhiteBalance() }
            else { settings.whiteBalanceMode = .camera; settings.temperature = 6500; settings.tint = 0 }
            return
        }
        settings.whiteBalanceMode = .custom; settings.temperature = desired.temperature
        if settings.masterRecipeID != nil {
            let delta = desired.tint - (try targetCamera(target ?? settings, context: context)).tint, scale = settings.recipeScale
            guard scale != 0 || delta == 0 else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
            let raw = scale == 0 ? 0 : delta / scale
            settings.tint = raw
            if raw.isFinite, !Adjustments.tintRange.contains(raw) {
                var clamped = settings
                clamped.tint = min(Adjustments.tintRange.upperBound, max(Adjustments.tintRange.lowerBound, raw))
                if renderWB(clamped, context: context) == desired { settings = clamped }
            }
        } else { settings.tint = desired.tint }
        guard renderWB(settings, context: context) == desired else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
    }

    private static func applyLogicalWB(_ value: [String: Value], to settings: inout Adjustments, context: AdjustmentTransferContext) {
        if context.usesAsShotWhiteBalanceFromSettings {
            if value["mode"]!.string == "temperature" { settings.whiteBalanceMode = .custom; settings.temperature = value["temperature"]!.number! }
            else { settings.resetWhiteBalance() }
            settings.tint = value["tint"]!.number!
        } else {
            settings.whiteBalanceMode = value["mode"]!.string == "temperature" ? .custom : .camera
            settings.temperature = value["temperature"]!.number ?? 6500; settings.tint = value["tint"]!.number!
        }
    }
}

public enum IOSAdjustmentTransfer {
    public typealias Field = AdjustmentTransferField; public typealias Value = AdjustmentTransferValue; public typealias ResolvedWB = AdjustmentTransfer.ResolvedWB
    public static func previewCapture(scope: AdjustmentTransferScope, snapshot: PhotoEditState, committed: PhotoEditState, context: AdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        try AdjustmentTransfer.previewCapture(scope: scope, snapshot: snapshot, committed: committed, context: context.withIOSCapabilities())
    }
    public static func capture(scope: AdjustmentTransferScope, snapshot: PhotoEditState, context: AdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        try AdjustmentTransfer.capture(scope: scope, snapshot: snapshot, context: context.withIOSCapabilities())
    }
    public static func prepare(payload: AdjustmentTransferPayload, target: PhotoEditState, context: AdjustmentTransferContext) throws -> PhotoEditState {
        try AdjustmentTransfer.prepare(payload: payload, target: target, context: context.withIOSCapabilities())
    }
    public static func validate(_ settings: Adjustments) throws { try AdjustmentTransfer.validate(settings) }
    public static func values(_ settings: Adjustments, context: AdjustmentTransferContext) -> [String: Value] {
        AdjustmentTransfer.values(PhotoEditState(settings: settings), context: context.withIOSCapabilities())
    }
}

public enum MacAdjustmentTransfer {
    public typealias Field = AdjustmentTransferField; public typealias Value = AdjustmentTransferValue; public typealias ResolvedWB = AdjustmentTransfer.ResolvedWB
    public static func previewCapture(scope: AdjustmentTransferScope, snapshot: PhotoEditState, committed: PhotoEditState?, context: AdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        try AdjustmentTransfer.previewCapture(scope: scope, snapshot: snapshot, committed: committed, context: context.withMacCapabilities())
    }
    public static func capture(scope: AdjustmentTransferScope, snapshot: PhotoEditState, context: AdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        try AdjustmentTransfer.capture(scope: scope, snapshot: snapshot, context: context.withMacCapabilities())
    }
    public static func prepare(payload: AdjustmentTransferPayload, target: PhotoEditState, context: AdjustmentTransferContext) throws -> PhotoEditState {
        try AdjustmentTransfer.prepare(payload: payload, target: target, context: context.withMacCapabilities())
    }
    public static func values(_ snapshot: PhotoEditState, isRaw: Bool) -> [String: Value] {
        AdjustmentTransfer.values(snapshot, context: AdjustmentTransferContext(identifier: "", isRaw: isRaw).withMacCapabilities())
    }
    public static func sourceEffective(_ value: Double, field: Field, recipe: AdjustmentRecipeContext?) -> Double { AdjustmentTransfer.sourceEffective(value, field: field, recipe: recipe) }
    public static func assignEffective(_ value: Double, field: Field, to settings: inout Adjustments) throws { try AdjustmentTransfer.assignEffective(value, field: field, to: &settings) }
    public static func renderWB(_ settings: Adjustments) -> ResolvedWB { AdjustmentTransfer.renderWB(settings, context: AdjustmentTransferContext(identifier: "", isRaw: true).withMacCapabilities()) }
    public static func applyResolvedWB(_ desired: ResolvedWB, to settings: inout Adjustments) throws {
        try AdjustmentTransfer.applyResolvedWB(desired, to: &settings, context: AdjustmentTransferContext(identifier: "", isRaw: true).withMacCapabilities())
    }
}

public enum IOSAdjustmentPasteNoticeDisplay {
    public static func showsInSheet(notices: [String], hasPasteResults: Bool) -> Bool { !notices.isEmpty && hasPasteResults }
}
