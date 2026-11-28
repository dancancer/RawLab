import Foundation

public struct ResolvedRenderValues: Equatable, Sendable {
    public let usesTemperatureWB: Bool
    public let exposureEV, brightness, temperature, tint, contrast, saturation, highlights, shadows, toneCurve, sharpening: Float
}
public typealias ResolvedMacRenderValues = ResolvedRenderValues

public struct Adjustments: Equatable, Codable {
    public enum LegacyWireFlavor: Sendable { case ios, mac }
    public static let legacyV1EncodingKey = CodingUserInfoKey(rawValue: "RawLabKit.Adjustments.legacyV1Encoding")!
    public static let legacyFormatHintKey = CodingUserInfoKey(rawValue: "RawLabKit.Adjustments.legacyFormatHint")!
    public static let lutStrengthRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.looksStrength.iosModel.closedRange!
    public static let temperatureRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.colorWhiteBalanceTemperatureKelvin.iosModel.closedRange!
    public static let tintRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.colorWhiteBalanceTint.iosModel.closedRange!
    public static let `default` = Adjustments()

    public var toneCurveConfig: ToneCurveSettings?
    public var curveSettings: ToneCurveSettings { get { toneCurveConfig ?? ToneCurveSettings() } set { toneCurveConfig = newValue.isDefault ? nil : newValue } }
    public var editingCurveSettings: ToneCurveSettings {
        get { isHDREditing ? hdr!.toneSettings.curve : curveSettings }
        set { guard newValue.isValid else { return }; if isHDREditing { hdr?.toneSettings.curve = newValue } else { curveSettings = newValue } }
    }

    public var colorGrading: ColorGradingSettings?
    public var gradingSettings: ColorGradingSettings { get { colorGrading ?? ColorGradingSettings() } set { colorGrading = newValue.isDefault ? nil : newValue } }
    public var editingGradingSettings: ColorGradingSettings {
        get { isHDREditing ? hdr!.colorSettings.grading : gradingSettings }
        set { guard newValue.isValid else { return }; if isHDREditing { hdr?.colorSettings.grading = newValue } else { gradingSettings = newValue } }
    }

    public var atmosphere: AtmosphereSettings?
    public var atmosphereSettings: AtmosphereSettings { atmosphere ?? AtmosphereSettings() }
    public var clarity: Double { get { atmosphereSettings.clarity } set { setAtmosphere(\.clarity, to: newValue) } }
    public var dehaze: Double { get { atmosphereSettings.dehaze } set { setAtmosphere(\.dehaze, to: newValue) } }
    public var texture: Double { get { atmosphereSettings.texture } set { setAtmosphere(\.texture, to: newValue) } }
    private mutating func setAtmosphere(_ key: WritableKeyPath<AtmosphereSettings, Double>, to value: Double) {
        var state = atmosphereSettings; state[keyPath: key] = value; atmosphere = state.isIdentity ? nil : state
    }

    public var cameraCalibration: CameraCalibrationSettings?
    public var calibrationSettings: CameraCalibrationSettings {
        get { cameraCalibration ?? CameraCalibrationSettings() }
        set { cameraCalibration = newValue.isDefault ? nil : newValue }
    }
    public var pointColor: PointColorSettings?
    public var pointColorSettings: PointColorSettings {
        get { pointColor ?? PointColorSettings() }
        set { pointColor = newValue.isDefault ? nil : newValue }
    }
    public var selectiveColor: SelectiveColorSettings?
    public var selectiveColorSettings: SelectiveColorSettings {
        get { selectiveColor ?? SelectiveColorSettings() }
        set { selectiveColor = newValue.isDefault ? nil : newValue }
    }
    public var bwMixer: BwMixerSettings?
    public var bwMixerSettings: BwMixerSettings {
        get { bwMixer ?? BwMixerSettings() }
        set { bwMixer = newValue.isDefault ? nil : newValue }
    }
    public var sharpenV2: SharpenV2Settings?
    public var sharpenV2Settings: SharpenV2Settings {
        get { sharpenV2 ?? SharpenV2Settings() }
        set { sharpenV2 = newValue.isDefault ? nil : newValue }
    }
    public mutating func applySharpenV2Edit(amount: Double? = nil, radius: Double? = nil, detail: Double? = nil,
                                            masking: Double? = nil, luminanceV2: Bool? = nil) {
        var v2 = sharpenV2Settings
        if let amount, amount.isFinite {
            let clamped = min(max(amount, 0), 2)
            let preserveLegacy = sharpening > 0 && !v2.luminanceV2 && v2.isDefault
            sharpening = clamped
            if !preserveLegacy && clamped > 0 && !v2.luminanceV2 {
                v2.luminanceV2 = true
            }
        }
        if let luminanceV2 {
            v2.luminanceV2 = luminanceV2
        }
        if let radius, radius.isFinite {
            v2.radius = min(max(radius, SharpenV2Settings.radiusRange.lowerBound), SharpenV2Settings.radiusRange.upperBound)
            v2.luminanceV2 = true
        }
        if let detail, detail.isFinite {
            let clean = min(max(detail, SharpenV2Settings.detailRange.lowerBound), SharpenV2Settings.detailRange.upperBound)
            v2.detail = clean == 0 ? 0 : clean
            v2.luminanceV2 = true
        }
        if let masking, masking.isFinite {
            let clean = min(max(masking, SharpenV2Settings.maskingRange.lowerBound), SharpenV2Settings.maskingRange.upperBound)
            v2.masking = clean == 0 ? 0 : clean
            v2.luminanceV2 = true
        }
        sharpenV2Settings = v2
    }
    public var filmOptics: FilmOpticsSettings?
    public var filmOpticsSettings: FilmOpticsSettings {
        get { filmOptics ?? FilmOpticsSettings() }
        set { filmOptics = newValue.isDefault ? nil : newValue }
    }

    public var toneControls: ToneControlsSettings?
    public var toneSettings: ToneControlsSettings { toneControls ?? ToneControlsSettings() }
    public var blackPoint: Double { get { toneSettings.blackPoint } set { setTone(\.blackPoint, to: newValue) } }
    public var whitePoint: Double { get { toneSettings.whitePoint } set { setTone(\.whitePoint, to: newValue) } }
    public var vibrance: Double { get { toneSettings.vibrance } set { setTone(\.vibrance, to: newValue) } }
    private mutating func setTone(_ key: WritableKeyPath<ToneControlsSettings, Double>, to value: Double) {
        var state = toneSettings; state[keyPath: key] = value; toneControls = state.isIdentity ? nil : state
    }

    public var processing = ProcessingIdentity.current
    public var x3fMode = X3fMode.normal
    public var hdr: HDRSettings?
    public var proRAWDecodeVersion: Int?
    public var isHDREditing: Bool { hdr?.mode == .hdr }
    public var exposureMode = ExposureMode.preview
    public var exposure = 0.0, temperature = 6500.0, tint = 0.0
    public var whiteBalanceMode = WhiteBalanceMode.camera
    public private(set) var asShotWhiteBalance: WhiteBalance?
    public var strength = 1.0, contrast = 1.0, highlights = 0.0, shadows = 0.0, toneCurve = 0.0, saturation = 1.0, sharpening = 0.0
    public var rawNoiseReduction = 0.0, chromaNoiseReduction = 0
    public var waveletNoiseReduction = WaveletDenoiseSettings()
    public var aiDenoiseEnabled = false
    private var aiDenoiseBlend: Double?
    public var aiDenoiseStrength: Double {
        get { aiDenoiseBlend ?? 100.0 }
        set { guard newValue.isFinite else { return }; let c = min(100.0, max(0.0, newValue)); aiDenoiseBlend = c == 100.0 ? nil : c }
    }
    private var hdrCameraAI: Bool?
    public var hdrCameraAIEnabled: Bool { get { hdrCameraAI == true } set { hdrCameraAI = newValue ? true : nil } }
    public var activeAIDenoise: Bool {
        get { isHDREditing ? hdrCameraAIEnabled : aiDenoiseEnabled }
        set { if isHDREditing { hdrCameraAIEnabled = newValue } else { aiDenoiseEnabled = newValue } }
    }
    public var photoEffects: PhotoEffectsSettings?
    public var hsl: HSLSettings?
    public var lensCorrection: LensCorrectionSettings?
    public var geometry: GeometrySettings?
    public private(set) var supportsRawNoiseReduction = false
    public var lutID: String? = nil, masterRecipeID: String? = nil
    public var masterRecipeSettingsVersion: Int? = 3

    public var lutStrength: Double { get { strength } set { strength = newValue } }
    public var clampedLUTStrength: Float { Float(min(max(strength, Self.lutStrengthRange.lowerBound), Self.lutStrengthRange.upperBound)) }
    public var denoise: WaveletDenoiseSettings { get { waveletNoiseReduction } set { waveletNoiseReduction = newValue } }
    public var displayChromaDenoise: Int { get { chromaNoiseReduction } set { chromaNoiseReduction = min(2, max(0, newValue)) } }
    public var hasLook: Bool { !isHDREditing && (lutID != nil || masterRecipeID != nil) }
    // 配方缩放按 Double 计算、到渲染请求才转 Float，与 Windows 一致；先收窄成 Float 再乘，请求值会差一档。
    public var recipeScale: Double { masterRecipeID == nil ? 1 : min(max(strength, Self.lutStrengthRange.lowerBound), Self.lutStrengthRange.upperBound) }
    public var usesCustomWhiteBalance: Bool { whiteBalanceMode == .custom }

    public init() {}
    public init(exposure: Double, contrast: Double, saturation: Double, temperature: Double, tint: Double,
                highlights: Double, shadows: Double, toneCurve: Double, sharpening: Double, lutID: String?,
                lutStrength: Double, whiteBalanceMode: WhiteBalanceMode = .camera,
                photoEffects: PhotoEffectsSettings = PhotoEffectsSettings(), displayChromaDenoise: Int = 0) {
        self.exposure = exposure; self.contrast = contrast; self.saturation = saturation
        self.temperature = temperature; self.tint = tint; self.highlights = highlights; self.shadows = shadows
        self.toneCurve = toneCurve; self.sharpening = sharpening; self.lutID = lutID; self.strength = lutStrength
        self.whiteBalanceMode = whiteBalanceMode; self.photoEffects = photoEffects.isDefault ? nil : photoEffects
        self.chromaNoiseReduction = min(2, max(0, displayChromaDenoise))
    }

    public static func sourceDefaults(for url: URL, isRaw: Bool, sourceIsHDR: Bool, x3fDefaultMode: (URL) throws -> X3fMode) throws -> Adjustments {
        var settings = Adjustments()
        if !isRaw { settings.exposureMode = .sensor }
        if isRaw && url.pathExtension.lowercased() == "x3f" { settings.x3fMode = try x3fDefaultMode(url) }
        if sourceIsHDR { settings.hdr = HDRSettings() }
        return settings
    }

    public static func reciprocalSliderValue(for temperature: Double) -> Double {
        let r = (1 / temperatureRange.upperBound)...(1 / temperatureRange.lowerBound)
        let rec = 1 / min(max(temperature, temperatureRange.lowerBound), temperatureRange.upperBound)
        return (r.upperBound - rec) / (r.upperBound - r.lowerBound)
    }

    public static func temperature(forReciprocalSliderValue value: Double) -> Double {
        let clamped = min(max(value, 0), 1), r = (1 / temperatureRange.upperBound)...(1 / temperatureRange.lowerBound)
        let rec = r.upperBound - clamped * (r.upperBound - r.lowerBound)
        return min(max(((1 / rec) / 10).rounded() * 10, temperatureRange.lowerBound), temperatureRange.upperBound)
    }

    public func customWhiteBalance(cameraTemperature: Double, cameraTint: Double) -> Adjustments {
        var result = self
        if whiteBalanceMode == .camera { result.temperature = cameraTemperature; if masterRecipeID == nil { result.tint = cameraTint } }
        result.whiteBalanceMode = .custom
        return result
    }

    public var masterRecipe: MasterRecipe? { MasterRecipe.recipe(for: masterRecipeID) }
    public var recipeSettingsVersion: Int { masterRecipeSettingsVersion ?? 2 }
    public var refinementScale: Double { masterRecipe != nil && recipeSettingsVersion >= 4 ? recipeScale : 1 }
    public var renderToneSettings: ToneControlsSettings { toneSettings.scaled(by: refinementScale) }
    public var renderAtmosphereSettings: AtmosphereSettings { atmosphereSettings.scaled(by: refinementScale) }
    public var renderGradingSettings: ColorGradingSettings { gradingSettings.scaled(by: refinementScale) }
    public var renderCurveSettings: ToneCurveSettings { curveSettings.scaled(by: refinementScale) }

    public mutating func setTransferRecipe(_ id: String?, settingsVersion: Int = 3) {
        masterRecipeID = id; masterRecipeSettingsVersion = settingsVersion
    }
    public var effectSettings: PhotoEffectsSettings { get { photoEffects ?? PhotoEffectsSettings() } set { photoEffects = newValue.isDefault ? nil : newValue } }
    public var hslSettings: HSLSettings { get { hsl ?? HSLSettings() } set { hsl = newValue.isIdentity ? nil : newValue } }
    public var editingHSLSettings: HSLSettings {
        get { isHDREditing ? hdr!.colorSettings.hsl : hslSettings }
        set { guard newValue.isValid else { return }; if isHDREditing { hdr?.colorSettings.hsl = newValue } else { hsl = newValue.isIdentity ? nil : newValue } }
    }
    public var renderHSLSettings: HSLSettings { hslSettings.scaled(by: (masterRecipe != nil && (masterRecipeSettingsVersion ?? 2) >= 3) ? strength : 1) }
    public mutating func setHSL(_ axis: HSLAxis, channel: Int, value: Double) {
        var s = hslSettings; s.set(axis, channel: channel, value: value); hsl = s.isIdentity ? nil : s
    }

    public var lensSettings: LensCorrectionSettings { lensCorrection ?? LensCorrectionSettings() }
    public mutating func selectX3fMode(_ mode: X3fMode) {
        x3fMode = mode; guard mode == .normal else { return }
        aiDenoiseEnabled = false; lensCorrection?.distortion = false; lensCorrection?.tca = false; lensCorrection?.vignetting = false
    }

    public var needsLegacyNormalX3fRepair: Bool {
        x3fMode == .normal && (lensSettings.isEnabled || aiDenoiseEnabled)
    }

    public static func isX3fInput(_ url: URL?, displayName: String? = nil) -> Bool {
        if url?.pathExtension.lowercased() == "x3f" { return true }
        if let displayName, (displayName as NSString).pathExtension.lowercased() == "x3f" { return true }
        return hasX3fSignature(url)
    }

    private static func hasX3fSignature(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return false }
        return header.elementsEqual([0x46, 0x4F, 0x56, 0x62]) // "FOVb"
    }

    @discardableResult
    public mutating func repairLegacyNormalX3f(isX3f: Bool) -> Bool {
        guard isX3f, needsLegacyNormalX3fRepair else { return false }
        selectX3fMode(.normal)
        return true
    }

    @discardableResult
    public mutating func repairLegacyNormalX3f(for url: URL?, displayName: String? = nil) -> Bool {
        guard needsLegacyNormalX3fRepair else { return false }
        return repairLegacyNormalX3f(isX3f: Self.isX3fInput(url, displayName: displayName))
    }

    public var geometrySettings: GeometrySettings { get { isHDREditing ? hdr!.geometry : (geometry ?? GeometrySettings()) } set { setGeometrySettings(newValue) } }
    public mutating func setGeometrySettings(_ state: GeometrySettings) {
        if isHDREditing { hdr?.geometry = state } else { geometry = state.isIdentity ? nil : state }
    }
    public mutating func setGeometry(_ parameter: GeometryParameter, to value: Double) {
        guard value.isFinite else { return }
        var s = geometrySettings; let r = parameter.range(for: s)
        s[keyPath: parameter.keyPath] = min(r.upperBound, max(r.lowerBound, value)); setGeometrySettings(s)
    }
    public mutating func rotateGeometry(clockwise: Bool) {
        var s = geometrySettings; s.quarterTurns = (s.quarterTurns + (clockwise ? 1 : 3)) % 4; setGeometrySettings(s)
    }
    public mutating func flipGeometry(horizontal: Bool) {
        var s = geometrySettings; if horizontal { s.flipHorizontal.toggle() } else { s.flipVertical.toggle() }; setGeometrySettings(s)
    }

    public var neutralSettings: Adjustments {
        if isHDREditing { var n = self; n.hdr?.reset(); n.hdrCameraAIEnabled = false; return n }
        var n = Adjustments(); n.processing = processing; n.x3fMode = x3fMode; return n
    }
    public var neutralGeometrySettings: Adjustments {
        var n = neutralSettings; n.setGeometrySettings(geometrySettings)
        if isHDREditing { n.hdr = hdr?.neutralGeometrySettings }
        n.lensCorrection = lensCorrection; return n
    }

    public var vignetteAmount: Double { get { editingEffectValue(.vignetteAmount) } set { setEffect(.vignetteAmount, to: newValue) } }
    public var grainAmount: Double { get { editingEffectValue(.grainAmount) } set { setEffect(.grainAmount, to: newValue) } }
    public func editingEffectValue(_ parameter: PhotoEffectParameter) -> Double {
        if isHDREditing, let hdr { return hdr.effectsSettings[keyPath: parameter.hdrKeyPath] }
        return effectSettings[keyPath: parameter.keyPath]
    }
    public mutating func setEffect(_ parameter: PhotoEffectParameter, to value: Double) {
        guard value.isFinite else { return }
        setExactEditingEffect(parameter, to: min(parameter.range.upperBound, max(parameter.range.lowerBound, (value * 10).rounded() / 10)))
    }
    public mutating func setEditingEffect(_ parameter: PhotoEffectParameter, to value: Double) { setExactEditingEffect(parameter, to: value) }
    public mutating func setGrainEffect(_ parameter: PhotoEffectParameter, to value: Double) {
        guard value.isFinite else { return }
        let rounded = min(parameter.range.upperBound, max(parameter.range.lowerBound, (value * 10).rounded() / 10))
        if isHDREditing { hdr?.effectsSettings[keyPath: parameter.hdrKeyPath] = rounded; return }
        var state = effectSettings
        guard state[keyPath: parameter.keyPath] != rounded else { return }
        state[keyPath: parameter.keyPath] = rounded
        if parameter == .grainSize || parameter == .grainRoughness {
            if let presetValues = state.grainFormatPreset.presetValues {
                if state.grainSize != presetValues.size || state.grainRoughness != presetValues.roughness {
                    state.grainFormatPreset = .custom
                }
            }
        }
        photoEffects = state.isDefault ? nil : state
    }
    public mutating func applyGrainToneCurve(_ curve: GrainToneCurve) {
        guard !isHDREditing else { return }
        var state = effectSettings
        guard state.grainToneCurve != curve else { return }
        state.grainToneCurve = curve
        photoEffects = state.isDefault ? nil : state
    }
    public mutating func applyGrainFormatPreset(_ preset: GrainFormatPreset) {
        guard !isHDREditing else { return }
        var state = effectSettings
        state.grainFormatPreset = preset
        if let values = preset.presetValues {
            state.grainSize = values.size
            state.grainRoughness = values.roughness
        }
        photoEffects = state.isDefault ? nil : state
    }
    public mutating func setFilmOptics(_ parameter: FilmOpticsParameter, to value: Double) {
        guard !isHDREditing, value.isFinite else { return }
        let rounded = min(parameter.range.upperBound, max(parameter.range.lowerBound, (value * 10).rounded() / 10))
        var state = filmOpticsSettings
        guard state[keyPath: parameter.keyPath] != rounded else { return }
        state[keyPath: parameter.keyPath] = rounded
        filmOptics = state.isDefault ? nil : state
    }
    public mutating func setExactEditingEffect(_ parameter: PhotoEffectParameter, to value: Double) {
        guard value.isFinite else { return }
        let amount = min(parameter.range.upperBound, max(parameter.range.lowerBound, value))
        if isHDREditing { hdr?.effectsSettings[keyPath: parameter.hdrKeyPath] = amount; return }
        var state = effectSettings; state[keyPath: parameter.keyPath] = amount; photoEffects = state.isDefault ? nil : state
    }
    public mutating func resetEffect(_ tool: AdjustmentParameter) {
        for p in PhotoEffectParameter.allCases where p.isVignette == (tool == .vignetteAmount) { setEffect(p, to: p.defaultValue) }
        if tool != .vignetteAmount && !isHDREditing {
            var state = effectSettings
            state.grainToneCurve = .legacy
            state.grainFormatPreset = .custom
            photoEffects = state.isDefault ? nil : state
        }
    }
    public func isEffectDefault(_ tool: AdjustmentParameter) -> Bool {
        PhotoEffectParameter.allCases.filter { $0.isVignette == (tool == .vignetteAmount) }.allSatisfy { editingEffectValue($0) == $0.defaultValue }
            && (tool == .vignetteAmount || (effectSettings.grainToneCurve == .legacy && effectSettings.grainFormatPreset == .custom))
    }

    public var waveletSettings: WaveletDenoiseSettings { waveletNoiseReduction }
    public var isWaveletDefault: Bool { waveletNoiseReduction == WaveletDenoiseSettings() }
    public var hasLegacyDenoise: Bool { isWaveletDefault && denoiseMode > 0 }
    public var hasLegacyFBDD: Bool { isWaveletDefault && chromaNoiseReduction == 0 && rawNoiseReduction > 0 }
    public var isDenoiseEnabled: Bool { activeAIDenoise || (!isHDREditing && (!isWaveletDefault ? waveletNoiseReduction.enabled : denoiseMode > 0)) }
    public var denoiseSummary: String {
        if activeAIDenoise { return L10n.text("AI 降噪") }
        if !isWaveletDefault { return waveletNoiseReduction.enabled ? waveletNoiseReduction.preset.title : L10n.text("停用") }
        if denoiseMode == 0 { return L10n.text("停用") }
        if denoiseMode == 3 { return L10n.text("旧版 FBDD") }
        return L10n.format("旧版：%@", String(describing: ChromaNoiseReductionMode(rawValue: denoiseMode)?.title ?? L10n.text("色度降噪")))
    }
    public mutating func setDenoiseEnabled(_ enabled: Bool) {
        var s = waveletNoiseReduction; s.enabled = enabled; waveletNoiseReduction = s; rawNoiseReduction = 0; chromaNoiseReduction = 0
    }
    public mutating func applyDenoisePreset(_ preset: DenoisePreset) {
        guard preset != .custom else { return }
        var s = WaveletDenoiseSettings(); s.apply(preset); waveletNoiseReduction = s; rawNoiseReduction = 0; chromaNoiseReduction = 0
    }
    public mutating func setDenoiseParameter(_ parameter: DenoiseParameter, to value: Double) {
        guard value.isFinite else { return }
        var s = waveletNoiseReduction; let v = min(100, max(0, (value * 10).rounded() / 10))
        guard s[keyPath: parameter.keyPath] != v else { return }
        s[keyPath: parameter.keyPath] = v; s.preset = .custom; waveletNoiseReduction = s
    }
    public var denoiseMode: Double {
        get { chromaNoiseReduction > 0 ? Double(chromaNoiseReduction) : (rawNoiseReduction > 0 ? 3 : 0) }
        set { guard ChromaNoiseReductionMode(rawValue: newValue) != nil else { return }; waveletNoiseReduction = WaveletDenoiseSettings(); chromaNoiseReduction = Int(newValue.rounded()); rawNoiseReduction = 0 }
    }

    public var usesAsShotWhiteBalance: Bool {
        whiteBalanceMode == .asShot || (masterRecipe == nil && temperature == asShotWhiteBalance?.temperature && tint == asShotWhiteBalance?.tint)
    }

    public func resolvedRenderValues() -> ResolvedRenderValues {
        let recipeActive = masterRecipe != nil, scale = recipeActive ? strength : 1, tintOffset = recipeActive ? tint * scale : 0
        let cameraWB = usesAsShotWhiteBalance, effectiveTemp = cameraWB ? (asShotWhiteBalance?.temperature ?? 6500) : temperature
        let effectiveTint = recipeActive ? (asShotWhiteBalance?.tint ?? 0) + tintOffset : tint, temperatureWB = !cameraWB || tintOffset != 0
        return ResolvedRenderValues(
            usesTemperatureWB: temperatureWB, exposureEV: Float(exposure * scale), brightness: 1,
            temperature: temperatureWB ? Float(effectiveTemp) : 6500,
            tint: temperatureWB ? Float(recipeActive ? min(150, max(-150, effectiveTint)) : effectiveTint) : 0,
            contrast: Float(1 + (contrast - 1) * scale), saturation: Float(1 + (saturation - 1) * scale),
            highlights: Float(highlights * scale), shadows: Float(shadows * scale),
            toneCurve: curveSettings.mode == .custom ? 0 : Float(min(1, max(-1, toneCurve * refinementScale))),
            sharpening: Float(sharpening)
        )
    }

    public mutating func applyMasterRecipe(_ recipe: MasterRecipe) {
        masterRecipeID = recipe.id; lutID = nil; masterRecipeSettingsVersion = recipe.version; strength = 1
        exposure = recipe.exposureDelta; shadows = recipe.shadowsDelta / 100; highlights = -recipe.highlightsDelta / 100
        contrast = 1 + recipe.contrastDelta / 100; saturation = 1 + recipe.saturationDelta / 100; tint = recipe.tintDelta
        hsl = recipe.hsl.isIdentity ? nil : recipe.hsl
        if recipe.version >= 4 {
            toneControls = recipe.tone?.isIdentity == true ? nil : recipe.tone
            atmosphere = recipe.atmosphere?.isIdentity == true ? nil : recipe.atmosphere
            gradingSettings = recipe.grading ?? ColorGradingSettings()
            curveSettings = recipe.curve ?? ToneCurveSettings(); toneCurve = 0
        }
    }

    public func renderedRecipe(cameraTemperature: Double, cameraTint: Double) -> Adjustments {
        guard masterRecipeID != nil else { return self }
        var result = self; let scale = recipeScale
        result.exposure *= scale; result.shadows *= scale; result.highlights *= scale
        result.contrast = 1 + (contrast - 1) * scale; result.saturation = 1 + (saturation - 1) * scale
        result.hslSettings = hslSettings.scaled(by: recipeSettingsVersion >= 3 ? scale : 1)
        if recipeSettingsVersion >= 4 {
            let tone = toneSettings.scaled(by: scale), atm = atmosphereSettings.scaled(by: scale)
            result.toneControls = tone.isIdentity ? nil : tone; result.atmosphere = atm.isIdentity ? nil : atm
            result.gradingSettings = gradingSettings.scaled(by: scale); result.curveSettings = curveSettings.scaled(by: scale)
            result.toneCurve = min(1, max(-1, toneCurve * scale))
        }
        if whiteBalanceMode == .camera { result.temperature = cameraTemperature }
        result.tint = min(150, max(-150, cameraTint + tint * scale))
        if tint * scale != 0 { result.whiteBalanceMode = .custom }
        result.masterRecipeID = nil; result.masterRecipeSettingsVersion = 3; return result
    }

    public func editorEffectiveValues(isRaw: Bool, cameraTemperature: Double, cameraTint: Double) -> [Float] {
        var effective = renderedRecipe(cameraTemperature: cameraTemperature, cameraTint: cameraTint)
        if !isRaw { if masterRecipeID != nil || effective.whiteBalanceMode != .camera { effective.temperature = 6500; effective.tint = 0 } }
        else if effective.whiteBalanceMode == .camera { effective.temperature = 6500; effective.tint = 0 }
        return [effective.exposure, effective.contrast, effective.saturation, effective.temperature, effective.tint,
                effective.highlights, effective.shadows, effective.toneCurve, 0.0, effective.sharpening].map(Float.init) +
            [Float(isRaw && effective.whiteBalanceMode == .custom ? 1 : 0)] +
            (effective.hslSettings.hue + effective.hslSettings.saturation + effective.hslSettings.lightness).map(Float.init)
    }

    @discardableResult public mutating func clearMasterRecipe(isRaw: Bool = true) -> Bool {
        guard masterRecipeID != nil else { return true }
        let ctx = EditorAdjustmentContext(isRaw: isRaw, defaultExposureMode: exposureMode, neutralFilmID: "")
        guard var independent = try? detachingRecipeForReset(context: ctx) else { return false }
        independent.strength = strength; self = independent; return true
    }

    public mutating func reset(_ group: AdjustmentGroup) {
        if isHDREditing {
            for p in group.parameters where p.hdrKeyPath != nil { set(p, to: p.spec(for: self).defaultValue) }
            if group == .tone { hdr?.toneSettings.curve = ToneCurveSettings() }
            if group == .color { hdr?.colorSettings = HDRColorSettings() }
            if group == .detail { hdrCameraAIEnabled = false }
            if group == .geometry { hdr?.geometry = GeometrySettings() }
            return
        }
        if group == .film { guard clearMasterRecipe() else { return } }
        for p in group.parameters { set(p, to: p.spec(for: self).defaultValue) }
        if group == .input { exposureMode = .preview; resetWhiteBalance() }
        if group == .color {
            hsl = nil; colorGrading = nil
            cameraCalibration = nil; pointColor = nil; selectiveColor = nil; bwMixer = nil
        }
        if group == .tone { toneCurveConfig = nil }
        if group == .detail { aiDenoiseEnabled = false; aiDenoiseStrength = 100.0; sharpenV2 = nil }
        if group == .effects { photoEffects = nil; atmosphere = nil; filmOptics = nil }
        if group == .lens { lensCorrection = nil }
        if group == .geometry { geometry = nil }
    }

    public func isDefault(_ group: AdjustmentGroup) -> Bool {
        if isHDREditing {
            return group.parameters.filter { $0.hdrKeyPath != nil }.allSatisfy { $0.value(from: self) == $0.spec(for: self).defaultValue }
                && (group != .geometry || geometrySettings.isIdentity) && (group != .tone || editingCurveSettings.isDefault)
                && (group != .color || (hdr?.colorSettings.isDefault ?? true)) && (group != .detail || !hdrCameraAIEnabled)
        }
        return group.parameters.allSatisfy { self[keyPath: $0.spec.keyPath] == $0.spec(for: self).defaultValue }
            && (group != .input || exposureMode == .preview) && (group != .tone || curveSettings.isDefault)
            && (group != .color || (hslSettings.isIdentity && gradingSettings.isDefault
                && calibrationSettings.isDefault && pointColorSettings.isDefault
                && selectiveColorSettings.isDefault && bwMixerSettings.isDefault))
            && (group != .detail || (!isDenoiseEnabled && aiDenoiseStrength == 100.0 && sharpenV2Settings.isDefault))
            && (group != .effects || (effectSettings == PhotoEffectsSettings() && atmosphereSettings.isIdentity && filmOpticsSettings.isDefault))
            && (group != .film || masterRecipeID == nil) && (group != .lens || lensSettings == LensCorrectionSettings())
            && (group != .geometry || geometrySettings.isIdentity)
    }

    public mutating func resolveWhiteBalance(_ camera: WhiteBalance?) {
        asShotWhiteBalance = camera; if isHDREditing { return }
        if whiteBalanceMode == .asShot { if masterRecipe != nil { temperature = camera?.temperature ?? 6500 } else { resetWhiteBalance() } }
    }
    public mutating func resetWhiteBalance() {
        if isHDREditing { hdr?.temperature = 6500; hdr?.tint = 0; return }
        temperature = asShotWhiteBalance?.temperature ?? 6500; tint = masterRecipe != nil ? 0 : (asShotWhiteBalance?.tint ?? 0); whiteBalanceMode = .asShot
    }
    public var isWhiteBalanceDefault: Bool {
        if isHDREditing { return hdr?.temperature == 6500 && hdr?.tint == 0 }
        return [AdjustmentParameter.temperature, .tint].allSatisfy { self[keyPath: $0.spec.keyPath] == $0.spec(for: self).defaultValue }
    }
    public mutating func resolveRawNoiseReductionSupport(_ supported: Bool) {
        supportsRawNoiseReduction = supported; if !supported && !isHDREditing { rawNoiseReduction = 0 }
    }
    public mutating func set(_ parameter: AdjustmentParameter, to value: Double) {
        if isHDREditing {
            guard let key = parameter.hdrKeyPath, var state = hdr, value.isFinite else { return }
            state[keyPath: key] = value; guard state.isValid else { return }; hdr = state; return
        }
        self[keyPath: parameter.spec.keyPath] = value
        if parameter.isWhiteBalance, let camera = asShotWhiteBalance {
            if masterRecipe != nil { if parameter == .temperature { whiteBalanceMode = temperature == camera.temperature ? .asShot : .custom } }
            else { whiteBalanceMode = temperature == camera.temperature && tint == camera.tint ? .asShot : .custom }
        }
    }
    public mutating func resetAll() {
        if isHDREditing { hdr?.reset(); hdrCameraAIEnabled = false; return }
        let (h, hAI, d, p, x, c, n) = (hdr, hdrCameraAI, proRAWDecodeVersion, processing, x3fMode, asShotWhiteBalance, supportsRawNoiseReduction)
        self = Adjustments(); hdr = h; hdrCameraAI = hAI; proRAWDecodeVersion = d; processing = p; x3fMode = x
        resolveWhiteBalance(c); resolveRawNoiseReductionSupport(n)
    }
    public var isDefault: Bool { AdjustmentGroup.allCases.allSatisfy { isDefault($0) } }
    public var resolvedForRaster: Adjustments {
        if isHDREditing { return self }
        var state = self; state.exposureMode = .sensor
        if state.whiteBalanceMode != .asShot || state.asShotWhiteBalance != nil || state.masterRecipe != nil {
            state.whiteBalanceMode = .asShot; state.resolveWhiteBalance(nil); state.temperature = 6500; state.tint = 0
        }
        state.rawNoiseReduction = 0; state.aiDenoiseEnabled = false
        state.lensCorrection = state.lensCorrection?.defringeOnly
        return state
    }

    public func validateResetValues() throws {
        if isHDREditing { guard hdr?.isValid == true else { throw EditorResetBlockedReason.invalidSnapshot("hdr") }; return }
        for p in [AdjustmentParameter.strength, .exposure, .temperature, .tint, .contrast, .highlights, .shadows, .toneCurve, .blackPoint, .whitePoint, .vibrance, .saturation, .sharpening, .rawNoiseReduction] {
            let v = self[keyPath: p.spec.keyPath]
            guard v.isFinite, p.spec.range.contains(v) else { throw EditorResetBlockedReason.invalidSnapshot(p.rawValue) }
        }
        guard rawNoiseReduction.rounded() == rawNoiseReduction, aiDenoiseStrength.isFinite, (0...100).contains(aiDenoiseStrength),
              (0...2).contains(chromaNoiseReduction), waveletNoiseReduction.isValid else {
            throw EditorResetBlockedReason.invalidSnapshot("denoise")
        }
        guard PhotoEffectParameter.allCases.allSatisfy({ let v = effectSettings[keyPath: $0.keyPath]; return v.isFinite && $0.range.contains(v) }),
              hslSettings.isValid, geometrySettings.isValid, atmosphereSettings.isValid, gradingSettings.isValid, curveSettings.isValid,
              calibrationSettings.isValid, pointColorSettings.isValid, selectiveColorSettings.isValid, bwMixerSettings.isValid,
              sharpenV2Settings.isValid, filmOpticsSettings.isValid, lensSettings.isValid else {
            throw EditorResetBlockedReason.invalidSnapshot("effects/hsl/geometry")
        }
        if let lens = lensCorrection {
            guard (lens.focalLength.map { $0.isFinite && $0 > 0 } ?? true), (lens.cropFactor.map { $0.isFinite && $0 > 0 } ?? true) else {
                throw EditorResetBlockedReason.invalidSnapshot("lensCorrection")
            }
        }
        if let cam = asShotWhiteBalance {
            guard cam.temperature.isFinite, cam.tint.isFinite, AdjustmentParameter.temperature.spec.range.contains(cam.temperature),
                  AdjustmentParameter.tint.spec.range.contains(cam.tint) else { throw EditorResetBlockedReason.invalidSnapshot("asShotWhiteBalance") }
        }
        if masterRecipeID != nil {
            guard masterRecipe != nil, [2, 3, 4].contains(masterRecipeSettingsVersion ?? 2) else {
                throw EditorResetBlockedReason.invalidSnapshot("masterRecipe")
            }
        }
    }

    private func resetCoreValues(context: EditorAdjustmentContext) -> [Float] {
        let effective = context.isRaw ? self : resolvedForRaster, rendered = effective.resolvedRenderValues()
        let tone = effective.renderToneSettings, atm = effective.renderAtmosphereSettings
        let grading = effective.renderGradingSettings, curve = effective.renderCurveSettings
        var out: [Float] = [Float(rendered.usesTemperatureWB ? 1 : 0), rendered.exposureEV, rendered.brightness, rendered.temperature, rendered.tint,
                            rendered.contrast, rendered.saturation, rendered.highlights, rendered.shadows, rendered.toneCurve, rendered.sharpening]
        out += (effective.renderHSLSettings.hue + effective.renderHSLSettings.saturation + effective.renderHSLSettings.lightness).map(Float.init)
        out += [tone.blackPoint, tone.whitePoint, tone.vibrance, atm.clarity, atm.dehaze].map(Float.init)
        out += ColorGradingZone.allCases.flatMap { [Float(grading[$0].hue), Float(grading[$0].saturation), Float(grading[$0].luminance)] }
        out += [Float(grading.global.hue), Float(grading.global.saturation), Float(grading.global.luminance), Float(grading.blending), Float(grading.balance)]
        if !context.isRaw { out += [Float(effective.temperature), Float(effective.tint)] }
        for channel in ToneCurveChannel.allCases {
            let s = curve.shape(channel)
            out.append(s.mode == .custom ? 1 : 0)
            out += s.points.flatMap { [Float($0.x), Float($0.y)] }
        }
        return out
    }

    internal func detachingRecipeForReset(context: EditorAdjustmentContext) throws -> Adjustments {
        try validateResetValues()
        var result = self; let renderedHSL = renderHSLSettings
        if masterRecipe != nil {
            let tone = renderToneSettings, atm = renderAtmosphereSettings, scale = strength
            result.toneControls = tone.isIdentity ? nil : tone; result.atmosphere = atm.isIdentity ? nil : atm
            result.gradingSettings = renderGradingSettings; result.curveSettings = renderCurveSettings
            result.toneCurve = min(1, max(-1, toneCurve * refinementScale))
            result.exposure = exposure * scale; result.contrast = 1 + (contrast - 1) * scale
            result.highlights = highlights * scale; result.shadows = shadows * scale; result.saturation = 1 + (saturation - 1) * scale
            if context.isRaw {
                if (tint * scale != 0 || !usesAsShotWhiteBalance) && asShotWhiteBalance == nil { throw EditorResetBlockedReason.missingAsShotWhiteBalance }
                let before = resolvedRenderValues(); result.masterRecipeID = nil
                if !before.usesTemperatureWB { result.resetWhiteBalance() }
                else { result.whiteBalanceMode = .custom; result.temperature = Double(before.temperature); result.tint = Double(before.tint) }
            } else {
                result.masterRecipeID = nil; result.whiteBalanceMode = .asShot; result.temperature = 6500; result.tint = 0
            }
            result.hsl = renderedHSL.isIdentity ? nil : renderedHSL
        }
        result.masterRecipeID = nil; result.masterRecipeSettingsVersion = 3; result.strength = 1
        try result.validateResetValues()
        guard result.resetCoreValues(context: context) == resetCoreValues(context: context) else { throw EditorResetBlockedReason.unrepresentableRecipe }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case settingsVersion, toneCurveConfig, colorGrading, atmosphere, toneControls, processing, x3fMode, hdr, proRAWDecodeVersion
        case exposureMode, exposure, temperature, tint, whiteBalanceMode, asShotWhiteBalance, strength, contrast, highlights, shadows
        case toneCurve, saturation, sharpening, rawNoiseReduction, chromaNoiseReduction, waveletNoiseReduction, aiDenoiseEnabled, aiDenoiseBlend, hdrCameraAI
        case photoEffects, hsl, lensCorrection, geometry, supportsRawNoiseReduction, masterRecipeID, masterRecipeSettingsVersion
        case lutID, lutStrength, denoise, displayChromaDenoise
        case cameraCalibration, pointColor, selectiveColor, bwMixer, sharpenV2, filmOptics
    }
    private enum WireFormat { case canonicalV2, legacyIOSV1, legacyMacV1 }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let isLegacyV1 = (encoder.userInfo[Self.legacyV1EncodingKey] as? Bool) == true
        try c.encodeIfPresent(toneCurveConfig, forKey: .toneCurveConfig); try c.encodeIfPresent(colorGrading, forKey: .colorGrading)
        try c.encodeIfPresent(atmosphere, forKey: .atmosphere); try c.encodeIfPresent(toneControls, forKey: .toneControls)
        try c.encode(processing, forKey: .processing); try c.encode(x3fMode, forKey: .x3fMode)
        try c.encodeIfPresent(hdr, forKey: .hdr); try c.encodeIfPresent(proRAWDecodeVersion, forKey: .proRAWDecodeVersion)
        try c.encode(exposureMode, forKey: .exposureMode); try c.encode(exposure, forKey: .exposure)
        try c.encode(temperature, forKey: .temperature); try c.encode(tint, forKey: .tint)
        try c.encode(whiteBalanceMode, forKey: .whiteBalanceMode); try c.encodeIfPresent(asShotWhiteBalance, forKey: .asShotWhiteBalance)
        try c.encode(strength, forKey: .strength)
        if isLegacyV1 {
            try c.encode((contrast - 1) * 100, forKey: .contrast); try c.encode(highlights == 0 ? 0 : -highlights * 100, forKey: .highlights)
            try c.encode(shadows * 100, forKey: .shadows); try c.encode(toneCurve * 100, forKey: .toneCurve)
            try c.encode((saturation - 1) * 100, forKey: .saturation); try c.encode(sharpening * 100, forKey: .sharpening)
            try c.encode(rawNoiseReduction, forKey: .rawNoiseReduction)
            if chromaNoiseReduction != 0 { try c.encode(Double(chromaNoiseReduction), forKey: .chromaNoiseReduction) }
            if waveletNoiseReduction != WaveletDenoiseSettings() { try c.encode(waveletNoiseReduction, forKey: .waveletNoiseReduction) }
        } else {
            try c.encode(2, forKey: .settingsVersion); try c.encode(contrast, forKey: .contrast); try c.encode(highlights, forKey: .highlights)
            try c.encode(shadows, forKey: .shadows); try c.encode(toneCurve, forKey: .toneCurve); try c.encode(saturation, forKey: .saturation)
            try c.encode(sharpening, forKey: .sharpening); try c.encode(rawNoiseReduction, forKey: .rawNoiseReduction)
            try c.encode(chromaNoiseReduction, forKey: .chromaNoiseReduction); try c.encode(waveletNoiseReduction, forKey: .waveletNoiseReduction)
            try c.encodeIfPresent(lutID, forKey: .lutID)
        }
        try c.encode(aiDenoiseEnabled, forKey: .aiDenoiseEnabled); try c.encodeIfPresent(aiDenoiseBlend, forKey: .aiDenoiseBlend)
        try c.encodeIfPresent(hdrCameraAI, forKey: .hdrCameraAI); try c.encodeIfPresent(photoEffects, forKey: .photoEffects)
        try c.encodeIfPresent(hsl, forKey: .hsl); try c.encodeIfPresent(lensCorrection, forKey: .lensCorrection)
        try c.encodeIfPresent(geometry, forKey: .geometry); try c.encode(supportsRawNoiseReduction, forKey: .supportsRawNoiseReduction)
        try c.encodeIfPresent(masterRecipeID, forKey: .masterRecipeID); try c.encodeIfPresent(masterRecipeSettingsVersion, forKey: .masterRecipeSettingsVersion)
        try c.encodeIfPresent(cameraCalibration, forKey: .cameraCalibration)
        try c.encodeIfPresent(pointColor, forKey: .pointColor)
        try c.encodeIfPresent(selectiveColor, forKey: .selectiveColor)
        try c.encodeIfPresent(bwMixer, forKey: .bwMixer)
        try c.encodeIfPresent(sharpenV2, forKey: .sharpenV2)
        try c.encodeIfPresent(filmOptics, forKey: .filmOptics)
    }

    public init(from decoder: Decoder) throws { try self.init(from: decoder, defaultLegacyFlavor: nil) }

    internal init(from decoder: Decoder, defaultLegacyFlavor: LegacyWireFlavor?) throws {
        self.init()
        let v = try decoder.container(keyedBy: CodingKeys.self)
        let settingsVersion = try v.decodeIfPresent(Int.self, forKey: .settingsVersion)
        guard settingsVersion == nil || settingsVersion == 1 || settingsVersion == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .settingsVersion, in: v, debugDescription: "Unsupported settings version")
        }
        let format: WireFormat
        if settingsVersion == 2 { format = .canonicalV2 }
        else if v.contains(.lutID) || v.contains(.lutStrength) || v.contains(.denoise) || v.contains(.displayChromaDenoise)
            || ((try? v.decodeIfPresent(Int.self, forKey: .exposureMode)) != nil) { format = .legacyIOSV1 }
        else if (["标准显影", "匹配内嵌预览", "传感器基准"].contains((try? v.decodeIfPresent(String.self, forKey: .exposureMode)) ?? ""))
            || (["拍摄时设置", "自定义"].contains((try? v.decodeIfPresent(String.self, forKey: .whiteBalanceMode)) ?? ""))
            || v.contains(.chromaNoiseReduction) || v.contains(.waveletNoiseReduction) || v.contains(.strength)
            || v.contains(.asShotWhiteBalance) || v.contains(.supportsRawNoiseReduction) { format = .legacyMacV1 }
        else if (["camera", "custom"].contains((try? v.decodeIfPresent(String.self, forKey: .whiteBalanceMode)) ?? "")) { format = .legacyIOSV1 }
        else if v.contains(.aiDenoiseEnabled) { format = .legacyMacV1 }
        else {
            let hint = (decoder.userInfo[Self.legacyFormatHintKey] as? LegacyWireFlavor) ?? defaultLegacyFlavor
            format = hint == .ios ? .legacyIOSV1 : .legacyMacV1
        }
        processing = v.contains(.processing) ? try v.decode(ProcessingIdentity.self, forKey: .processing) : .legacy
        x3fMode = v.contains(.x3fMode) ? try v.decode(X3fMode.self, forKey: .x3fMode) : .legacy
        hdr = try v.decodeIfPresent(HDRSettings.self, forKey: .hdr); proRAWDecodeVersion = try v.decodeIfPresent(Int.self, forKey: .proRAWDecodeVersion)
        toneCurveConfig = try v.decodeIfPresent(ToneCurveSettings.self, forKey: .toneCurveConfig); if toneCurveConfig?.isDefault == true { toneCurveConfig = nil }
        colorGrading = try v.decodeIfPresent(ColorGradingSettings.self, forKey: .colorGrading); if colorGrading?.isDefault == true { colorGrading = nil }
        atmosphere = try v.decodeIfPresent(AtmosphereSettings.self, forKey: .atmosphere)
        guard atmosphereSettings.isValid else { throw DecodingError.dataCorruptedError(forKey: .atmosphere, in: v, debugDescription: "Invalid atmosphere controls") }
        if atmosphere?.isIdentity == true { atmosphere = nil }
        toneControls = try v.decodeIfPresent(ToneControlsSettings.self, forKey: .toneControls)
        guard toneSettings.isValid else { throw DecodingError.dataCorruptedError(forKey: .toneControls, in: v, debugDescription: "Invalid tone controls") }
        if toneControls?.isIdentity == true { toneControls = nil }
        exposureMode = try v.decodeIfPresent(ExposureMode.self, forKey: .exposureMode) ?? .scene
        exposure = try v.decodeIfPresent(Double.self, forKey: .exposure) ?? 0; if exposure == 0 { exposure = 0 }
        temperature = try v.decodeIfPresent(Double.self, forKey: .temperature) ?? 6500
        tint = try v.decodeIfPresent(Double.self, forKey: .tint) ?? 0; if tint == 0 { tint = 0 }
        whiteBalanceMode = try v.decodeIfPresent(WhiteBalanceMode.self, forKey: .whiteBalanceMode) ?? .camera
        asShotWhiteBalance = try v.decodeIfPresent(WhiteBalance.self, forKey: .asShotWhiteBalance)
        let (rawStrength, rawContrast, rawHighlights, rawShadows, rawToneCurve, rawSaturation, rawSharpening) = (
            try v.decodeIfPresent(Double.self, forKey: .strength), try v.decodeIfPresent(Double.self, forKey: .contrast),
            try v.decodeIfPresent(Double.self, forKey: .highlights), try v.decodeIfPresent(Double.self, forKey: .shadows),
            try v.decodeIfPresent(Double.self, forKey: .toneCurve), try v.decodeIfPresent(Double.self, forKey: .saturation),
            try v.decodeIfPresent(Double.self, forKey: .sharpening)
        )
        switch format {
        case .canonicalV2, .legacyIOSV1:
            let ls = format == .legacyIOSV1 ? try v.decodeIfPresent(Double.self, forKey: .lutStrength) : nil
            strength = ls ?? rawStrength ?? 1; contrast = rawContrast ?? 1; highlights = rawHighlights ?? 0; shadows = rawShadows ?? 0
            toneCurve = rawToneCurve ?? 0; saturation = rawSaturation ?? 1; sharpening = rawSharpening ?? 0; lutID = try v.decodeIfPresent(String.self, forKey: .lutID)
        case .legacyMacV1:
            strength = rawStrength ?? 1; contrast = rawContrast.map { 1 + $0 / 100 } ?? 1; highlights = rawHighlights.map { -$0 / 100 } ?? 0
            shadows = rawShadows.map { $0 / 100 } ?? 0; toneCurve = rawToneCurve.map { $0 / 100 } ?? 0
            saturation = rawSaturation.map { 1 + $0 / 100 } ?? 1; sharpening = rawSharpening.map { $0 / 100 } ?? 0; lutID = nil
        }
        if highlights == 0 { highlights = 0 }; if shadows == 0 { shadows = 0 }; if toneCurve == 0 { toneCurve = 0 }; if sharpening == 0 { sharpening = 0 }
        rawNoiseReduction = try v.decodeIfPresent(Double.self, forKey: .rawNoiseReduction) ?? 0
        if let rawChroma = try v.decodeIfPresent(Double.self, forKey: .chromaNoiseReduction) ?? (try v.decodeIfPresent(Double.self, forKey: .displayChromaDenoise)) {
            guard rawChroma.isFinite, (0...2).contains(rawChroma), rawChroma.rounded() == rawChroma else {
                throw DecodingError.dataCorruptedError(forKey: .chromaNoiseReduction, in: v, debugDescription: "Invalid chroma noise reduction")
            }
            chromaNoiseReduction = Int(rawChroma.rounded())
        }
        waveletNoiseReduction = try (v.decodeIfPresent(WaveletDenoiseSettings.self, forKey: .denoise) ?? v.decodeIfPresent(WaveletDenoiseSettings.self, forKey: .waveletNoiseReduction)) ?? WaveletDenoiseSettings()
        guard waveletNoiseReduction.isValid else { throw DecodingError.dataCorruptedError(forKey: .waveletNoiseReduction, in: v, debugDescription: "Invalid denoise strengths") }
        aiDenoiseEnabled = try v.decodeIfPresent(Bool.self, forKey: .aiDenoiseEnabled) ?? false
        if let blend = try v.decodeIfPresent(Double.self, forKey: .aiDenoiseBlend) {
            guard blend.isFinite, (0.0...100.0).contains(blend) else { throw DecodingError.dataCorruptedError(forKey: .aiDenoiseBlend, in: v, debugDescription: "Invalid AI denoise strength") }
            aiDenoiseBlend = blend == 100.0 ? nil : blend
        }
        hdrCameraAIEnabled = try v.decodeIfPresent(Bool.self, forKey: .hdrCameraAI) ?? false
        if hdrCameraAIEnabled && (hdr?.cameraDevelopmentSettings.fbddLevel != 0 || hdr?.cameraDevelopmentSettings.cameraProfile != nil) {
            throw DecodingError.dataCorruptedError(forKey: .hdrCameraAI, in: v, debugDescription: "HDR Bayer AI requires a camera HDR record without FBDD or a camera profile")
        }
        photoEffects = try v.decodeIfPresent(PhotoEffectsSettings.self, forKey: .photoEffects); if photoEffects?.isDefault == true { photoEffects = nil }
        hsl = try v.decodeIfPresent(HSLSettings.self, forKey: .hsl)
        guard hslSettings.isValid else { throw DecodingError.dataCorruptedError(forKey: .hsl, in: v, debugDescription: "Invalid HSL parameters") }
        if hsl?.isIdentity == true { hsl = nil }
        lensCorrection = try v.decodeIfPresent(LensCorrectionSettings.self, forKey: .lensCorrection)
        cameraCalibration = try v.decodeIfPresent(CameraCalibrationSettings.self, forKey: .cameraCalibration)
        if cameraCalibration?.isDefault == true { cameraCalibration = nil }
        pointColor = try v.decodeIfPresent(PointColorSettings.self, forKey: .pointColor)
        if pointColor?.isDefault == true { pointColor = nil }
        selectiveColor = try v.decodeIfPresent(SelectiveColorSettings.self, forKey: .selectiveColor)
        if selectiveColor?.isDefault == true { selectiveColor = nil }
        bwMixer = try v.decodeIfPresent(BwMixerSettings.self, forKey: .bwMixer)
        if bwMixer?.isDefault == true { bwMixer = nil }
        sharpenV2 = try v.decodeIfPresent(SharpenV2Settings.self, forKey: .sharpenV2)
        if sharpenV2?.isDefault == true { sharpenV2 = nil }
        filmOptics = try v.decodeIfPresent(FilmOpticsSettings.self, forKey: .filmOptics)
        if filmOptics?.isDefault == true { filmOptics = nil }
        geometry = try v.decodeIfPresent(GeometrySettings.self, forKey: .geometry)
        guard geometrySettings.isValid else { throw DecodingError.dataCorruptedError(forKey: .geometry, in: v, debugDescription: "Invalid geometry parameters") }
        if geometry?.isIdentity == true { geometry = nil }
        supportsRawNoiseReduction = try v.decodeIfPresent(Bool.self, forKey: .supportsRawNoiseReduction) ?? false
        masterRecipeID = try v.decodeIfPresent(String.self, forKey: .masterRecipeID)
        let version = try v.decodeIfPresent(Int.self, forKey: .masterRecipeSettingsVersion)
        guard [2, 3, 4].contains(version ?? 3) else { throw DecodingError.dataCorruptedError(forKey: .masterRecipeSettingsVersion, in: v, debugDescription: "Invalid master recipe version") }
        if format == .legacyMacV1 {
            masterRecipeSettingsVersion = masterRecipeID == nil ? 3 : (version ?? 2)
            if version == nil, let recipe = masterRecipe {
                let d = recipe.migrationDefaults, cameraWB = whiteBalanceMode == .asShot || (temperature == asShotWhiteBalance?.temperature && tint == asShotWhiteBalance?.tint)
                exposure += d.exposureDelta; shadows += d.shadowsDelta / 100; highlights += -d.highlightsDelta / 100
                contrast += d.contrastDelta / 100; saturation += d.saturationDelta / 100
                tint = (cameraWB ? 0 : tint - (asShotWhiteBalance?.tint ?? 0)) + d.tintDelta
                if cameraWB { whiteBalanceMode = .asShot }
            }
        } else { masterRecipeSettingsVersion = version ?? 3 }
    }

    public func withHDRMode(_ enabled: Bool, sourceIsHDR: Bool, cameraRAW: Bool = false) throws -> Adjustments {
        var result = self
        guard enabled else { result.hdr?.mode = .sdr; return result }
        var initial = HDRSettings()
        if !cameraRAW {
            let scale = recipeScale
            initial.exposure = min(4, max(-4, exposure * scale)); initial.contrast = min(100, max(-100, (contrast - 1) * 100 * scale))
            initial.highlights = min(100, max(-100, -highlights * 100 * scale)); initial.shadows = min(100, max(-100, shadows * scale * 100))
            initial.saturation = min(100, max(-100, (saturation - 1) * 100 * scale)); initial.geometry = geometry ?? GeometrySettings()
        }
        result.hdr = try HDRSettings.enabling(stored: hdr, initial: initial, sourceIsHDR: sourceIsHDR || cameraRAW); return result
    }
}

public typealias RawSettings = Adjustments
public typealias PhotoAdjustments = Adjustments

public struct PhotoEditState: Codable, Equatable {
    public var settings: Adjustments
    public var filmID: String?
    public var masterRecipeID: String?
    public var updatedAt: Date

    public init(settings: Adjustments = Adjustments(), filmID: String? = nil, updatedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.settings = settings; self.filmID = filmID ?? settings.lutID
        self.masterRecipeID = settings.masterRecipeID; self.updatedAt = updatedAt
    }
    public init(settings: Adjustments = Adjustments(), filmID: String, masterRecipeID: String?) {
        self.settings = settings; self.filmID = filmID; self.masterRecipeID = masterRecipeID; self.updatedAt = Date(timeIntervalSince1970: 0)
    }
    private init(settings: Adjustments, exactFilmID: String?, masterRecipeID: String?, updatedAt: Date) {
        self.settings = settings; self.filmID = exactFilmID; self.masterRecipeID = masterRecipeID; self.updatedAt = updatedAt
    }
    public func replacing(settings: Adjustments, preservingFilmID filmID: String?) -> PhotoEditState {
        PhotoEditState(settings: settings, exactFilmID: filmID, masterRecipeID: settings.masterRecipeID, updatedAt: updatedAt)
    }
    public func hasSameAdjustments(as other: PhotoEditState) -> Bool { settings == other.settings && filmID == other.filmID }
    public func withUpdatedAt(_ date: Date) -> PhotoEditState { .init(settings: settings, exactFilmID: filmID, masterRecipeID: masterRecipeID, updatedAt: date) }

    private enum CodingKeys: String, CodingKey { case settings, filmID, masterRecipeID, updatedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        settings = try Adjustments(from: try values.superDecoder(forKey: .settings), defaultLegacyFlavor: values.contains(.updatedAt) ? .ios : .mac)
        filmID = try values.decodeIfPresent(String.self, forKey: .filmID)
        masterRecipeID = try values.decodeIfPresent(String.self, forKey: .masterRecipeID)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let isLegacyV1 = (encoder.userInfo[Adjustments.legacyV1EncodingKey] as? Bool) == true
        try container.encode(settings, forKey: .settings)
        if isLegacyV1 {
            try container.encode(filmID ?? "", forKey: .filmID); try container.encodeIfPresent(masterRecipeID, forKey: .masterRecipeID)
        } else {
            try container.encodeIfPresent(filmID, forKey: .filmID); try container.encodeIfPresent(masterRecipeID, forKey: .masterRecipeID)
            if updatedAt != Date(timeIntervalSince1970: 0) { try container.encode(updatedAt, forKey: .updatedAt) }
        }
    }
}

public typealias MacPhotoEditState = PhotoEditState

public struct MacPhotoEditSession {
    private var edits: [URL: PhotoEditState] = [:]
    public init() {}
    public mutating func save(_ url: URL, settings: Adjustments, filmID: String, masterRecipeID: String? = nil) {
        edits[url.standardizedFileURL] = PhotoEditState(settings: settings, filmID: filmID, masterRecipeID: masterRecipeID)
    }
    public func state(for url: URL, defaultFilmID: String) -> PhotoEditState {
        edits[url.standardizedFileURL] ?? PhotoEditState(settings: Adjustments(), filmID: defaultFilmID, masterRecipeID: nil)
    }
}
