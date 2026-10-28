import Foundation

enum AdjustmentTransferError: Error, Equatable {
    case invalidPayload(String)
    case unsupportedVersion
    case emptyScope
    case draftRequiresPreflight
    case incompatible(String)
    case missingLook(String)
    case unrepresentable(String)
}

enum AdjustmentTransferField: String, CaseIterable, Codable, Hashable {
    case look = "looks.reference", strength = "looks.strength"
    case exposure = "light.exposure", exposureMode = "light.exposure_mode"
    case contrast = "light.contrast", highlights = "light.highlights", shadows = "light.shadows", sCurve = "light.s_curve"
    case curve = "light.curve"
    case blackPoint = "tone.black_point", whitePoint = "tone.white_point", vibrance = "color.vibrance"
    case gradingShadows = "color.grading.shadows", gradingMidtones = "color.grading.midtones", gradingHighlights = "color.grading.highlights"
    case whiteBalanceMode = "color.white_balance.mode", temperature = "color.white_balance.temperature_kelvin"
    case tint = "color.white_balance.tint", saturation = "color.saturation"
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
    case lensAutoCrop = "geometry.lens.auto_crop", lensProfile = "geometry.lens.profile_id"

    var group: String { self == .blackPoint || self == .whitePoint ? "light" : String(rawValue.split(separator: ".")[0]) }
    var gradingZone: ColorGradingZone? {
        switch self {
        case .gradingShadows: return .shadows
        case .gradingMidtones: return .midtones
        case .gradingHighlights: return .highlights
        default: return nil
        }
    }
    static var common: Set<Self> { Set(allCases.filter { $0.group != "geometry" }) }
    static let whiteBalanceFields: Set<Self> = [.whiteBalanceMode, .temperature, .tint]
    static let lensFields: Set<Self> = [.lensDistortion, .lensTCA, .lensAutoCrop, .lensProfile]
    static let denoiseFields: Set<Self> = [.rawDenoise, .postRGBDenoise, .chromaDenoise, .waveletDenoise]
    static var recipeDependencies: Set<Self> {
        Set([.look, .strength, .exposure, .contrast, .highlights, .shadows, .saturation]).union(whiteBalanceFields)
            .union(allCases.filter { $0.hslLocation != nil })
    }
    static let refinementScalars: Set<Self> = [.sCurve, .blackPoint, .whitePoint, .vibrance, .clarity, .dehaze]
    static let refinementObjects: Set<Self> = [.curve, .gradingShadows, .gradingMidtones, .gradingHighlights]
    static func recipeDependencies(version: Int) -> Set<Self> {
        version >= 4 ? recipeDependencies.union(refinementScalars).union(refinementObjects) : recipeDependencies
    }
    var hslLocation: (axis: String, channel: Int)? {
        let parts = rawValue.split(separator: ".").map(String.init)
        guard parts.count == 4, parts[1] == "hsl",
              let channel = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"].firstIndex(of: parts[3]) else { return nil }
        return (parts[2], channel)
    }
    var scalarRange: ClosedRange<Double>? {
        if hslLocation != nil { return -100...100 }
        switch self {
        case .strength, .contrast, .saturation, .sharpening: return 0...2
        case .exposure: return -20...20
        case .highlights, .shadows, .sCurve, .perspectiveHorizontal, .perspectiveVertical: return -1...1
        case .vignetteAmount, .vignetteRoundness, .blackPoint, .whitePoint, .vibrance, .clarity, .dehaze: return -100...100
        case .vignetteMidpoint, .vignetteFeather, .vignetteHighlights, .grainAmount, .grainSize, .grainRoughness: return 0...100
        case .quarterTurns: return 0...3
        case .cropX, .cropY, .cropWidth, .cropHeight: return 0...1
        case .postRGBDenoise: return 0...1
        case .straighten: return -45...45
        default: return nil
        }
    }
}

enum AdjustmentTransferScope {
    case all, modified, custom(Set<AdjustmentTransferField>)
    static var standard: Self { .custom(AdjustmentTransferField.common) }
}

// 这是逻辑 payload 的 JSON 值，不是 native snapshot 或渲染 recipe。
enum AdjustmentTransferValue: Codable, Equatable {
    case number(Double), string(String), boolean(Bool), object([String: Self]), array([Self]), null

    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var boolean: Bool? { if case .boolean(let value) = self { return value }; return nil }
    var object: [String: Self]? { if case .object(let value) = self { return value }; return nil }
    var array: [Self]? { if case .array(let value) = self { return value }; return nil }
    var curve: ToneCurveSettings? {
        guard let object, Set(object.keys) == ["mode", "points"],
              let mode = object["mode"]?.string.flatMap(ToneCurveMode.init(rawValue:)),
              let values = object["points"]?.array else { return nil }
        var points = [ToneCurvePoint]()
        for value in values {
            guard let pair = value.array, pair.count == 2, let x = pair[0].number, let y = pair[1].number else { return nil }
            points.append(.init(x: x, y: y))
        }
        let curve = ToneCurveSettings(mode: mode, points: points)
        return curve.isValid ? curve : nil
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .boolean(bool) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = .object(try value.decode([String: Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
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

extension ToneCurveSettings {
    var transferValue: AdjustmentTransferValue {
        .object(["mode": .string(mode.rawValue), "points": .array(points.map { .array([.number($0.x), .number($0.y)]) })])
    }
}

extension ColorGradingWheel {
    var transferValue: AdjustmentTransferValue { .object(["hue": .number(hue), "saturation": .number(saturation)]) }
}

// 曲线和色轮在完整复制时保留逻辑值；部分复制只转换一次实际效果。
enum AdjustmentTransferRefinement {
    typealias Value = AdjustmentTransferValue
    typealias Field = AdjustmentTransferField

    static func values(curve: ToneCurveSettings, grading: ColorGradingSettings) -> [Field: Value] {
        var result: [Field: Value] = [.curve: curve.transferValue]
        for field in Field.refinementObjects {
            if let zone = field.gradingZone { result[field] = grading[zone].transferValue }
        }
        return result
    }

    static func applying(_ payload: AdjustmentTransferPayload, original: [Field: Value],
                         previousScale: Double, targetScale: Double, fullRecipe: Bool) throws -> [Field: Value] {
        var result = original
        for field in Field.refinementObjects {
            let expected = try payload[field].map {
                try scaled($0, field: field, by: payload.source.recipe?.refinementScale ?? 1)
            } ?? scaled(original[field]!, field: field, by: previousScale)
            // 完整复制优先保留原逻辑值；移动端强度经过 Float 投影时仅反解必要的差值。
            let preferred = fullRecipe ? payload[field] ?? original[field]! : original[field]!
            let value = try logical(expected, field: field, strength: targetScale, preserving: preferred)
            guard equivalent(try scaled(value, field: field, by: targetScale), expected, field: field) else {
                throw AdjustmentTransferError.unrepresentable(field.rawValue)
            }
            result[field] = value
        }
        return result
    }

    static func scaled(_ value: Value, field: Field, by strength: Double) throws -> Value {
        if field == .curve, let curve = value.curve { return curve.scaled(by: strength).transferValue }
        guard field.gradingZone != nil, let wheel = value.object,
              let hue = wheel["hue"]?.number, let saturation = wheel["saturation"]?.number else {
            throw AdjustmentTransferError.invalidPayload(field.rawValue)
        }
        return ColorGradingWheel(hue: hue, saturation: min(100, max(0, saturation * strength))).transferValue
    }

    static func logical(_ effective: Value, field: Field, strength: Double, preserving current: Value) throws -> Value {
        if equivalent(try scaled(current, field: field, by: strength), effective, field: field) { return current }
        let result: Value
        if field == .curve, let curve = effective.curve {
            if curve.mode == .legacy || strength == 0 && curve.isIdentity { return effective }
            guard strength != 0 else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            let inverse = ToneCurveSettings(mode: .custom, points: curve.points.map {
                ToneCurvePoint(x: $0.x, y: $0.x + ($0.y - $0.x) / strength)
            })
            guard inverse.isValid else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            result = inverse.transferValue
        } else if field.gradingZone != nil, let wheel = effective.object,
                  let hue = wheel["hue"]?.number, let saturation = wheel["saturation"]?.number {
            guard strength != 0 || saturation == 0 else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            let inverse = ColorGradingWheel(hue: hue, saturation: strength == 0 ? 0 : saturation / strength)
            guard inverse.isValid else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            result = inverse.transferValue
        } else { throw AdjustmentTransferError.invalidPayload(field.rawValue) }
        guard equivalent(try scaled(result, field: field, by: strength), effective, field: field) else {
            throw AdjustmentTransferError.unrepresentable(field.rawValue)
        }
        return result
    }

    static func equivalent(_ a: Value, _ b: Value, field: Field) -> Bool {
        if field == .curve, let first = a.curve, let second = b.curve {
            guard first.mode == second.mode else { return false }
            if first.isIdentity && second.isIdentity { return true }
            return first.points.count == second.points.count && zip(first.points, second.points).allSatisfy {
                $0.x == $1.x && abs($0.y - $1.y) <= 1e-12
            }
        }
        guard let first = a.object, let second = b.object,
              let firstSat = first["saturation"]?.number, let secondSat = second["saturation"]?.number else { return false }
        return first["hue"] == second["hue"] && Float(firstSat) == Float(secondSat)
    }
}

struct AdjustmentRecipeContext: Codable, Equatable {
    let id: String
    let strength: Double
    let settingsVersion: Int
    var refinementScale: Double { settingsVersion >= 4 ? strength : 1 }
    enum CodingKeys: String, CodingKey { case id, strength; case settingsVersion = "settings_version" }
    init(id: String, strength: Double, settingsVersion: Int) {
        self.id = id; self.strength = strength; self.settingsVersion = settingsVersion
    }
    init(from decoder: Decoder) throws {
        try TransferCodingKey.rejectUnknown(decoder, allowed: ["id", "strength", "settings_version"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        strength = try values.decode(Double.self, forKey: .strength)
        settingsVersion = try values.decode(Int.self, forKey: .settingsVersion)
    }
}

struct AdjustmentTransferSource: Codable, Equatable {
    let identifier: String
    let isRaw: Bool
    let processingVersion: Int
    let recipe: AdjustmentRecipeContext?
    enum CodingKeys: String, CodingKey {
        case identifier, recipe
        case isRaw = "is_raw", processingVersion = "processing_version"
    }
    init(identifier: String, isRaw: Bool, processingVersion: Int, recipe: AdjustmentRecipeContext?) {
        self.identifier = identifier; self.isRaw = isRaw
        self.processingVersion = processingVersion; self.recipe = recipe
    }
    init(from decoder: Decoder) throws {
        try TransferCodingKey.rejectUnknown(decoder, allowed: ["identifier", "is_raw", "processing_version", "recipe"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try values.decode(String.self, forKey: .identifier)
        isRaw = try values.decode(Bool.self, forKey: .isRaw)
        processingVersion = try values.decode(Int.self, forKey: .processingVersion)
        recipe = try values.decodeIfPresent(AdjustmentRecipeContext.self, forKey: .recipe)
    }
}

struct AdjustmentTransferPayload: Codable, Equatable {
    let payloadVersion: Int
    let scopeVersion: Int
    let source: AdjustmentTransferSource
    let values: [String: AdjustmentTransferValue]
    var fields: Set<AdjustmentTransferField> { Set(values.keys.compactMap(AdjustmentTransferField.init(rawValue:))) }
    subscript(_ field: AdjustmentTransferField) -> AdjustmentTransferValue? { values[field.rawValue] }
    enum CodingKeys: String, CodingKey {
        case payloadVersion = "payload_version", scopeVersion = "scope_version", source, values
    }

    init(source: AdjustmentTransferSource, values: [String: AdjustmentTransferValue]) throws {
        payloadVersion = 1; scopeVersion = 1; self.source = source; self.values = values
        try validate()
    }

    init(from decoder: Decoder) throws {
        try TransferCodingKey.rejectUnknown(decoder, allowed: ["payload_version", "scope_version", "source", "values"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payloadVersion = try container.decode(Int.self, forKey: .payloadVersion)
        scopeVersion = try container.decode(Int.self, forKey: .scopeVersion)
        source = try container.decode(AdjustmentTransferSource.self, forKey: .source)
        values = try container.decode([String: AdjustmentTransferValue].self, forKey: .values)
        try validate()
    }

    func validate() throws {
        guard payloadVersion == 1, scopeVersion == 1 else { throw AdjustmentTransferError.unsupportedVersion }
        guard !values.isEmpty else { throw AdjustmentTransferError.emptyScope }
        guard !source.identifier.isEmpty, [1, 2].contains(source.processingVersion) else {
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
                  self[.postRGBDenoise] == nil || self[.postRGBDenoise] == .number(0),
                  self[.lensDistortion] != .boolean(true), self[.lensTCA] != .boolean(true) else {
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
        if field == .curve { return value.curve != nil }
        if field.gradingZone != nil {
            guard let wheel = value.object, Set(wheel.keys) == ["hue", "saturation"],
                  let hue = wheel["hue"]?.number, let saturation = wheel["saturation"]?.number else { return false }
            return ColorGradingWheel(hue: hue, saturation: saturation).isValid
        }
        if let range = field.scalarRange {
            guard let number = value.number, number.isFinite, range.contains(number) else { return false }
            if field == .quarterTurns { return number.rounded() == number }
            return ![.cropWidth, .cropHeight].contains(field) || number > 0
        }
        switch field {
        case .flipHorizontal, .flipVertical, .lensDistortion, .lensTCA, .lensAutoCrop: return value.boolean != nil
        case .exposureMode: return value.string.map { ["scene", "preview", "sensor"].contains($0) } ?? false
        case .whiteBalanceMode: return value.string.map { ["camera", "temperature", "none"].contains($0) } ?? false
        case .temperature: return value == .null || value.number.map { $0.isFinite && (2000...50000).contains($0) } == true
        case .tint: return value == .null || value.number.map { $0.isFinite && (-150...150).contains($0) } == true
        case .look:
            guard let object = value.object, Set(object.keys) == ["kind", "id"], let kind = object["kind"]?.string else { return false }
            if kind == "neutral" { return object["id"] == .null }
            guard ["builtin", "managed", "recipe", "recipe_lut"].contains(kind), let id = object["id"]?.string,
                  !id.isEmpty, !id.contains("/"), !id.contains("\\"), id != ".", id != ".." else { return false }
            return true
        case .lensProfile: return value == .null || value.string.map { !$0.isEmpty } == true
        case .rawDenoise: return value.number.map { [0, 1, 2].contains($0) } == true
        case .chromaDenoise: return value == .null || value.number.map { [0, 1, 2].contains($0) } == true
        case .waveletDenoise: return validWavelet(value)
        default: return false
        }
    }

    private static func validWavelet(_ value: AdjustmentTransferValue) -> Bool {
        if value == .null { return true }
        guard let wavelet = value.object,
              Set(wavelet.keys) == ["enabled", "luma", "chroma", "coarse", "preset"],
              wavelet["enabled"]?.boolean != nil,
              ["detail", "clean", "custom"].contains(wavelet["preset"]?.string ?? "") else { return false }
        return ["luma", "chroma", "coarse"].allSatisfy { wavelet[$0]?.number.map { $0.isFinite && (0...100).contains($0) } == true }
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
