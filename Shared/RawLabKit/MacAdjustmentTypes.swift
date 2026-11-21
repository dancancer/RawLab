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

    public init(temperature: Double, tint: Double) {
        self.temperature = temperature
        self.tint = tint
    }
}

public enum WhiteBalanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case asShot = "拍摄时设置", custom = "自定义"
    public var id: String { rawValue }
    public var title: String { L10n.text(rawValue) }
}

public enum ExposureMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case scene = "标准显影"
    case preview = "匹配内嵌预览"
    case sensor = "传感器基准"
    public var id: String { rawValue }
    public var title: String { L10n.text(rawValue) }
}

public enum RawNoiseReductionLevel: Double, CaseIterable, Identifiable, Sendable {
    case off = 0, light = 1, full = 2
    public var id: Double { rawValue }
    public var title: String {
        switch self {
        case .off: return L10n.text("停用")
        case .light: return L10n.text("轻度")
        case .full: return L10n.text("强度")
        }
    }
}

public enum ChromaNoiseReductionMode: Double, CaseIterable, Identifiable, Sendable {
    case off = 0, detail = 1, clean = 2
    public var id: Double { rawValue }
    public var title: String {
        switch self {
        case .off: return L10n.text("停用")
        case .detail: return L10n.text("细节优先")
        case .clean: return L10n.text("去噪优先")
        }
    }
}

public enum DenoisePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case detail, clean, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .detail: return L10n.text("细节优先")
        case .clean: return L10n.text("去噪优先")
        case .custom: return L10n.text("自定义")
        }
    }
}

public struct WaveletDenoiseSettings: Equatable, Codable, Sendable {
    public var enabled = false
    public var luma = 0.0
    public var chroma = 46.0
    public var coarse = 50.0
    public var preset = DenoisePreset.detail

    public init(enabled: Bool = false, luma: Double = 0.0, chroma: Double = 46.0, coarse: Double = 50.0, preset: DenoisePreset = .detail) {
        self.enabled = enabled
        self.luma = luma
        self.chroma = chroma
        self.coarse = coarse
        self.preset = preset
    }
}

public enum DenoiseParameter: String, CaseIterable, Identifiable, Sendable {
    case luma, chroma, coarse
    public var id: String { rawValue }
    public var shortTitle: String {
        switch self {
        case .luma: return L10n.text("降噪亮度")
        case .chroma: return L10n.text("降噪色彩")
        case .coarse: return L10n.text("降噪粗色斑")
        }
    }
    public var title: String {
        switch self {
        case .luma: return L10n.text("亮度降噪")
        case .chroma: return L10n.text("色彩降噪")
        case .coarse: return L10n.text("粗色斑抑制")
        }
    }
    public var keyPath: WritableKeyPath<WaveletDenoiseSettings, Double> {
        switch self {
        case .luma: return \.luma
        case .chroma: return \.chroma
        case .coarse: return \.coarse
        }
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
        case .effects: return [.clarity, .dehaze, .vignetteAmount, .grainAmount]
        case .lens, .geometry: return []
        }
    }
}

// 编辑导航仅属于会话，不能写入照片调整记录。
public enum EditorAdjustmentGroup: String, CaseIterable, Identifiable, Sendable {
    case looks, light, color, effects, detail, geometry, hdrRendition
    public var id: String { rawValue }
    public var title: String {
        L10n.text(["外观", "光线", "颜色", "效果", "细节", "几何与镜头", "HDR 输出与 SDR 底图"][Self.allCases.firstIndex(of: self)!])
    }
    public var tools: [EditorAdjustmentTool] {
        switch self {
        case .looks: return [.film, .recipe, .strength]
        case .light: return [.exposure, .highlights, .shadows, .blackPoint, .whitePoint, .contrast, .toneCurve]
        case .color: return [.whiteBalance, .saturation, .vibrance, .hsl, .colorGrading]
        case .effects: return [.clarity, .dehaze, .vignette, .grain]
        case .detail: return [.denoise, .sharpening]
        case .geometry: return [.geometry, .lens]
        case .hdrRendition: return [.hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation]
        }
    }
    public var defaultTool: EditorAdjustmentTool { tools[0] }
    public func isVisible(isHDREditing: Bool) -> Bool { self != .hdrRendition || isHDREditing }
    public static func visibleGroups(isHDREditing: Bool) -> [Self] {
        allCases.filter { $0.isVisible(isHDREditing: isHDREditing) }
    }
}

public enum EditorAdjustmentTool: String, CaseIterable, Identifiable, Sendable {
    case film, recipe, strength, exposure, highlights, shadows, blackPoint, whitePoint, vibrance, contrast, toneCurve
    case clarity, dehaze
    case whiteBalance, saturation, hsl, colorGrading, vignette, grain, denoise, sharpening, geometry, lens
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
        case .strength: return .strength
        case .exposure: return .exposure
        case .highlights: return .highlights
        case .shadows: return .shadows
        case .blackPoint: return .blackPoint
        case .whitePoint: return .whitePoint
        case .vibrance: return .vibrance
        case .clarity: return .clarity
        case .dehaze: return .dehaze
        case .contrast: return .contrast
        case .toneCurve: return .toneCurve
        case .whiteBalance: return .temperature
        case .saturation: return .saturation
        case .vignette: return .vignetteAmount
        case .grain: return .grainAmount
        case .denoise: return .denoiseMode
        case .sharpening: return .sharpening
        default: return nil
        }
    }
    public var title: String {
        switch self {
        case .film: return L10n.text("胶片")
        case .recipe: return L10n.text("大师配方")
        case .whiteBalance: return L10n.text("白平衡")
        case .colorGrading: return L10n.text("颜色分级")
        case .toneCurve: return L10n.text("曲线")
        case .hsl: return "HSL"
        case .geometry: return L10n.text("几何")
        case .lens: return L10n.text("镜头")
        case .hdrPeakLimit: return L10n.text("HDR 亮度上限")
        case .hdrSDRExposure: return L10n.text("SDR 底图曝光")
        case .hdrSDRContrast: return L10n.text("SDR 底图对比度")
        case .hdrSDRSaturation: return L10n.text("SDR 底图饱和度")
        default: return parameter!.spec.title
        }
    }
    public var symbol: String {
        switch self {
        case .film: return "film"
        case .recipe: return "photo.stack"
        case .colorGrading: return "paintpalette"
        case .hsl: return "slider.horizontal.3"
        case .geometry: return "crop.rotate"
        case .lens: return "viewfinder"
        case .hdrPeakLimit: return "sun.max"
        case .hdrSDRExposure: return "plusminus.circle"
        case .hdrSDRContrast: return "circle.lefthalf.filled"
        case .hdrSDRSaturation: return "drop.halffull"
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

    public init(expandedGroup: EditorAdjustmentGroup? = .looks,
                tool: EditorAdjustmentTool = .film,
                selectedHSLChannel: Int = 0,
                selectedGradingZone: ColorGradingZone = .shadows) {
        self.expandedGroup = expandedGroup
        self.tool = tool
        self.selectedHSLChannel = selectedHSLChannel
        self.selectedGradingZone = selectedGradingZone
    }

    public mutating func selectGroup(_ group: EditorAdjustmentGroup) {
        if expandedGroup == group { expandedGroup = nil }
        else { expandedGroup = group; tool = group.defaultTool }
    }
    public mutating func selectTool(_ target: EditorAdjustmentTool) { tool = target; expandedGroup = target.group }
    public mutating func normalize(isHDREditing: Bool) {
        let wasCollapsed = expandedGroup == nil
        if !tool.group.isVisible(isHDREditing: isHDREditing) {
            selectTool(.exposure)
            if wasCollapsed { expandedGroup = nil }
        } else if let group = expandedGroup, !group.isVisible(isHDREditing: isHDREditing) {
            expandedGroup = tool.group
        }
    }
    public func normalized(isHDREditing: Bool) -> Self {
        var copy = self
        copy.normalize(isHDREditing: isHDREditing)
        return copy
    }
}

public enum EditorResetScope: Equatable {
    case tool(EditorAdjustmentTool)
    case group(EditorAdjustmentGroup)
    case hslColor(Int)
    case hslAll
    case gradingZone(ColorGradingZone), allGrading
    case all
    public var usesGeometryDraft: Bool {
        switch self {
        case .group(.geometry), .tool(.geometry), .tool(.lens): return true
        default: return false
        }
    }
}

public struct MacEditorAdjustmentContext: Sendable {
    public let isRaw: Bool
    public let defaultExposureMode: ExposureMode
    public let neutralFilmID: String

    public init(isRaw: Bool, defaultExposureMode: ExposureMode, neutralFilmID: String) {
        self.isRaw = isRaw
        self.defaultExposureMode = defaultExposureMode
        self.neutralFilmID = neutralFilmID
    }
}

public enum EditorResetBlockedReason: Error, Equatable, Sendable {
    case invalidSnapshot(String)
    case invalidHSLChannel
    case missingAsShotWhiteBalance
    case unrepresentableRecipe
}

public enum EditorResetResult: Equatable {
    case unchanged
    case candidate(MacPhotoEditState)
    case blocked(EditorResetBlockedReason)
}

public enum GeometryParameter: String, CaseIterable, Identifiable, Sendable {
    case cropX, cropY, cropWidth, cropHeight, straightenDegrees
    case perspectiveHorizontal, perspectiveVertical
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cropX: return L10n.text("裁切左边")
        case .cropY: return L10n.text("裁切上边")
        case .cropWidth: return L10n.text("裁切宽度")
        case .cropHeight: return L10n.text("裁切高度")
        case .straightenDegrees: return L10n.text("拉直")
        case .perspectiveHorizontal: return L10n.text("水平透视")
        case .perspectiveVertical: return L10n.text("垂直透视")
        }
    }
    public var keyPath: WritableKeyPath<GeometrySettings, Double> {
        switch self {
        case .cropX: return \.cropX
        case .cropY: return \.cropY
        case .cropWidth: return \.cropWidth
        case .cropHeight: return \.cropHeight
        case .straightenDegrees: return \.straightenDegrees
        case .perspectiveHorizontal: return \.perspectiveHorizontal
        case .perspectiveVertical: return \.perspectiveVertical
        }
    }
    public var multiplier: Double { self == .straightenDegrees ? 1 : 100 }
    public var defaultValue: Double { GeometrySettings()[keyPath: keyPath] }
    public var unit: String {
        switch self {
        case .straightenDegrees: return "°"
        case .perspectiveHorizontal, .perspectiveVertical: return ""
        default: return "%"
        }
    }
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
    public let title: String
    public let keyPath: WritableKeyPath<Adjustments, Double>
    public let range: ClosedRange<Double>
    public var defaultValue: Double
    public let step: Double
    public let unit: String
    public var multiplier: Double
    public var decimals: Int
    public var reciprocalScale: Bool

    public init(title: String,
                keyPath: WritableKeyPath<Adjustments, Double>,
                range: ClosedRange<Double>,
                defaultValue: Double,
                step: Double,
                unit: String,
                multiplier: Double = 1.0,
                decimals: Int = 0,
                reciprocalScale: Bool = false) {
        self.title = title
        self.keyPath = keyPath
        self.range = range
        self.defaultValue = defaultValue
        self.step = step
        self.unit = unit
        self.multiplier = multiplier
        self.decimals = decimals
        self.reciprocalScale = reciprocalScale
    }

    public func position(for value: Double) -> Double {
        if reciprocalScale {
            return (1 / range.lowerBound - 1 / value) / (1 / range.lowerBound - 1 / range.upperBound)
        }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    public func value(at position: Double) -> Double {
        let position = min(1, max(0, position))
        let value = reciprocalScale ? 1 / (1 / range.lowerBound - position * (1 / range.lowerBound - 1 / range.upperBound)) :
            range.lowerBound + position * (range.upperBound - range.lowerBound)
        return min(range.upperBound, max(range.lowerBound, (value / step).rounded() * step))
    }

    public func text(_ value: Double) -> String {
        let displayed = value * multiplier
        let places = decimals == 1 && abs(displayed - displayed.rounded()) < 0.0000001 ? 0 : decimals
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, displayed == 0 ? 0 : displayed)
    }

    // 给用户看的数值：与编辑框一致，可正可负的参数带正号；"EV""K"前空一格，"%"紧跟数字
    public func display(_ value: Double) -> String {
        let number = (range.lowerBound < 0 && value * multiplier > 0 ? "+" : "") + text(value)
        return unit.isEmpty || unit == "%" ? number + unit : number + " " + unit
    }

    public func parse(_ text: String) -> Double? {
        guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, number / multiplier))
    }
    public func progress(for value: Double) -> Double {
        let origin = position(for: defaultValue)
        let offset = position(for: value) - origin
        let distance = offset < 0 ? origin : 1 - origin
        return distance > 0 ? min(1, max(-1, offset / distance)) : 0
    }
}

public enum AdjustmentParameter: String, CaseIterable, Identifiable, Sendable {
    case strength, exposure, temperature, tint, contrast, highlights, shadows, blackPoint, whitePoint, vibrance, toneCurve, saturation, sharpening, rawNoiseReduction, denoiseMode
    case vignetteAmount, grainAmount, clarity, dehaze
    public var id: String { rawValue }
    public var isWhiteBalance: Bool { self == .temperature || self == .tint }
    public var hdrKeyPath: WritableKeyPath<HDRSettings, Double>? {
        switch self {
        case .exposure: return \.exposure
        case .temperature: return \.temperature
        case .tint: return \.tint
        case .contrast: return \.contrast
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .blackPoint: return \.toneSettings.blackPoint
        case .whitePoint: return \.toneSettings.whitePoint
        case .toneCurve: return \.toneSettings.curveStrength
        case .saturation: return \.saturation
        case .vibrance: return \.colorSettings.vibrance
        case .sharpening: return \.detailSettings.sharpeningPercent
        case .clarity: return \.detailSettings.clarityPercent
        case .dehaze: return \.detailSettings.dehazePercent
        case .denoiseMode: return \.detailSettings.denoise
        default: return nil
        }
    }
    public func value(from settings: Adjustments) -> Double {
        if settings.isHDREditing, let key = hdrKeyPath { return settings.hdr![keyPath: key] }
        return settings[keyPath: spec.keyPath]
    }
    public var isPhotoEffect: Bool { self == .vignetteAmount || self == .grainAmount }
    public func spec(for settings: Adjustments) -> AdjustmentSpec {
        var value = spec
        if settings.isHDREditing && self == .denoiseMode {
            return AdjustmentSpec(title: value.title, keyPath: value.keyPath, range: 0...1,
                defaultValue: 0, step: 0.01, unit: "%", multiplier: 100)
        }
        if settings.isHDREditing && self == .exposure {
            return AdjustmentSpec(title: value.title, keyPath: value.keyPath, range: -4...4,
                defaultValue: 0, step: value.step, unit: value.unit, decimals: value.decimals)
        }
        if settings.isHDREditing { return value }
        if self == .temperature { value.defaultValue = settings.asShotWhiteBalance?.temperature ?? 6500 }
        if self == .tint { value.defaultValue = settings.masterRecipe != nil ? 0 : (settings.asShotWhiteBalance?.tint ?? 0) }
        return value
    }
    public var symbol: String {
        switch self {
        case .strength: return "camera.aperture"
        case .exposure: return "plusminus.circle"
        case .highlights: return "sun.max"
        case .shadows: return "moon"
        case .blackPoint: return "circle.fill"
        case .whitePoint: return "circle"
        case .vibrance: return "drop.fill"
        case .clarity: return "circle.dotted.circle"
        case .dehaze: return "cloud.fog"
        case .contrast: return "circle.lefthalf.filled"
        case .toneCurve: return "waveform.path"
        case .saturation: return "drop.halffull"
        case .temperature: return "thermometer.medium"
        case .tint: return "camera.filters"
        case .sharpening: return "triangle"
        case .rawNoiseReduction, .denoiseMode: return "circle.dotted"
        case .vignetteAmount: return "circle.lefthalf.filled.inverse"
        case .grainAmount: return "square.dotted"
        }
    }
    public var spec: AdjustmentSpec {
        switch self {
        case .strength: return AdjustmentSpec(title: L10n.text("强度"), keyPath: \.strength, range: 0...2, defaultValue: 1, step: 0.001, unit: "%", multiplier: 100, decimals: 1)
        case .exposure: return AdjustmentSpec(title: L10n.text("曝光"), keyPath: \.exposure, range: -5...5, defaultValue: 0, step: 0.01, unit: "EV", decimals: 2)
        case .temperature: return AdjustmentSpec(title: L10n.text("色温"), keyPath: \.temperature, range: 2000...50000, defaultValue: 6500, step: 10, unit: "K", reciprocalScale: true)
        case .tint: return AdjustmentSpec(title: L10n.text("色调"), keyPath: \.tint, range: -150...150, defaultValue: 0, step: 0.1, unit: "", decimals: 1)
        case .blackPoint: return AdjustmentSpec(title: L10n.text("黑场"), keyPath: \.blackPoint, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .whitePoint: return AdjustmentSpec(title: L10n.text("白场"), keyPath: \.whitePoint, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .vibrance: return AdjustmentSpec(title: L10n.text("鲜艳度"), keyPath: \.vibrance, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .clarity: return AdjustmentSpec(title: L10n.text("清晰度"), keyPath: \.clarity, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .dehaze: return AdjustmentSpec(title: L10n.text("去朦胧"), keyPath: \.dehaze, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .contrast: return AdjustmentSpec(title: L10n.text("对比度"), keyPath: \.contrast, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .highlights: return AdjustmentSpec(title: L10n.text("高光"), keyPath: \.highlights, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .shadows: return AdjustmentSpec(title: L10n.text("阴影"), keyPath: \.shadows, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .toneCurve: return AdjustmentSpec(title: L10n.text("S 曲线"), keyPath: \.toneCurve, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .saturation: return AdjustmentSpec(title: L10n.text("饱和度"), keyPath: \.saturation, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .sharpening: return AdjustmentSpec(title: L10n.text("锐化"), keyPath: \.sharpening, range: 0...200, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .rawNoiseReduction: return AdjustmentSpec(title: L10n.text("RAW 降噪"), keyPath: \.rawNoiseReduction, range: 0...2, defaultValue: 0, step: 1, unit: "")
        case .denoiseMode: return AdjustmentSpec(title: L10n.text("降噪"), keyPath: \.denoiseMode, range: 0...2, defaultValue: 0, step: 1, unit: "")
        case .vignetteAmount: return AdjustmentSpec(title: L10n.text("暗角"), keyPath: \.vignetteAmount, range: -100...100, defaultValue: 0, step: 0.1, unit: "", decimals: 1)
        case .grainAmount: return AdjustmentSpec(title: L10n.text("颗粒"), keyPath: \.grainAmount, range: 0...100, defaultValue: 0, step: 0.1, unit: "", decimals: 1)
        }
    }
}
