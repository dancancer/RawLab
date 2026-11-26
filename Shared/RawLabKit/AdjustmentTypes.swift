import Foundation
import UniformTypeIdentifiers

public enum PhotoInputClassification {
    public static func isRasterInput(_ url: URL?) -> Bool {
        guard let url, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .rawImage)
    }
}

public struct WhiteBalance: Equatable, Codable, Sendable {
    public let temperature: Double
    public let tint: Double
    public init(temperature: Double, tint: Double) { self.temperature = temperature; self.tint = tint }
}

public enum WhiteBalanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case camera, custom
    public static var asShot: Self { .camera }
    public var id: String { rawValue }
    public var title: String { L10n.text(self == .camera ? "拍摄时设置" : "自定义") }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "camera", "拍摄时设置": self = .camera
        case "custom", "自定义": self = .custom
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid WhiteBalanceMode: \(value)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        let v1 = (encoder.userInfo[Adjustments.legacyV1EncodingKey] as? Bool) == true
        try c.encode(v1 ? (self == .camera ? "拍摄时设置" : "自定义") : rawValue)
    }
}
public typealias RawWhiteBalanceMode = WhiteBalanceMode

public enum ExposureMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case scene, preview, sensor
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .scene: return L10n.text("标准显影")
        case .preview: return L10n.text("匹配内嵌预览")
        case .sensor: return L10n.text("传感器基准")
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) {
            switch text {
            case "scene", "标准显影": self = .scene
            case "preview", "匹配内嵌预览": self = .preview
            case "sensor", "传感器基准": self = .sensor
            default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ExposureMode: \(text)"))
            }
            return
        }
        if let code = try? c.decode(Int.self), let mode = [Self.scene, .preview, .sensor][safe: code] {
            self = mode; return
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ExposureMode"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if (encoder.userInfo[Adjustments.legacyV1EncodingKey] as? Bool) == true {
            switch self {
            case .scene: try c.encode("标准显影")
            case .preview: try c.encode("匹配内嵌预览")
            case .sensor: try c.encode("传感器基准")
            }
        } else { try c.encode(rawValue) }
    }
}
public typealias RawExposureMode = ExposureMode

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

public enum RawNoiseReductionLevel: Double, CaseIterable, Identifiable, Sendable {
    case off = 0, light = 1, full = 2
    public var id: Double { rawValue }
    public var title: String { L10n.text(self == .off ? "停用" : self == .light ? "轻度" : "强度") }
}

public enum ChromaNoiseReductionMode: Double, CaseIterable, Identifiable, Sendable {
    case off = 0, detail = 1, clean = 2
    public var id: Double { rawValue }
    public var title: String { L10n.text(self == .off ? "停用" : self == .detail ? "细节优先" : "去噪优先") }
}

public enum DenoisePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case detail, clean, custom
    public var id: String { rawValue }
    public var title: String { L10n.text(self == .detail ? "细节优先" : self == .clean ? "去噪优先" : "自定义") }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "detail", "细节优先": self = .detail
        case "clean", "去噪优先": self = .clean
        case "custom", "自定义": self = .custom
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid DenoisePreset: \(value)"))
        }
    }
}
public typealias RawDenoisePreset = DenoisePreset

public struct WaveletDenoiseSettings: Equatable, Codable, Sendable {
    public var enabled = false, preset = DenoisePreset.detail
    public var luma = 0.0 { didSet { preset = Self.computedPreset(luma: luma, chroma: chroma, coarse: coarse) } }
    public var chroma = 46.0 { didSet { preset = Self.computedPreset(luma: luma, chroma: chroma, coarse: coarse) } }
    public var coarse = 50.0 { didSet { preset = Self.computedPreset(luma: luma, chroma: chroma, coarse: coarse) } }
    public init(enabled: Bool = false, luma: Double = 0.0, chroma: Double = 46.0, coarse: Double = 50.0, preset: DenoisePreset? = nil) {
        self.enabled = enabled; self.luma = luma; self.chroma = chroma; self.coarse = coarse
        self.preset = preset ?? Self.computedPreset(luma: luma, chroma: chroma, coarse: coarse)
    }
    public var isValid: Bool { [luma, chroma, coarse].allSatisfy { $0.isFinite && (0...100).contains($0) } }
    public static func computedPreset(luma: Double, chroma: Double, coarse: Double) -> DenoisePreset {
        if luma == 0 && chroma == 46 && coarse == 50 { return .detail }
        if luma == 10 && chroma == 72 && coarse == 100 { return .clean }
        return .custom
    }
    public mutating func apply(_ preset: DenoisePreset) {
        switch preset {
        case .detail: self = Self(enabled: true, luma: 0, chroma: 46, coarse: 50, preset: .detail)
        case .clean: self = Self(enabled: true, luma: 10, chroma: 72, coarse: 100, preset: .clean)
        case .custom: break
        }
    }
    private enum CodingKeys: String, CodingKey { case enabled, luma, chroma, coarse, preset }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try v.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        luma = try v.decodeIfPresent(Double.self, forKey: .luma) ?? 0.0
        chroma = try v.decodeIfPresent(Double.self, forKey: .chroma) ?? 46.0
        coarse = try v.decodeIfPresent(Double.self, forKey: .coarse) ?? 50.0
        preset = try v.decodeIfPresent(DenoisePreset.self, forKey: .preset) ?? Self.computedPreset(luma: luma, chroma: chroma, coarse: coarse)
    }
}
public typealias RawDenoiseSettings = WaveletDenoiseSettings

public enum DenoiseParameter: String, CaseIterable, Identifiable, Sendable {
    case luma, chroma, coarse
    public var id: String { rawValue }
    public var shortTitle: String { L10n.text(self == .luma ? "降噪亮度" : self == .chroma ? "降噪色彩" : "降噪粗色斑") }
    public var title: String { L10n.text(self == .luma ? "亮度降噪" : self == .chroma ? "色彩降噪" : "粗色斑抑制") }
    public var keyPath: WritableKeyPath<WaveletDenoiseSettings, Double> {
        switch self { case .luma: return \.luma; case .chroma: return \.chroma; case .coarse: return \.coarse }
    }
    public var defaultValue: Double { WaveletDenoiseSettings()[keyPath: keyPath] }
}

public enum AdjustmentGroup: String, CaseIterable, Identifiable, Sendable {
    case film = "胶片模拟", input = "输入调整", tone = "明暗", color = "色彩", detail = "细节", effects = "效果", lens = "镜头校正", geometry = "几何编辑"
    public var id: String { rawValue }
    public var title: String { L10n.text(rawValue) }
    public var parameters: [AdjustmentParameter] {
        switch self {
        case .film: return [.strength]
        case .input: return [.exposure, .temperature, .tint]
        case .tone: return [.contrast, .highlights, .shadows, .blackPoint, .whitePoint, .toneCurve]
        case .color: return [.saturation, .vibrance]
        case .detail: return [.denoiseMode, .sharpening]
        case .effects: return [.clarity, .dehaze, .texture, .vignetteAmount, .grainAmount]
        case .lens, .geometry: return []
        }
    }
}

public enum EditorAdjustmentGroup: String, CaseIterable, Identifiable, Sendable {
    case looks, light, color, effects, detail, geometry, hdrRendition
    public var id: String { rawValue }
    public var title: String { L10n.text(["外观", "光线", "颜色", "效果", "细节", "几何与镜头", "HDR 输出与 SDR 底图"][Self.allCases.firstIndex(of: self)!]) }
    public var tools: [EditorAdjustmentTool] {
        switch self {
        case .looks: return [.film, .recipe, .strength]
        case .light: return [.exposure, .highlights, .shadows, .blackPoint, .whitePoint, .contrast, .toneCurve]
        case .color: return [.whiteBalance, .saturation, .vibrance, .hsl, .pointColor, .selectiveColor, .bwMixer, .colorGrading, .cameraCalibration]
        case .effects: return [.clarity, .dehaze, .texture, .vignette, .grain]
        case .detail: return [.denoise, .sharpening]
        case .geometry: return [.geometry, .lens]
        case .hdrRendition: return [.hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation]
        }
    }
    public var defaultTool: EditorAdjustmentTool { tools[0] }
    public func isVisible(isHDREditing: Bool) -> Bool { self != .hdrRendition || isHDREditing }
    public static func visibleGroups(isHDREditing: Bool) -> [Self] { allCases.filter { $0.isVisible(isHDREditing: isHDREditing) } }
}

public enum EditorAdjustmentTool: String, CaseIterable, Identifiable, Sendable {
    case film, recipe, strength, exposure, highlights, shadows, blackPoint, whitePoint, vibrance, contrast, toneCurve
    case clarity, dehaze, texture, whiteBalance, saturation, hsl, pointColor, selectiveColor, bwMixer, colorGrading, cameraCalibration, vignette, grain, denoise, sharpening, geometry, lens
    case hdrPeakLimit, hdrSDRExposure, hdrSDRContrast, hdrSDRSaturation
    public var id: String { rawValue }
    public var group: EditorAdjustmentGroup { EditorAdjustmentGroup.allCases.first { $0.tools.contains(self) }! }
    public var hdrRenditionKeyPath: WritableKeyPath<HDRRenditionSettings, Double>? {
        switch self {
        case .hdrPeakLimit: return \.peakLimitEV
        case .hdrSDRExposure: return \.sdrExposureEV
        case .hdrSDRContrast: return \.sdrContrast
        case .hdrSDRSaturation: return \.sdrSaturation
        default: return nil
        }
    }
    public var parameter: AdjustmentParameter? {
        switch self {
        case .strength: return .strength; case .exposure: return .exposure; case .highlights: return .highlights
        case .shadows: return .shadows; case .blackPoint: return .blackPoint; case .whitePoint: return .whitePoint
        case .vibrance: return .vibrance; case .clarity: return .clarity; case .dehaze: return .dehaze; case .texture: return .texture
        case .contrast: return .contrast; case .toneCurve: return .toneCurve; case .whiteBalance: return .temperature
        case .saturation: return .saturation; case .vignette: return .vignetteAmount; case .grain: return .grainAmount
        case .denoise: return .denoiseMode; case .sharpening: return .sharpening
        default: return nil
        }
    }
    public var title: String {
        switch self {
        case .film: return L10n.text("胶片"); case .recipe: return L10n.text("大师配方")
        case .whiteBalance: return L10n.text("白平衡"); case .colorGrading: return L10n.text("颜色分级")
        case .pointColor: return L10n.text("点颜色"); case .selectiveColor: return L10n.text("可选颜色")
        case .bwMixer: return L10n.text("黑白"); case .cameraCalibration: return L10n.text("相机校准")
        case .toneCurve: return L10n.text("曲线"); case .hsl: return "HSL"
        case .geometry: return L10n.text("几何"); case .lens: return L10n.text("镜头")
        case .hdrPeakLimit: return L10n.text("HDR 亮度上限"); case .hdrSDRExposure: return L10n.text("SDR 底图曝光")
        case .hdrSDRContrast: return L10n.text("SDR 底图对比度"); case .hdrSDRSaturation: return L10n.text("SDR 底图饱和度")
        default: return parameter!.spec.title
        }
    }
    public var symbol: String {
        switch self {
        case .film: return "film"; case .recipe: return "photo.stack"; case .colorGrading: return "paintpalette"
        case .pointColor: return "eyedropper"; case .selectiveColor: return "circle.hexagongrid"
        case .bwMixer: return "circle.lefthalf.filled"; case .cameraCalibration: return "camera.aperture"
        case .hsl: return "slider.horizontal.3"; case .geometry: return "crop.rotate"; case .lens: return "viewfinder"
        case .hdrPeakLimit: return "sun.max"; case .hdrSDRExposure: return "plusminus.circle"
        case .hdrSDRContrast: return "circle.lefthalf.filled"; case .hdrSDRSaturation: return "drop.halffull"
        default: return parameter!.symbol
        }
    }
    public var usesGeometryDraft: Bool { self == .geometry || self == .lens }
}

public struct EditorAdjustmentNavigation: Equatable {
    public var expandedGroup: EditorAdjustmentGroup?
    public var tool: EditorAdjustmentTool
    public var selectedHSLChannel: Int
    public var selectedGradingZone: ColorGradingZone
    public var gradingGlobalSelected: Bool

    public init(expandedGroup: EditorAdjustmentGroup? = .looks, tool: EditorAdjustmentTool = .film,
                selectedHSLChannel: Int = 0, selectedGradingZone: ColorGradingZone = .shadows, gradingGlobalSelected: Bool = false) {
        self.expandedGroup = expandedGroup; self.tool = tool; self.selectedHSLChannel = selectedHSLChannel
        self.selectedGradingZone = selectedGradingZone; self.gradingGlobalSelected = gradingGlobalSelected
    }
    public var currentGradingResetScope: EditorResetScope { gradingGlobalSelected ? .gradingGlobal : .gradingZone(selectedGradingZone) }
    public mutating func selectGroup(_ group: EditorAdjustmentGroup) {
        if expandedGroup == group { expandedGroup = nil } else { expandedGroup = group; tool = group.defaultTool }
    }
    public mutating func selectTool(_ target: EditorAdjustmentTool) { tool = target; expandedGroup = target.group }
    public mutating func normalize(isHDREditing: Bool) {
        let wasCollapsed = expandedGroup == nil
        if !tool.group.isVisible(isHDREditing: isHDREditing) { selectTool(.exposure); if wasCollapsed { expandedGroup = nil } }
        else if let group = expandedGroup, !group.isVisible(isHDREditing: isHDREditing) { expandedGroup = tool.group }
    }
    public func normalized(isHDREditing: Bool) -> Self { var copy = self; copy.normalize(isHDREditing: isHDREditing); return copy }
}

public enum EditorResetScope: Equatable {
    case tool(EditorAdjustmentTool), group(EditorAdjustmentGroup), hslColor(Int), hslAll
    case gradingZone(ColorGradingZone), gradingGlobal, allGrading, all
    public var usesGeometryDraft: Bool {
        switch self { case .group(.geometry), .tool(.geometry), .tool(.lens): return true; default: return false }
    }
}

public enum EditorResetBlockedReason: Error, Equatable, Sendable {
    case invalidSnapshot(String), invalidHSLChannel, missingAsShotWhiteBalance, unrepresentableRecipe
}
public enum EditorResetResult: Equatable { case unchanged, candidate(PhotoEditState), blocked(EditorResetBlockedReason) }

public enum GeometryParameter: String, CaseIterable, Identifiable, Sendable {
    case cropX, cropY, cropWidth, cropHeight, straightenDegrees, perspectiveHorizontal, perspectiveVertical
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cropX: return L10n.text("裁切左边"); case .cropY: return L10n.text("裁切上边")
        case .cropWidth: return L10n.text("裁切宽度"); case .cropHeight: return L10n.text("裁切高度")
        case .straightenDegrees: return L10n.text("拉直")
        case .perspectiveHorizontal: return L10n.text("水平透视"); case .perspectiveVertical: return L10n.text("垂直透视")
        }
    }
    public var keyPath: WritableKeyPath<GeometrySettings, Double> {
        switch self {
        case .cropX: return \.cropX; case .cropY: return \.cropY; case .cropWidth: return \.cropWidth
        case .cropHeight: return \.cropHeight; case .straightenDegrees: return \.straightenDegrees
        case .perspectiveHorizontal: return \.perspectiveHorizontal; case .perspectiveVertical: return \.perspectiveVertical
        }
    }
    public var multiplier: Double { self == .straightenDegrees ? 1 : 100 }
    public var defaultValue: Double { GeometrySettings()[keyPath: keyPath] }
    public var unit: String { self == .straightenDegrees ? "°" : (self == .perspectiveHorizontal || self == .perspectiveVertical ? "" : "%") }
    public func range(for state: GeometrySettings) -> ClosedRange<Double> {
        switch self {
        case .cropX: return 0...max(0, 1 - state.cropWidth)
        case .cropY: return 0...max(0, 1 - state.cropHeight)
        case .cropWidth: return min(0.001, 1 - state.cropX)...(1 - state.cropX)
        case .cropHeight: return min(0.001, 1 - state.cropY)...(1 - state.cropY)
        case .straightenDegrees: return -45...45
        case .perspectiveHorizontal, .perspectiveVertical: return -1...1
        }
    }
}

public struct AdjustmentSpec {
    public let title: String, unit: String; public let keyPath: WritableKeyPath<Adjustments, Double>; public let range, displayRange: ClosedRange<Double>
    public var defaultValue, displayDefault, displayScale: Double; public let step: Double; public var decimals: Int; public var reciprocalScale: Bool
    public let displayValue, modelValue: (Double) -> Double

    public init(title: String, keyPath: WritableKeyPath<Adjustments, Double>, range: ClosedRange<Double>, defaultValue: Double, step: Double, unit: String,
                displayRange: ClosedRange<Double>? = nil, displayDefault: Double? = nil, displayScale: Double = 1.0, decimals: Int = 0,
                reciprocalScale: Bool = false, displayValue: ((Double) -> Double)? = nil, modelValue: ((Double) -> Double)? = nil) {
        self.title = title; self.keyPath = keyPath; self.range = range; self.defaultValue = defaultValue; self.step = step; self.unit = unit
        self.displayScale = displayScale; self.decimals = decimals; self.reciprocalScale = reciprocalScale
        let toDisplay = displayValue ?? { $0 * displayScale }, toModel = modelValue ?? { $0 / displayScale }
        self.displayValue = toDisplay; self.modelValue = toModel
        self.displayRange = displayRange ?? (min(toDisplay(range.lowerBound), toDisplay(range.upperBound))...max(toDisplay(range.lowerBound), toDisplay(range.upperBound)))
        self.displayDefault = displayDefault ?? toDisplay(defaultValue)
    }

    public func position(for value: Double) -> Double {
        if reciprocalScale { return (1 / range.lowerBound - 1 / value) / (1 / range.lowerBound - 1 / range.upperBound) }
        return (displayValue(value) - displayRange.lowerBound) / (displayRange.upperBound - displayRange.lowerBound)
    }
    public func value(at position: Double) -> Double {
        let p = min(1, max(0, position))
        if reciprocalScale {
            let v = 1 / (1 / range.lowerBound - p * (1 / range.lowerBound - 1 / range.upperBound))
            return min(range.upperBound, max(range.lowerBound, (v / step).rounded() * step))
        }
        let rawDisplay = displayRange.lowerBound + p * (displayRange.upperBound - displayRange.lowerBound)
        let displayStep = step * displayScale
        let snapped = min(displayRange.upperBound, max(displayRange.lowerBound, (rawDisplay / displayStep).rounded() * displayStep))
        return min(range.upperBound, max(range.lowerBound, modelValue(snapped)))
    }
    public func text(_ value: Double) -> String {
        let displayed = displayValue(value)
        let places = decimals == 1 && abs(displayed - displayed.rounded()) < 0.0000001 ? 0 : decimals
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, displayed == 0 ? 0 : displayed)
    }
    public func display(_ value: Double) -> String {
        let displayed = displayValue(value)
        let number = (displayRange.lowerBound < 0 && displayed > 0 ? "+" : "") + text(value)
        return unit.isEmpty || unit == "%" ? number + unit : number + " " + unit
    }
    public func parse(_ text: String) -> Double? {
        guard let n = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), n.isFinite else { return nil }
        let clamped = min(displayRange.upperBound, max(displayRange.lowerBound, n))
        return min(range.upperBound, max(range.lowerBound, modelValue(clamped)))
    }
    public func progress(for value: Double) -> Double {
        let origin = position(for: defaultValue), offset = position(for: value) - origin, distance = offset < 0 ? origin : 1 - origin
        return distance > 0 ? min(1, max(-1, offset / distance)) : 0
    }
}

public enum AdjustmentParameter: String, CaseIterable, Identifiable, Sendable {
    case strength, exposure, temperature, tint, contrast, highlights, shadows, blackPoint, whitePoint, vibrance, toneCurve, saturation, sharpening, rawNoiseReduction, denoiseMode
    case vignetteAmount, grainAmount, clarity, dehaze, texture
    public var id: String { rawValue }
    public var isWhiteBalance: Bool { self == .temperature || self == .tint }
    public var isPhotoEffect: Bool { self == .vignetteAmount || self == .grainAmount }
    public var hdrKeyPath: WritableKeyPath<HDRSettings, Double>? {
        switch self {
        case .exposure: return \.exposure; case .temperature: return \.temperature; case .tint: return \.tint
        case .contrast: return \.contrast; case .highlights: return \.highlights; case .shadows: return \.shadows
        case .blackPoint: return \.toneSettings.blackPoint; case .whitePoint: return \.toneSettings.whitePoint
        case .toneCurve: return \.toneSettings.curveStrength; case .saturation: return \.saturation
        case .vibrance: return \.colorSettings.vibrance; case .sharpening: return \.detailSettings.sharpening
        case .clarity: return \.detailSettings.clarityPercent; case .dehaze: return \.detailSettings.dehazePercent
        case .denoiseMode: return \.detailSettings.denoise; default: return nil
        }
    }
    public func value(from settings: Adjustments) -> Double {
        if settings.isHDREditing, let key = hdrKeyPath { return settings.hdr![keyPath: key] }
        return settings[keyPath: spec.keyPath]
    }
    private var generatedModelSpec: AdjustmentFieldModelSpec {
        let f = AdjustmentFieldSpec.Fields.self
        switch self {
        case .strength: return f.looksStrength.macosModel; case .exposure: return f.lightExposure.macosModel
        case .temperature: return f.colorWhiteBalanceTemperatureKelvin.macosModel; case .tint: return f.colorWhiteBalanceTint.macosModel
        case .blackPoint: return f.toneBlackPoint.macosModel; case .whitePoint: return f.toneWhitePoint.macosModel
        case .vibrance: return f.colorVibrance.macosModel; case .clarity: return f.effectsClarity.macosModel
        case .dehaze: return f.effectsDehaze.macosModel; case .texture: return f.effectsTexture.macosModel; case .contrast: return f.lightContrast.macosModel
        case .highlights: return f.lightHighlights.macosModel; case .shadows: return f.lightShadows.macosModel
        case .toneCurve: return f.lightSCurve.macosModel; case .saturation: return f.colorSaturation.macosModel
        case .sharpening: return f.detailSharpening.macosModel; case .rawNoiseReduction: return f.detailDenoiseRawLevel.macosModel
        case .denoiseMode: return f.detailDenoiseChromaMode.macosModel; case .vignetteAmount: return f.effectsVignetteAmount.macosModel
        case .grainAmount: return f.effectsGrainAmount.macosModel
        }
    }
    private func makeSpec(title: String, keyPath: WritableKeyPath<Adjustments, Double>, step: Double? = nil, unit: String = "%",
                          displayRange: ClosedRange<Double>? = nil, displayDefault: Double? = nil, displayScale: Double = 1.0,
                          decimals: Int? = nil, reciprocalScale: Bool = false, displayValue: ((Double) -> Double)? = nil,
                          modelValue: ((Double) -> Double)? = nil) -> AdjustmentSpec {
        let model = generatedModelSpec
        return AdjustmentSpec(title: title, keyPath: keyPath, range: model.closedRange!, defaultValue: model.defaultValue.numberValue ?? 0,
                              step: step ?? (model.quantization == .discrete ? 1.0 : 0.1), unit: unit,
                              displayRange: displayRange, displayDefault: displayDefault, displayScale: displayScale,
                              decimals: decimals ?? (model.quantization == .discrete ? 0 : 1), reciprocalScale: reciprocalScale,
                              displayValue: displayValue, modelValue: modelValue)
    }
    public func spec(for settings: Adjustments) -> AdjustmentSpec {
        var value = spec
        if settings.isHDREditing {
            if self == .denoiseMode {
                let m = AdjustmentFieldSpec.Fields.detailDenoisePostRgb.macosModel
                return AdjustmentSpec(title: value.title, keyPath: value.keyPath, range: m.closedRange!, defaultValue: m.defaultValue.numberValue ?? 0,
                                      step: 0.01, unit: "%", displayRange: 0...100, displayDefault: 0, displayScale: 100)
            }
            if self == .exposure {
                let m = AdjustmentFieldSpec.Fields.lightExposure.macosModel
                return AdjustmentSpec(title: value.title, keyPath: value.keyPath, range: m.hdrClosedRange!, defaultValue: m.defaultValue.numberValue ?? 0,
                                      step: value.step, unit: value.unit, decimals: value.decimals)
            }
            if [.contrast, .highlights, .shadows, .toneCurve, .saturation].contains(self) {
                let r = generatedModelSpec.hdrClosedRange!, d = generatedModelSpec.hdrDefaultNumber ?? 0
                return AdjustmentSpec(title: value.title, keyPath: value.keyPath, range: r, defaultValue: d, step: 0.1,
                                      unit: value.unit, displayRange: r, displayDefault: d, displayScale: 1.0, decimals: 1)
            }
            return value
        }
        if self == .temperature {
            value.defaultValue = settings.asShotWhiteBalance?.temperature ?? AdjustmentFieldSpec.Fields.colorWhiteBalanceTemperatureKelvin.macosModel.defaultValue.numberValue!
            value.displayDefault = value.displayValue(value.defaultValue)
        } else if self == .tint {
            let d = AdjustmentFieldSpec.Fields.colorWhiteBalanceTint.macosModel.defaultValue.numberValue!
            value.defaultValue = settings.masterRecipe != nil ? d : (settings.asShotWhiteBalance?.tint ?? d)
            value.displayDefault = value.displayValue(value.defaultValue)
        }
        return value
    }
    public var symbol: String {
        switch self {
        case .strength: return "camera.aperture"; case .exposure: return "plusminus.circle"; case .highlights: return "sun.max"
        case .shadows: return "moon"; case .blackPoint: return "circle.fill"; case .whitePoint: return "circle"
        case .vibrance: return "drop.fill"; case .clarity: return "circle.dotted.circle"; case .dehaze: return "cloud.fog"; case .texture: return "circle.grid.3x3"
        case .contrast: return "circle.lefthalf.filled"; case .toneCurve: return "waveform.path"; case .saturation: return "drop.halffull"
        case .temperature: return "thermometer.medium"; case .tint: return "camera.filters"; case .sharpening: return "triangle"
        case .rawNoiseReduction, .denoiseMode: return "circle.dotted"; case .vignetteAmount: return "circle.lefthalf.filled.inverse"
        case .grainAmount: return "square.dotted"
        }
    }
    public var spec: AdjustmentSpec {
        switch self {
        case .strength: return makeSpec(title: L10n.text("强度"), keyPath: \.strength, step: 0.001, displayScale: 100, decimals: 1)
        case .exposure: return makeSpec(title: L10n.text("曝光"), keyPath: \.exposure, step: 0.01, unit: "EV", decimals: 2)
        case .temperature: return makeSpec(title: L10n.text("色温"), keyPath: \.temperature, step: 10, unit: "K", decimals: 0, reciprocalScale: true)
        case .tint: return makeSpec(title: L10n.text("色调"), keyPath: \.tint, unit: "")
        case .blackPoint: return makeSpec(title: L10n.text("黑场"), keyPath: \.blackPoint)
        case .whitePoint: return makeSpec(title: L10n.text("白场"), keyPath: \.whitePoint)
        case .vibrance: return makeSpec(title: L10n.text("鲜艳度"), keyPath: \.vibrance)
        case .clarity: return makeSpec(title: L10n.text("清晰度"), keyPath: \.clarity)
        case .dehaze: return makeSpec(title: L10n.text("去朦胧"), keyPath: \.dehaze)
        case .texture: return makeSpec(title: L10n.text("纹理"), keyPath: \.texture, step: 1.0, decimals: 0)
        case .contrast: return makeSpec(title: L10n.text("对比度"), keyPath: \.contrast, step: 0.001, displayRange: -100...100, displayDefault: 0, displayScale: 100, decimals: 1, displayValue: { ($0 - 1) * 100 }, modelValue: { 1 + $0 / 100 })
        case .highlights: return makeSpec(title: L10n.text("高光"), keyPath: \.highlights, step: 0.001, displayRange: -100...100, displayDefault: 0, displayScale: 100, decimals: 1, displayValue: { -$0 * 100 }, modelValue: { -$0 / 100 })
        case .shadows: return makeSpec(title: L10n.text("阴影"), keyPath: \.shadows, step: 0.001, displayRange: -100...100, displayDefault: 0, displayScale: 100, decimals: 1)
        case .toneCurve: return makeSpec(title: L10n.text("S 曲线"), keyPath: \.toneCurve, step: 0.001, displayRange: -100...100, displayDefault: 0, displayScale: 100, decimals: 1)
        case .saturation: return makeSpec(title: L10n.text("饱和度"), keyPath: \.saturation, step: 0.001, displayRange: -100...100, displayDefault: 0, displayScale: 100, decimals: 1, displayValue: { ($0 - 1) * 100 }, modelValue: { 1 + $0 / 100 })
        case .sharpening: return makeSpec(title: L10n.text("锐化"), keyPath: \.sharpening, step: 0.001, displayRange: 0...200, displayDefault: 0, displayScale: 100, decimals: 1)
        case .rawNoiseReduction: return makeSpec(title: L10n.text("RAW 降噪"), keyPath: \.rawNoiseReduction, unit: "")
        case .denoiseMode: return makeSpec(title: L10n.text("降噪"), keyPath: \.denoiseMode, unit: "")
        case .vignetteAmount: return makeSpec(title: L10n.text("暗角"), keyPath: \.vignetteAmount, unit: "")
        case .grainAmount: return makeSpec(title: L10n.text("颗粒"), keyPath: \.grainAmount, unit: "")
        }
    }
}

public enum AdjustmentKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case strength, exposure, highlights, shadows, contrast, blackPoint, whitePoint, vibrance, clarity, dehaze, texture
    case toneCurve, saturation, hsl, colorGrading, temperature, tint, noiseReduction, sharpening, vignette, grain

    public static let toolCases: [AdjustmentKind] = allCases.filter { $0 != .tint }
    public static let badgeKinds: Set<AdjustmentKind> = [.strength, .exposure, .highlights, .shadows, .contrast, .toneCurve, .saturation, .sharpening, .blackPoint, .whitePoint, .vibrance, .clarity, .dehaze, .texture]
    public var id: String { rawValue }

    private var parameter: AdjustmentParameter? {
        switch self {
        case .vignette: return .vignetteAmount; case .grain: return .grainAmount
        case .hsl, .colorGrading, .noiseReduction: return nil
        default: return AdjustmentParameter(rawValue: rawValue)
        }
    }

    public var title: String {
        switch self {
        case .toneCurve: return L10n.text("曲线"); case .colorGrading: return L10n.text("颜色分级")
        case .hsl: return "HSL"; case .temperature: return L10n.text("白平衡"); case .noiseReduction: return L10n.text("降噪")
        default: return parameter!.spec.title
        }
    }
    public var iconName: String {
        switch self {
        case .highlights: return "sun.max.fill"; case .toneCurve: return "waveform.path.ecg"
        case .saturation: return "drop"; case .colorGrading: return "paintpalette"
        case .hsl: return "slider.horizontal.3"; case .temperature: return "thermometer"
        case .tint: return "circle.hexagongrid"; case .noiseReduction: return "sparkles"
        case .vignette: return "circle.dashed"; case .grain: return "circle.dotted"
        default: return parameter!.symbol
        }
    }
    public var range: ClosedRange<Double> {
        switch self {
        case .strength: return Adjustments.lutStrengthRange
        case .exposure: return -5...5
        case .contrast, .blackPoint, .whitePoint, .vibrance, .clarity, .dehaze, .texture, .highlights, .shadows, .toneCurve, .saturation, .hsl: return -100...100
        case .colorGrading: return 0...100
        case .temperature: return Adjustments.temperatureRange
        case .tint: return Adjustments.tintRange
        case .noiseReduction: return 0...1
        case .sharpening: return 0...200
        case .vignette: return PhotoEffectsSettings.vignetteAmountRange
        case .grain: return PhotoEffectsSettings.grainAmountRange
        }
    }
    public var step: Double {
        switch self { case .strength, .noiseReduction: return 0.01; case .exposure: return 0.05; case .temperature: return 10; default: return 1 }
    }
    public var hdrKeyPath: WritableKeyPath<HDRSettings, Double>? {
        switch self {
        case .sharpening: return \.detailSettings.sharpeningPercent
        case .noiseReduction: return \.detailSettings.denoise
        default: return parameter?.hdrKeyPath
        }
    }
    public func value(from settings: Adjustments) -> Double {
        if settings.isHDREditing, let key = hdrKeyPath { return settings.hdr![keyPath: key] }
        switch self {
        case .strength: return settings.strength
        case .colorGrading: return settings.editingGradingSettings.progress * 100
        case .hsl: return settings.editingHSLSettings.progress * 100
        case .noiseReduction: return settings.waveletNoiseReduction.enabled ? 1 : 0
        case .vignette: return settings.editingEffectValue(.vignetteAmount)
        case .grain: return settings.editingEffectValue(.grainAmount)
        default:
            let spec = parameter!.spec
            return spec.displayValue(settings[keyPath: spec.keyPath])
        }
    }
    public func setValue(_ value: Double, in settings: inout Adjustments) {
        if settings.isHDREditing {
            guard let key = hdrKeyPath, var state = settings.hdr, value.isFinite else { return }
            state[keyPath: key] = value; guard state.isValid else { return }; settings.hdr = state; return
        }
        switch self {
        case .strength: settings.strength = value
        case .colorGrading: if value == 0 { settings.colorGrading = nil }
        case .hsl: if value == 0 { settings.hsl = nil }
        case .noiseReduction: settings.waveletNoiseReduction = WaveletDenoiseSettings(enabled: value > 0)
        case .vignette: settings.setExactEditingEffect(.vignetteAmount, to: value)
        case .grain: settings.setExactEditingEffect(.grainAmount, to: value)
        default:
            let spec = parameter!.spec
            settings[keyPath: spec.keyPath] = spec.modelValue(value)
        }
    }
    public var unit: String {
        switch self {
        case .strength, .contrast, .highlights, .shadows, .toneCurve, .saturation, .sharpening, .blackPoint, .whitePoint, .vibrance, .clarity, .dehaze, .texture: return "%"
        case .exposure: return "EV"; case .temperature: return "K"; default: return ""
        }
    }
    public func formatted(_ value: Double) -> String {
        let scaled = self == .strength ? value * 100 : value
        let number = scaled == 0 ? 0 : scaled
        let signed = number != 0 && self != .strength && self != .temperature
        return String(format: (signed ? "%+" : "%") + (self == .exposure ? ".2f" : ".0f"), locale: L10n.locale, number)
    }
    public func displayValue(_ value: Double) -> String { "\(formatted(value)) \(unit)".trimmingCharacters(in: .whitespaces) }
    public func badge(for value: Double) -> String? { Self.badgeKinds.contains(self) ? formatted(value) : nil }
    public func valueLabel(for value: Double) -> String {
        switch self {
        case .strength: return String(format: "%.0f%%", value * 100)
        case .exposure: return String(format: "%+.2f EV", value)
        case .contrast, .saturation, .sharpening, .blackPoint, .whitePoint, .vibrance, .clarity, .dehaze, .texture, .highlights, .shadows, .toneCurve: return String(format: "%+.0f%%", value)
        case .noiseReduction: return String(format: "%.2f", value)
        case .temperature: return String(format: "%.0fK", value)
        case .tint: return String(format: "%.0f", value)
        case .vignette, .grain: return String(format: "%+.0f", value)
        case .colorGrading: return L10n.text("颜色分级")
        case .hsl: return "HSL"
        }
    }
    public func progress(in settings: Adjustments) -> Double {
        if self == .temperature {
            let t = scalarProgress(value: AdjustmentKind.temperature.value(from: settings), baseline: Adjustments.default.temperature, range: Adjustments.temperatureRange)
            let n = scalarProgress(value: AdjustmentKind.tint.value(from: settings), baseline: Adjustments.default.tint, range: Adjustments.tintRange)
            return abs(t) >= abs(n) ? t : n
        }
        if self == .vignette || self == .grain {
            return PhotoEffectParameter.allCases.filter { $0.isVignette == (self == .vignette) }
                .map { scalarProgress(value: settings.editingEffectValue($0), baseline: $0.defaultValue, range: $0.range) }.max { abs($0) < abs($1) } ?? 0
        }
        return scalarProgress(value: value(from: settings), baseline: value(from: .default), range: range)
    }
    private func scalarProgress(value: Double, baseline: Double, range: ClosedRange<Double>) -> Double {
        let delta = value - baseline, span = delta >= 0 ? range.upperBound - baseline : baseline - range.lowerBound
        return span > 0 ? min(max(delta / span, -1), 1) : 0
    }
    public static func asShotCaption(temperature: Double, tint: Double) -> String { L10n.format("拍摄时：%.0f K · 色调 %+.0f", temperature, tint) }
    public static func asShotNote(for settings: Adjustments, cameraTemperature: Double, cameraTint: Double) -> String? {
        (settings.whiteBalanceMode == .camera && settings.masterRecipeID == nil) ? nil : asShotCaption(temperature: cameraTemperature, tint: cameraTint)
    }
    public static func resetWhiteBalance(in settings: inout Adjustments, cameraTemperature: Double?, cameraTint: Double?) {
        settings.temperature = cameraTemperature ?? Adjustments.default.temperature
        settings.tint = settings.masterRecipeID == nil ? (cameraTint ?? Adjustments.default.tint) : Adjustments.default.tint
        settings.whiteBalanceMode = .camera
    }
    public func reset(in settings: inout Adjustments) {
        switch self {
        case .vignette: settings.effectSettings.resetVignette()
        case .grain: settings.effectSettings.resetGrain()
        default: setValue(value(from: .default), in: &settings)
        }
    }
}
