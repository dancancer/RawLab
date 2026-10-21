import Foundation

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

    var isWhiteBalanceDefault: Bool {
        [AdjustmentParameter.temperature, .tint].allSatisfy {
            self[keyPath: $0.spec.keyPath] == $0.spec(for: self).defaultValue
        }
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

    // 与实际渲染共用普通图片的有效设置，避免 reset 校验把 RAW 元数据当成 RGB 白平衡。
    var resolvedForRaster: Adjustments {
        var state = self
        state.exposureMode = .sensor
        state.whiteBalanceMode = .asShot
        state.resolveWhiteBalance(nil)
        state.temperature = 6500
        state.tint = 0
        state.rawNoiseReduction = 0
        state.lensCorrection = nil
        return state
    }

    fileprivate func validateResetValues() throws {
        for parameter in [AdjustmentParameter.strength, .exposure, .temperature, .tint, .contrast,
                          .highlights, .shadows, .toneCurve, .saturation, .sharpening, .rawNoiseReduction] {
            let value = self[keyPath: parameter.spec.keyPath]
            guard value.isFinite, parameter.spec.range.contains(value) else {
                throw EditorResetBlockedReason.invalidSnapshot(parameter.rawValue)
            }
        }
        guard rawNoiseReduction.rounded() == rawNoiseReduction,
              chromaNoiseReduction.map({ $0.isFinite && (0...2).contains($0) && $0.rounded() == $0 }) ?? true,
              DenoiseParameter.allCases.allSatisfy({
                  let value = waveletSettings[keyPath: $0.keyPath]
                  return value.isFinite && (0...100).contains(value)
              }) else { throw EditorResetBlockedReason.invalidSnapshot("denoise") }
        guard PhotoEffectParameter.allCases.allSatisfy({
            let value = effectSettings[keyPath: $0.keyPath]
            return value.isFinite && $0.range.contains(value)
        }), hslSettings.isValid, geometrySettings.isValid else {
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
            guard masterRecipe != nil, [2, 3].contains(masterRecipeSettingsVersion ?? 2) else {
                throw EditorResetBlockedReason.invalidSnapshot("masterRecipe")
            }
        }
    }

    private func resetCoreValues(context: EditorAdjustmentContext) -> [Float] {
        let effective = context.isRaw ? self : resolvedForRaster
        var request = sony2fuji_request()
        effective.apply(to: &request)
        return [Float(request.wb_mode.rawValue), request.exposure_ev, request.brightness, request.temperature,
                request.tint, request.contrast, request.saturation, request.highlights, request.shadows,
                request.tone_curve, request.sharpening] +
            (effective.renderHSLSettings.hue + effective.renderHSLSettings.saturation + effective.renderHSLSettings.lightness).map(Float.init)
    }

    fileprivate func detachingRecipeForReset(context: EditorAdjustmentContext) throws -> Adjustments {
        try validateResetValues()
        var result = self
        let renderedHSL = renderHSLSettings
        if masterRecipe != nil {
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
                var before = sony2fuji_request()
                apply(to: &before)
                result.masterRecipeID = nil
                if before.wb_mode == SONY2FUJI_WB_CAMERA {
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
}

enum EditorAdjustmentRules {
    static func isModified(scope: EditorResetScope, snapshot: PhotoEditState, context: EditorAdjustmentContext) -> Bool {
        let settings = snapshot.settings
        switch scope {
        case .all:
            return EditorAdjustmentGroup.allCases.contains { isModified(scope: .group($0), snapshot: snapshot, context: context) }
        case .hslAll: return !settings.hslSettings.isIdentity
        case .hslColor(let channel):
            guard (0..<8).contains(channel), settings.hslSettings.isValid else { return true }
            return HSLAxis.allCases.contains { settings.hslSettings.value($0, channel: channel) != 0 }
        case .group(.looks):
            return snapshot.filmID != context.neutralFilmID || snapshot.masterRecipeID != nil ||
                settings.masterRecipeID != nil || settings.strength != 1
        case .group(.light):
            return (context.isRaw && settings.exposureMode != context.defaultExposureMode) || settings.exposure != 0 ||
                settings.contrast != 0 || settings.highlights != 0 || settings.shadows != 0 || settings.toneCurve != 0
        case .group(.color):
            return settings.saturation != 0 || !settings.hslSettings.isIdentity ||
                (context.isRaw && (!settings.isWhiteBalanceDefault || !settings.usesAsShotWhiteBalance)) ||
                (settings.masterRecipe != nil && settings.tint != 0)
        case .group(.effects): return settings.effectSettings != PhotoEffectsSettings()
        case .group(.detail):
            return settings.sharpening != 0 || settings.rawNoiseReduction != 0 ||
                (settings.chromaNoiseReduction ?? 0) != 0 || settings.waveletSettings != WaveletDenoiseSettings()
        case .group(.geometry):
            return !settings.geometrySettings.isIdentity || settings.lensSettings != LensCorrectionSettings()
        }
    }

    static func prepareReset(scope: EditorResetScope, snapshot: PhotoEditState, context: EditorAdjustmentContext) -> EditorResetResult {
        var result = snapshot
        do {
            try snapshot.settings.validateResetValues()
            if case .hslColor(let channel) = scope, !(0..<8).contains(channel) {
                throw EditorResetBlockedReason.invalidHSLChannel
            }
            guard isModified(scope: scope, snapshot: snapshot, context: context) else { return .unchanged }
            switch scope {
            case .all:
                result.settings.resetAll()
                result.settings.exposureMode = context.defaultExposureMode
                if !context.isRaw { result.settings = result.settings.resolvedForRaster }
                result.filmID = context.neutralFilmID
                result.masterRecipeID = nil
            case .group(.looks):
                guard snapshot.masterRecipeID == snapshot.settings.masterRecipeID else {
                    throw EditorResetBlockedReason.invalidSnapshot("masterRecipeID")
                }
                result.settings = try result.settings.detachingRecipeForReset(context: context)
                result.filmID = context.neutralFilmID
                result.masterRecipeID = nil
            case .group(.light):
                result.settings.exposureMode = context.defaultExposureMode
                result.settings.exposure = 0; result.settings.contrast = 0
                result.settings.highlights = 0; result.settings.shadows = 0; result.settings.toneCurve = 0
            case .group(.color):
                result.settings.saturation = 0
                result.settings.resetWhiteBalance()
                result.settings.hsl = nil
            case .group(.effects): result.settings.photoEffects = nil
            case .group(.detail):
                result.settings.sharpening = 0; result.settings.rawNoiseReduction = 0
                result.settings.chromaNoiseReduction = nil; result.settings.waveletNoiseReduction = nil
            case .group(.geometry): result.settings.geometry = nil; result.settings.lensCorrection = nil
            case .hslAll: result.settings.hsl = nil
            case .hslColor(let channel):
                var hsl = result.settings.hslSettings
                hsl.reset(channel: channel)
                result.settings.hsl = hsl.isIdentity ? nil : hsl
            }
            try result.settings.validateResetValues()
            return result == snapshot ? .unchanged : .candidate(result)
        } catch let reason as EditorResetBlockedReason {
            return .blocked(reason)
        } catch {
            return .blocked(.invalidSnapshot(String(describing: error)))
        }
    }
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
