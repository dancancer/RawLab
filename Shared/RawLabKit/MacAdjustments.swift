import Foundation

public struct ResolvedMacRenderValues: Equatable, Sendable {
    public let usesTemperatureWB: Bool
    public let exposureEV: Float
    public let brightness: Float
    public let temperature: Float
    public let tint: Float
    public let contrast: Float
    public let saturation: Float
    public let highlights: Float
    public let shadows: Float
    public let toneCurve: Float
    public let sharpening: Float
}

public struct Adjustments: Equatable, Codable {
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
    public var hdr: HDRSettings?
    public var proRAWDecodeVersion: Int?
    public var isHDREditing: Bool { hdr?.mode == .hdr }
    public var exposureMode = ExposureMode.preview
    public var exposure = 0.0
    public var temperature = 6500.0
    public var tint = 0.0
    public var whiteBalanceMode = WhiteBalanceMode.asShot
    public private(set) var asShotWhiteBalance: WhiteBalance?
    public var strength = 1.0
    public var contrast = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    public var toneCurve = 0.0
    public var saturation = 0.0
    public var sharpening = 0.0
    public var rawNoiseReduction = 0.0
    // 缺少此字段的旧记录继续按 FBDD 解释，不静默切换算法。
    public var chromaNoiseReduction: Double?
    // nil 保留旧算法语义，显式启用或选择预设后才迁移。
    public var waveletNoiseReduction: WaveletDenoiseSettings?
    public var aiDenoiseEnabled = false
    private var aiDenoiseBlend: Double?
    public var aiDenoiseStrength: Double {
        get { aiDenoiseBlend ?? 100.0 }
        set {
            guard newValue.isFinite else { return }
            let clamped = min(100.0, max(0.0, newValue))
            aiDenoiseBlend = clamped == 100.0 ? nil : clamped
        }
    }
    private var hdrCameraAI: Bool?
    public var hdrCameraAIEnabled: Bool {
        get { hdrCameraAI == true }
        set { hdrCameraAI = newValue ? true : nil }
    }
    public var activeAIDenoise: Bool {
        get { isHDREditing ? hdrCameraAIEnabled : aiDenoiseEnabled }
        set {
            if isHDREditing { hdrCameraAIEnabled = newValue }
            else { aiDenoiseEnabled = newValue }
        }
    }
    public var photoEffects: PhotoEffectsSettings?
    public var hsl: HSLSettings?
    public var lensCorrection: LensCorrectionSettings?
    public var geometry: GeometrySettings?
    public private(set) var supportsRawNoiseReduction = false
    public var masterRecipeID: String? = nil
    public private(set) var masterRecipeSettingsVersion: Int? = 3

    public init() {}

    public var masterRecipe: MasterRecipe? { MasterRecipe.recipe(for: masterRecipeID) }
    public var recipeSettingsVersion: Int { masterRecipeSettingsVersion ?? 2 }
    public var refinementScale: Double { masterRecipe != nil && recipeSettingsVersion >= 4 ? strength : 1 }
    public var renderToneSettings: ToneControlsSettings { toneSettings.scaled(by: refinementScale) }
    public var renderAtmosphereSettings: AtmosphereSettings { atmosphereSettings.scaled(by: refinementScale) }
    public var renderGradingSettings: ColorGradingSettings { gradingSettings.scaled(by: refinementScale) }
    public var renderCurveSettings: ToneCurveSettings { curveSettings.scaled(by: refinementScale) }
    public mutating func setTransferRecipe(_ id: String?, settingsVersion: Int = 3) {
        masterRecipeID = id
        masterRecipeSettingsVersion = settingsVersion
    }
    public var effectSettings: PhotoEffectsSettings { photoEffects ?? PhotoEffectsSettings() }
    public var hslSettings: HSLSettings { hsl ?? HSLSettings() }
    public var editingHSLSettings: HSLSettings {
        get { isHDREditing ? hdr!.colorSettings.hsl : hslSettings }
        set {
            guard newValue.isValid else { return }
            if isHDREditing { hdr?.colorSettings.hsl = newValue }
            else { hsl = newValue.isIdentity ? nil : newValue }
        }
    }
    public var renderHSLSettings: HSLSettings {
        // 旧编辑及冻结批量保留独立 HSL；重新应用预设后才采用整体强度。
        let scalesHSL = masterRecipe != nil && (masterRecipeSettingsVersion ?? 2) >= 3
        return hslSettings.scaled(by: scalesHSL ? strength : 1)
    }
    public mutating func setHSL(_ axis: HSLAxis, channel: Int, value: Double) {
        var state = hslSettings
        state.set(axis, channel: channel, value: value)
        hsl = state.isIdentity ? nil : state
    }
    public var lensSettings: LensCorrectionSettings { lensCorrection ?? LensCorrectionSettings() }
    public mutating func selectX3fMode(_ mode: X3fMode) {
        x3fMode = mode
        guard mode == .normal else { return }
        aiDenoiseEnabled = false
        lensCorrection?.distortion = false
        lensCorrection?.tca = false
        lensCorrection?.vignetting = false
    }
    public var geometrySettings: GeometrySettings { isHDREditing ? hdr!.geometry : (geometry ?? GeometrySettings()) }

    public mutating func setGeometrySettings(_ state: GeometrySettings) {
        if isHDREditing { hdr?.geometry = state }
        else { geometry = state.isIdentity ? nil : state }
    }

    public mutating func setGeometry(_ parameter: GeometryParameter, to value: Double) {
        guard value.isFinite else { return }
        var state = geometrySettings
        let range = parameter.range(for: state)
        state[keyPath: parameter.keyPath] = min(range.upperBound, max(range.lowerBound, value))
        setGeometrySettings(state)
    }

    public mutating func rotateGeometry(clockwise: Bool) {
        var state = geometrySettings
        state.quarterTurns = (state.quarterTurns + (clockwise ? 1 : 3)) % 4
        setGeometrySettings(state)
    }

    public mutating func flipGeometry(horizontal: Bool) {
        var state = geometrySettings
        if horizontal { state.flipHorizontal.toggle() } else { state.flipVertical.toggle() }
        setGeometrySettings(state)
    }

    public var neutralSettings: Adjustments {
        if isHDREditing {
            var neutral = self
            neutral.hdr?.reset()
            neutral.hdrCameraAIEnabled = false
            return neutral
        }
        var neutral = Adjustments()
        neutral.processing = processing
        neutral.x3fMode = x3fMode
        return neutral
    }

    // Compare the color edit on the same geometric canvas without changing the
    // immutable original cached by EditorModel.
    public var neutralGeometrySettings: Adjustments {
        var neutral = neutralSettings
        neutral.setGeometrySettings(geometrySettings)
        if isHDREditing { neutral.hdr = hdr?.neutralGeometrySettings }
        neutral.lensCorrection = lensCorrection
        return neutral
    }
    public var vignetteAmount: Double {
        get { editingEffectValue(.vignetteAmount) }
        set { setEffect(.vignetteAmount, to: newValue) }
    }
    public var grainAmount: Double {
        get { editingEffectValue(.grainAmount) }
        set { setEffect(.grainAmount, to: newValue) }
    }

    public func editingEffectValue(_ parameter: PhotoEffectParameter) -> Double {
        if isHDREditing, let hdr { return hdr.effectsSettings[keyPath: parameter.hdrKeyPath] }
        return effectSettings[keyPath: parameter.keyPath]
    }

    public mutating func setEffect(_ parameter: PhotoEffectParameter, to value: Double) {
        guard value.isFinite else { return }
        let amount = min(parameter.range.upperBound, max(parameter.range.lowerBound, (value * 10).rounded() / 10))
        if isHDREditing { hdr?.effectsSettings[keyPath: parameter.hdrKeyPath] = amount; return }
        var state = effectSettings
        state[keyPath: parameter.keyPath] = amount
        photoEffects = state == PhotoEffectsSettings() ? nil : state
    }

    public mutating func resetEffect(_ tool: AdjustmentParameter) {
        for parameter in PhotoEffectParameter.allCases where parameter.isVignette == (tool == .vignetteAmount) {
            setEffect(parameter, to: parameter.defaultValue)
        }
    }

    public func isEffectDefault(_ tool: AdjustmentParameter) -> Bool {
        PhotoEffectParameter.allCases.filter { $0.isVignette == (tool == .vignetteAmount) }
            .allSatisfy { editingEffectValue($0) == $0.defaultValue }
    }

    public var waveletSettings: WaveletDenoiseSettings { waveletNoiseReduction ?? WaveletDenoiseSettings() }
    public var hasLegacyDenoise: Bool { waveletNoiseReduction == nil && denoiseMode > 0 }
    public var isDenoiseEnabled: Bool { activeAIDenoise || (!isHDREditing && (waveletNoiseReduction?.enabled ?? (denoiseMode > 0))) }
    public var denoiseSummary: String {
        if activeAIDenoise { return L10n.text("AI 降噪") }
        if let settings = waveletNoiseReduction {
            return settings.enabled ? settings.preset.title : L10n.text("停用")
        }
        if denoiseMode == 0 { return L10n.text("停用") }
        if denoiseMode == 3 { return L10n.text("旧版 FBDD") }
        return L10n.format("旧版：%@", String(describing: ChromaNoiseReductionMode(rawValue: denoiseMode)?.title ?? L10n.text("色度降噪")))
    }

    public mutating func setDenoiseEnabled(_ enabled: Bool) {
        var state = waveletSettings
        state.enabled = enabled
        waveletNoiseReduction = state == WaveletDenoiseSettings() ? nil : state
        rawNoiseReduction = 0
        chromaNoiseReduction = nil
    }

    public mutating func applyDenoisePreset(_ preset: DenoisePreset) {
        guard preset != .custom else { return }
        var state = WaveletDenoiseSettings()
        state.enabled = true
        state.preset = preset
        if preset == .clean { state.luma = 10; state.chroma = 72; state.coarse = 100 }
        waveletNoiseReduction = state
        rawNoiseReduction = 0
        chromaNoiseReduction = nil
    }

    public mutating func setDenoiseParameter(_ parameter: DenoiseParameter, to value: Double) {
        guard value.isFinite else { return }
        var state = waveletSettings
        let value = min(100, max(0, (value * 10).rounded() / 10))
        guard state[keyPath: parameter.keyPath] != value else { return }
        state[keyPath: parameter.keyPath] = value
        state.preset = .custom
        waveletNoiseReduction = state
    }

    public var denoiseMode: Double {
        get { chromaNoiseReduction ?? (rawNoiseReduction > 0 ? 3 : 0) }
        set {
            guard ChromaNoiseReductionMode(rawValue: newValue) != nil else { return }
            waveletNoiseReduction = nil
            chromaNoiseReduction = newValue == 0 ? nil : newValue
            rawNoiseReduction = 0
        }
    }

    public var usesAsShotWhiteBalance: Bool {
        whiteBalanceMode == .asShot ||
            (masterRecipe == nil && temperature == asShotWhiteBalance?.temperature && tint == asShotWhiteBalance?.tint)
    }

    public func resolvedRenderValues() -> ResolvedMacRenderValues {
        let recipeActive = masterRecipe != nil
        let scale = recipeActive ? strength : 1
        let tintOffset = recipeActive ? tint * scale : 0
        let cameraWB = usesAsShotWhiteBalance
        let effectiveTemp = cameraWB ? (asShotWhiteBalance?.temperature ?? 6500) : temperature
        let effectiveTint = recipeActive ? (asShotWhiteBalance?.tint ?? 0) + tintOffset : tint
        let temperatureWB = !cameraWB || tintOffset != 0
        return ResolvedMacRenderValues(
            usesTemperatureWB: temperatureWB,
            exposureEV: Float(exposure * scale),
            brightness: 1,
            temperature: temperatureWB ? Float(effectiveTemp) : 6500,
            tint: temperatureWB ? Float(recipeActive ? min(150, max(-150, effectiveTint)) : effectiveTint) : 0,
            contrast: Float(1 + contrast * scale / 100),
            saturation: Float(1 + saturation * scale / 100),
            highlights: Float(-highlights * scale / 100),
            shadows: Float(shadows * scale / 100),
            toneCurve: curveSettings.mode == .custom ? 0 : Float(min(100, max(-100, toneCurve * refinementScale)) / 100),
            sharpening: Float(sharpening / 100)
        )
    }

    public mutating func applyMasterRecipe(_ recipe: MasterRecipe) {
        masterRecipeID = recipe.id
        masterRecipeSettingsVersion = recipe.version
        strength = 1
        exposure = recipe.exposureDelta
        shadows = recipe.shadowsDelta
        highlights = recipe.highlightsDelta
        contrast = recipe.contrastDelta
        saturation = recipe.saturationDelta
        tint = recipe.tintDelta
        hsl = recipe.hsl.isIdentity ? nil : recipe.hsl
        if recipe.version >= 4 {
            toneControls = recipe.tone?.isIdentity == true ? nil : recipe.tone
            atmosphere = recipe.atmosphere?.isIdentity == true ? nil : recipe.atmosphere
            gradingSettings = recipe.grading ?? ColorGradingSettings()
            curveSettings = recipe.curve ?? ToneCurveSettings()
            toneCurve = 0
        }
    }

    @discardableResult public mutating func clearMasterRecipe(isRaw: Bool = true) -> Bool {
        guard masterRecipeID != nil else { return true }
        let context = MacEditorAdjustmentContext(isRaw: isRaw, defaultExposureMode: exposureMode, neutralFilmID: "")
        guard var independent = try? detachingRecipeForReset(context: context) else { return false }
        // 选用下一个胶片时保留外观强度；独立的调整值已经展开一次。
        independent.strength = strength
        self = independent
        return true
    }

    public mutating func reset(_ group: AdjustmentGroup) {
        if isHDREditing {
            for parameter in group.parameters where parameter.hdrKeyPath != nil {
                set(parameter, to: parameter.spec.defaultValue)
            }
            if group == .tone { hdr?.toneSettings.curve = ToneCurveSettings() }
            if group == .color { hdr?.colorSettings = HDRColorSettings() }
            if group == .detail { hdrCameraAIEnabled = false }
            if group == .geometry { hdr?.geometry = GeometrySettings() }
            return
        }
        if group == .film {
            guard clearMasterRecipe() else { return }
        }
        for parameter in group.parameters {
            set(parameter, to: parameter.spec(for: self).defaultValue)
        }
        if group == .input { exposureMode = .preview; resetWhiteBalance() }
        if group == .color { hsl = nil; colorGrading = nil }
        if group == .tone { toneCurveConfig = nil }
        if group == .detail { aiDenoiseEnabled = false; aiDenoiseStrength = 100.0 }
        if group == .effects { photoEffects = nil; atmosphere = nil }
        if group == .lens { lensCorrection = nil }
        if group == .geometry { geometry = nil }
    }

    public func isDefault(_ group: AdjustmentGroup) -> Bool {
        if isHDREditing {
            return group.parameters.filter { $0.hdrKeyPath != nil }.allSatisfy {
                $0.value(from: self) == $0.spec.defaultValue
            } && (group != .geometry || geometrySettings.isIdentity)
                && (group != .tone || editingCurveSettings.isDefault)
                && (group != .color || (hdr?.colorSettings.isDefault ?? true))
                && (group != .detail || !hdrCameraAIEnabled)
        }
        return group.parameters.allSatisfy { self[keyPath: $0.spec.keyPath] == $0.spec(for: self).defaultValue }
            && (group != .input || exposureMode == .preview)
            && (group != .tone || curveSettings.isDefault)
            && (group != .color || hslSettings.isIdentity && gradingSettings.isDefault)
            && (group != .detail || (!isDenoiseEnabled && aiDenoiseStrength == 100.0))
            && (group != .effects || effectSettings == PhotoEffectsSettings() && atmosphereSettings.isIdentity)
            && (group != .film || masterRecipeID == nil)
            && (group != .lens || lensSettings == LensCorrectionSettings())
            && (group != .geometry || geometrySettings.isIdentity)
    }

    public mutating func resolveWhiteBalance(_ camera: WhiteBalance?) {
        asShotWhiteBalance = camera
        if isHDREditing { return }
        if whiteBalanceMode == .asShot {
            if masterRecipe != nil { temperature = camera?.temperature ?? 6500 }
            else { resetWhiteBalance() }
        }
    }

    public mutating func resetWhiteBalance() {
        if isHDREditing { hdr?.temperature = 6500; hdr?.tint = 0; return }
        temperature = asShotWhiteBalance?.temperature ?? 6500
        tint = masterRecipe != nil ? 0 : (asShotWhiteBalance?.tint ?? 0)
        whiteBalanceMode = .asShot
    }

    public var isWhiteBalanceDefault: Bool {
        if isHDREditing { return hdr?.temperature == 6500 && hdr?.tint == 0 }
        return [AdjustmentParameter.temperature, .tint].allSatisfy {
            self[keyPath: $0.spec.keyPath] == $0.spec(for: self).defaultValue
        }
    }

    public mutating func resolveRawNoiseReductionSupport(_ supported: Bool) {
        supportsRawNoiseReduction = supported
        if !supported && !isHDREditing { rawNoiseReduction = 0 }
    }

    public mutating func set(_ parameter: AdjustmentParameter, to value: Double) {
        if isHDREditing {
            guard let key = parameter.hdrKeyPath, var state = hdr, value.isFinite else { return }
            state[keyPath: key] = value
            guard state.isValid else { return }
            hdr = state
            return
        }
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

    public mutating func resetAll() {
        if isHDREditing {
            hdr?.reset()
            hdrCameraAIEnabled = false
            return
        }
        let inactiveHDR = hdr
        let inactiveHDRCameraAI = hdrCameraAI
        let decodeVersion = proRAWDecodeVersion
        let identity = processing
        let x3f = x3fMode
        let camera = asShotWhiteBalance
        let noiseReductionSupport = supportsRawNoiseReduction
        self = Adjustments()
        hdr = inactiveHDR
        hdrCameraAI = inactiveHDRCameraAI
        proRAWDecodeVersion = decodeVersion
        processing = identity
        x3fMode = x3f
        resolveWhiteBalance(camera)
        resolveRawNoiseReductionSupport(noiseReductionSupport)
    }

    public var isDefault: Bool { AdjustmentGroup.allCases.allSatisfy { isDefault($0) } }

    // 与实际渲染共用普通图片的有效设置，避免 reset 校验把 RAW 元数据当成 RGB 白平衡。
    public var resolvedForRaster: Adjustments {
        if isHDREditing { return self }
        var state = self
        state.exposureMode = .sensor
        if state.whiteBalanceMode != .asShot || state.asShotWhiteBalance != nil || state.masterRecipe != nil {
            state.whiteBalanceMode = .asShot
            state.resolveWhiteBalance(nil)
            state.temperature = 6500
            state.tint = 0
        }
        state.rawNoiseReduction = 0
        state.aiDenoiseEnabled = false
        state.lensCorrection = nil
        return state
    }

    public func validateResetValues() throws {
        if isHDREditing {
            guard hdr?.isValid == true else { throw EditorResetBlockedReason.invalidSnapshot("hdr") }
            return
        }
        for parameter in [AdjustmentParameter.strength, .exposure, .temperature, .tint, .contrast,
                          .highlights, .shadows, .toneCurve, .blackPoint, .whitePoint, .vibrance, .saturation, .sharpening, .rawNoiseReduction] {
            let value = self[keyPath: parameter.spec.keyPath]
            guard value.isFinite, parameter.spec.range.contains(value) else {
                throw EditorResetBlockedReason.invalidSnapshot(parameter.rawValue)
            }
        }
        guard rawNoiseReduction.rounded() == rawNoiseReduction,
              aiDenoiseStrength.isFinite, (0...100).contains(aiDenoiseStrength),
              chromaNoiseReduction.map({ $0.isFinite && (0...2).contains($0) && $0.rounded() == $0 }) ?? true,
              DenoiseParameter.allCases.allSatisfy({
                  let value = waveletSettings[keyPath: $0.keyPath]
                  return value.isFinite && (0...100).contains(value)
              }) else { throw EditorResetBlockedReason.invalidSnapshot("denoise") }
        guard PhotoEffectParameter.allCases.allSatisfy({
            let value = effectSettings[keyPath: $0.keyPath]
            return value.isFinite && $0.range.contains(value)
        }), hslSettings.isValid, geometrySettings.isValid, atmosphereSettings.isValid, gradingSettings.isValid, curveSettings.isValid else {
            throw EditorResetBlockedReason.invalidSnapshot("effects/hsl/geometry")
        }
        if let camera = asShotWhiteBalance {
            guard camera.temperature.isFinite, camera.tint.isFinite,
                  AdjustmentParameter.temperature.spec.range.contains(camera.temperature),
                  AdjustmentParameter.tint.spec.range.contains(camera.tint) else {
                throw EditorResetBlockedReason.invalidSnapshot("asShotWhiteBalance")
            }
        }
        if masterRecipeID != nil {
            guard masterRecipe != nil, [2, 3, 4].contains(masterRecipeSettingsVersion ?? 2) else {
                throw EditorResetBlockedReason.invalidSnapshot("masterRecipe")
            }
        }
    }

    private func resetCoreValues(context: MacEditorAdjustmentContext) -> [Float] {
        let effective = context.isRaw ? self : resolvedForRaster
        let rendered = effective.resolvedRenderValues()
        let tone = effective.renderToneSettings, atmosphere = effective.renderAtmosphereSettings
        let grading = effective.renderGradingSettings, curve = effective.renderCurveSettings
        return [Float(rendered.usesTemperatureWB ? 1 : 0), rendered.exposureEV, rendered.brightness, rendered.temperature,
                rendered.tint, rendered.contrast, rendered.saturation, rendered.highlights, rendered.shadows,
                rendered.toneCurve, rendered.sharpening] +
            (effective.renderHSLSettings.hue + effective.renderHSLSettings.saturation + effective.renderHSLSettings.lightness).map(Float.init) +
            [tone.blackPoint, tone.whitePoint, tone.vibrance, atmosphere.clarity, atmosphere.dehaze].map(Float.init) +
            ColorGradingZone.allCases.flatMap { [Float(grading[$0].hue), Float(grading[$0].saturation), Float(grading[$0].luminance)] } +
            [Float(grading.global.hue), Float(grading.global.saturation), Float(grading.global.luminance), Float(grading.blending), Float(grading.balance)] +
            (context.isRaw ? [] : [Float(effective.temperature), Float(effective.tint)]) +
            ToneCurveChannel.allCases.flatMap { channel -> [Float] in
                let shape = curve.shape(channel)
                return [shape.mode == .custom ? 1 : 0] + shape.points.flatMap { [Float($0.x), Float($0.y)] }
            }
    }

    internal func detachingRecipeForReset(context: MacEditorAdjustmentContext) throws -> Adjustments {
        try validateResetValues()
        var result = self
        let renderedHSL = renderHSLSettings
        if masterRecipe != nil {
            let tone = renderToneSettings, atmosphere = renderAtmosphereSettings
            result.toneControls = tone.isIdentity ? nil : tone
            result.atmosphere = atmosphere.isIdentity ? nil : atmosphere
            result.gradingSettings = renderGradingSettings
            result.curveSettings = renderCurveSettings
            result.toneCurve = min(100, max(-100, toneCurve * refinementScale))
            let scale = strength
            result.exposure = exposure * scale
            result.contrast = contrast * scale
            result.highlights = highlights * scale
            result.shadows = shadows * scale
            result.saturation = saturation * scale
            if context.isRaw {
                if (tint * scale != 0 || !usesAsShotWhiteBalance) && asShotWhiteBalance == nil {
                    throw EditorResetBlockedReason.missingAsShotWhiteBalance
                }
                let before = resolvedRenderValues()
                result.masterRecipeID = nil
                if !before.usesTemperatureWB {
                    result.resetWhiteBalance()
                } else {
                    result.whiteBalanceMode = .custom
                    result.temperature = Double(before.temperature)
                    result.tint = Double(before.tint)
                }
            } else {
                result.masterRecipeID = nil
                result.whiteBalanceMode = .asShot
                result.temperature = 6500
                result.tint = 0
            }
            // 捕获旧版本的实际 HSL，不调用会再次量化的用户输入 setter。
            result.hsl = renderedHSL.isIdentity ? nil : renderedHSL
        }
        result.masterRecipeID = nil
        result.masterRecipeSettingsVersion = 3
        result.strength = 1
        try result.validateResetValues()
        guard result.resetCoreValues(context: context) == resetCoreValues(context: context) else {
            throw EditorResetBlockedReason.unrepresentableRecipe
        }
        return result
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        processing = values.contains(.processing) ?
            try values.decode(ProcessingIdentity.self, forKey: .processing) : .legacy
        x3fMode = values.contains(.x3fMode) ? try values.decode(X3fMode.self, forKey: .x3fMode) : .legacy
        hdr = try values.decodeIfPresent(HDRSettings.self, forKey: .hdr)
        proRAWDecodeVersion = try values.decodeIfPresent(Int.self, forKey: .proRAWDecodeVersion)
        toneCurveConfig = try values.decodeIfPresent(ToneCurveSettings.self, forKey: .toneCurveConfig)
        colorGrading = try values.decodeIfPresent(ColorGradingSettings.self, forKey: .colorGrading)
        if colorGrading?.isDefault == true { colorGrading = nil }
        atmosphere = try values.decodeIfPresent(AtmosphereSettings.self, forKey: .atmosphere)
        guard atmosphereSettings.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .atmosphere, in: values, debugDescription: "Invalid atmosphere controls")
        }
        if atmosphere?.isIdentity == true { atmosphere = nil }
        toneControls = try values.decodeIfPresent(ToneControlsSettings.self, forKey: .toneControls)
        guard toneSettings.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .toneControls, in: values, debugDescription: "Invalid tone controls")
        }
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
        aiDenoiseEnabled = try values.decodeIfPresent(Bool.self, forKey: .aiDenoiseEnabled) ?? false
        if let blend = try values.decodeIfPresent(Double.self, forKey: .aiDenoiseBlend) {
            guard blend.isFinite, (0.0...100.0).contains(blend) else {
                throw DecodingError.dataCorruptedError(forKey: .aiDenoiseBlend, in: values, debugDescription: "Invalid AI denoise strength")
            }
            aiDenoiseBlend = blend == 100.0 ? nil : blend
        }
        hdrCameraAIEnabled = try values.decodeIfPresent(Bool.self, forKey: .hdrCameraAI) ?? false
        if hdrCameraAIEnabled && (hdr?.cameraDevelopmentSettings.fbddLevel != 0 || hdr?.cameraDevelopmentSettings.cameraProfile != nil) {
            throw DecodingError.dataCorruptedError(forKey: .hdrCameraAI, in: values, debugDescription: "HDR Bayer AI requires a camera HDR record without FBDD or a camera profile")
        }
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
        guard [2, 3, 4].contains(version ?? 3) else {
            throw DecodingError.dataCorruptedError(forKey: .masterRecipeSettingsVersion, in: values, debugDescription: "Invalid master recipe version")
        }
        if version == nil, let recipe = masterRecipe {
            // 旧记录只保存基础值；一次性合入预设，之后由新规则整体缩放这些当前值。
            let defaults = recipe.migrationDefaults
            let cameraWB = whiteBalanceMode == .asShot ||
                (temperature == asShotWhiteBalance?.temperature && tint == asShotWhiteBalance?.tint)
            exposure += defaults.exposureDelta
            shadows += defaults.shadowsDelta
            highlights += defaults.highlightsDelta
            contrast += defaults.contrastDelta
            saturation += defaults.saturationDelta
            tint = (cameraWB ? 0 : tint - (asShotWhiteBalance?.tint ?? 0)) + defaults.tintDelta
            if cameraWB { whiteBalanceMode = .asShot }
        }
    }

    public func withHDRMode(_ enabled: Bool, sourceIsHDR: Bool, cameraRAW: Bool = false) throws -> Adjustments {
        var result = self
        guard enabled else { result.hdr?.mode = .sdr; return result }
        var initial = HDRSettings()
        if !cameraRAW {
            let scale = masterRecipe == nil ? 1 : strength
            initial.exposure = min(4, max(-4, exposure * scale))
            initial.contrast = min(100, max(-100, contrast * scale))
            initial.highlights = min(100, max(-100, highlights * scale))
            initial.shadows = min(100, max(-100, shadows * scale))
            initial.saturation = min(100, max(-100, saturation * scale))
            initial.geometry = geometry ?? GeometrySettings()
        }
        result.hdr = try HDRSettings.enabling(stored: hdr, initial: initial, sourceIsHDR: sourceIsHDR || cameraRAW)
        return result
    }
}

public struct MacPhotoEditState: Codable, Equatable {
    public var settings: Adjustments
    public var filmID: String
    public var masterRecipeID: String?

    public init(settings: Adjustments = Adjustments(), filmID: String = "", masterRecipeID: String? = nil) {
        self.settings = settings
        self.filmID = filmID
        self.masterRecipeID = masterRecipeID
    }
}

public struct MacPhotoEditSession {
    private var edits: [URL: MacPhotoEditState] = [:]

    public init() {}

    public mutating func save(_ url: URL, settings: Adjustments, filmID: String, masterRecipeID: String? = nil) {
        edits[url.standardizedFileURL] = MacPhotoEditState(settings: settings, filmID: filmID, masterRecipeID: masterRecipeID)
    }
    public func state(for url: URL, defaultFilmID: String) -> MacPhotoEditState {
        edits[url.standardizedFileURL] ?? MacPhotoEditState(settings: Adjustments(), filmID: defaultFilmID, masterRecipeID: nil)
    }
}
