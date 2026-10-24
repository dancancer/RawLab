import Foundation

struct ProcessingIdentity: Equatable, Hashable, Codable {
    let family: String
    let version: Int
    let quality: String
    static let legacy = ProcessingIdentity(version: 1)
    static let current = ProcessingIdentity(version: 2)
    var core: sony2fuji_processing_version {
        version == 1 ? SONY2FUJI_PROCESSING_LEGACY : SONY2FUJI_PROCESSING_C5_V2
    }

    private init(version: Int) {
        family = "rawlab"
        self.version = version
        quality = "standard"
    }

    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self).allKeys
        guard fields.allSatisfy({ CodingKeys(stringValue: $0.stringValue) != nil }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unsupported processing identity field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        family = try values.decode(String.self, forKey: .family)
        version = try values.decode(Int.self, forKey: .version)
        quality = try values.decode(String.self, forKey: .quality)
        guard family == "rawlab", version == 1 || version == 2, quality == "standard" else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unsupported processing identity"))
        }
    }
}

struct WhiteBalance: Equatable, Codable {
    let temperature: Double
    let tint: Double
}

enum WhiteBalanceMode: String, CaseIterable, Identifiable, Codable {
    case asShot = "拍摄时设置", custom = "自定义"
    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
}

enum ExposureMode: String, CaseIterable, Identifiable, Codable {
    case scene = "标准显影"
    case preview = "匹配内嵌预览"
    case sensor = "传感器基准"
    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
    var core: sony2fuji_raw_exposure_mode {
        switch self {
        case .scene: return SONY2FUJI_EXPOSURE_SCENE
        case .preview: return SONY2FUJI_EXPOSURE_PREVIEW
        case .sensor: return SONY2FUJI_EXPOSURE_SENSOR
        }
    }
}

enum RawNoiseReductionLevel: Double, CaseIterable, Identifiable {
    case off = 0, light = 1, full = 2
    var id: Double { rawValue }
    var title: String {
        switch self {
        case .off: return L10n.text("停用")
        case .light: return L10n.text("轻度")
        case .full: return L10n.text("强度")
        }
    }
}

enum ChromaNoiseReductionMode: Double, CaseIterable, Identifiable {
    case off = 0, detail = 1, clean = 2
    var id: Double { rawValue }
    var title: String {
        switch self {
        case .off: return L10n.text("停用")
        case .detail: return L10n.text("细节优先")
        case .clean: return L10n.text("去噪优先")
        }
    }
}

enum DenoisePreset: String, Codable, CaseIterable, Identifiable {
    case detail, clean, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .detail: return L10n.text("细节优先")
        case .clean: return L10n.text("去噪优先")
        case .custom: return L10n.text("自定义")
        }
    }
}

struct WaveletDenoiseSettings: Equatable, Codable {
    var enabled = false
    var luma = 0.0
    var chroma = 46.0
    var coarse = 50.0
    var preset = DenoisePreset.detail
}

enum DenoiseParameter: String, CaseIterable, Identifiable {
    case luma, chroma, coarse
    var id: String { rawValue }
    var shortTitle: String {
        switch self {
        case .luma: return L10n.text("降噪亮度")
        case .chroma: return L10n.text("降噪色彩")
        case .coarse: return L10n.text("降噪粗色斑")
        }
    }
    var title: String {
        switch self {
        case .luma: return L10n.text("亮度降噪")
        case .chroma: return L10n.text("色彩降噪")
        case .coarse: return L10n.text("粗色斑抑制")
        }
    }
    var keyPath: WritableKeyPath<WaveletDenoiseSettings, Double> {
        switch self {
        case .luma: return \.luma
        case .chroma: return \.chroma
        case .coarse: return \.coarse
        }
    }
    var defaultValue: Double { WaveletDenoiseSettings()[keyPath: keyPath] }
}

struct PhotoEffectsSettings: Equatable, Codable {
    var vignetteAmount = 0.0
    var vignetteMidpoint = 50.0
    var vignetteRoundness = 0.0
    var vignetteFeather = 50.0
    var vignetteHighlights = 0.0
    var grainAmount = 0.0
    var grainSize = 25.0
    var grainRoughness = 50.0
}

enum PhotoEffectParameter: String, CaseIterable, Identifiable {
    case vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights
    case grainAmount, grainSize, grainRoughness
    var id: String { rawValue }
    var isVignette: Bool {
        switch self {
        case .grainAmount, .grainSize, .grainRoughness: return false
        default: return true
        }
    }
    var title: String {
        switch self {
        case .vignetteAmount, .grainAmount: return L10n.text("强度")
        case .vignetteMidpoint: return L10n.text("中点")
        case .vignetteRoundness: return L10n.text("圆度")
        case .vignetteFeather: return L10n.text("羽化")
        case .vignetteHighlights: return L10n.text("高光保护")
        case .grainSize: return L10n.text("大小")
        case .grainRoughness: return L10n.text("粗糙度")
        }
    }
    var keyPath: WritableKeyPath<PhotoEffectsSettings, Double> {
        switch self {
        case .vignetteAmount: return \.vignetteAmount
        case .vignetteMidpoint: return \.vignetteMidpoint
        case .vignetteRoundness: return \.vignetteRoundness
        case .vignetteFeather: return \.vignetteFeather
        case .vignetteHighlights: return \.vignetteHighlights
        case .grainAmount: return \.grainAmount
        case .grainSize: return \.grainSize
        case .grainRoughness: return \.grainRoughness
        }
    }
    var range: ClosedRange<Double> { self == .vignetteAmount || self == .vignetteRoundness ? -100...100 : 0...100 }
    var defaultValue: Double { PhotoEffectsSettings()[keyPath: keyPath] }
}

enum LensProfileMode: String, Codable, CaseIterable {
    case automatic, manual
}

struct LensCorrectionSettings: Equatable, Codable {
    var distortion = false
    var tca = false
    var autoCrop = true
    var mode = LensProfileMode.automatic
    var profileID: String?
    var isEnabled: Bool { distortion || tca }
    var coreProfileID: String {
        mode == .automatic ? "" : (profileID ?? "__rawlab_manual_selection_required__")
    }
}

struct LensCandidate: Identifiable, Equatable {
    let id: String
    let maker: String
    let model: String
    let hasDistortion: Bool
    let hasTCA: Bool
    let isMatch: Bool
    var title: String { model.localizedCaseInsensitiveContains(maker) ? model : "\(maker) \(model)" }
}

struct LensInfo: Equatable {
    let state: sony2fuji_lens_state
    let detectedLens: String
    let selectedLens: String
    let focalLength: Float
    let appliedDistortion: Bool
    let appliedTCA: Bool
    let cropScale: Float
    let candidates: [LensCandidate]
    var message: String {
        switch state {
        case SONY2FUJI_LENS_OFF: return L10n.text("镜头校正已关闭")
        case SONY2FUJI_LENS_MATCHED:
            let applied = [appliedDistortion ? L10n.text("畸变") : nil, appliedTCA ? L10n.text("横向色差") : nil].compactMap { $0 }
            return applied.isEmpty ? L10n.text("已匹配镜头") : L10n.format("已校正%@", applied.joined(separator: " / "))
        case SONY2FUJI_LENS_NO_DATABASE: return L10n.text("镜头数据库不可用")
        case SONY2FUJI_LENS_NO_CAMERA: return L10n.text("未找到机身或传感器尺寸信息")
        case SONY2FUJI_LENS_AMBIGUOUS: return L10n.text("有多个匹配镜头，请手动选择")
        case SONY2FUJI_LENS_NO_CALIBRATION: return L10n.text("此镜头没有所选校正的标定数据")
        case SONY2FUJI_LENS_MISSING_FOCAL_LENGTH: return L10n.text("照片缺少有效焦距，未应用校正")
        case SONY2FUJI_LENS_EMBEDDED_GEOMETRY: return L10n.text("DNG 已执行内嵌 Stage3 处理，未叠加校正")
        case SONY2FUJI_LENS_UNSUPPORTED_INPUT: return L10n.text("此输入不支持镜头校正")
        default: return L10n.text("未匹配镜头，请手动选择")
        }
    }
}

enum AdjustmentGroup: String, CaseIterable, Identifiable {
    case film = "胶片模拟", input = "输入调整", tone = "明暗", color = "色彩", detail = "细节", effects = "效果", lens = "镜头校正", geometry = "几何编辑"
    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
    var parameters: [AdjustmentParameter] {
        switch self {
        case .film: return [.strength]
        case .input: return [.exposure, .temperature, .tint]
        case .tone: return [.contrast, .highlights, .shadows, .blackPoint, .whitePoint, .toneCurve]
        case .color: return [.saturation, .vibrance]
        case .detail: return [.denoiseMode, .sharpening]
        case .effects: return [.vignetteAmount, .grainAmount]
        case .lens, .geometry: return []
        }
    }
}

// 编辑导航仅属于会话，不能写入照片调整记录。
enum EditorAdjustmentGroup: String, CaseIterable, Identifiable {
    case looks, light, color, effects, detail, geometry
    var id: String { rawValue }
    var title: String {
        L10n.text(["外观", "光线", "颜色", "效果", "细节", "几何与镜头"][Self.allCases.firstIndex(of: self)!])
    }
    var tools: [EditorAdjustmentTool] {
        switch self {
        case .looks: return [.film, .recipe, .strength]
        case .light: return [.exposure, .highlights, .shadows, .blackPoint, .whitePoint, .contrast, .toneCurve]
        case .color: return [.whiteBalance, .saturation, .vibrance, .hsl, .colorGrading]
        case .effects: return [.vignette, .grain]
        case .detail: return [.denoise, .sharpening]
        case .geometry: return [.geometry, .lens]
        }
    }
    var defaultTool: EditorAdjustmentTool { tools[0] }
}

enum EditorAdjustmentTool: String, CaseIterable, Identifiable {
    case film, recipe, strength, exposure, highlights, shadows, blackPoint, whitePoint, vibrance, contrast, toneCurve
    case whiteBalance, saturation, hsl, colorGrading, vignette, grain, denoise, sharpening, geometry, lens
    var id: String { rawValue }
    var group: EditorAdjustmentGroup { EditorAdjustmentGroup.allCases.first { $0.tools.contains(self) }! }
    var parameter: AdjustmentParameter? {
        switch self {
        case .strength: return .strength
        case .exposure: return .exposure
        case .highlights: return .highlights
        case .shadows: return .shadows
        case .blackPoint: return .blackPoint
        case .whitePoint: return .whitePoint
        case .vibrance: return .vibrance
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
    var title: String {
        switch self {
        case .film: return L10n.text("胶片")
        case .recipe: return L10n.text("大师配方")
        case .whiteBalance: return L10n.text("白平衡")
        case .colorGrading: return L10n.text("颜色分级")
        case .toneCurve: return L10n.text("曲线")
        case .hsl: return "HSL"
        case .geometry: return L10n.text("几何")
        case .lens: return L10n.text("镜头")
        default: return parameter!.spec.title
        }
    }
    var symbol: String {
        switch self {
        case .film: return "film"
        case .recipe: return "photo.stack"
        case .colorGrading: return "paintpalette"
        case .hsl: return "slider.horizontal.3"
        case .geometry: return "crop.rotate"
        case .lens: return "viewfinder"
        default: return parameter!.symbol
        }
    }
    var usesGeometryDraft: Bool { self == .geometry || self == .lens }
}

struct EditorAdjustmentNavigation: Equatable {
    var expandedGroup: EditorAdjustmentGroup? = .looks
    var tool: EditorAdjustmentTool = .film
    var selectedHSLChannel = 0
    var selectedGradingZone: ColorGradingZone = .shadows
    mutating func selectGroup(_ group: EditorAdjustmentGroup) {
        if expandedGroup == group { expandedGroup = nil }
        else { expandedGroup = group; tool = group.defaultTool }
    }
    mutating func selectTool(_ target: EditorAdjustmentTool) { tool = target; expandedGroup = target.group }
}

enum EditorResetScope: Equatable {
    case tool(EditorAdjustmentTool)
    case group(EditorAdjustmentGroup)
    case hslColor(Int)
    case hslAll
    case gradingZone(ColorGradingZone), allGrading
    case all
    var usesGeometryDraft: Bool {
        switch self {
        case .group(.geometry), .tool(.geometry), .tool(.lens): return true
        default: return false
        }
    }
}

struct EditorAdjustmentContext {
    let isRaw: Bool
    let defaultExposureMode: ExposureMode
    let neutralFilmID: String
}

enum EditorResetBlockedReason: Error, Equatable {
    case invalidSnapshot(String)
    case invalidHSLChannel
    case missingAsShotWhiteBalance
    case unrepresentableRecipe
}

enum EditorResetResult: Equatable {
    case unchanged
    case candidate(PhotoEditState)
    case blocked(EditorResetBlockedReason)
}

enum GeometryParameter: String, CaseIterable, Identifiable {
    case cropX, cropY, cropWidth, cropHeight, straightenDegrees
    case perspectiveHorizontal, perspectiveVertical
    var id: String { rawValue }
    var title: String {
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
    var keyPath: WritableKeyPath<GeometrySettings, Double> {
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
    var multiplier: Double { self == .straightenDegrees ? 1 : 100 }
    var defaultValue: Double { GeometrySettings()[keyPath: keyPath] }
    var unit: String {
        switch self {
        case .straightenDegrees: return "°"
        case .perspectiveHorizontal, .perspectiveVertical: return ""
        default: return "%"
        }
    }
    func range(for state: GeometrySettings) -> ClosedRange<Double> {
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

struct AdjustmentSpec {
    let title: String
    let keyPath: WritableKeyPath<Adjustments, Double>
    let range: ClosedRange<Double>
    var defaultValue: Double
    let step: Double
    let unit: String
    var multiplier = 1.0
    var decimals = 0
    var reciprocalScale = false

    func position(for value: Double) -> Double {
        if reciprocalScale {
            return (1 / range.lowerBound - 1 / value) / (1 / range.lowerBound - 1 / range.upperBound)
        }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    func value(at position: Double) -> Double {
        let position = min(1, max(0, position))
        let value = reciprocalScale ? 1 / (1 / range.lowerBound - position * (1 / range.lowerBound - 1 / range.upperBound)) :
            range.lowerBound + position * (range.upperBound - range.lowerBound)
        return min(range.upperBound, max(range.lowerBound, (value / step).rounded() * step))
    }

    func text(_ value: Double) -> String {
        let displayed = value * multiplier
        let places = decimals == 1 && abs(displayed - displayed.rounded()) < 0.0000001 ? 0 : decimals
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, displayed == 0 ? 0 : displayed)
    }

    // 给用户看的数值：与编辑框一致，可正可负的参数带正号；"EV""K"前空一格，"%"紧跟数字
    func display(_ value: Double) -> String {
        let number = (range.lowerBound < 0 && value * multiplier > 0 ? "+" : "") + text(value)
        return unit.isEmpty || unit == "%" ? number + unit : number + " " + unit
    }

    func parse(_ text: String) -> Double? {
        guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, number / multiplier))
    }
    func progress(for value: Double) -> Double {
        let origin = position(for: defaultValue)
        let offset = position(for: value) - origin
        let distance = offset < 0 ? origin : 1 - origin
        return distance > 0 ? min(1, max(-1, offset / distance)) : 0
    }
}

enum AdjustmentParameter: String, CaseIterable, Identifiable {
    case strength, exposure, temperature, tint, contrast, highlights, shadows, blackPoint, whitePoint, vibrance, toneCurve, saturation, sharpening, rawNoiseReduction, denoiseMode
    case vignetteAmount, grainAmount
    var id: String { rawValue }
    var isWhiteBalance: Bool { self == .temperature || self == .tint }
    var isPhotoEffect: Bool { self == .vignetteAmount || self == .grainAmount }
    func spec(for settings: Adjustments) -> AdjustmentSpec {
        var value = spec
        if self == .temperature { value.defaultValue = settings.asShotWhiteBalance?.temperature ?? 6500 }
        if self == .tint { value.defaultValue = settings.masterRecipe != nil ? 0 : (settings.asShotWhiteBalance?.tint ?? 0) }
        return value
    }
    static let photoTools: [Self] = [.exposure, .highlights, .shadows, .contrast, .toneCurve,
                                    .saturation, .temperature, .denoiseMode, .sharpening, .vignetteAmount, .grainAmount]
    var symbol: String {
        switch self {
        case .strength: return "camera.aperture"
        case .exposure: return "plusminus.circle"
        case .highlights: return "sun.max"
        case .shadows: return "moon"
        case .blackPoint: return "circle.fill"
        case .whitePoint: return "circle"
        case .vibrance: return "drop.fill"
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
    var spec: AdjustmentSpec {
        switch self {
        case .strength: return AdjustmentSpec(title: L10n.text("强度"), keyPath: \.strength, range: 0...2, defaultValue: 1, step: 0.001, unit: "%", multiplier: 100, decimals: 1)
        case .exposure: return AdjustmentSpec(title: L10n.text("曝光"), keyPath: \.exposure, range: -4...4, defaultValue: 0, step: 0.01, unit: "EV", decimals: 2)
        case .temperature: return AdjustmentSpec(title: L10n.text("色温"), keyPath: \.temperature, range: 2000...50000, defaultValue: 6500, step: 10, unit: "K", reciprocalScale: true)
        case .tint: return AdjustmentSpec(title: L10n.text("色调"), keyPath: \.tint, range: -150...150, defaultValue: 0, step: 0.1, unit: "", decimals: 1)
        case .blackPoint: return AdjustmentSpec(title: L10n.text("黑场"), keyPath: \.blackPoint, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .whitePoint: return AdjustmentSpec(title: L10n.text("白场"), keyPath: \.whitePoint, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
        case .vibrance: return AdjustmentSpec(title: L10n.text("鲜艳度"), keyPath: \.vibrance, range: -100...100, defaultValue: 0, step: 0.1, unit: "%", decimals: 1)
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
