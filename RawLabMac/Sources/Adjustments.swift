import Foundation

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

struct Adjustments: Equatable, Codable {
    var exposureMode = ExposureMode.preview
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
    var hsl: HSLSettings?
    var lensCorrection: LensCorrectionSettings?
    var geometry: GeometrySettings?
    private(set) var supportsRawNoiseReduction = false
    var masterRecipeID: String? = nil
    private var masterRecipeSettingsVersion: Int? = 3

    var masterRecipe: MasterRecipe? { MasterRecipe.recipe(for: masterRecipeID) }
    var effectSettings: PhotoEffectsSettings { photoEffects ?? PhotoEffectsSettings() }
    var hslSettings: HSLSettings { hsl ?? HSLSettings() }
    var renderHSLSettings: HSLSettings {
        // 旧编辑及冻结批量保留独立 HSL；重新应用预设后才采用整体强度。
        let scalesHSL = masterRecipe != nil && (masterRecipeSettingsVersion ?? 2) >= 3
        return hslSettings.scaled(by: scalesHSL ? strength : 1)
    }
    mutating func setHSL(_ axis: HSLAxis, channel: Int, value: Double) {
        var state = hslSettings
        state.set(axis, channel: channel, value: value)
        hsl = state.isIdentity ? nil : state
    }
    var lensSettings: LensCorrectionSettings { lensCorrection ?? LensCorrectionSettings() }
    var geometrySettings: GeometrySettings { geometry ?? GeometrySettings() }

    mutating func setGeometry(_ parameter: GeometryParameter, to value: Double) {
        guard value.isFinite else { return }
        var state = geometrySettings
        let range = parameter.range(for: state)
        state[keyPath: parameter.keyPath] = min(range.upperBound, max(range.lowerBound, value))
        geometry = state.isIdentity ? nil : state
    }

    mutating func rotateGeometry(clockwise: Bool) {
        var state = geometrySettings
        state.quarterTurns = (state.quarterTurns + (clockwise ? 1 : 3)) % 4
        geometry = state.isIdentity ? nil : state
    }

    mutating func flipGeometry(horizontal: Bool) {
        var state = geometrySettings
        if horizontal { state.flipHorizontal.toggle() } else { state.flipVertical.toggle() }
        geometry = state.isIdentity ? nil : state
    }

    // Compare the color edit on the same geometric canvas without changing the
    // immutable original cached by EditorModel.
    var neutralGeometrySettings: Adjustments {
        var neutral = Adjustments()
        neutral.geometry = geometry
        neutral.lensCorrection = lensCorrection
        return neutral
    }
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
        state[keyPath: parameter.keyPath] = min(parameter.range.upperBound, max(parameter.range.lowerBound, (value * 10).rounded() / 10))
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

    var waveletSettings: WaveletDenoiseSettings { waveletNoiseReduction ?? WaveletDenoiseSettings() }
    var hasLegacyDenoise: Bool { waveletNoiseReduction == nil && denoiseMode > 0 }
    var isDenoiseEnabled: Bool { waveletNoiseReduction?.enabled ?? (denoiseMode > 0) }
    var denoiseSummary: String {
        if let settings = waveletNoiseReduction {
            return settings.enabled ? settings.preset.title : L10n.text("停用")
        }
        if denoiseMode == 0 { return L10n.text("停用") }
        if denoiseMode == 3 { return L10n.text("旧版 FBDD") }
        return L10n.format("旧版：%@", String(describing: ChromaNoiseReductionMode(rawValue: denoiseMode)?.title ?? L10n.text("色度降噪")))
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
        let value = min(100, max(0, (value * 10).rounded() / 10))
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

    var usesAsShotWhiteBalance: Bool {
        whiteBalanceMode == .asShot ||
            (masterRecipe == nil && temperature == asShotWhiteBalance?.temperature && tint == asShotWhiteBalance?.tint)
    }

    mutating func applyMasterRecipe(_ recipe: MasterRecipe) {
        masterRecipeID = recipe.id
        masterRecipeSettingsVersion = 3
        strength = 1
        exposure = recipe.exposureDelta
        shadows = recipe.shadowsDelta
        highlights = recipe.highlightsDelta
        contrast = recipe.contrastDelta
        saturation = recipe.saturationDelta
        tint = recipe.tintDelta
        hsl = recipe.hsl.isIdentity ? nil : recipe.hsl
    }

    mutating func clearMasterRecipe() {
        masterRecipeSettingsVersion = 3
        guard masterRecipe != nil else { masterRecipeID = nil; return }
        let cameraWB = usesAsShotWhiteBalance
        let offset = tint
        masterRecipeID = nil
        if cameraWB && (offset == 0 || asShotWhiteBalance == nil) {
            resetWhiteBalance()
        } else {
            tint = min(150, max(-150, (asShotWhiteBalance?.tint ?? 0) + offset))
            whiteBalanceMode = .custom
        }
    }

    func apply(to request: inout sony2fuji_request) {
        let recipeActive = masterRecipe != nil
        let scale = recipeActive ? strength : 1
        let tintOffset = recipeActive ? tint * scale : 0
        request.exposure_ev = Float(exposure * scale)
        request.brightness = 1
        let cameraWB = usesAsShotWhiteBalance
        let effectiveTemp = cameraWB ? (asShotWhiteBalance?.temperature ?? 6500) : temperature
        let effectiveTint = recipeActive ? (asShotWhiteBalance?.tint ?? 0) + tintOffset : tint
        let temperatureWB = !cameraWB || tintOffset != 0
        request.wb_mode = temperatureWB ? SONY2FUJI_WB_TEMPERATURE : SONY2FUJI_WB_CAMERA
        request.temperature = temperatureWB ? Float(effectiveTemp) : 6500
        request.tint = temperatureWB ? Float(recipeActive ? min(150, max(-150, effectiveTint)) : effectiveTint) : 0
        request.contrast = Float(1 + contrast * scale / 100)
        request.saturation = Float(1 + saturation * scale / 100)
        // The core's positive highlight value compresses light; UI positive brightens.
        request.highlights = Float(-highlights * scale / 100)
        request.shadows = Float(shadows * scale / 100)
        request.tone_curve = Float(toneCurve / 100)
        request.sharpening = Float(sharpening / 100)
    }

    mutating func reset(_ group: AdjustmentGroup) {
        for parameter in group.parameters {
            set(parameter, to: parameter.spec(for: self).defaultValue)
        }
        if group == .film { clearMasterRecipe() }
        if group == .input { exposureMode = .preview; resetWhiteBalance() }
        if group == .color { hsl = nil }
        if group == .effects { photoEffects = nil }
        if group == .lens { lensCorrection = nil }
        if group == .geometry { geometry = nil }
    }

    func isDefault(_ group: AdjustmentGroup) -> Bool {
        group.parameters.allSatisfy { self[keyPath: $0.spec.keyPath] == $0.spec(for: self).defaultValue }
            && (group != .input || exposureMode == .preview)
            && (group != .color || hslSettings.isIdentity)
            && (group != .detail || !isDenoiseEnabled)
            && (group != .effects || effectSettings == PhotoEffectsSettings())
            && (group != .film || masterRecipeID == nil)
            && (group != .lens || lensSettings == LensCorrectionSettings())
            && (group != .geometry || geometrySettings.isIdentity)
    }

    mutating func resolveWhiteBalance(_ camera: WhiteBalance?) {
        asShotWhiteBalance = camera
        if whiteBalanceMode == .asShot {
            if masterRecipe != nil { temperature = camera?.temperature ?? 6500 }
            else { resetWhiteBalance() }
        }
    }

    mutating func resetWhiteBalance() {
        temperature = asShotWhiteBalance?.temperature ?? 6500
        tint = masterRecipe != nil ? 0 : (asShotWhiteBalance?.tint ?? 0)
        whiteBalanceMode = .asShot
    }

    mutating func resolveRawNoiseReductionSupport(_ supported: Bool) {
        supportsRawNoiseReduction = supported
        if !supported { rawNoiseReduction = 0 }
    }

    mutating func set(_ parameter: AdjustmentParameter, to value: Double) {
        self[keyPath: parameter.spec.keyPath] = value
        if parameter.isWhiteBalance {
            if masterRecipe != nil {
                if parameter == .temperature {
                    whiteBalanceMode = temperature == asShotWhiteBalance?.temperature ? .asShot : .custom
                }
                return
            }
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

extension Adjustments {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exposureMode = try values.decodeIfPresent(ExposureMode.self, forKey: .exposureMode) ?? .scene
        exposure = try values.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 6500
        tint = try values.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        whiteBalanceMode = try values.decodeIfPresent(WhiteBalanceMode.self, forKey: .whiteBalanceMode) ?? .asShot
        asShotWhiteBalance = try values.decodeIfPresent(WhiteBalance.self, forKey: .asShotWhiteBalance)
        strength = try values.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try values.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try values.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        toneCurve = try values.decodeIfPresent(Double.self, forKey: .toneCurve) ?? 0
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        sharpening = try values.decodeIfPresent(Double.self, forKey: .sharpening) ?? 0
        rawNoiseReduction = try values.decodeIfPresent(Double.self, forKey: .rawNoiseReduction) ?? 0
        chromaNoiseReduction = try values.decodeIfPresent(Double.self, forKey: .chromaNoiseReduction)
        waveletNoiseReduction = try values.decodeIfPresent(WaveletDenoiseSettings.self, forKey: .waveletNoiseReduction)
        photoEffects = try values.decodeIfPresent(PhotoEffectsSettings.self, forKey: .photoEffects)
        hsl = try values.decodeIfPresent(HSLSettings.self, forKey: .hsl)
        lensCorrection = try values.decodeIfPresent(LensCorrectionSettings.self, forKey: .lensCorrection)
        geometry = try values.decodeIfPresent(GeometrySettings.self, forKey: .geometry)
        guard geometrySettings.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .geometry, in: values, debugDescription: "Invalid geometry parameters")
        }
        supportsRawNoiseReduction = try values.decodeIfPresent(Bool.self, forKey: .supportsRawNoiseReduction) ?? false
        guard hslSettings.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .hsl, in: values, debugDescription: "Invalid HSL parameters")
        }
        masterRecipeID = try values.decodeIfPresent(String.self, forKey: .masterRecipeID)
        let version = try values.decodeIfPresent(Int.self, forKey: .masterRecipeSettingsVersion)
        masterRecipeSettingsVersion = masterRecipeID == nil ? 3 : (version ?? 2)
        if version == nil, let recipe = masterRecipe {
            // 旧记录只保存基础值；一次性合入预设，之后由新规则整体缩放这些当前值。
            let cameraWB = whiteBalanceMode == .asShot ||
                (temperature == asShotWhiteBalance?.temperature && tint == asShotWhiteBalance?.tint)
            exposure += recipe.exposureDelta
            shadows += recipe.shadowsDelta
            highlights += recipe.highlightsDelta
            contrast += recipe.contrastDelta
            saturation += recipe.saturationDelta
            tint = (cameraWB ? 0 : tint - (asShotWhiteBalance?.tint ?? 0)) + recipe.tintDelta
            if cameraWB { whiteBalanceMode = .asShot }
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
        case .tone: return [.contrast, .highlights, .shadows, .toneCurve]
        case .color: return [.saturation]
        case .detail: return [.denoiseMode, .sharpening]
        case .effects: return [.vignetteAmount, .grainAmount]
        case .lens, .geometry: return []
        }
    }
}

enum GeometryParameter: String, CaseIterable, Identifiable {
    case cropX, cropY, cropWidth, cropHeight, straightenDegrees
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cropX: return L10n.text("裁切左边")
        case .cropY: return L10n.text("裁切上边")
        case .cropWidth: return L10n.text("裁切宽度")
        case .cropHeight: return L10n.text("裁切高度")
        case .straightenDegrees: return L10n.text("拉直")
        }
    }
    var keyPath: WritableKeyPath<GeometrySettings, Double> {
        switch self {
        case .cropX: return \.cropX
        case .cropY: return \.cropY
        case .cropWidth: return \.cropWidth
        case .cropHeight: return \.cropHeight
        case .straightenDegrees: return \.straightenDegrees
        }
    }
    var multiplier: Double { self == .straightenDegrees ? 1 : 100 }
    var unit: String { self == .straightenDegrees ? "°" : "%" }
    func range(for state: GeometrySettings) -> ClosedRange<Double> {
        switch self {
        case .cropX: return 0...max(0, 1 - state.cropWidth)
        case .cropY: return 0...max(0, 1 - state.cropHeight)
        case .cropWidth: return min(0.001, 1 - state.cropX)...(1 - state.cropX)
        case .cropHeight: return min(0.001, 1 - state.cropY)...(1 - state.cropY)
        case .straightenDegrees: return -45...45
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
        if self == .tint { value.defaultValue = settings.masterRecipe != nil ? 0 : (settings.asShotWhiteBalance?.tint ?? 0) }
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
        case .strength: return AdjustmentSpec(title: L10n.text("强度"), keyPath: \.strength, range: 0...2, defaultValue: 1, step: 0.001, unit: "%", multiplier: 100, decimals: 1)
        case .exposure: return AdjustmentSpec(title: L10n.text("曝光"), keyPath: \.exposure, range: -4...4, defaultValue: 0, step: 0.01, unit: "EV", decimals: 2)
        case .temperature: return AdjustmentSpec(title: L10n.text("色温"), keyPath: \.temperature, range: 2000...50000, defaultValue: 6500, step: 10, unit: "K", reciprocalScale: true)
        case .tint: return AdjustmentSpec(title: L10n.text("色调"), keyPath: \.tint, range: -150...150, defaultValue: 0, step: 0.1, unit: "", decimals: 1)
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
    func previewLongEdge(canvas: CGSize, displayScale: CGFloat, source: CGSize) -> Int {
        let width = max(1, canvas.width - 24), height = max(1, canvas.height - 24)
        let sourceEdge = max(source.width, source.height)
        guard source.width > 0, source.height > 0, sourceEdge.isFinite else { return 2000 }
        let fit = min(width / source.width, height / source.height)
        let pixels = (pixelMode ? max(width, height) : fit * sourceEdge * magnification) * max(1, displayScale)
        guard pixels.isFinite else { return 2000 }
        // 按小档位取整，窗口微调不会不断产生新的渲染尺寸。
        return Int(min(65535, sourceEdge, max(1, ceil(pixels / 64) * 64)))
    }
}

struct PhotoEditState: Codable, Equatable {
    var settings: Adjustments
    var filmID: String
    var masterRecipeID: String? = nil
}

struct PhotoEditSession {
    private var edits: [URL: PhotoEditState] = [:]
    mutating func save(_ url: URL, settings: Adjustments, filmID: String, masterRecipeID: String? = nil) {
        edits[url.standardizedFileURL] = PhotoEditState(settings: settings, filmID: filmID, masterRecipeID: masterRecipeID)
    }
    func state(for url: URL, defaultFilmID: String) -> PhotoEditState {
        edits[url.standardizedFileURL] ?? PhotoEditState(settings: Adjustments(), filmID: defaultFilmID, masterRecipeID: nil)
    }
}
