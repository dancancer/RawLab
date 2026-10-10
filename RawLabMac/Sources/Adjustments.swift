import Foundation

struct WhiteBalance: Equatable, Codable {
    let temperature: Double
    let tint: Double
}

enum WhiteBalanceMode: String, CaseIterable, Identifiable, Codable {
    case asShot = "拍摄时设置", custom = "自定义"
    var id: String { rawValue }
}

enum RawNoiseReductionLevel: Double, CaseIterable, Identifiable {
    case off = 0, light = 1, full = 2
    var id: Double { rawValue }
    var title: String {
        switch self {
        case .off: return "关闭"
        case .light: return "轻度"
        case .full: return "强度"
        }
    }
}

enum ChromaNoiseReductionMode: Double, CaseIterable, Identifiable {
    case off = 0, detail = 1, clean = 2
    var id: Double { rawValue }
    var title: String {
        switch self {
        case .off: return "关闭"
        case .detail: return "细节优先"
        case .clean: return "去噪优先"
        }
    }
}

enum DenoisePreset: String, Codable, CaseIterable, Identifiable {
    case detail, clean, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .detail: return "细节优先"
        case .clean: return "去噪优先"
        case .custom: return "自定义"
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
    var title: String {
        switch self {
        case .luma: return "亮度降噪"
        case .chroma: return "色彩降噪"
        case .coarse: return "粗色斑抑制"
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
        case .vignetteAmount, .grainAmount: return "强度"
        case .vignetteMidpoint: return "中点"
        case .vignetteRoundness: return "圆度"
        case .vignetteFeather: return "羽化"
        case .vignetteHighlights: return "高光保护"
        case .grainSize: return "大小"
        case .grainRoughness: return "粗糙度"
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

struct Adjustments: Equatable, Codable {
    var exposureMode = ExposureMode.scene
    var exposure = 0.0
    var temperature = 6500.0
    var tint = 0.0
    var whiteBalanceMode = WhiteBalanceMode.asShot
    private(set) var asShotWhiteBalance: WhiteBalance?
    var strength = 1.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var toneCurve = 0.0
    var saturation = 0.0
    var sharpening = 0.0
    var rawNoiseReduction = 0.0
    // 缺少此字段的旧记录继续按 FBDD 解释，不静默切换算法。
    var chromaNoiseReduction: Double?
    // nil 保留旧算法语义，显式启用或选择预设后才迁移。
    var waveletNoiseReduction: WaveletDenoiseSettings?
    var photoEffects: PhotoEffectsSettings?
    private(set) var supportsRawNoiseReduction = false

    var effectSettings: PhotoEffectsSettings { photoEffects ?? PhotoEffectsSettings() }
    var vignetteAmount: Double {
        get { effectSettings.vignetteAmount }
        set { setEffect(.vignetteAmount, to: newValue) }
    }
    var grainAmount: Double {
        get { effectSettings.grainAmount }
        set { setEffect(.grainAmount, to: newValue) }
    }

    mutating func setEffect(_ parameter: PhotoEffectParameter, to value: Double) {
        guard value.isFinite else { return }
        var state = effectSettings
        state[keyPath: parameter.keyPath] = min(parameter.range.upperBound, max(parameter.range.lowerBound, value.rounded()))
        photoEffects = state == PhotoEffectsSettings() ? nil : state
    }

    mutating func resetEffect(_ tool: AdjustmentParameter) {
        for parameter in PhotoEffectParameter.allCases where parameter.isVignette == (tool == .vignetteAmount) {
            setEffect(parameter, to: parameter.defaultValue)
        }
    }

    func isEffectDefault(_ tool: AdjustmentParameter) -> Bool {
        PhotoEffectParameter.allCases.filter { $0.isVignette == (tool == .vignetteAmount) }
            .allSatisfy { effectSettings[keyPath: $0.keyPath] == $0.defaultValue }
    }

    var photoEffectsConfig: sony2fuji_photo_effects_config {
        let state = effectSettings
        return sony2fuji_photo_effects_config(
            version: UInt32(SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION),
            struct_size: UInt32(MemoryLayout<sony2fuji_photo_effects_config>.size),
            vignette_amount: Float(state.vignetteAmount), vignette_midpoint: Float(state.vignetteMidpoint),
            vignette_roundness: Float(state.vignetteRoundness), vignette_feather: Float(state.vignetteFeather),
            vignette_highlights: Float(state.vignetteHighlights), grain_amount: Float(state.grainAmount),
            grain_size: Float(state.grainSize), grain_roughness: Float(state.grainRoughness))
    }

    var aiBaseline: Self {
        var value = self
        value.strength = 1
        value.contrast = 0; value.highlights = 0; value.shadows = 0
        value.toneCurve = 0; value.saturation = 0
        return value
    }

    var waveletSettings: WaveletDenoiseSettings { waveletNoiseReduction ?? WaveletDenoiseSettings() }
    var hasLegacyDenoise: Bool { waveletNoiseReduction == nil && denoiseMode > 0 }
    var isDenoiseEnabled: Bool { waveletNoiseReduction?.enabled ?? (denoiseMode > 0) }
    var denoiseSummary: String {
        if let settings = waveletNoiseReduction {
            return settings.enabled ? settings.preset.title : "关闭"
        }
        if denoiseMode == 0 { return "关闭" }
        if denoiseMode == 3 { return "旧版 FBDD" }
        return "旧版：\(ChromaNoiseReductionMode(rawValue: denoiseMode)?.title ?? "色度降噪")"
    }

    mutating func setDenoiseEnabled(_ enabled: Bool) {
        var state = waveletSettings
        state.enabled = enabled
        waveletNoiseReduction = state
        rawNoiseReduction = 0
        chromaNoiseReduction = nil
    }

    mutating func applyDenoisePreset(_ preset: DenoisePreset) {
        guard preset != .custom else { return }
        var state = WaveletDenoiseSettings()
        state.enabled = true
        state.preset = preset
        if preset == .clean { state.luma = 10; state.chroma = 72; state.coarse = 100 }
        waveletNoiseReduction = state
        rawNoiseReduction = 0
        chromaNoiseReduction = nil
    }

    mutating func setDenoiseParameter(_ parameter: DenoiseParameter, to value: Double) {
        guard value.isFinite else { return }
        var state = waveletSettings
        let value = min(100, max(0, value.rounded()))
        guard state[keyPath: parameter.keyPath] != value else { return }
        state[keyPath: parameter.keyPath] = value
        state.preset = .custom
        waveletNoiseReduction = state
    }

    var denoiseMode: Double {
        get { chromaNoiseReduction ?? (rawNoiseReduction > 0 ? 3 : 0) }
        set {
            guard ChromaNoiseReductionMode(rawValue: newValue) != nil else { return }
            waveletNoiseReduction = nil
            chromaNoiseReduction = newValue == 0 ? nil : newValue
            rawNoiseReduction = 0
        }
    }

    func apply(to request: inout sony2fuji_request) {
        request.exposure_ev = Float(exposure)
        request.brightness = 1
        let cameraWB = whiteBalanceMode == .asShot ||
            (temperature == asShotWhiteBalance?.temperature && tint == asShotWhiteBalance?.tint)
        request.wb_mode = cameraWB ? SONY2FUJI_WB_CAMERA : SONY2FUJI_WB_TEMPERATURE
        request.temperature = cameraWB ? 6500 : Float(temperature)
        request.tint = cameraWB ? 0 : Float(tint)
        request.contrast = Float(1 + contrast / 100)
        request.saturation = Float(1 + saturation / 100)
        // The core's positive highlight value compresses light; UI positive brightens.
        request.highlights = Float(-highlights / 100)
        request.shadows = Float(shadows / 100)
        request.tone_curve = Float(toneCurve / 100)
        request.sharpening = Float(sharpening / 100)
    }

    mutating func reset(_ group: AdjustmentGroup) {
        for parameter in group.parameters {
            set(parameter, to: parameter.spec(for: self).defaultValue)
        }
        if group == .input { exposureMode = .scene; resetWhiteBalance() }
        if group == .effects { photoEffects = nil }
    }

    func isDefault(_ group: AdjustmentGroup) -> Bool {
        group.parameters.allSatisfy { self[keyPath: $0.spec.keyPath] == $0.spec(for: self).defaultValue }
            && (group != .input || exposureMode == .scene)
            && (group != .detail || !isDenoiseEnabled)
            && (group != .effects || effectSettings == PhotoEffectsSettings())
    }

    mutating func resolveWhiteBalance(_ camera: WhiteBalance?) {
        asShotWhiteBalance = camera
        if whiteBalanceMode == .asShot { resetWhiteBalance() }
    }

    mutating func resetWhiteBalance() {
        temperature = asShotWhiteBalance?.temperature ?? 6500
        tint = asShotWhiteBalance?.tint ?? 0
        whiteBalanceMode = .asShot
    }

    mutating func resolveRawNoiseReductionSupport(_ supported: Bool) {
        supportsRawNoiseReduction = supported
        if !supported { rawNoiseReduction = 0 }
    }

    mutating func set(_ parameter: AdjustmentParameter, to value: Double) {
        self[keyPath: parameter.spec.keyPath] = value
        if parameter.isWhiteBalance {
            whiteBalanceMode = temperature == asShotWhiteBalance?.temperature && tint == asShotWhiteBalance?.tint ? .asShot : .custom
        }
    }

    mutating func resetAll() {
        let camera = asShotWhiteBalance
        let noiseReductionSupport = supportsRawNoiseReduction
        self = Adjustments()
        resolveWhiteBalance(camera)
        resolveRawNoiseReductionSupport(noiseReductionSupport)
    }

    var isDefault: Bool { AdjustmentGroup.allCases.allSatisfy { isDefault($0) } }
}

enum AdjustmentGroup: String, CaseIterable, Identifiable {
    case film = "胶片模拟", input = "输入调整", tone = "明暗", color = "色彩", detail = "细节", effects = "效果"
    var id: String { rawValue }
    var parameters: [AdjustmentParameter] {
        switch self {
        case .film: return [.strength]
        case .input: return [.exposure, .temperature, .tint]
        case .tone: return [.contrast, .highlights, .shadows, .toneCurve]
        case .color: return [.saturation]
        case .detail: return [.denoiseMode, .sharpening]
        case .effects: return [.vignetteAmount, .grainAmount]
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
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, value * multiplier)
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
    case strength, exposure, temperature, tint, contrast, highlights, shadows, toneCurve, saturation, sharpening, rawNoiseReduction, denoiseMode
    case vignetteAmount, grainAmount
    var id: String { rawValue }
    var isWhiteBalance: Bool { self == .temperature || self == .tint }
    var isPhotoEffect: Bool { self == .vignetteAmount || self == .grainAmount }
    func spec(for settings: Adjustments) -> AdjustmentSpec {
        var value = spec
        if self == .temperature { value.defaultValue = settings.asShotWhiteBalance?.temperature ?? 6500 }
        if self == .tint { value.defaultValue = settings.asShotWhiteBalance?.tint ?? 0 }
        return value
    }
    static let photoTools: [Self] = [.exposure, .highlights, .shadows, .contrast, .toneCurve,
                                    .saturation, .temperature, .tint, .denoiseMode, .sharpening, .vignetteAmount, .grainAmount]
    var symbol: String {
        switch self {
        case .strength: return "camera.aperture"
        case .exposure: return "plusminus.circle"
        case .highlights: return "sun.max"
        case .shadows: return "moon"
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
        case .strength: return AdjustmentSpec(title: "强度", keyPath: \.strength, range: 0...2, defaultValue: 1, step: 0.01, unit: "%", multiplier: 100)
        case .exposure: return AdjustmentSpec(title: "曝光", keyPath: \.exposure, range: -4...4, defaultValue: 0, step: 0.05, unit: "EV", decimals: 2)
        case .temperature: return AdjustmentSpec(title: "色温", keyPath: \.temperature, range: 2000...50000, defaultValue: 6500, step: 10, unit: "K", reciprocalScale: true)
        case .tint: return AdjustmentSpec(title: "色调", keyPath: \.tint, range: -150...150, defaultValue: 0, step: 1, unit: "")
        case .contrast: return AdjustmentSpec(title: "对比度", keyPath: \.contrast, range: -100...100, defaultValue: 0, step: 1, unit: "%")
        case .highlights: return AdjustmentSpec(title: "高光", keyPath: \.highlights, range: -100...100, defaultValue: 0, step: 1, unit: "%")
        case .shadows: return AdjustmentSpec(title: "阴影", keyPath: \.shadows, range: -100...100, defaultValue: 0, step: 1, unit: "%")
        case .toneCurve: return AdjustmentSpec(title: "S 曲线", keyPath: \.toneCurve, range: -100...100, defaultValue: 0, step: 1, unit: "%")
        case .saturation: return AdjustmentSpec(title: "饱和度", keyPath: \.saturation, range: -100...100, defaultValue: 0, step: 1, unit: "%")
        case .sharpening: return AdjustmentSpec(title: "锐化", keyPath: \.sharpening, range: 0...200, defaultValue: 0, step: 1, unit: "%")
        case .rawNoiseReduction: return AdjustmentSpec(title: "RAW 降噪", keyPath: \.rawNoiseReduction, range: 0...2, defaultValue: 0, step: 1, unit: "")
        case .denoiseMode: return AdjustmentSpec(title: "降噪", keyPath: \.denoiseMode, range: 0...2, defaultValue: 0, step: 1, unit: "")
        case .vignetteAmount: return AdjustmentSpec(title: "暗角", keyPath: \.vignetteAmount, range: -100...100, defaultValue: 0, step: 1, unit: "")
        case .grainAmount: return AdjustmentSpec(title: "颗粒", keyPath: \.grainAmount, range: 0...100, defaultValue: 0, step: 1, unit: "")
        }
    }
}

struct PhotoViewport: Equatable {
    private(set) var magnification: CGFloat = 1
    private(set) var pixelMode = false
    mutating func fit() { self = PhotoViewport() }
    mutating func actualPixels() { magnification = 1; pixelMode = true }
    mutating func toggleActualPixels() {
        if pixelMode || magnification != 1 { fit() } else { actualPixels() }
    }
    mutating func zoom(by multiplier: CGFloat) {
        magnification = min(16, max(0.1, magnification * multiplier))
    }
    func factor(fit: CGFloat, displayScale: CGFloat, sourceWidth: CGFloat = 1, renderedWidth: CGFloat = 1) -> CGFloat {
        let pixelFactor = sourceWidth / max(1, renderedWidth) / max(1, displayScale)
        return (pixelMode ? pixelFactor : fit) * magnification
    }
}

struct PhotoEditState: Codable, Equatable {
    var settings: Adjustments
    var filmID: String
}

struct PhotoEditSession {
    private var edits: [URL: PhotoEditState] = [:]
    mutating func save(_ url: URL, settings: Adjustments, filmID: String) {
        edits[url.standardizedFileURL] = PhotoEditState(settings: settings, filmID: filmID)
    }
    func state(for url: URL, defaultFilmID: String) -> PhotoEditState {
        edits[url.standardizedFileURL] ?? PhotoEditState(settings: Adjustments(), filmID: defaultFilmID)
    }
}
