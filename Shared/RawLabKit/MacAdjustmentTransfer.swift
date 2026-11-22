import Foundation

public struct MacAdjustmentTransferContext {
    public var identifier: String
    public var isRaw: Bool
    public var sourceIsHDR = false
    public var sourceSupportsCameraHDR = false
    public var sourceIsBayerHDR = false
    public var availableLookIDs: Set<String> = []
    public var defaultExposureMode = ExposureMode.preview
    public var hasUncommittedDraft = false
    public var validateLensRequest: ((LensCorrectionSettings) throws -> Void)? = nil
    public var validateHDRCameraRequest: ((Adjustments) throws -> Void)? = nil
    public var transferNotices: ((AdjustmentTransferNotice) -> Void)? = nil

    public init(identifier: String,
                isRaw: Bool,
                sourceIsHDR: Bool = false,
                sourceSupportsCameraHDR: Bool = false,
                sourceIsBayerHDR: Bool = false,
                availableLookIDs: Set<String> = [],
                defaultExposureMode: ExposureMode = .preview,
                hasUncommittedDraft: Bool = false,
                validateLensRequest: ((LensCorrectionSettings) throws -> Void)? = nil,
                validateHDRCameraRequest: ((Adjustments) throws -> Void)? = nil,
                transferNotices: ((AdjustmentTransferNotice) -> Void)? = nil) {
        self.identifier = identifier
        self.isRaw = isRaw
        self.sourceIsHDR = sourceIsHDR
        self.sourceSupportsCameraHDR = sourceSupportsCameraHDR
        self.sourceIsBayerHDR = sourceIsBayerHDR
        self.availableLookIDs = availableLookIDs
        self.defaultExposureMode = defaultExposureMode
        self.hasUncommittedDraft = hasUncommittedDraft
        self.validateLensRequest = validateLensRequest
        self.validateHDRCameraRequest = validateHDRCameraRequest
        self.transferNotices = transferNotices
    }
}

public enum MacAdjustmentTransfer {
    public typealias Field = AdjustmentTransferField
    public typealias Value = AdjustmentTransferValue

    public static func previewCapture(scope: AdjustmentTransferScope, snapshot: MacPhotoEditState,
                                      committed: MacPhotoEditState?, context: MacAdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        var defaults = Adjustments()
        defaults.exposureMode = context.isRaw ? context.defaultExposureMode : .sensor
        if context.sourceIsHDR { defaults.hdr = HDRSettings() }
        let saved = committed ?? MacPhotoEditState(settings: defaults, filmID: "")
        // 相机元数据会补齐 live settings；比较逻辑调整，不能把元数据补齐误判为未保存编辑。
        guard snapshot.settings.hdr == saved.settings.hdr,
              snapshot.settings.processing == saved.settings.processing,
              snapshot.settings.aiDenoiseEnabled == saved.settings.aiDenoiseEnabled,
              snapshot.settings.recipeSettingsVersion == saved.settings.recipeSettingsVersion,
              snapshot.settings.waveletNoiseReduction == saved.settings.waveletNoiseReduction,
              snapshot.settings.chromaNoiseReduction == saved.settings.chromaNoiseReduction,
              values(snapshot, isRaw: context.isRaw) == values(saved, isRaw: context.isRaw) else {
            throw AdjustmentTransferError.draftRequiresPreflight
        }
        return try capture(scope: scope, snapshot: saved, context: context)
    }

    public static func capture(scope: AdjustmentTransferScope, snapshot: MacPhotoEditState,
                               context: MacAdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        guard !context.hasUncommittedDraft else { throw AdjustmentTransferError.draftRequiresPreflight }
        if snapshot.settings.isHDREditing {
            guard supportsHDRTransfer(context) else { throw AdjustmentTransferError.incompatible("hdr.source") }
            return try HDRAdjustmentTransfer.capture(settings: snapshot.settings.hdr!, identifier: context.identifier,
                processingVersion: snapshot.settings.processing.version, scope: scope, cameraRAW: context.sourceIsBayerHDR)
        }
        if snapshot.settings.aiDenoiseEnabled {
            switch scope {
            case .all, .modified: throw AdjustmentTransferError.incompatible("ai.copy_scope")
            case .custom: break
            }
        }
        try snapshot.settings.validateResetValues()
        guard snapshot.masterRecipeID == snapshot.settings.masterRecipeID else {
            throw AdjustmentTransferError.invalidPayload("recipe identity")
        }
        var defaults = Adjustments()
        defaults.exposureMode = context.isRaw ? context.defaultExposureMode : .sensor
        let original = values(snapshot, isRaw: context.isRaw)
        let neutral = values(MacPhotoEditState(settings: defaults, filmID: ""), isRaw: context.isRaw)
        let selected: Set<Field>
        switch scope {
        case .all: selected = Field.legacyFields
        case .custom(let fields): selected = fields
        case .modified: selected = Set(Field.common.filter { original[$0.rawValue] != neutral[$0.rawValue] })
        }
        let settings = snapshot.settings
        let recipe = settings.masterRecipeID.map {
            AdjustmentRecipeContext(id: $0, strength: settings.strength, settingsVersion: settings.recipeSettingsVersion)
        }
        return try AdjustmentTransferPayload(source: AdjustmentTransferSource(identifier: context.identifier,
            isRaw: context.isRaw, processingVersion: settings.processing.version, recipe: recipe),
            values: original.filter { selected.contains(Field(rawValue: $0.key)!) })
    }

    public static func prepare(payload: AdjustmentTransferPayload, target: MacPhotoEditState,
                               context: MacAdjustmentTransferContext) throws -> MacPhotoEditState {
        guard !context.hasUncommittedDraft else { throw AdjustmentTransferError.draftRequiresPreflight }
        try payload.validate()
        if target.settings.isHDREditing {
            guard supportsHDRTransfer(context) else { throw AdjustmentTransferError.incompatible("hdr.source") }
            var result = target
            let hdr = try HDRAdjustmentTransfer.prepare(payload: payload, target: target.settings.hdr!, cameraRAW: context.sourceIsBayerHDR)
            guard hdr.lookSettings.assetIsAvailable() else { throw AdjustmentTransferError.missingLook(hdr.lookSettings.name ?? "HDR LUT") }
            result.settings.hdr = hdr
            if payload.fields.contains(.hdrCameraDevelopment) {
                guard let validate = context.validateHDRCameraRequest else { throw AdjustmentTransferError.incompatible("hdr.camera_development") }
                if hdr.cameraDevelopmentSettings.fbddLevel != 0 { result.settings.hdrCameraAIEnabled = false }
                var development = result.settings
                development.hdrCameraAIEnabled = false
                try validate(development)
            }
            return result
        }
        if payload.source.isHDR {
            return try prepare(payload: HDRAdjustmentTransfer.legacyPayload(payload), target: target, context: context)
        }
        // Q4：来源与目标处理版本不同不拒绝，沿用目标处理版本并一次性提示。
        if payload.source.processingVersion != target.settings.processing.version {
            context.transferNotices?(.retainedTargetProcessingVersion)
        }
        try target.settings.validateResetValues()
        guard target.masterRecipeID == target.settings.masterRecipeID else {
            throw AdjustmentTransferError.invalidPayload("target recipe identity")
        }
        var result = target
        let selected = payload.fields
        let oldEffective = effectiveNumbers(target.settings)
        var fullRecipe = false
        if let look = payload[.look]?.object {
            let kind = look["kind"]!.string!
            let id = look["id"]!.string
            let lookup = kind == "recipe_lut" ? "recipe:\(id!)" : kind == "managed" ? id! : "\(kind):\(id ?? "")"
            if kind != "neutral", !context.availableLookIDs.contains(lookup) {
                throw AdjustmentTransferError.missingLook(lookup)
            }
            fullRecipe = kind == "recipe" && Field.recipeDependencies(version: payload.source.recipe?.settingsVersion ?? 3).isSubset(of: selected)
            if fullRecipe {
                guard let recipe = payload.source.recipe, MasterRecipe.recipe(for: recipe.id) != nil else {
                    throw AdjustmentTransferError.missingLook(lookup)
                }
                result.settings.setTransferRecipe(recipe.id, settingsVersion: recipe.settingsVersion)
                result.masterRecipeID = recipe.id
                result.filmID = ""
            } else {
                result.settings.setTransferRecipe(nil)
                result.masterRecipeID = nil
                switch kind {
                case "neutral": result.filmID = ""
                case "managed": result.filmID = id!
                case "recipe", "recipe_lut": result.filmID = "recipe-lut:\(id!)"
                default: result.filmID = "builtin:\(id!)"
                }
            }
        }
        if let strength = payload[.strength]?.number { result.settings.strength = strength }
        let contextChanged = result.settings.masterRecipeID != target.settings.masterRecipeID
            || result.settings.recipeSettingsVersion != target.settings.recipeSettingsVersion
            || result.settings.strength != target.settings.strength

        for field in scalarKeys.keys {
            guard let value = payload[field]?.number else {
                if contextChanged && effectiveNumbers(result.settings)[field] != oldEffective[field] {
                    try assignEffective(oldEffective[field]!, field: field, to: &result.settings)
                }
                continue
            }
            if fullRecipe { assignLogical(value, field: field, to: &result.settings) }
            else { try assignEffective(sourceEffective(value, field: field, recipe: payload.source.recipe), field: field, to: &result.settings) }
        }
        for field in Field.allCases where field.hslLocation != nil {
            if let value = payload[field]?.number {
                let desired = fullRecipe ? value : sourceEffective(value, field: field, recipe: payload.source.recipe)
                if fullRecipe { try assignHSL(desired, field: field, to: &result.settings) }
                else { try assignEffective(desired, field: field, to: &result.settings) }
            } else if contextChanged && effectiveNumbers(result.settings)[field] != oldEffective[field] {
                try assignEffective(oldEffective[field]!, field: field, to: &result.settings)
            }
        }
        try applyWhiteBalance(payload, target: target.settings, to: &result.settings, context: context,
            fullRecipe: fullRecipe, contextChanged: contextChanged)
        if let mode = payload[.exposureMode]?.string, payload.source.isRaw || !context.isRaw {
            // 普通图片没有 RAW 曝光基准：其 sensor 占位值不改变 RAW 目标；普通目标始终保持 sensor。
            result.settings.exposureMode = !context.isRaw || mode == "sensor" ? .sensor : mode == "scene" ? .scene : .preview
        }
        for (field, key) in effectKeys {
            if let value = payload[field]?.number, result.settings.effectSettings[keyPath: key] != value {
                var effects = result.settings.effectSettings
                effects[keyPath: key] = value
                result.settings.photoEffects = effects == PhotoEffectsSettings() ? nil : effects
            }
        }
        try applyObjects(payload, to: &result.settings, context: context)
        let refinements = try AdjustmentTransferRefinement.applying(payload,
            original: AdjustmentTransferRefinement.values(curve: target.settings.curveSettings, grading: target.settings.gradingSettings),
            previousScale: target.settings.refinementScale, targetScale: result.settings.refinementScale, fullRecipe: fullRecipe)
        if let updatedCurve = refinements[.curve]?.curve {
            result.settings.curveSettings.master = updatedCurve.master
            result.settings.curveSettings.channels = updatedCurve.channels
        }
        if let applyToLuminosity = payload[.curveApplyToLuminosity]?.boolean {
            result.settings.curveSettings.applyToLuminosity = applyToLuminosity
        }
        if let parametric = refinements[.curveParametric]?.parametricCurve {
            result.settings.curveSettings.parametric = parametric
        }
        for field in Field.refinementObjects {
            if let zone = field.gradingZone, let wheel = refinements[field]?.gradingWheel {
                result.settings.gradingSettings[zone] = wheel
            }
        }
        if let global = payload[.gradingGlobal]?.gradingWheel {
            result.settings.gradingSettings.global = global
        }
        if let blending = payload[.gradingBlending]?.number {
            result.settings.gradingSettings.blending = blending
        }
        if let balance = payload[.gradingBalance]?.number {
            result.settings.gradingSettings.balance = balance
        }
        do { try result.settings.validateResetValues() }
        catch { throw AdjustmentTransferError.unrepresentable("native range") }

        let actual = effectiveNumbers(result.settings)
        for field in oldEffective.keys where field != .strength {
            let expected: Double
            if let value = payload[field]?.number { expected = sourceEffective(value, field: field, recipe: payload.source.recipe) }
            else { expected = oldEffective[field]! }
            guard Float(actual[field]!) == Float(expected) else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
        }
        // processing、原图 metadata 和未选择对象均沿用 target；入口返回完整候选而不保存。
        if values(result, isRaw: context.isRaw) == values(target, isRaw: context.isRaw)
            && result.settings.recipeSettingsVersion == target.settings.recipeSettingsVersion
            && result.settings.waveletNoiseReduction == target.settings.waveletNoiseReduction
            && result.settings.chromaNoiseReduction == target.settings.chromaNoiseReduction {
            return target
        }
        return result
    }

    public static func isRecipeScaled(_ field: Field, version: Int = 3) -> Bool {
        [.exposure, .contrast, .highlights, .shadows, .saturation].contains(field) || version >= 4 && Field.refinementScalars.contains(field)
    }

    private static func supportsHDRTransfer(_ context: MacAdjustmentTransferContext) -> Bool {
        (!context.isRaw && context.sourceIsHDR) || (context.isRaw && context.sourceSupportsCameraHDR)
    }

    public static func sourceEffective(_ value: Double, field: Field, recipe: AdjustmentRecipeContext?) -> Double {
        let scale = recipe?.strength ?? 1
        if field.hslLocation != nil {
            return min(100, max(-100, value * ((recipe?.settingsVersion ?? 2) >= 3 ? scale : 1)))
        }
        if field == .contrast || field == .saturation { return 1 + (value - 1) * scale }
        if (recipe?.settingsVersion ?? 3) >= 4 && Field.refinementScalars.contains(field) {
            let limit = field == .sCurve ? 1.0 : 100.0
            return min(limit, max(-limit, value * scale))
        }
        return isRecipeScaled(field) ? value * scale : value
    }

    public static func assignEffective(_ value: Double, field: Field, to settings: inout Adjustments) throws {
        let scale = settings.masterRecipe == nil ? 1 : settings.strength
        if field.hslLocation != nil {
            let hslScale = settings.masterRecipe != nil && settings.recipeSettingsVersion >= 3 ? scale : 1
            guard hslScale != 0 || value == 0 else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            try assignHSL(hslScale == 0 ? 0 : value / hslScale, field: field, to: &settings)
            return
        }
        let identity: Double = field == .contrast || field == .saturation ? 1 : 0
        if isRecipeScaled(field, version: settings.recipeSettingsVersion) {
            guard scale != 0 || value == identity else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            assignLogical(scale == 0 ? identity : identity + (value - identity) / scale, field: field, to: &settings)
        } else { assignLogical(value, field: field, to: &settings) }
    }

    public static func assignHSL(_ value: Double, field: Field, to settings: inout Adjustments) throws {
        let location = field.hslLocation!
        var hsl = settings.hslSettings
        if hsl.value(HSLAxis(rawValue: location.axis)!, channel: location.channel) == value { return }
        guard hsl.setExact(HSLAxis(rawValue: location.axis)!, channel: location.channel, value: value) else {
            throw AdjustmentTransferError.unrepresentable(field.rawValue)
        }
        settings.hsl = hsl.isIdentity ? nil : hsl
    }

    public static let scalarKeys: [Field: WritableKeyPath<Adjustments, Double>] = [
        .strength: \.strength, .exposure: \.exposure, .contrast: \.contrast,
        .highlights: \.highlights, .shadows: \.shadows, .sCurve: \.toneCurve,
        .saturation: \.saturation, .sharpening: \.sharpening,
        .blackPoint: \.blackPoint, .whitePoint: \.whitePoint, .vibrance: \.vibrance, .clarity: \.clarity, .dehaze: \.dehaze
    ]
    public static let effectKeys: [Field: WritableKeyPath<PhotoEffectsSettings, Double>] = [
        .vignetteAmount: \.vignetteAmount, .vignetteMidpoint: \.vignetteMidpoint,
        .vignetteRoundness: \.vignetteRoundness, .vignetteFeather: \.vignetteFeather,
        .vignetteHighlights: \.vignetteHighlights, .grainAmount: \.grainAmount,
        .grainSize: \.grainSize, .grainRoughness: \.grainRoughness
    ]
    public static let geometryKeys: [Field: WritableKeyPath<GeometrySettings, Double>] = [
        .cropX: \.cropX, .cropY: \.cropY, .cropWidth: \.cropWidth, .cropHeight: \.cropHeight,
        .straighten: \.straightenDegrees, .perspectiveHorizontal: \.perspectiveHorizontal,
        .perspectiveVertical: \.perspectiveVertical
    ]

    public static func logical(_ value: Double, field: Field) -> Double {
        switch field {
        case .contrast, .saturation: return 1 + value / 100
        case .highlights: return -value / 100
        case .shadows, .sCurve, .sharpening: return value / 100
        default: return value
        }
    }

    public static func assignLogical(_ value: Double, field: Field, to settings: inout Adjustments) {
        let native: Double
        switch field {
        case .contrast, .saturation: native = (value - 1) * 100
        case .highlights: native = -value * 100
        case .shadows, .sCurve, .sharpening: native = value * 100
        default: native = value
        }
        settings[keyPath: scalarKeys[field]!] = native
    }

    public static func effectiveNumbers(_ settings: Adjustments) -> [Field: Double] {
        let rendered = settings.resolvedRenderValues()
        var result: [Field: Double] = [
            .strength: settings.strength, .exposure: Double(rendered.exposureEV), .contrast: Double(rendered.contrast),
            .highlights: Double(rendered.highlights), .shadows: Double(rendered.shadows), .sCurve: Double(Float(min(100, max(-100, settings.toneCurve * settings.refinementScale)) / 100)),
            .saturation: Double(rendered.saturation), .sharpening: Double(rendered.sharpening),
            .blackPoint: settings.renderToneSettings.blackPoint, .whitePoint: settings.renderToneSettings.whitePoint,
            .vibrance: settings.renderToneSettings.vibrance, .clarity: settings.renderAtmosphereSettings.clarity, .dehaze: settings.renderAtmosphereSettings.dehaze
        ]
        for field in Field.allCases {
            if let location = field.hslLocation {
                result[field] = settings.renderHSLSettings.value(HSLAxis(rawValue: location.axis)!, channel: location.channel)
            }
        }
        return result
    }

    public static func values(_ snapshot: MacPhotoEditState, isRaw: Bool) -> [String: Value] {
        let settings = snapshot.settings
        var result = [String: Value]()
        result[Field.curve.rawValue] = settings.curveSettings.transferValue
        result[Field.curveApplyToLuminosity.rawValue] = .boolean(settings.curveSettings.applyToLuminosity)
        result[Field.curveParametric.rawValue] = settings.curveSettings.parametric.transferValue
        for (field, key) in scalarKeys { result[field.rawValue] = .number(logical(settings[keyPath: key], field: field)) }
        let look: [String: Value]
        if let recipe = settings.masterRecipeID { look = ["kind": .string("recipe"), "id": .string(recipe)] }
        else if snapshot.filmID.isEmpty { look = ["kind": .string("neutral"), "id": .null] }
        else if snapshot.filmID.hasPrefix("builtin:") { look = ["kind": .string("builtin"), "id": .string(String(snapshot.filmID.dropFirst(8)))] }
        else if snapshot.filmID.hasPrefix("recipe-lut:") { look = ["kind": .string("recipe_lut"), "id": .string(String(snapshot.filmID.dropFirst(11)))] }
        else { look = ["kind": .string("managed"), "id": .string(snapshot.filmID)] }
        result[Field.look.rawValue] = .object(look)
        result[Field.exposureMode.rawValue] = .string(!isRaw ? "sensor" : settings.exposureMode == .scene ? "scene" : settings.exposureMode == .preview ? "preview" : "sensor")
        let camera = !isRaw || settings.usesAsShotWhiteBalance
        let recipe = settings.masterRecipe != nil
        let rasterRelative = !isRaw && !recipe && (settings.temperature != 6500 || settings.tint != 0)
        result[Field.whiteBalanceMode.rawValue] = .string(!isRaw ? (rasterRelative ? "relative" : "none") : camera ? "camera" : "temperature")
        result[Field.temperature.rawValue] = rasterRelative ? .number(settings.temperature) : (!isRaw || camera ? .null : .number(settings.temperature))
        result[Field.tint.rawValue] = recipe ? .number(settings.tint) : rasterRelative ? .number(settings.tint) : (!isRaw || camera ? .null : .number(settings.tint))
        for field in Field.allCases {
            if let location = field.hslLocation {
                result[field.rawValue] = .number(settings.hslSettings.value(HSLAxis(rawValue: location.axis)!, channel: location.channel))
            }
        }
        for field in Field.allCases {
            if let zone = field.gradingZone {
                result[field.rawValue] = settings.gradingSettings[zone].transferValue
            }
        }
        result[Field.gradingGlobal.rawValue] = settings.gradingSettings.global.transferValue
        result[Field.gradingBlending.rawValue] = .number(settings.gradingSettings.blending)
        result[Field.gradingBalance.rawValue] = .number(settings.gradingSettings.balance)
        for (field, key) in effectKeys { result[field.rawValue] = .number(settings.effectSettings[keyPath: key]) }
        let wavelet = settings.waveletSettings
        let waveletValue: Value = .object([
            "enabled": .boolean(wavelet.enabled), "luma": .number(wavelet.luma), "chroma": .number(wavelet.chroma),
            "coarse": .number(wavelet.coarse), "preset": .string(wavelet.preset.rawValue)
        ])
        result[Field.rawDenoise.rawValue] = .number(isRaw ? settings.rawNoiseReduction : 0)
        result[Field.postRGBDenoise.rawValue] = .number(0)
        result[Field.chromaDenoise.rawValue] = .number(settings.chromaNoiseReduction ?? 0)
        result[Field.waveletDenoise.rawValue] = waveletValue
        let geometry = settings.geometrySettings
        result[Field.quarterTurns.rawValue] = .number(Double(geometry.quarterTurns))
        result[Field.flipHorizontal.rawValue] = .boolean(geometry.flipHorizontal)
        result[Field.flipVertical.rawValue] = .boolean(geometry.flipVertical)
        for (field, key) in geometryKeys { result[field.rawValue] = .number(geometry[keyPath: key]) }
        let lens = isRaw ? settings.lensSettings : LensCorrectionSettings()
        result[Field.lensDistortion.rawValue] = .boolean(lens.distortion)
        result[Field.lensTCA.rawValue] = .boolean(lens.tca)
        result[Field.lensVignetting.rawValue] = .boolean(lens.vignetting)
        result[Field.lensAutoCrop.rawValue] = .boolean(lens.autoCrop)
        result[Field.lensProfile.rawValue] = lens.mode == .automatic ? .null : .string(lens.coreProfileID)
        return result
    }

    public static func applyObjects(_ payload: AdjustmentTransferPayload, to settings: inout Adjustments,
                                    context: MacAdjustmentTransferContext) throws {
        // Q3：Mac 的 SDR 管线不建模 post_rgb，收到非 0 值忽略并提示，不再拒绝。
        if let value = payload[.postRGBDenoise]?.number, value != 0 {
            context.transferNotices?(.ignoredPostRGBDenoise)
        }
        if let raw = payload[.rawDenoise]?.number, payload.source.isRaw || !context.isRaw {
            if raw != 0 && (settings.aiDenoiseEnabled || !context.isRaw || !settings.supportsRawNoiseReduction) {
                context.transferNotices?(.ignoredRawDenoise)
            } else if !settings.aiDenoiseEnabled {
                settings.rawNoiseReduction = raw
                if raw != 0, settings.waveletNoiseReduction?.enabled == false {
                    settings.waveletNoiseReduction = nil
                }
            }
        }
        if let value = payload[.chromaDenoise] {
            let chroma = value.number ?? 0
            if settings.aiDenoiseEnabled {
                if chroma != 0 { context.transferNotices?(.ignoredTargetDenoise) }
            } else {
                settings.chromaNoiseReduction = chroma == 0 ? nil : chroma
                if chroma != 0, settings.waveletNoiseReduction?.enabled == false {
                    settings.waveletNoiseReduction = nil
                }
            }
        }
        if let value = payload[.waveletDenoise] {
            let decoded: WaveletDenoiseSettings
            if let wavelet = value.object {
                decoded = WaveletDenoiseSettings(enabled: wavelet["enabled"]!.boolean!,
                    luma: wavelet["luma"]!.number!, chroma: wavelet["chroma"]!.number!, coarse: wavelet["coarse"]!.number!,
                    preset: DenoisePreset(rawValue: wavelet["preset"]!.string!)!)
            } else { decoded = WaveletDenoiseSettings() }
            // AI 运行时传统降噪不生效，连零值也不覆盖关闭 AI 后要恢复的存量参数。
            if settings.aiDenoiseEnabled {
                if decoded != WaveletDenoiseSettings() { context.transferNotices?(.ignoredTargetDenoise) }
            } else {
                settings.waveletNoiseReduction = decoded == WaveletDenoiseSettings() ? nil : decoded
            }
        }
        if payload.fields.contains(where: { $0.group == "geometry" && !Field.lensFields.contains($0) }) {
            var geometry = settings.geometrySettings
            if let turns = payload[.quarterTurns]?.number { geometry.quarterTurns = Int(turns) }
            if let flip = payload[.flipHorizontal]?.boolean { geometry.flipHorizontal = flip }
            if let flip = payload[.flipVertical]?.boolean { geometry.flipVertical = flip }
            for (field, key) in geometryKeys { if let value = payload[field]?.number { geometry[keyPath: key] = value } }
            guard geometry.isValid else { throw AdjustmentTransferError.unrepresentable("geometry.crop") }
            if geometry != settings.geometrySettings { settings.geometry = geometry.isIdentity ? nil : geometry }
        }
        if !payload.fields.isDisjoint(with: Field.lensFields) {
            let neutral: [Field: Value] = [.lensDistortion: .boolean(false), .lensTCA: .boolean(false), .lensVignetting: .boolean(false),
                .lensAutoCrop: .boolean(true), .lensProfile: .null]
            let isNeutralLens = neutral.allSatisfy { payload[$0.key] == nil || payload[$0.key] == $0.value }
            if !context.isRaw {
                guard isNeutralLens else {
                    throw AdjustmentTransferError.incompatible("geometry.lens")
                }
            }
            if payload.source.isRaw || !context.isRaw || !isNeutralLens {
                var lens = settings.lensSettings
                if let value = payload[.lensDistortion]?.boolean { lens.distortion = value }
                if let value = payload[.lensTCA]?.boolean { lens.tca = value }
                if let value = payload[.lensVignetting]?.boolean { lens.vignetting = value }
                if let value = payload[.lensAutoCrop]?.boolean { lens.autoCrop = value }
                if let value = payload[.lensProfile] {
                    lens.mode = value == .null ? .automatic : .manual
                    lens.profileID = value.string == "__rawlab_manual_selection_required__" ? nil : value.string
                }
                if lens.isEnabled && lens.mode == .manual && lens.profileID == nil {
                    throw AdjustmentTransferError.unrepresentable(Field.lensProfile.rawValue)
                }
                guard context.isRaw || !lens.isEnabled else { throw AdjustmentTransferError.incompatible("geometry.lens") }
                if lens.isEnabled {
                    guard let validate = context.validateLensRequest else {
                        throw AdjustmentTransferError.incompatible("target lens calibration unavailable")
                    }
                    try validate(lens)
                }
                let existing = settings.lensSettings
                if lens.distortion != existing.distortion || lens.tca != existing.tca || lens.vignetting != existing.vignetting || lens.autoCrop != existing.autoCrop
                    || lens.mode != existing.mode || (lens.mode == .manual && lens.profileID != existing.profileID) {
                    settings.lensCorrection = lens == LensCorrectionSettings() ? nil : lens
                }
            }
        }
    }

    public static func applyWhiteBalance(_ payload: AdjustmentTransferPayload, target: Adjustments,
                                         to result: inout Adjustments, context: MacAdjustmentTransferContext,
                                         fullRecipe: Bool, contextChanged: Bool) throws {
        var selected = payload.fields.intersection(Field.whiteBalanceFields)
        if !payload.source.isRaw && context.isRaw && (payload.source.recipe == nil || !selected.contains(.tint)) {
            selected.removeAll()
        }
        if selected.isEmpty {
            if context.isRaw && contextChanged && renderWB(result) != renderWB(target) {
                try requireTargetCalibrationForMaterialization(target)
                try applyResolvedWB(renderWB(target), to: &result)
            }
            return
        }
        if !context.isRaw && payload.source.isRaw {
            let neutral: [Field: Value] = [.whiteBalanceMode: .string("camera"), .temperature: .null,
                .tint: payload.source.recipe == nil ? .null : .number(0)]
            let recipeTint = payload.source.recipe.flatMap { MasterRecipe.recipe(for: $0.id)?.tintDelta }
            let defaultRecipeTint = fullRecipe && recipeTint != nil && payload[.tint]?.number == recipeTint
            guard neutral.allSatisfy({ payload[$0.key] == nil || payload[$0.key] == $0.value
                || $0.key == .tint && defaultRecipeTint }) else {
                throw AdjustmentTransferError.incompatible("color.white_balance")
            }
            if !fullRecipe { return }
        }
        let targetValues = values(MacPhotoEditState(settings: target, filmID: "", masterRecipeID: target.masterRecipeID), isRaw: context.isRaw)
        let targetRecipe = target.masterRecipeID.map {
            AdjustmentRecipeContext(id: $0, strength: target.strength, settingsVersion: target.recipeSettingsVersion)
        }
        if !contextChanged && payload.source.isRaw == context.isRaw && payload.source.recipe == targetRecipe
            && selected.allSatisfy({ payload[$0] == targetValues[$0.rawValue] }) { return }
        if selected == Field.whiteBalanceFields {
            let mode = payload[.whiteBalanceMode]!.string!
            if !context.isRaw && !payload.source.isRaw {
                if mode == "relative", let temp = payload[.temperature]?.number, let tint = payload[.tint]?.number {
                    result.whiteBalanceMode = .asShot
                    result.temperature = temp
                    result.tint = tint
                } else {
                    result.resetWhiteBalance()
                }
                return
            }
            let balance: [String: Value] = [
                "mode": .string(mode == "none" && payload.source.recipe != nil ? "camera" : mode),
                "temperature": payload[.temperature]!, "tint": .number(payload[.tint]?.number ?? 0),
                "tint_mode": .string(payload.source.recipe != nil || mode == "camera" ? "camera_offset" : "absolute")
            ]
            let desired = try resolvedWB(balance, recipe: payload.source.recipe, target: target,
                sourceIsRaw: payload.source.isRaw, targetIsRaw: context.isRaw)
            if fullRecipe { applyLogicalWB(balance, to: &result) }
            else if context.isRaw { try applyResolvedWB(desired, to: &result) }
            return
        }
        if !context.isRaw {
            guard !payload.source.isRaw else { return }
            let selectedMode = payload[.whiteBalanceMode]?.string
            if selectedMode == "none" {
                if payload[.temperature]?.number != nil || payload[.tint]?.number != nil {
                    throw AdjustmentTransferError.incompatible("select white balance mode with temperature/tint")
                }
                result.resetWhiteBalance()
                return
            }
            if let temp = payload[.temperature]?.number { result.whiteBalanceMode = .asShot; result.temperature = temp }
            if let tint = payload[.tint]?.number { result.whiteBalanceMode = .asShot; result.tint = tint }
            return
        }
        try applyPartialWhiteBalance(payload, target: target, to: &result, contextChanged: contextChanged)
    }

    private static func requireTargetCalibrationForMaterialization(_ target: Adjustments) throws {
        if target.masterRecipe != nil && target.asShotWhiteBalance == nil
            && (target.tint * target.strength != 0 || !target.usesAsShotWhiteBalance) {
            throw AdjustmentTransferError.incompatible("target camera white balance unavailable")
        }
    }

    private static func targetCamera(_ target: Adjustments) throws -> WhiteBalance {
        guard let camera = target.asShotWhiteBalance else {
            throw AdjustmentTransferError.incompatible("target camera white balance unavailable")
        }
        return camera
    }

    private static func applyPartialWhiteBalance(_ payload: AdjustmentTransferPayload, target: Adjustments,
                                                   to result: inout Adjustments, contextChanged: Bool) throws {
        let selectedMode = payload[.whiteBalanceMode]?.string
        let cameraMode = selectedMode.map { $0 != "temperature" } ?? target.usesAsShotWhiteBalance
        let temperature = payload[.temperature], tint = payload[.tint]
        if temperature != nil && (cameraMode ? temperature != .null : temperature?.number == nil) {
            throw AdjustmentTransferError.incompatible("select white balance mode with temperature")
        }
        if let tint, cameraMode ? tint.number != nil && payload.source.recipe == nil : tint == .null {
            throw AdjustmentTransferError.incompatible("select white balance mode with tint")
        }
        try requireTargetCalibrationForMaterialization(target)
        let previous = renderWB(target)
        let desired: ResolvedWB
        if cameraMode {
            let offset: Double
            if let tint { offset = (tint.number ?? 0) * (payload.source.recipe?.strength ?? 1) }
            else if target.masterRecipe != nil { offset = target.tint * target.strength }
            else if target.usesAsShotWhiteBalance { offset = 0 }
            else { offset = previous.tint - (try targetCamera(target)).tint }
            if temperature == nil && !target.usesAsShotWhiteBalance {
                guard Float(previous.temperature) == Float(try targetCamera(target).temperature) else {
                    throw AdjustmentTransferError.unrepresentable("unselected white balance temperature")
                }
            }
            if offset == 0 { desired = ResolvedWB(camera: true, temperature: 6500, tint: 0) }
            else {
                let camera = try targetCamera(target)
                let value = camera.tint + offset
                guard (-150...150).contains(value) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
                desired = ResolvedWB(camera: false, temperature: camera.temperature, tint: value)
            }
            if result.masterRecipe == nil && offset != 0 && selectedMode == nil && !contextChanged {
                throw AdjustmentTransferError.incompatible("select white balance mode with relative tint")
            }
            if result.masterRecipe == nil && offset != 0 && selectedMode != nil && tint == nil {
                throw AdjustmentTransferError.unrepresentable("unselected white balance tint")
            }
        } else {
            let fixedTemperature = try temperature?.number ?? (previous.camera ? targetCamera(target).temperature : previous.temperature)
            let fixedTint: Double
            if let value = tint?.number {
                fixedTint = try payload.source.recipe.map { (try targetCamera(target)).tint + value * $0.strength } ?? value
            } else { fixedTint = try previous.camera ? targetCamera(target).tint : previous.tint }
            guard (-150...150).contains(fixedTint) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
            desired = ResolvedWB(camera: false, temperature: fixedTemperature, tint: fixedTint)
        }
        try applyResolvedWB(desired, to: &result)
        if cameraMode && result.masterRecipe != nil {
            result.whiteBalanceMode = .asShot
        }
        if !contextChanged {
            if temperature == nil { result.temperature = target.temperature }
            if tint == nil { result.tint = target.tint }
            if selectedMode == nil { result.whiteBalanceMode = target.whiteBalanceMode }
        }
        guard renderWB(result) == desired else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
    }

    public struct ResolvedWB: Equatable {
        public let camera: Bool
        public let temperature: Double
        public let tint: Double

        public init(camera: Bool, temperature: Double, tint: Double) {
            self.camera = camera
            self.temperature = temperature
            self.tint = tint
        }
    }

    public static func renderWB(_ settings: Adjustments) -> ResolvedWB {
        let rendered = settings.resolvedRenderValues()
        return ResolvedWB(camera: !rendered.usesTemperatureWB,
            temperature: Double(rendered.temperature), tint: Double(rendered.tint))
    }

    public static func resolvedWB(_ value: [String: Value], recipe: AdjustmentRecipeContext?, target: Adjustments,
                                  sourceIsRaw: Bool, targetIsRaw: Bool) throws -> ResolvedWB {
        guard targetIsRaw else { return ResolvedWB(camera: true, temperature: 6500, tint: 0) }
        let camera = value["mode"]!.string == "camera"
        let offset = value["tint_mode"]!.string == "camera_offset"
        let tint = value["tint"]!.number! * (offset ? recipe?.strength ?? 1 : 1)
        if camera && tint == 0 { return ResolvedWB(camera: true, temperature: 6500, tint: 0) }
        if (camera || offset) && target.asShotWhiteBalance == nil {
            throw AdjustmentTransferError.incompatible("target camera white balance unavailable")
        }
        let resolvedTint = offset ? target.asShotWhiteBalance!.tint + tint : tint
        guard resolvedTint.isFinite, (-150...150).contains(resolvedTint) else {
            throw AdjustmentTransferError.unrepresentable("color.white_balance")
        }
        return ResolvedWB(camera: false, temperature: camera ? target.asShotWhiteBalance!.temperature : value["temperature"]!.number!,
            tint: resolvedTint)
    }

    public static func applyResolvedWB(_ desired: ResolvedWB, to settings: inout Adjustments) throws {
        if desired.camera { settings.resetWhiteBalance(); return }
        settings.whiteBalanceMode = .custom
        settings.temperature = desired.temperature
        if settings.masterRecipe != nil {
            guard let camera = settings.asShotWhiteBalance else { throw AdjustmentTransferError.incompatible("target camera white balance unavailable") }
            let delta = desired.tint - camera.tint
            guard settings.strength != 0 || delta == 0 else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
            settings.tint = settings.strength == 0 ? 0 : delta / settings.strength
        } else { settings.tint = desired.tint }
        let actual = renderWB(settings)
        guard !actual.camera, Float(actual.temperature) == Float(desired.temperature), Float(actual.tint) == Float(desired.tint) else {
            throw AdjustmentTransferError.unrepresentable("color.white_balance")
        }
    }

    public static func applyLogicalWB(_ value: [String: Value], to settings: inout Adjustments) {
        if value["mode"]!.string == "temperature" {
            settings.whiteBalanceMode = .custom; settings.temperature = value["temperature"]!.number!
        } else { settings.resetWhiteBalance() }
        settings.tint = value["tint"]!.number!
    }
}
