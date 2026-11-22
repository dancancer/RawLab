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
    case vignetteAmount = "effects.vignette.amount", vignetteMidpoint = "effects.vignette.midpoint"
    case vignetteRoundness = "effects.vignette.roundness", vignetteFeather = "effects.vignette.feather"
    case vignetteHighlights = "effects.vignette.highlights", grainAmount = "effects.grain.amount"
    case clarity = "effects.clarity", dehaze = "effects.dehaze"
    case grainSize = "effects.grain.size", grainRoughness = "effects.grain.roughness"
    case sharpening = "detail.sharpening", rawDenoise = "detail.denoise.raw_level"
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

    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public var hdrLookSettings: HDRLookSettings? {
        if self == .null { return HDRLookSettings() }
        let expectedKeys = Set(AdjustmentFieldSpec.Fields.hdrLook.protocolSpec.objectKeys)
        guard let object, Set(object.keys) == expectedKeys,
              let sha256 = object["sha256"]?.string, let name = object["name"]?.string,
              let strength = object["strength"]?.number else { return nil }
        let value = HDRLookSettings(sha256: sha256, name: name, strength: strength)
        return value.isValid ? value : nil
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
        var value = HDRCameraDevelopmentSettings()
        value.whiteBalance = mode; value.temperature = temperature; value.tint = tint
        value.exposureReference = exposure; value.fbddLevel = Int(level)
        return value.isValid ? value : nil
    }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var boolean: Bool? { if case .boolean(let value) = self { return value }; return nil }
    public var object: [String: Self]? { if case .object(let value) = self { return value }; return nil }
    public var array: [Self]? { if case .array(let value) = self { return value }; return nil }
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
              let highlights = object["highlights"]?.number,
              let lights = object["lights"]?.number,
              let darks = object["darks"]?.number,
              let shadows = object["shadows"]?.number,
              let splitShadow = object["split_shadow"]?.number,
              let splitMidtone = object["split_midtone"]?.number,
              let splitHighlight = object["split_highlight"]?.number else { return nil }
        let value = ToneCurveParametric(
            highlights: highlights, lights: lights, darks: darks, shadows: shadows,
            splitShadow: splitShadow, splitMidtone: splitMidtone, splitHighlight: splitHighlight
        )
        return value.isValid ? value : nil
    }
    public var gradingWheel: ColorGradingWheel? {
        let proto = AdjustmentFieldSpec.Fields.colorGradingShadows.protocolSpec
        guard let wheel = object,
              Set(wheel.keys).isSuperset(of: proto.objectKeys),
              Set(wheel.keys).isSubset(of: Set(proto.objectKeys).union(proto.optionalKeys)),
              let hue = wheel["hue"]?.number, let saturation = wheel["saturation"]?.number else { return nil }
        let luminance: Double
        if let lumVal = wheel["luminance"] {
            guard let lum = lumVal.number else { return nil }
            luminance = lum
        } else {
            luminance = 0.0
        }
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
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .boolean(let bool): try value.encode(bool)
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .null: try value.encodeNil()
        }
    }
}

public extension ToneCurveShape {
    var transferValue: AdjustmentTransferValue {
        .object(["mode": .string(mode.rawValue), "points": .array(points.map { .array([.number($0.x), .number($0.y)]) })])
    }
}

public extension ToneCurveSettings {
    var transferValue: AdjustmentTransferValue {
        var value = master.transferValue.object!
        if hasChannelCurves {
            value["channels"] = .object(["red": channels.red.transferValue, "green": channels.green.transferValue, "blue": channels.blue.transferValue])
        }
        return .object(value)
    }
}

public extension ToneCurveParametric {
    var transferValue: AdjustmentTransferValue {
        .object([
            "highlights": .number(highlights),
            "lights": .number(lights),
            "darks": .number(darks),
            "shadows": .number(shadows),
            "split_shadow": .number(splitShadow),
            "split_midtone": .number(splitMidtone),
            "split_highlight": .number(splitHighlight),
        ])
    }
}

public extension ColorGradingWheel {
    var transferValue: AdjustmentTransferValue {
        var obj: [String: AdjustmentTransferValue] = ["hue": .number(hue), "saturation": .number(saturation)]
        if luminance != 0.0 { obj["luminance"] = .number(luminance) }
        return .object(obj)
    }
}

// 曲线和色轮在完整复制时保留逻辑值；部分复制只转换一次实际效果。
public enum AdjustmentTransferRefinement {
    public typealias Value = AdjustmentTransferValue
    public typealias Field = AdjustmentTransferField

    public static func values(curve: ToneCurveSettings, grading: ColorGradingSettings) -> [Field: Value] {
        var result: [Field: Value] = [.curve: curve.transferValue, .curveParametric: curve.parametric.transferValue]
        for field in Field.refinementObjects {
            if let zone = field.gradingZone { result[field] = grading[zone].transferValue }
        }
        return result
    }

    public static func applying(_ payload: AdjustmentTransferPayload, original: [Field: Value],
                                previousScale: Double, targetScale: Double, fullRecipe: Bool) throws -> [Field: Value] {
        var result = original
        let fields = Array(Field.refinementObjects) + [.curveParametric]
        for field in fields {
            let fallback = original[field] ?? (field == .curveParametric ? ToneCurveParametric().transferValue : nil)
            guard let originalValue = fallback else { continue }
            let expected = try payload[field].map {
                try scaled($0, field: field, by: payload.source.recipe?.refinementScale ?? 1)
            } ?? scaled(originalValue, field: field, by: previousScale)
            // 完整复制优先保留原逻辑值；移动端强度经过 Float 投影时仅反解必要的差值。
            let preferred = fullRecipe ? payload[field] ?? originalValue : originalValue
            let value = try logical(expected, field: field, strength: targetScale, preserving: preferred)
            guard equivalent(try scaled(value, field: field, by: targetScale), expected, field: field) else {
                throw AdjustmentTransferError.unrepresentable(field.rawValue)
            }
            result[field] = value
        }
        return result
    }

    public static func scaled(_ value: Value, field: Field, by strength: Double) throws -> Value {
        if field == .curve, let curve = value.curve { return curve.scaled(by: strength).transferValue }
        if field == .curveParametric, let parametric = value.parametricCurve { return parametric.scaled(by: strength).transferValue }
        guard field.gradingZone != nil, let wheel = value.gradingWheel else {
            throw AdjustmentTransferError.invalidPayload(field.rawValue)
        }
        return ColorGradingWheel(
            hue: wheel.hue,
            saturation: min(100, max(0, wheel.saturation * strength)),
            luminance: min(100, max(-100, wheel.luminance * strength))
        ).transferValue
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
                    inverse = inverse.replacing(channel, with: .init(mode: .custom, points: shape.points.map {
                        ToneCurvePoint(x: $0.x, y: $0.x + ($0.y - $0.x) / strength)
                    }))
                }
            }
            guard inverse.isValid else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            result = inverse.transferValue
        } else if field == .curveParametric, let p = effective.parametricCurve {
            if p.isIdentity { return effective }
            guard strength != 0 else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            let inverse = ToneCurveParametric(
                highlights: p.highlights / strength,
                lights: p.lights / strength,
                darks: p.darks / strength,
                shadows: p.shadows / strength,
                splitShadow: p.splitShadow,
                splitMidtone: p.splitMidtone,
                splitHighlight: p.splitHighlight
            )
            guard inverse.isValid else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            result = inverse.transferValue
        } else if field.gradingZone != nil, let wheel = effective.gradingWheel {
            guard strength != 0 || (wheel.saturation == 0 && wheel.luminance == 0) else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            let inverse = ColorGradingWheel(
                hue: wheel.hue,
                saturation: strength == 0 ? 0 : wheel.saturation / strength,
                luminance: strength == 0 ? 0 : wheel.luminance / strength
            )
            guard inverse.isValid else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            result = inverse.transferValue
        } else { throw AdjustmentTransferError.invalidPayload(field.rawValue) }
        guard equivalent(try scaled(result, field: field, by: strength), effective, field: field) else {
            throw AdjustmentTransferError.unrepresentable(field.rawValue)
        }
        return result
    }

    public static func equivalent(_ a: Value, _ b: Value, field: Field) -> Bool {
        if field == .curve, let first = a.curve, let second = b.curve {
            return ToneCurveChannel.allCases.allSatisfy { channel in
                let a = first.shape(channel), b = second.shape(channel)
                guard a.mode == b.mode else { return false }
                if a.isIdentity && b.isIdentity { return true }
                return a.points.count == b.points.count && zip(a.points, b.points).allSatisfy {
                    $0.x == $1.x && abs($0.y - $1.y) <= 1e-12
                }
            }
        }
        if field == .curveParametric, let first = a.parametricCurve, let second = b.parametricCurve {
            return first.splitShadow == second.splitShadow &&
                first.splitMidtone == second.splitMidtone &&
                first.splitHighlight == second.splitHighlight &&
                abs(first.highlights - second.highlights) <= 1e-12 &&
                abs(first.lights - second.lights) <= 1e-12 &&
                abs(first.darks - second.darks) <= 1e-12 &&
                abs(first.shadows - second.shadows) <= 1e-12
        }
        guard let first = a.gradingWheel, let second = b.gradingWheel else { return false }
        return first.hue == second.hue && Float(first.saturation) == Float(second.saturation) && Float(first.luminance) == Float(second.luminance)
    }
}

public struct AdjustmentRecipeContext: Codable, Equatable {
    public let id: String
    public let strength: Double
    public let settingsVersion: Int
    public var refinementScale: Double { settingsVersion >= 4 ? strength : 1 }
    enum CodingKeys: String, CodingKey { case id, strength; case settingsVersion = "settings_version" }
    public init(id: String, strength: Double, settingsVersion: Int) {
        self.id = id; self.strength = strength; self.settingsVersion = settingsVersion
    }
    public init(from decoder: Decoder) throws {
        try TransferCodingKey.rejectUnknown(decoder, allowed: ["id", "strength", "settings_version"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        strength = try values.decode(Double.self, forKey: .strength)
        settingsVersion = try values.decode(Int.self, forKey: .settingsVersion)
    }
}

public struct AdjustmentTransferSource: Codable, Equatable {
    public let identifier: String
    public let isRaw: Bool
    public let processingVersion: Int
    public let recipe: AdjustmentRecipeContext?
    public let hdrProcessingVersion: Int?
    public var isHDR: Bool { hdrProcessingVersion != nil }
    enum CodingKeys: String, CodingKey {
        case identifier, recipe
        case isRaw = "is_raw", processingVersion = "processing_version"
        case hdrProcessingVersion = "hdr_processing_version"
    }
    public init(identifier: String, isRaw: Bool, processingVersion: Int, recipe: AdjustmentRecipeContext?, hdrProcessingVersion: Int? = nil) {
        self.identifier = identifier; self.isRaw = isRaw
        self.processingVersion = processingVersion; self.recipe = recipe
        self.hdrProcessingVersion = hdrProcessingVersion
    }
    public init(from decoder: Decoder) throws {
        try TransferCodingKey.rejectUnknown(decoder, allowed: ["identifier", "is_raw", "processing_version", "recipe", "hdr_processing_version"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try values.decode(String.self, forKey: .identifier)
        isRaw = try values.decode(Bool.self, forKey: .isRaw)
        processingVersion = try values.decode(Int.self, forKey: .processingVersion)
        recipe = try values.decodeIfPresent(AdjustmentRecipeContext.self, forKey: .recipe)
        hdrProcessingVersion = values.contains(.hdrProcessingVersion) ? try values.decode(Int.self, forKey: .hdrProcessingVersion) : nil
    }
}

public struct AdjustmentTransferPayload: Codable, Equatable {
    public let payloadVersion: Int
    public let scopeVersion: Int
    public let source: AdjustmentTransferSource
    public let values: [String: AdjustmentTransferValue]
    public var fields: Set<AdjustmentTransferField> { Set(values.keys.compactMap(AdjustmentTransferField.init(rawValue:))) }
    public subscript(_ field: AdjustmentTransferField) -> AdjustmentTransferValue? { values[field.rawValue] }
    enum CodingKeys: String, CodingKey {
        case payloadVersion = "payload_version", scopeVersion = "scope_version", source, values
    }

    public init(source: AdjustmentTransferSource, values: [String: AdjustmentTransferValue]) throws {
        payloadVersion = source.isHDR ? 2 : 1; scopeVersion = payloadVersion; self.source = source; self.values = values
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try TransferCodingKey.rejectUnknown(decoder, allowed: ["payload_version", "scope_version", "source", "values"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payloadVersion = try container.decode(Int.self, forKey: .payloadVersion)
        scopeVersion = try container.decode(Int.self, forKey: .scopeVersion)
        source = try container.decode(AdjustmentTransferSource.self, forKey: .source)
        values = try container.decode([String: AdjustmentTransferValue].self, forKey: .values)
        try validate()
    }

    public func validate() throws {
        guard (payloadVersion == 1 && scopeVersion == 1 && !source.isHDR) ||
            (payloadVersion == 2 && scopeVersion == 2 && source.isHDR) else { throw AdjustmentTransferError.unsupportedVersion }
        if source.isHDR {
            guard let version = source.hdrProcessingVersion, (1...9).contains(version) else {
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
        if let mode, source.isRaw ? mode == "none" : mode != "none" {
            throw AdjustmentTransferError.invalidPayload("white_balance.mode")
        }
        if !source.isRaw && (self[.temperature]?.number != nil || source.recipe == nil && self[.tint]?.number != nil) {
            throw AdjustmentTransferError.invalidPayload("raster.white_balance")
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
        case .look:
            guard let object = value.object, Set(object.keys) == Set(proto.objectKeys),
                  let kind = object["kind"]?.string,
                  AdjustmentFieldSpec.SubFields.LookReference.allowedKinds.contains(kind) else { return false }
            if kind == AdjustmentFieldSpec.SubFields.LookReference.idNullableWhenKind { return object["id"] == .null }
            guard let id = object["id"]?.string,
                  !id.isEmpty, !id.contains("/"), !id.contains("\\"), id != ".", id != ".." else { return false }
            return true
        case .waveletDenoise: return validWavelet(value)
        default: break
        }
        switch proto.valueType {
        case .boolean:
            return value.boolean != nil
        case .string:
            guard let text = value.string else { return false }
            if proto.nonEmpty && text.isEmpty { return false }
            if !proto.allowedStringValues.isEmpty { return proto.allowedStringValues.contains(text) }
            return true
        case .integer:
            guard let number = value.number, number.isFinite, number.rounded() == number else { return false }
            if let range = proto.closedRange, !range.contains(number) { return false }
            if !proto.allowedIntValues.isEmpty { return proto.allowedIntValues.contains(Int(number)) }
            return true
        case .number:
            guard let number = value.number, number.isFinite else { return false }
            if let min = proto.min {
                if proto.exclusiveMin ? number <= min : number < min { return false }
            }
            if let max = proto.max, number > max { return false }
            return true
        case .object:
            return false
        }
    }

    private static func validWavelet(_ value: AdjustmentTransferValue) -> Bool {
        let proto = AdjustmentFieldSpec.Fields.detailDenoiseWavelet.protocolSpec
        if value == .null { return proto.nullable }
        guard let wavelet = value.object,
              Set(wavelet.keys) == Set(proto.objectKeys),
              wavelet["enabled"]?.boolean != nil,
              AdjustmentFieldSpec.SubFields.WaveletDenoise.allowedPresets.contains(wavelet["preset"]?.string ?? "") else { return false }
        let sub = AdjustmentFieldSpec.SubFields.WaveletDenoise.self
        let ranges: [(String, ClosedRange<Double>)] = [
            ("luma", sub.lumaRange),
            ("chroma", sub.chromaRange),
            ("coarse", sub.coarseRange),
        ]
        return ranges.allSatisfy { key, range in
            wavelet[key]?.number.map { $0.isFinite && range.contains($0) } == true
        }
    }
}

private struct TransferCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func rejectUnknown(_ decoder: Decoder, allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: Self.self)
        guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw AdjustmentTransferError.invalidPayload("unknown field")
        }
    }
}
