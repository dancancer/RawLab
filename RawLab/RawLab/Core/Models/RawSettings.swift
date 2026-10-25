import Foundation

struct ProcessingIdentity: Equatable, Hashable, Codable {
    let family: String
    let version: Int
    let quality: String
    static let legacy = ProcessingIdentity(version: 1)
    static let current = ProcessingIdentity(version: 2)
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


enum RawDenoisePreset: String, CaseIterable, Identifiable {
    case detail = "细节优先", clean = "去噪优先", custom = "自定义"
    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
}

struct PhotoEffectsSettings: Codable, Equatable {
    static let vignetteAmountRange: ClosedRange<Double> = -100...100
    static let vignetteMidpointRange: ClosedRange<Double> = 0...100
    static let vignetteRoundnessRange: ClosedRange<Double> = -100...100
    static let vignetteFeatherRange: ClosedRange<Double> = 0...100
    static let vignetteHighlightsRange: ClosedRange<Double> = 0...100
    static let grainAmountRange: ClosedRange<Double> = 0...100
    static let grainSizeRange: ClosedRange<Double> = 0...100
    static let grainRoughnessRange: ClosedRange<Double> = 0...100

    var vignetteAmount: Double {
        didSet { vignetteAmount = Self.clamped(vignetteAmount, to: Self.vignetteAmountRange) }
    }
    var vignetteMidpoint: Double {
        didSet { vignetteMidpoint = Self.clamped(vignetteMidpoint, to: Self.vignetteMidpointRange) }
    }
    var vignetteRoundness: Double {
        didSet { vignetteRoundness = Self.clamped(vignetteRoundness, to: Self.vignetteRoundnessRange) }
    }
    var vignetteFeather: Double {
        didSet { vignetteFeather = Self.clamped(vignetteFeather, to: Self.vignetteFeatherRange) }
    }
    var vignetteHighlights: Double {
        didSet { vignetteHighlights = Self.clamped(vignetteHighlights, to: Self.vignetteHighlightsRange) }
    }
    var grainAmount: Double {
        didSet { grainAmount = Self.clamped(grainAmount, to: Self.grainAmountRange) }
    }
    var grainSize: Double {
        didSet { grainSize = Self.clamped(grainSize, to: Self.grainSizeRange) }
    }
    var grainRoughness: Double {
        didSet { grainRoughness = Self.clamped(grainRoughness, to: Self.grainRoughnessRange) }
    }

    init(vignetteAmount: Double = 0,
         vignetteMidpoint: Double = 50,
         vignetteRoundness: Double = 0,
         vignetteFeather: Double = 50,
         vignetteHighlights: Double = 0,
         grainAmount: Double = 0,
         grainSize: Double = 25,
         grainRoughness: Double = 50) {
        self.vignetteAmount = Self.clamped(vignetteAmount, to: Self.vignetteAmountRange)
        self.vignetteMidpoint = Self.clamped(vignetteMidpoint, to: Self.vignetteMidpointRange)
        self.vignetteRoundness = Self.clamped(vignetteRoundness, to: Self.vignetteRoundnessRange)
        self.vignetteFeather = Self.clamped(vignetteFeather, to: Self.vignetteFeatherRange)
        self.vignetteHighlights = Self.clamped(vignetteHighlights, to: Self.vignetteHighlightsRange)
        self.grainAmount = Self.clamped(grainAmount, to: Self.grainAmountRange)
        self.grainSize = Self.clamped(grainSize, to: Self.grainSizeRange)
        self.grainRoughness = Self.clamped(grainRoughness, to: Self.grainRoughnessRange)
    }

    var isValid: Bool {
        [vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather,
         vignetteHighlights, grainAmount, grainSize, grainRoughness].allSatisfy { $0.isFinite }
    }

    var isDefault: Bool { self == Self() }

    mutating func resetVignette() {
        self = Self(vignetteAmount: 0, vignetteMidpoint: 50, vignetteRoundness: 0,
                    vignetteFeather: 50, vignetteHighlights: 0,
                    grainAmount: grainAmount, grainSize: grainSize, grainRoughness: grainRoughness)
    }

    mutating func resetGrain() {
        self = Self(vignetteAmount: vignetteAmount, vignetteMidpoint: vignetteMidpoint,
                    vignetteRoundness: vignetteRoundness, vignetteFeather: vignetteFeather,
                    vignetteHighlights: vignetteHighlights, grainAmount: 0, grainSize: 25,
                    grainRoughness: 50)
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound <= 0 && range.upperBound >= 0 ? 0 : range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, value.rounded()))
    }

    private enum CodingKeys: String, CodingKey {
        case vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights
        case grainAmount, grainSize, grainRoughness
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            vignetteAmount: try values.decodeIfPresent(Double.self, forKey: .vignetteAmount) ?? 0,
            vignetteMidpoint: try values.decodeIfPresent(Double.self, forKey: .vignetteMidpoint) ?? 50,
            vignetteRoundness: try values.decodeIfPresent(Double.self, forKey: .vignetteRoundness) ?? 0,
            vignetteFeather: try values.decodeIfPresent(Double.self, forKey: .vignetteFeather) ?? 50,
            vignetteHighlights: try values.decodeIfPresent(Double.self, forKey: .vignetteHighlights) ?? 0,
            grainAmount: try values.decodeIfPresent(Double.self, forKey: .grainAmount) ?? 0,
            grainSize: try values.decodeIfPresent(Double.self, forKey: .grainSize) ?? 25,
            grainRoughness: try values.decodeIfPresent(Double.self, forKey: .grainRoughness) ?? 50
        )
    }
}

enum PhotoEffectParameter: String, CaseIterable, Identifiable {
    case vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights
    case grainAmount, grainSize, grainRoughness

    var id: String { rawValue }
    var isVignette: Bool {
        switch self {
        case .vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather, .vignetteHighlights:
            return true
        case .grainAmount, .grainSize, .grainRoughness:
            return false
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
    var range: ClosedRange<Double> {
        switch self {
        case .vignetteAmount: return PhotoEffectsSettings.vignetteAmountRange
        case .vignetteMidpoint: return PhotoEffectsSettings.vignetteMidpointRange
        case .vignetteRoundness: return PhotoEffectsSettings.vignetteRoundnessRange
        case .vignetteFeather: return PhotoEffectsSettings.vignetteFeatherRange
        case .vignetteHighlights: return PhotoEffectsSettings.vignetteHighlightsRange
        case .grainAmount: return PhotoEffectsSettings.grainAmountRange
        case .grainSize: return PhotoEffectsSettings.grainSizeRange
        case .grainRoughness: return PhotoEffectsSettings.grainRoughnessRange
        }
    }
    var defaultValue: Double { PhotoEffectsSettings()[keyPath: keyPath] }
}

struct RawDenoiseSettings: Codable, Equatable {
    var enabled = false
    var luma = 0.0
    var chroma = 46.0
    var coarse = 50.0
    var isValid: Bool { [luma, chroma, coarse].allSatisfy { $0.isFinite && (0...100).contains($0) } }
    var preset: RawDenoisePreset {
        if luma == 0 && chroma == 46 && coarse == 50 { return .detail }
        if luma == 10 && chroma == 72 && coarse == 100 { return .clean }
        return .custom
    }
    mutating func apply(_ preset: RawDenoisePreset) {
        switch preset {
        case .detail: self = Self(enabled: true)
        case .clean: self = Self(enabled: true, luma: 10, chroma: 72, coarse: 100)
        case .custom: break
        }
    }
}

enum RawWhiteBalanceMode: String, Codable, CaseIterable, Equatable {
    case camera
    case custom

    static var asShot: Self { .camera }
}

enum LensProfileMode: String, Codable, CaseIterable { case automatic, manual }

struct LensCorrectionSettings: Codable, Equatable {
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

enum RawExposureMode: Int, Codable, CaseIterable, Identifiable {
    case scene = 0, preview = 1, sensor = 2
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .scene: return L10n.text("标准显影")
        case .preview: return L10n.text("匹配内嵌预览")
        case .sensor: return L10n.text("传感器基准")
        }
    }
}

struct RawSettings: Codable, Equatable {
    static let lutStrengthRange: ClosedRange<Double> = 0...2
    static let temperatureRange: ClosedRange<Double> = 2000...50000
    static let tintRange: ClosedRange<Double> = -150...150

    var toneCurveConfig: ToneCurveSettings?
    var curveSettings: ToneCurveSettings {
        get { toneCurveConfig ?? ToneCurveSettings() }
        set { toneCurveConfig = newValue.isDefault ? nil : newValue }
    }
    var colorGrading: ColorGradingSettings?
    var gradingSettings: ColorGradingSettings {
        get { colorGrading ?? ColorGradingSettings() }
        set { colorGrading = newValue.isDefault ? nil : newValue }
    }
    var atmosphere: AtmosphereSettings?
    var atmosphereSettings: AtmosphereSettings { atmosphere ?? AtmosphereSettings() }
    var clarity: Double {
        get { atmosphereSettings.clarity }
        set { setAtmosphere(\.clarity, to: newValue) }
    }
    var dehaze: Double {
        get { atmosphereSettings.dehaze }
        set { setAtmosphere(\.dehaze, to: newValue) }
    }
    private mutating func setAtmosphere(_ key: WritableKeyPath<AtmosphereSettings, Double>, to value: Double) {
        var state = atmosphereSettings
        state[keyPath: key] = value
        atmosphere = state.isIdentity ? nil : state
    }

    var toneControls: ToneControlsSettings?
    var toneSettings: ToneControlsSettings { toneControls ?? ToneControlsSettings() }
    var blackPoint: Double {
        get { toneSettings.blackPoint }
        set { setTone(\.blackPoint, to: newValue) }
    }
    var whitePoint: Double {
        get { toneSettings.whitePoint }
        set { setTone(\.whitePoint, to: newValue) }
    }
    var vibrance: Double {
        get { toneSettings.vibrance }
        set { setTone(\.vibrance, to: newValue) }
    }
    private mutating func setTone(_ key: WritableKeyPath<ToneControlsSettings, Double>, to value: Double) {
        var state = toneSettings
        state[keyPath: key] = value
        toneControls = state.isIdentity ? nil : state
    }

    var processing = ProcessingIdentity.current
    var geometry = GeometrySettings()
    var denoise = RawDenoiseSettings()
    var lensCorrection: LensCorrectionSettings?
    var lensSettings: LensCorrectionSettings { lensCorrection ?? LensCorrectionSettings() }
    var photoEffects = PhotoEffectsSettings()
    var hsl = HSLSettings()
    var exposureMode = RawExposureMode.preview
    var displayChromaDenoise = 0 {
        didSet { displayChromaDenoise = Self.clampedDisplayChromaDenoise(displayChromaDenoise) }
    }
    var exposure: Double
    var contrast: Double
    var saturation: Double
    var temperature: Double
    var tint: Double
    var highlights: Double
    var shadows: Double
    var toneCurve: Double
    var noiseReduction: Double
    var sharpening: Double
    var lutID: String?
    var lutStrength: Double
    var whiteBalanceMode: RawWhiteBalanceMode
    var masterRecipeID: String?
    var hasLook: Bool { lutID != nil || masterRecipeID != nil }
    var masterRecipe: MasterRecipe? { MasterRecipe.recipe(for: masterRecipeID) }
    var recipeScale: Double { masterRecipeID == nil ? 1 : Double(clampedLUTStrength) }
    mutating func applyMasterRecipe(_ recipe: MasterRecipe) {
        masterRecipeID = recipe.id; lutID = nil; lutStrength = 1
        exposure = recipe.exposureDelta; shadows = recipe.shadowsDelta / 100
        highlights = -recipe.highlightsDelta / 100
        contrast = 1 + recipe.contrastDelta / 100; saturation = 1 + recipe.saturationDelta / 100
        tint = recipe.tintDelta; hsl = recipe.hsl
    }
    mutating func clearMasterRecipe(cameraTint: Double?) {
        guard masterRecipeID != nil else { return }
        masterRecipeID = nil
        if whiteBalanceMode == .camera && (tint == 0 || cameraTint == nil) { tint = cameraTint ?? 0 }
        else { tint = min(150, max(-150, (cameraTint ?? 0) + tint)); whiteBalanceMode = .custom }
    }
    func renderedRecipe(cameraTemperature: Double, cameraTint: Double) -> RawSettings {
        guard masterRecipeID != nil else { return self }
        var result = self
        let scale = recipeScale
        result.exposure *= scale; result.shadows *= scale; result.highlights *= scale
        result.contrast = 1 + (contrast - 1) * scale; result.saturation = 1 + (saturation - 1) * scale
        result.hsl = hsl.scaled(by: scale)
        if whiteBalanceMode == .camera { result.temperature = cameraTemperature }
        result.tint = min(150, max(-150, cameraTint + tint * scale))
        if tint * scale != 0 { result.whiteBalanceMode = .custom }
        result.masterRecipeID = nil
        return result
    }

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, temperature, tint, highlights, shadows
        case toneCurve, noiseReduction, sharpening, lutID, lutStrength, whiteBalanceMode
        case denoise, photoEffects, displayChromaDenoise, exposureMode, hsl
        case masterRecipeID, lensCorrection, geometry, processing, toneControls, atmosphere, colorGrading, toneCurveConfig
    }

    var clampedLUTStrength: Float {
        Float(min(max(lutStrength, Self.lutStrengthRange.lowerBound), Self.lutStrengthRange.upperBound))
    }

    static let `default` = RawSettings(
        exposure: 0,
        contrast: 1,
        saturation: 1,
        temperature: 6500,
        tint: 0,
        highlights: 0,
        shadows: 0,
        toneCurve: 0,
        noiseReduction: 0,
        sharpening: 0,
        lutID: nil,
        lutStrength: 1,
        whiteBalanceMode: .camera,
        photoEffects: PhotoEffectsSettings(),
        displayChromaDenoise: 0
    )

    init(
        exposure: Double,
        contrast: Double,
        saturation: Double,
        temperature: Double,
        tint: Double,
        highlights: Double,
        shadows: Double,
        toneCurve: Double,
        noiseReduction: Double,
        sharpening: Double,
        lutID: String?,
        lutStrength: Double,
        whiteBalanceMode: RawWhiteBalanceMode = .camera,
        photoEffects: PhotoEffectsSettings = PhotoEffectsSettings(),
        displayChromaDenoise: Int = 0
    ) {
        self.photoEffects = photoEffects
        self.displayChromaDenoise = Self.clampedDisplayChromaDenoise(displayChromaDenoise)
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.highlights = highlights
        self.shadows = shadows
        self.toneCurve = toneCurve
        self.noiseReduction = noiseReduction
        self.sharpening = sharpening
        self.lutID = lutID
        self.lutStrength = lutStrength
        self.whiteBalanceMode = whiteBalanceMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        processing = values.contains(.processing)
            ? try values.decode(ProcessingIdentity.self, forKey: .processing) : .legacy
        geometry = try values.decodeIfPresent(GeometrySettings.self, forKey: .geometry) ?? GeometrySettings()
        guard geometry.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .geometry, in: values, debugDescription: "Invalid geometry parameters")
        }
        toneCurveConfig = try values.decodeIfPresent(ToneCurveSettings.self, forKey: .toneCurveConfig)
        colorGrading = try values.decodeIfPresent(ColorGradingSettings.self, forKey: .colorGrading)
        if colorGrading?.isDefault == true { colorGrading = nil }
        atmosphere = try values.decodeIfPresent(AtmosphereSettings.self, forKey: .atmosphere)
        guard atmosphere?.isValid ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .atmosphere, in: values, debugDescription: "Invalid atmosphere controls")
        }
        if atmosphere?.isIdentity == true { atmosphere = nil }
        toneControls = try values.decodeIfPresent(ToneControlsSettings.self, forKey: .toneControls)
        guard toneControls?.isValid ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .toneControls, in: values, debugDescription: "Invalid tone controls")
        }
        exposureMode = RawExposureMode(rawValue: try values.decodeIfPresent(Int.self, forKey: .exposureMode) ?? 0) ?? .scene
        hsl = try values.decodeIfPresent(HSLSettings.self, forKey: .hsl) ?? HSLSettings()
        guard hsl.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .hsl, in: values, debugDescription: "Invalid HSL parameters")
        }
        exposure = try values.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 6500
        tint = try values.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        highlights = try values.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try values.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        toneCurve = try values.decodeIfPresent(Double.self, forKey: .toneCurve) ?? 0
        noiseReduction = try values.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        sharpening = try values.decodeIfPresent(Double.self, forKey: .sharpening) ?? 0
        lutID = try values.decodeIfPresent(String.self, forKey: .lutID)
        masterRecipeID = try values.decodeIfPresent(String.self, forKey: .masterRecipeID)
        lutStrength = try values.decodeIfPresent(Double.self, forKey: .lutStrength) ?? 1
        whiteBalanceMode = try values.decodeIfPresent(RawWhiteBalanceMode.self, forKey: .whiteBalanceMode) ?? .camera
        denoise = try values.decodeIfPresent(RawDenoiseSettings.self, forKey: .denoise) ?? RawDenoiseSettings()
        lensCorrection = try values.decodeIfPresent(LensCorrectionSettings.self, forKey: .lensCorrection)
        photoEffects = try values.decodeIfPresent(PhotoEffectsSettings.self, forKey: .photoEffects) ?? PhotoEffectsSettings()
        displayChromaDenoise = Self.clampedDisplayChromaDenoise(
            try values.decodeIfPresent(Int.self, forKey: .displayChromaDenoise) ?? 0
        )
        guard denoise.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .denoise, in: values, debugDescription: "Invalid denoise strengths")
        }
    }

    private static func clampedDisplayChromaDenoise(_ mode: Int) -> Int {
        min(2, max(0, mode))
    }

    var usesCustomWhiteBalance: Bool { whiteBalanceMode == .custom }

    func resettingAdjustments() -> RawSettings {
        var neutral = Self.default
        neutral.processing = processing
        return neutral
    }

    func customWhiteBalance(cameraTemperature: Double, cameraTint: Double) -> RawSettings {
        var result = self
        if whiteBalanceMode == .camera {
            result.temperature = cameraTemperature
            if masterRecipeID == nil { result.tint = cameraTint }
        }
        result.whiteBalanceMode = .custom
        return result
    }

    // The visible slider is linear in reciprocal Kelvin while its value field remains Kelvin.
    static func reciprocalSliderValue(for temperature: Double) -> Double {
        let reciprocalRange = (1 / temperatureRange.upperBound)...(1 / temperatureRange.lowerBound)
        let reciprocal = 1 / min(max(temperature, temperatureRange.lowerBound), temperatureRange.upperBound)
        return (reciprocalRange.upperBound - reciprocal) /
            (reciprocalRange.upperBound - reciprocalRange.lowerBound)
    }

    static func temperature(forReciprocalSliderValue value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        let reciprocalRange = (1 / temperatureRange.upperBound)...(1 / temperatureRange.lowerBound)
        let reciprocal = reciprocalRange.upperBound -
            clamped * (reciprocalRange.upperBound - reciprocalRange.lowerBound)
        return min(max(((1 / reciprocal) / 10).rounded() * 10, temperatureRange.lowerBound), temperatureRange.upperBound)
    }
}

struct MasterRecipe: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let summary: String
    let lutFileName: String
    let exposureDelta: Double
    let shadowsDelta: Double
    let highlightsDelta: Double
    let contrastDelta: Double
    let saturationDelta: Double
    let tintDelta: Double
    let hsl: HSLSettings
    static let allRecipes: [MasterRecipe] = {
        let paths = [Bundle.main.url(forResource: "master-recipes", withExtension: "json"),
                     ProcessInfo.processInfo.environment["RAWLAB_MASTER_RECIPE_CATALOG"].map { URL(fileURLWithPath: $0) },
                     URL(fileURLWithPath: "Shared/master-recipes.json"),
                     URL(fileURLWithPath: "../Shared/master-recipes.json")].compactMap { $0 }
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: path), let recipes = try? JSONDecoder().decode([MasterRecipe].self, from: data),
              recipes.count == 14, Set(recipes.map(\.id)).count == 14, recipes.allSatisfy({ $0.hsl.isValid }) else {
            preconditionFailure("Missing or invalid master recipe catalog")
        }
        return recipes
    }()
    static func recipe(for id: String?) -> MasterRecipe? {
        guard let id else { return nil }
        return allRecipes.first { $0.id == id }
    }
    func lutURL() -> URL? {
        Bundle.main.url(forResource: lutFileName, withExtension: nil, subdirectory: "MasterRecipes")
            ?? existingFile("RawLabMac/Resources/MasterRecipes/" + lutFileName)
    }
    func artworkURL() -> URL? {
        Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "MasterRecipeIcons")
            ?? existingFile("RawLabMac/Resources/MasterRecipeIcons/" + id + ".png")
    }
    private func existingFile(_ path: String) -> URL? {
        FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}

extension RawSettings {
    // 只用于候选的等价校验：先消费现有配方转换，再按 processor 的输入限制捕获 core Float。
    func editorEffectiveValues(isRaw: Bool, cameraTemperature: Double, cameraTint: Double) -> [Float] {
        var effective = renderedRecipe(cameraTemperature: cameraTemperature, cameraTint: cameraTint)
        if !isRaw || effective.whiteBalanceMode == .camera {
            effective.temperature = 6500; effective.tint = 0
        }
        let noise = !isRaw || effective.denoise.enabled ? 0 : effective.noiseReduction
        return [effective.exposure, effective.contrast, effective.saturation, effective.temperature,
                effective.tint, effective.highlights, effective.shadows, effective.toneCurve,
                noise, effective.sharpening].map(Float.init) +
            [Float(isRaw && effective.whiteBalanceMode == .custom ? 1 : 0)] +
            (effective.hsl.hue + effective.hsl.saturation + effective.hsl.lightness).map(Float.init)
    }
}
