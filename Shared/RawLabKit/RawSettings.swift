import Foundation

public enum RawDenoisePreset: String, CaseIterable, Identifiable, Sendable {
    case detail = "细节优先", clean = "去噪优先", custom = "自定义"
    public var id: String { rawValue }
    public var title: String { L10n.text(rawValue) }
}

public extension RawSettings {
    func editingEffectValue(_ parameter: PhotoEffectParameter) -> Double {
        if isHDREditing, let hdr { return hdr.effectsSettings[keyPath: parameter.hdrKeyPath] }
        return photoEffects[keyPath: parameter.keyPath]
    }

    mutating func setEditingEffect(_ parameter: PhotoEffectParameter, to value: Double) {
        setExactEditingEffect(parameter, to: value.rounded())
    }

    mutating func setExactEditingEffect(_ parameter: PhotoEffectParameter, to value: Double) {
        guard value.isFinite else { return }
        let amount = min(parameter.range.upperBound, max(parameter.range.lowerBound, value))
        if isHDREditing { hdr?.effectsSettings[keyPath: parameter.hdrKeyPath] = amount }
        else { photoEffects[keyPath: parameter.keyPath] = amount }
    }
}

public struct RawDenoiseSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var luma = 0.0
    public var chroma = 46.0
    public var coarse = 50.0

    public init(enabled: Bool = false, luma: Double = 0.0, chroma: Double = 46.0, coarse: Double = 50.0) {
        self.enabled = enabled
        self.luma = luma
        self.chroma = chroma
        self.coarse = coarse
    }

    public var isValid: Bool { [luma, chroma, coarse].allSatisfy { $0.isFinite && (0...100).contains($0) } }
    public var preset: RawDenoisePreset {
        if luma == 0 && chroma == 46 && coarse == 50 { return .detail }
        if luma == 10 && chroma == 72 && coarse == 100 { return .clean }
        return .custom
    }

    public mutating func apply(_ preset: RawDenoisePreset) {
        switch preset {
        case .detail: self = Self(enabled: true)
        case .clean: self = Self(enabled: true, luma: 10, chroma: 72, coarse: 100)
        case .custom: break
        }
    }
}

public enum RawWhiteBalanceMode: String, Codable, CaseIterable, Equatable, Sendable {
    case camera
    case custom

    public static var asShot: Self { .camera }
}

public enum RawExposureMode: Int, Codable, CaseIterable, Identifiable, Sendable {
    case scene = 0, preview = 1, sensor = 2
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .scene: return L10n.text("标准显影")
        case .preview: return L10n.text("匹配内嵌预览")
        case .sensor: return L10n.text("传感器基准")
        }
    }
}

public struct RawSettings: Codable, Equatable {
    public var hdr: HDRSettings?
    public var proRAWDecodeVersion: Int?
    public var isHDREditing: Bool { hdr?.mode == .hdr }
    public static let lutStrengthRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.looksStrength.iosModel.closedRange!
    public static let temperatureRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.colorWhiteBalanceTemperatureKelvin.iosModel.closedRange!
    public static let tintRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.colorWhiteBalanceTint.iosModel.closedRange!

    public var toneCurveConfig: ToneCurveSettings?
    public var curveSettings: ToneCurveSettings {
        get { toneCurveConfig ?? ToneCurveSettings() }
        set { toneCurveConfig = newValue.isDefault ? nil : newValue }
    }
    public var editingCurveSettings: ToneCurveSettings {
        get { isHDREditing ? hdr!.toneSettings.curve : curveSettings }
        set {
            guard newValue.isValid else { return }
            if isHDREditing { hdr?.toneSettings.curve = newValue }
            else { curveSettings = newValue }
        }
    }
    public var colorGrading: ColorGradingSettings?
    public var gradingSettings: ColorGradingSettings {
        get { colorGrading ?? ColorGradingSettings() }
        set { colorGrading = newValue.isDefault ? nil : newValue }
    }
    public var editingGradingSettings: ColorGradingSettings {
        get { isHDREditing ? hdr!.colorSettings.grading : gradingSettings }
        set {
            guard newValue.isValid else { return }
            if isHDREditing { hdr?.colorSettings.grading = newValue }
            else { gradingSettings = newValue }
        }
    }
    public var atmosphere: AtmosphereSettings?
    public var atmosphereSettings: AtmosphereSettings { atmosphere ?? AtmosphereSettings() }
    public var clarity: Double {
        get { atmosphereSettings.clarity }
        set { setAtmosphere(\.clarity, to: newValue) }
    }
    public var dehaze: Double {
        get { atmosphereSettings.dehaze }
        set { setAtmosphere(\.dehaze, to: newValue) }
    }
    private mutating func setAtmosphere(_ key: WritableKeyPath<AtmosphereSettings, Double>, to value: Double) {
        var state = atmosphereSettings
        state[keyPath: key] = value
        atmosphere = state.isIdentity ? nil : state
    }

    public var toneControls: ToneControlsSettings?
    public var toneSettings: ToneControlsSettings { toneControls ?? ToneControlsSettings() }
    public var blackPoint: Double {
        get { toneSettings.blackPoint }
        set { setTone(\.blackPoint, to: newValue) }
    }
    public var whitePoint: Double {
        get { toneSettings.whitePoint }
        set { setTone(\.whitePoint, to: newValue) }
    }
    public var vibrance: Double {
        get { toneSettings.vibrance }
        set { setTone(\.vibrance, to: newValue) }
    }
    private mutating func setTone(_ key: WritableKeyPath<ToneControlsSettings, Double>, to value: Double) {
        var state = toneSettings
        state[keyPath: key] = value
        toneControls = state.isIdentity ? nil : state
    }

    public var processing = ProcessingIdentity.current
    public var x3fMode = X3fMode.normal
    public var geometry = GeometrySettings()
    public var denoise = RawDenoiseSettings()
    public var lensCorrection: LensCorrectionSettings?
    public var lensSettings: LensCorrectionSettings { lensCorrection ?? LensCorrectionSettings() }
    public mutating func selectX3fMode(_ mode: X3fMode) {
        x3fMode = mode
        guard mode == .normal else { return }
        lensCorrection?.distortion = false
        lensCorrection?.tca = false
        lensCorrection?.vignetting = false
    }
    public var photoEffects = PhotoEffectsSettings()
    public var hsl = HSLSettings()
    public var editingHSLSettings: HSLSettings {
        get { isHDREditing ? hdr!.colorSettings.hsl : hsl }
        set {
            guard newValue.isValid else { return }
            if isHDREditing { hdr?.colorSettings.hsl = newValue }
            else { hsl = newValue }
        }
    }
    public var exposureMode = RawExposureMode.preview
    public var displayChromaDenoise = 0 {
        didSet { displayChromaDenoise = Self.clampedDisplayChromaDenoise(displayChromaDenoise) }
    }
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var temperature: Double
    public var tint: Double
    public var highlights: Double
    public var shadows: Double
    public var toneCurve: Double
    public var noiseReduction: Double
    public var sharpening: Double
    public var lutID: String?
    public var lutStrength: Double
    public var whiteBalanceMode: RawWhiteBalanceMode
    public var masterRecipeID: String?
    public var masterRecipeSettingsVersion = 3
    public var hasLook: Bool { !isHDREditing && (lutID != nil || masterRecipeID != nil) }
    public var masterRecipe: MasterRecipe? { MasterRecipe.recipe(for: masterRecipeID) }
    public var recipeScale: Double { masterRecipeID == nil ? 1 : Double(clampedLUTStrength) }
    public var refinementScale: Double { masterRecipeSettingsVersion >= 4 ? recipeScale : 1 }
    public mutating func applyMasterRecipe(_ recipe: MasterRecipe) {
        masterRecipeID = recipe.id; lutID = nil; lutStrength = 1
        masterRecipeSettingsVersion = recipe.version
        exposure = recipe.exposureDelta; shadows = recipe.shadowsDelta / 100
        highlights = -recipe.highlightsDelta / 100
        contrast = 1 + recipe.contrastDelta / 100; saturation = 1 + recipe.saturationDelta / 100
        tint = recipe.tintDelta; hsl = recipe.hsl
        if recipe.version >= 4 {
            toneControls = recipe.tone?.isIdentity == true ? nil : recipe.tone
            atmosphere = recipe.atmosphere?.isIdentity == true ? nil : recipe.atmosphere
            gradingSettings = recipe.grading ?? ColorGradingSettings()
            curveSettings = recipe.curve ?? ToneCurveSettings()
            toneCurve = 0
        }
    }
    public func renderedRecipe(cameraTemperature: Double, cameraTint: Double) -> RawSettings {
        guard masterRecipeID != nil else { return self }
        var result = self
        let scale = recipeScale
        result.exposure *= scale; result.shadows *= scale; result.highlights *= scale
        result.contrast = 1 + (contrast - 1) * scale; result.saturation = 1 + (saturation - 1) * scale
        result.hsl = hsl.scaled(by: masterRecipeSettingsVersion >= 3 ? scale : 1)
        if masterRecipeSettingsVersion >= 4 {
            let tone = toneSettings.scaled(by: scale), atmosphere = atmosphereSettings.scaled(by: scale)
            result.toneControls = tone.isIdentity ? nil : tone
            result.atmosphere = atmosphere.isIdentity ? nil : atmosphere
            result.gradingSettings = gradingSettings.scaled(by: scale)
            result.curveSettings = curveSettings.scaled(by: scale)
            result.toneCurve = min(1, max(-1, toneCurve * scale))
        }
        if whiteBalanceMode == .camera { result.temperature = cameraTemperature }
        result.tint = min(150, max(-150, cameraTint + tint * scale))
        if tint * scale != 0 { result.whiteBalanceMode = .custom }
        result.masterRecipeID = nil
        result.masterRecipeSettingsVersion = 3
        return result
    }

    public enum CodingKeys: String, CodingKey {
        case hdr, proRAWDecodeVersion, x3fMode
        case exposure, contrast, saturation, temperature, tint, highlights, shadows
        case toneCurve, noiseReduction, sharpening, lutID, lutStrength, whiteBalanceMode
        case denoise, photoEffects, displayChromaDenoise, exposureMode, hsl
        case masterRecipeID, masterRecipeSettingsVersion, lensCorrection, geometry, processing, toneControls, atmosphere, colorGrading, toneCurveConfig
    }

    public var clampedLUTStrength: Float {
        Float(min(max(lutStrength, Self.lutStrengthRange.lowerBound), Self.lutStrengthRange.upperBound))
    }

    public static func sourceDefaults(for url: URL, isRaw: Bool, sourceIsHDR: Bool,
                                      x3fDefaultMode: (URL) throws -> X3fMode) throws -> RawSettings {
        var settings = RawSettings.default
        if !isRaw { settings.exposureMode = .sensor }
        if isRaw && url.pathExtension.lowercased() == "x3f" { settings.x3fMode = try x3fDefaultMode(url) }
        if sourceIsHDR { settings.hdr = HDRSettings() }
        return settings
    }

    public static let `default` = RawSettings(
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

    public init(
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

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hdr = try values.decodeIfPresent(HDRSettings.self, forKey: .hdr)
        proRAWDecodeVersion = try values.decodeIfPresent(Int.self, forKey: .proRAWDecodeVersion)
        processing = values.contains(.processing)
            ? try values.decode(ProcessingIdentity.self, forKey: .processing) : .legacy
        x3fMode = values.contains(.x3fMode) ? try values.decode(X3fMode.self, forKey: .x3fMode) : .legacy
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
        masterRecipeSettingsVersion = try values.decodeIfPresent(Int.self, forKey: .masterRecipeSettingsVersion) ?? 3
        guard [2, 3, 4].contains(masterRecipeSettingsVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .masterRecipeSettingsVersion, in: values, debugDescription: "Invalid master recipe version")
        }
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

    public var usesCustomWhiteBalance: Bool { whiteBalanceMode == .custom }

    public func customWhiteBalance(cameraTemperature: Double, cameraTint: Double) -> RawSettings {
        var result = self
        if whiteBalanceMode == .camera {
            result.temperature = cameraTemperature
            if masterRecipeID == nil { result.tint = cameraTint }
        }
        result.whiteBalanceMode = .custom
        return result
    }

    // The visible slider is linear in reciprocal Kelvin while its value field remains Kelvin.
    public static func reciprocalSliderValue(for temperature: Double) -> Double {
        let reciprocalRange = (1 / temperatureRange.upperBound)...(1 / temperatureRange.lowerBound)
        let reciprocal = 1 / min(max(temperature, temperatureRange.lowerBound), temperatureRange.upperBound)
        return (reciprocalRange.upperBound - reciprocal) /
            (reciprocalRange.upperBound - reciprocalRange.lowerBound)
    }

    public static func temperature(forReciprocalSliderValue value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        let reciprocalRange = (1 / temperatureRange.upperBound)...(1 / temperatureRange.lowerBound)
        let reciprocal = reciprocalRange.upperBound -
            clamped * (reciprocalRange.upperBound - reciprocalRange.lowerBound)
        return min(max(((1 / reciprocal) / 10).rounded() * 10, temperatureRange.lowerBound), temperatureRange.upperBound)
    }
}

public extension RawSettings {
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

    var geometrySettings: GeometrySettings {
        get { isHDREditing ? hdr!.geometry : geometry }
        set { setGeometrySettings(newValue) }
    }
    mutating func setGeometrySettings(_ state: GeometrySettings) {
        if isHDREditing { hdr?.geometry = state }
        else { geometry = state }
    }

    func withHDRMode(_ enabled: Bool, sourceIsHDR: Bool, cameraRAW: Bool = false) throws -> RawSettings {
        var result = self
        guard enabled else { result.hdr?.mode = .sdr; return result }
        var initial = HDRSettings()
        if !cameraRAW {
            let scale = recipeScale
            initial.exposure = min(4, max(-4, exposure * scale))
            initial.contrast = min(100, max(-100, (contrast - 1) * 100 * scale))
            initial.highlights = min(100, max(-100, -highlights * 100 * scale))
            initial.shadows = min(100, max(-100, shadows * 100 * scale))
            initial.saturation = min(100, max(-100, (saturation - 1) * 100 * scale))
            initial.geometry = geometry
        }
        result.hdr = try HDRSettings.enabling(stored: hdr, initial: initial, sourceIsHDR: sourceIsHDR || cameraRAW)
        return result
    }
}
