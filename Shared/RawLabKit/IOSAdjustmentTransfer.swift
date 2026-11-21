import Foundation

public struct IOSAdjustmentTransferContext {
    public var identifier: String
    public var isRaw: Bool
    public var sourceIsHDR = false
    public var sourceSupportsCameraHDR = false
    public var sourceIsBayerHDR = false
    public var availableLookIDs: Set<String> = []
    public var builtinLookIDs: [String: String] = [:]
    public var cameraTemperature: Double? = nil
    public var cameraTint: Double? = nil
    public var defaultExposureMode = RawExposureMode.preview
    public var hasUncommittedDraft = false
    public var validateLensRequest: ((LensCorrectionSettings) throws -> Void)? = nil
    public var validateHDRCameraRequest: ((RawSettings) throws -> Void)? = nil
    public var transferNotices: ((AdjustmentTransferNotice) -> Void)? = nil

    public init(identifier: String,
                isRaw: Bool,
                sourceIsHDR: Bool = false,
                sourceSupportsCameraHDR: Bool = false,
                sourceIsBayerHDR: Bool = false,
                availableLookIDs: Set<String> = [],
                builtinLookIDs: [String: String] = [:],
                cameraTemperature: Double? = nil,
                cameraTint: Double? = nil,
                defaultExposureMode: RawExposureMode = .preview,
                hasUncommittedDraft: Bool = false,
                validateLensRequest: ((LensCorrectionSettings) throws -> Void)? = nil,
                validateHDRCameraRequest: ((RawSettings) throws -> Void)? = nil,
                transferNotices: ((AdjustmentTransferNotice) -> Void)? = nil) {
        self.identifier = identifier
        self.isRaw = isRaw
        self.sourceIsHDR = sourceIsHDR
        self.sourceSupportsCameraHDR = sourceSupportsCameraHDR
        self.sourceIsBayerHDR = sourceIsBayerHDR
        self.availableLookIDs = availableLookIDs
        self.builtinLookIDs = builtinLookIDs
        self.cameraTemperature = cameraTemperature
        self.cameraTint = cameraTint
        self.defaultExposureMode = defaultExposureMode
        self.hasUncommittedDraft = hasUncommittedDraft
        self.validateLensRequest = validateLensRequest
        self.validateHDRCameraRequest = validateHDRCameraRequest
        self.transferNotices = transferNotices
    }
}

public enum IOSAdjustmentTransfer {
    public typealias Field = AdjustmentTransferField
    public typealias Value = AdjustmentTransferValue

    public static func previewCapture(scope: AdjustmentTransferScope, snapshot: PhotoEditState,
                                      committed: PhotoEditState, context: IOSAdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        guard snapshot.hasSameAdjustments(as: committed) else { throw AdjustmentTransferError.draftRequiresPreflight }
        return try capture(scope: scope, snapshot: committed, context: context)
    }

    public static func capture(scope: AdjustmentTransferScope, snapshot: PhotoEditState,
                               context: IOSAdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        guard !context.hasUncommittedDraft else { throw AdjustmentTransferError.draftRequiresPreflight }
        if snapshot.settings.isHDREditing {
            guard supportsHDRTransfer(context) else { throw AdjustmentTransferError.incompatible("hdr.source") }
            return try HDRAdjustmentTransfer.capture(settings: snapshot.settings.hdr!, identifier: context.identifier,
                processingVersion: snapshot.settings.processing.version, scope: scope, cameraRAW: context.sourceIsBayerHDR)
        }
        try validate(snapshot.settings)
        var defaults = RawSettings.default
        defaults.exposureMode = context.isRaw ? context.defaultExposureMode : .sensor
        let original = values(snapshot.settings, context: context), neutral = values(defaults, context: context)
        let selected: Set<Field>
        switch scope {
        case .all: selected = Field.legacyFields
        case .custom(let fields): selected = fields
        case .modified: selected = Set(Field.common.filter { original[$0.rawValue] != neutral[$0.rawValue] })
        }
        let settings = snapshot.settings
        let recipe = settings.masterRecipeID.map {
            AdjustmentRecipeContext(id: $0, strength: settings.recipeScale, settingsVersion: settings.masterRecipeSettingsVersion)
        }
        return try AdjustmentTransferPayload(source: .init(identifier: context.identifier, isRaw: context.isRaw,
            processingVersion: settings.processing.version, recipe: recipe),
            values: original.filter { selected.contains(Field(rawValue: $0.key)!) })
    }

    public static func prepare(payload: AdjustmentTransferPayload, target: PhotoEditState,
                               context: IOSAdjustmentTransferContext) throws -> PhotoEditState {
        guard !context.hasUncommittedDraft else { throw AdjustmentTransferError.draftRequiresPreflight }
        try payload.validate()
        if target.settings.isHDREditing {
            guard supportsHDRTransfer(context) else { throw AdjustmentTransferError.incompatible("hdr.source") }
            var settings = target.settings
            let hdr = try HDRAdjustmentTransfer.prepare(payload: payload, target: target.settings.hdr!, cameraRAW: context.sourceIsBayerHDR)
            guard hdr.lookSettings.assetIsAvailable() else { throw AdjustmentTransferError.missingLook(hdr.lookSettings.name ?? "HDR LUT") }
            settings.hdr = hdr
            if payload.fields.contains(.hdrCameraDevelopment) {
                guard let validate = context.validateHDRCameraRequest else { throw AdjustmentTransferError.incompatible("hdr.camera_development") }
                try validate(settings)
            }
            return target.replacing(settings: settings, preservingFilmID: target.filmID)
        }
        if payload.source.isHDR {
            return try prepare(payload: HDRAdjustmentTransfer.legacyPayload(payload), target: target, context: context)
        }
        // Q4：来源与目标处理版本不同不拒绝，沿用目标处理版本并一次性提示。
        if payload.source.processingVersion != target.settings.processing.version {
            context.transferNotices?(.retainedTargetProcessingVersion)
        }
        try validate(target.settings)
        var result = target.settings, filmID = target.filmID
        let selected = payload.fields, before = effectiveNumbers(target.settings)
        var fullRecipe = false
        if let look = payload[.look]?.object {
            let kind = look["kind"]!.string!, id = look["id"]!.string
            let lookup = kind == "recipe_lut" ? "recipe:\(id!)" : kind == "managed" ? id! : "\(kind):\(id ?? "")"
            guard kind == "neutral" || context.availableLookIDs.contains(lookup) else {
                throw AdjustmentTransferError.missingLook(lookup)
            }
            fullRecipe = kind == "recipe" && Field.recipeDependencies(version: payload.source.recipe?.settingsVersion ?? 3).isSubset(of: selected)
            if fullRecipe {
                guard let recipe = payload.source.recipe, MasterRecipe.recipe(for: recipe.id) != nil else {
                    throw AdjustmentTransferError.missingLook(lookup)
                }
                result.masterRecipeID = recipe.id; result.lutID = nil; filmID = nil
                result.masterRecipeSettingsVersion = recipe.settingsVersion
            } else {
                result.masterRecipeID = nil
                result.masterRecipeSettingsVersion = 3
                switch kind {
                case "neutral": result.lutID = nil
                case "recipe", "recipe_lut": result.lutID = "recipe-lut:\(id!)"
                case "managed": result.lutID = id!
                default:
                    guard let native = context.builtinLookIDs[id!] else { throw AdjustmentTransferError.missingLook(lookup) }
                    result.lutID = native
                }
                filmID = result.lutID
            }
        }
        if let strength = payload[.strength]?.number { result.lutStrength = strength }
        let contextChanged = result.masterRecipeID != target.settings.masterRecipeID
            || result.masterRecipeSettingsVersion != target.settings.masterRecipeSettingsVersion
            || result.recipeScale != target.settings.recipeScale
        for (field, key) in scalarKeys {
            if let value = payload[field]?.number {
                if fullRecipe { result[keyPath: key] = value }
                else { try assignEffective(sourceEffective(value, field: field, recipe: payload.source.recipe), field: field, to: &result) }
            } else if contextChanged && effectiveNumbers(result)[field] != before[field] {
                try assignEffective(before[field]!, field: field, to: &result)
            }
        }
        for field in Field.allCases where field.hslLocation != nil {
            if let value = payload[field]?.number {
                if fullRecipe { try assignHSL(value, field: field, to: &result) }
                else { try assignEffective(sourceEffective(value, field: field, recipe: payload.source.recipe), field: field, to: &result) }
            } else if contextChanged && effectiveNumbers(result)[field] != before[field] {
                try assignEffective(before[field]!, field: field, to: &result)
            }
        }
        // iOS 现有 renderer 的配方强度经 Float 投影；只修正实际 request 不一致的选中值。
        for field in before.keys where field != .strength {
            guard let value = payload[field]?.number else { continue }
            let expected = sourceEffective(value, field: field, recipe: payload.source.recipe)
            if Float(effectiveNumbers(result)[field]!) != Float(expected) {
                try assignEffective(expected, field: field, to: &result)
            }
        }
        try applyWhiteBalance(payload, target: target.settings, to: &result, context: context,
            fullRecipe: fullRecipe, contextChanged: contextChanged)
        if let mode = payload[.exposureMode]?.string, payload.source.isRaw || !context.isRaw {
            // 普通图片没有 RAW 曝光基准：其 sensor 占位值不改变 RAW 目标；普通目标始终保持 sensor。
            result.exposureMode = !context.isRaw || mode == "sensor" ? .sensor : mode == "scene" ? .scene : .preview
        }
        for (field, key) in effectKeys {
            if let value = payload[field]?.number {
                result.photoEffects[keyPath: key] = value
            }
        }
        try applyObjects(payload, to: &result, context: context)
        let refinements = try AdjustmentTransferRefinement.applying(payload,
            original: AdjustmentTransferRefinement.values(curve: target.settings.curveSettings, grading: target.settings.gradingSettings),
            previousScale: target.settings.refinementScale, targetScale: result.refinementScale, fullRecipe: fullRecipe)
        result.curveSettings = refinements[.curve]!.curve!
        for field in Field.refinementObjects {
            if let zone = field.gradingZone, let wheel = refinements[field]?.object {
                result.gradingSettings[zone] = ColorGradingWheel(hue: wheel["hue"]!.number!, saturation: wheel["saturation"]!.number!)
            }
        }
        if context.isRaw, !selected.contains(.postRGBDenoise), target.settings.denoise.enabled != result.denoise.enabled,
           target.settings.noiseReduction != 0 {
            throw AdjustmentTransferError.unrepresentable("unselected \(Field.postRGBDenoise.rawValue)")
        }
        try validate(result)
        let actual = effectiveNumbers(result)
        for field in before.keys where field != .strength {
            let expected = payload[field]?.number.map { sourceEffective($0, field: field, recipe: payload.source.recipe) } ?? before[field]!
            guard Float(actual[field]!) == Float(expected) else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
        }
        if values(result, context: context) == values(target.settings, context: context)
            && result.masterRecipeSettingsVersion == target.settings.masterRecipeSettingsVersion { return target }
        return target.replacing(settings: result, preservingFilmID: filmID)
    }

    public static func validate(_ settings: RawSettings) throws {
        guard EditorAdjustmentRules.valid(settings) else { throw AdjustmentTransferError.unrepresentable("native range") }
        if let id = settings.masterRecipeID, MasterRecipe.recipe(for: id) == nil {
            throw AdjustmentTransferError.missingLook("recipe:\(id)")
        }
    }

    private static func supportsHDRTransfer(_ context: IOSAdjustmentTransferContext) -> Bool {
        (!context.isRaw && context.sourceIsHDR) || (context.isRaw && context.sourceSupportsCameraHDR)
    }
    public static func isRecipeScaled(_ field: Field, version: Int = 3) -> Bool {
        [.exposure, .contrast, .highlights, .shadows, .saturation].contains(field) || version >= 4 && Field.refinementScalars.contains(field)
    }
    public static func sourceEffective(_ value: Double, field: Field, recipe: AdjustmentRecipeContext?) -> Double {
        let scale = recipe?.strength ?? 1
        if field.hslLocation != nil { return min(100, max(-100, value * ((recipe?.settingsVersion ?? 2) >= 3 ? scale : 1))) }
        if field == .contrast || field == .saturation { return 1 + (value - 1) * scale }
        if (recipe?.settingsVersion ?? 3) >= 4 && Field.refinementScalars.contains(field) {
            let limit = field == .sCurve ? 1.0 : 100.0
            return min(limit, max(-limit, value * scale))
        }
        return isRecipeScaled(field) ? value * scale : value
    }
    public static func assignEffective(_ value: Double, field: Field, to settings: inout RawSettings) throws {
        let scale = settings.recipeScale
        if field.hslLocation != nil {
            let hslScale = settings.masterRecipeSettingsVersion >= 3 ? scale : 1
            guard hslScale != 0 || value == 0 else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            try assignHSL(hslScale == 0 ? 0 : value / hslScale, field: field, to: &settings); return
        }
        let identity: Double = [.contrast, .saturation].contains(field) ? 1 : 0
        if isRecipeScaled(field, version: settings.masterRecipeSettingsVersion) {
            guard scale != 0 || value == identity else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            settings[keyPath: scalarKeys[field]!] = scale == 0 ? identity : identity + (value - identity) / scale
        } else { settings[keyPath: scalarKeys[field]!] = value }
    }
    public static func assignHSL(_ value: Double, field: Field, to settings: inout RawSettings) throws {
        let location = field.hslLocation!
        guard settings.hsl.setExact(HSLAxis(rawValue: location.axis)!, channel: location.channel, value: value) else {
            throw AdjustmentTransferError.unrepresentable(field.rawValue)
        }
    }

    public static let scalarKeys: [Field: WritableKeyPath<RawSettings, Double>] = [
        .strength: \.lutStrength, .exposure: \.exposure, .contrast: \.contrast, .highlights: \.highlights,
        .shadows: \.shadows, .sCurve: \.toneCurve, .saturation: \.saturation, .sharpening: \.sharpening,
        .blackPoint: \.blackPoint, .whitePoint: \.whitePoint, .vibrance: \.vibrance, .clarity: \.clarity, .dehaze: \.dehaze
    ]
    public static let effectKeys: [Field: WritableKeyPath<PhotoEffectsSettings, Double>] = [
        .vignetteAmount: \.vignetteAmount, .vignetteMidpoint: \.vignetteMidpoint, .vignetteRoundness: \.vignetteRoundness,
        .vignetteFeather: \.vignetteFeather, .vignetteHighlights: \.vignetteHighlights, .grainAmount: \.grainAmount,
        .grainSize: \.grainSize, .grainRoughness: \.grainRoughness
    ]
    public static let geometryKeys: [Field: WritableKeyPath<GeometrySettings, Double>] = [
        .cropX: \.cropX, .cropY: \.cropY, .cropWidth: \.cropWidth, .cropHeight: \.cropHeight,
        .straighten: \.straightenDegrees, .perspectiveHorizontal: \.perspectiveHorizontal,
        .perspectiveVertical: \.perspectiveVertical
    ]
    public static func presetID(_ preset: RawDenoisePreset) -> String {
        switch preset { case .detail: return "detail"; case .clean: return "clean"; case .custom: return "custom" }
    }
    public static func effectiveNumbers(_ settings: RawSettings) -> [Field: Double] {
        let rendered = settings.renderedRecipe(cameraTemperature: 6500, cameraTint: 0)
        var result = scalarKeys.mapValues { Double(Float(rendered[keyPath: $0])) }
        for field in Field.allCases {
            if let location = field.hslLocation {
                result[field] = rendered.hsl.value(HSLAxis(rawValue: location.axis)!, channel: location.channel)
            }
        }
        return result
    }
    public static func values(_ settings: RawSettings, context: IOSAdjustmentTransferContext) -> [String: Value] {
        var result = [String: Value]()
        result[Field.curve.rawValue] = settings.curveSettings.transferValue
        for (field, key) in scalarKeys { result[field.rawValue] = .number(settings[keyPath: key]) }
        result[Field.strength.rawValue] = .number(Double(settings.clampedLUTStrength))
        let look: [String: Value]
        if let id = settings.masterRecipeID { look = ["kind": .string("recipe"), "id": .string(id)] }
        else if let id = settings.lutID {
            if id.hasPrefix("recipe-lut:") { look = ["kind": .string("recipe_lut"), "id": .string(String(id.dropFirst(11)))] }
            else if let filename = context.builtinLookIDs.first(where: { $0.value == id })?.key {
                look = ["kind": .string("builtin"), "id": .string(filename)]
            } else { look = ["kind": .string("managed"), "id": .string(id)] }
        } else { look = ["kind": .string("neutral"), "id": .null] }
        result[Field.look.rawValue] = .object(look)
        result[Field.exposureMode.rawValue] = .string(!context.isRaw ? "sensor" : settings.exposureMode == .scene ? "scene" : settings.exposureMode == .preview ? "preview" : "sensor")
        let camera = !context.isRaw || settings.whiteBalanceMode == .camera
        result[Field.whiteBalanceMode.rawValue] = .string(!context.isRaw ? "none" : camera ? "camera" : "temperature")
        result[Field.temperature.rawValue] = camera ? .null : .number(settings.temperature)
        result[Field.tint.rawValue] = settings.masterRecipeID != nil ? .number(settings.tint) : camera ? .null : .number(settings.tint)
        for field in Field.allCases {
            if let location = field.hslLocation {
                result[field.rawValue] = .number(settings.hsl.value(HSLAxis(rawValue: location.axis)!, channel: location.channel))
            }
        }
        for field in Field.allCases {
            if let zone = field.gradingZone {
                let wheel = settings.gradingSettings[zone]
                result[field.rawValue] = .object(["hue": .number(wheel.hue), "saturation": .number(wheel.saturation)])
            }
        }
        for (field, key) in effectKeys { result[field.rawValue] = .number(settings.photoEffects[keyPath: key]) }
        result[Field.rawDenoise.rawValue] = .number(0)
        result[Field.postRGBDenoise.rawValue] = .number(context.isRaw ? settings.noiseReduction : 0)
        result[Field.chromaDenoise.rawValue] = .number(Double(settings.displayChromaDenoise))
        let denoise = settings.denoise
        result[Field.waveletDenoise.rawValue] = .object(["enabled": .boolean(denoise.enabled),
            "luma": .number(denoise.luma), "chroma": .number(denoise.chroma), "coarse": .number(denoise.coarse),
            "preset": .string(presetID(denoise.preset))])
        for (field, key) in geometryKeys { result[field.rawValue] = .number(settings.geometry[keyPath: key]) }
        result[Field.quarterTurns.rawValue] = .number(Double(settings.geometry.quarterTurns))
        result[Field.flipHorizontal.rawValue] = .boolean(settings.geometry.flipHorizontal)
        result[Field.flipVertical.rawValue] = .boolean(settings.geometry.flipVertical)
        let lens = settings.lensSettings
        result[Field.lensDistortion.rawValue] = .boolean(lens.distortion)
        result[Field.lensTCA.rawValue] = .boolean(lens.tca)
        result[Field.lensVignetting.rawValue] = .boolean(lens.vignetting)
        result[Field.lensAutoCrop.rawValue] = .boolean(lens.autoCrop)
        result[Field.lensProfile.rawValue] = lens.mode == .automatic ? .null : .string(lens.coreProfileID)
        return result
    }
    public static func applyObjects(_ payload: AdjustmentTransferPayload, to settings: inout RawSettings,
                                    context: IOSAdjustmentTransferContext) throws {
        // Q3：iOS 不建模解马赛克前 FBDD，收到非 0 raw_level 忽略并提示，不再拒绝。
        if let raw = payload[.rawDenoise]?.number, raw != 0 { context.transferNotices?(.ignoredRawDenoise) }
        if let post = payload[.postRGBDenoise]?.number, payload.source.isRaw || !context.isRaw {
            if !context.isRaw && post != 0 {
                context.transferNotices?(.ignoredPostRGBDenoise)
            } else {
                settings.noiseReduction = post
            }
        }
        if let chroma = payload[.chromaDenoise] { settings.displayChromaDenoise = Int(chroma.number ?? 0) }
        if let value = payload[.waveletDenoise] {
            if let wavelet = value.object {
                let denoise = RawDenoiseSettings(enabled: wavelet["enabled"]!.boolean!, luma: wavelet["luma"]!.number!,
                    chroma: wavelet["chroma"]!.number!, coarse: wavelet["coarse"]!.number!)
                guard presetID(denoise.preset) == wavelet["preset"]!.string! else {
                    throw AdjustmentTransferError.unrepresentable("detail.denoise.wavelet.preset")
                }
                settings.denoise = denoise
            } else { settings.denoise = RawDenoiseSettings() }
        }
        if payload.fields.contains(where: { $0.group == "geometry" && !Field.lensFields.contains($0) }) {
            var geometry = settings.geometry
            for (field, key) in geometryKeys { if let value = payload[field]?.number { geometry[keyPath: key] = value } }
            if let value = payload[.quarterTurns]?.number { geometry.quarterTurns = Int(value) }
            if let value = payload[.flipHorizontal]?.boolean { geometry.flipHorizontal = value }
            if let value = payload[.flipVertical]?.boolean { geometry.flipVertical = value }
            guard geometry.isValid else { throw AdjustmentTransferError.unrepresentable("geometry.crop") }
            settings.geometry = geometry
        }
        if !payload.fields.isDisjoint(with: Field.lensFields) {
            let neutral: [Field: Value] = [.lensDistortion: .boolean(false), .lensTCA: .boolean(false), .lensVignetting: .boolean(false),
                .lensAutoCrop: .boolean(true), .lensProfile: .null]
            let isNeutralLens = neutral.allSatisfy { payload[$0.key] == nil || payload[$0.key] == $0.value }
            if payload.source.isRaw || !context.isRaw || !isNeutralLens {
                var lens = settings.lensSettings
                if let value = payload[.lensDistortion]?.boolean { lens.distortion = value }
                if let value = payload[.lensTCA]?.boolean { lens.tca = value }
                if let value = payload[.lensVignetting]?.boolean { lens.vignetting = value }
                if let value = payload[.lensAutoCrop]?.boolean { lens.autoCrop = value }
                if let value = payload[.lensProfile] { lens.mode = value == .null ? .automatic : .manual; lens.profileID = value.string == "__rawlab_manual_selection_required__" ? nil : value.string }
                if lens.isEnabled && lens.mode == .manual && lens.profileID == nil {
                    throw AdjustmentTransferError.unrepresentable(Field.lensProfile.rawValue)
                }
                if lens.isEnabled {
                    guard let validate = context.validateLensRequest else { throw AdjustmentTransferError.incompatible("target lens calibration unavailable") }
                    try validate(lens)
                }
                let previous = settings.lensSettings
                if lens.distortion != previous.distortion || lens.tca != previous.tca || lens.vignetting != previous.vignetting || lens.autoCrop != previous.autoCrop
                    || lens.mode != previous.mode || lens.mode == .manual && lens.profileID != previous.profileID {
                    settings.lensCorrection = lens == LensCorrectionSettings() ? nil : lens
                }
            }
        }
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
        public static func == (left: Self, right: Self) -> Bool {
            left.camera == right.camera && Float(left.temperature) == Float(right.temperature) && Float(left.tint) == Float(right.tint)
        }
    }
    public static func renderWB(_ settings: RawSettings, context: IOSAdjustmentTransferContext) -> ResolvedWB {
        let rendered = settings.renderedRecipe(cameraTemperature: context.cameraTemperature ?? 6500, cameraTint: context.cameraTint ?? 0)
        let camera = rendered.whiteBalanceMode == .camera
        return .init(camera: camera, temperature: camera ? 6500 : Double(Float(rendered.temperature)),
            tint: camera ? 0 : Double(Float(rendered.tint)))
    }
    private static func targetCamera(_ context: IOSAdjustmentTransferContext) throws -> ResolvedWB {
        guard let temperature = context.cameraTemperature, let tint = context.cameraTint,
              temperature.isFinite, tint.isFinite, RawSettings.temperatureRange.contains(temperature), RawSettings.tintRange.contains(tint) else {
            throw AdjustmentTransferError.incompatible("target camera white balance unavailable")
        }
        return .init(camera: false, temperature: temperature, tint: tint)
    }
    private static func requireTargetCalibration(_ target: RawSettings, context: IOSAdjustmentTransferContext) throws {
        if target.masterRecipeID != nil && (target.tint * target.recipeScale != 0 || target.whiteBalanceMode != .camera) {
            _ = try targetCamera(context)
        }
    }
    public static func applyWhiteBalance(_ payload: AdjustmentTransferPayload, target: RawSettings, to result: inout RawSettings,
                                         context: IOSAdjustmentTransferContext, fullRecipe: Bool, contextChanged: Bool) throws {
        var selected = payload.fields.intersection(Field.whiteBalanceFields)
        if !payload.source.isRaw && context.isRaw && (payload.source.recipe == nil || !selected.contains(.tint)) {
            selected.removeAll()
        }
        if selected.isEmpty {
            if context.isRaw && contextChanged && renderWB(result, context: context) != renderWB(target, context: context) {
                try requireTargetCalibration(target, context: context)
                try applyResolvedWB(renderWB(target, context: context), to: &result, context: context)
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
        let previousValues = values(target, context: context)
        let previousRecipe = target.masterRecipeID.map { AdjustmentRecipeContext(id: $0, strength: target.recipeScale, settingsVersion: target.masterRecipeSettingsVersion) }
        if !contextChanged && context.isRaw == payload.source.isRaw && previousRecipe == payload.source.recipe
            && selected.allSatisfy({ payload[$0] == previousValues[$0.rawValue] }) { return }
        if selected == Field.whiteBalanceFields {
            let mode = payload[.whiteBalanceMode]!.string!
            let balance: [String: Value] = ["mode": .string(mode == "none" && payload.source.recipe != nil ? "camera" : mode),
                "temperature": payload[.temperature]!, "tint": .number(payload[.tint]?.number ?? 0),
                "tint_mode": .string(payload.source.recipe != nil || mode == "camera" ? "camera_offset" : "absolute")]
            let desired = try resolvedWB(balance, recipe: payload.source.recipe, sourceIsRaw: payload.source.isRaw, context: context)
            if fullRecipe {
                applyLogicalWB(balance, to: &result)
                if context.isRaw && renderWB(result, context: context) != desired {
                    try applyResolvedWB(desired, to: &result, context: context)
                    if balance["mode"]!.string == "camera" { result.whiteBalanceMode = .camera }
                }
            } else if context.isRaw { try applyResolvedWB(desired, to: &result, context: context) }
            return
        }
        guard context.isRaw else { return }
        let selectedMode = payload[.whiteBalanceMode]?.string
        let cameraMode = selectedMode.map { $0 != "temperature" } ?? (target.whiteBalanceMode == .camera)
        let temperature = payload[.temperature], tint = payload[.tint]
        if temperature != nil && (cameraMode ? temperature != .null : temperature?.number == nil) {
            throw AdjustmentTransferError.incompatible("select white balance mode with temperature")
        }
        if let tint, cameraMode ? tint.number != nil && payload.source.recipe == nil : tint == .null {
            throw AdjustmentTransferError.incompatible("select white balance mode with tint")
        }
        try requireTargetCalibration(target, context: context)
        let previous = renderWB(target, context: context), desired: ResolvedWB
        if cameraMode {
            let offset: Double
            if let tint { offset = (tint.number ?? 0) * (payload.source.recipe?.strength ?? 1) }
            else if target.masterRecipeID != nil { offset = target.tint * target.recipeScale }
            else if target.whiteBalanceMode == .camera { offset = 0 }
            else { offset = previous.tint - (try targetCamera(context)).tint }
            if temperature == nil && target.whiteBalanceMode != .camera {
                guard Float(previous.temperature) == Float(try targetCamera(context).temperature) else {
                    throw AdjustmentTransferError.unrepresentable("unselected white balance temperature")
                }
            }
            if offset == 0 { desired = .init(camera: true, temperature: 6500, tint: 0) }
            else {
                let camera = try targetCamera(context), value = camera.tint + offset
                guard RawSettings.tintRange.contains(value) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
                desired = .init(camera: false, temperature: camera.temperature, tint: value)
            }
            if result.masterRecipeID == nil && offset != 0 && selectedMode == nil && !contextChanged {
                throw AdjustmentTransferError.incompatible("select white balance mode with relative tint")
            }
            if result.masterRecipeID == nil && offset != 0 && selectedMode != nil && tint == nil {
                throw AdjustmentTransferError.unrepresentable("unselected white balance tint")
            }
        } else {
            let fixedTemperature = try temperature?.number ?? (previous.camera ? targetCamera(context).temperature : previous.temperature)
            let fixedTint: Double
            if let value = tint?.number { fixedTint = try payload.source.recipe.map { (try targetCamera(context)).tint + value * $0.strength } ?? value }
            else { fixedTint = try previous.camera ? targetCamera(context).tint : previous.tint }
            guard RawSettings.tintRange.contains(fixedTint) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
            desired = .init(camera: false, temperature: fixedTemperature, tint: fixedTint)
        }
        try applyResolvedWB(desired, to: &result, context: context)
        if cameraMode && result.masterRecipeID != nil { result.whiteBalanceMode = .camera }
        if !contextChanged {
            if temperature == nil { result.temperature = target.temperature }
            if tint == nil { result.tint = target.tint }
            if selectedMode == nil { result.whiteBalanceMode = target.whiteBalanceMode }
        }
        guard renderWB(result, context: context) == desired else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
    }
    public static func resolvedWB(_ value: [String: Value], recipe: AdjustmentRecipeContext?, sourceIsRaw: Bool,
                                  context: IOSAdjustmentTransferContext) throws -> ResolvedWB {
        guard context.isRaw else { return .init(camera: true, temperature: 6500, tint: 0) }
        let camera = value["mode"]!.string == "camera", offset = value["tint_mode"]!.string == "camera_offset"
        let tint = value["tint"]!.number! * (offset ? recipe?.strength ?? 1 : 1)
        if camera && tint == 0 { return .init(camera: true, temperature: 6500, tint: 0) }
        let calibration = try camera || offset ? targetCamera(context) : nil
        let resolvedTint = offset ? calibration!.tint + tint : tint
        guard RawSettings.tintRange.contains(resolvedTint) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
        return .init(camera: false, temperature: camera ? calibration!.temperature : value["temperature"]!.number!, tint: resolvedTint)
    }
    public static func applyResolvedWB(_ desired: ResolvedWB, to settings: inout RawSettings, context: IOSAdjustmentTransferContext) throws {
        if desired.camera { settings.whiteBalanceMode = .camera; settings.temperature = 6500; settings.tint = 0; return }
        settings.whiteBalanceMode = .custom; settings.temperature = desired.temperature
        if settings.masterRecipeID != nil {
            let delta = desired.tint - (try targetCamera(context)).tint, scale = settings.recipeScale
            guard scale != 0 || delta == 0 else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
            settings.tint = scale == 0 ? 0 : delta / scale
        } else { settings.tint = desired.tint }
        guard renderWB(settings, context: context) == desired else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
    }
    private static func applyLogicalWB(_ value: [String: Value], to settings: inout RawSettings) {
        settings.whiteBalanceMode = value["mode"]!.string == "temperature" ? .custom : .camera
        settings.temperature = value["temperature"]!.number ?? 6500
        settings.tint = value["tint"]!.number!
    }
}

/// 粘贴结果提示在 Sheet 内的展示契约（Q14 表示层断言，V-UIIOS #301）：
/// 提示只属于当前粘贴批次——重备或重开面板后结果尚未产生时，上一批旧提示不得再现。
public enum IOSAdjustmentPasteNoticeDisplay {
    public static func showsInSheet(notices: [String], hasPasteResults: Bool) -> Bool {
        !notices.isEmpty && hasPasteResults
    }
}
