import Foundation

struct IOSAdjustmentTransferContext {
    var identifier: String
    var isRaw: Bool
    var sourceIsHDR = false
    var availableLookIDs: Set<String> = []
    var builtinLookIDs: [String: String] = [:]
    var cameraTemperature: Double? = nil
    var cameraTint: Double? = nil
    var defaultExposureMode = RawExposureMode.preview
    var hasUncommittedDraft = false
    var validateLensRequest: ((LensCorrectionSettings) throws -> Void)? = nil
}

enum IOSAdjustmentTransfer {
    typealias Field = AdjustmentTransferField
    typealias Value = AdjustmentTransferValue

    static func previewCapture(scope: AdjustmentTransferScope, snapshot: PhotoEditState,
                               committed: PhotoEditState, context: IOSAdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        guard snapshot.hasSameAdjustments(as: committed) else { throw AdjustmentTransferError.draftRequiresPreflight }
        return try capture(scope: scope, snapshot: committed, context: context)
    }

    static func capture(scope: AdjustmentTransferScope, snapshot: PhotoEditState,
                        context: IOSAdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        guard !context.hasUncommittedDraft else { throw AdjustmentTransferError.draftRequiresPreflight }
        if snapshot.settings.isHDREditing {
            guard context.sourceIsHDR, !context.isRaw else { throw AdjustmentTransferError.incompatible("hdr.source") }
            return try HDRAdjustmentTransfer.capture(settings: snapshot.settings.hdr!, identifier: context.identifier,
                processingVersion: snapshot.settings.processing.version, scope: scope)
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

    static func prepare(payload: AdjustmentTransferPayload, target: PhotoEditState,
                        context: IOSAdjustmentTransferContext) throws -> PhotoEditState {
        guard !context.hasUncommittedDraft else { throw AdjustmentTransferError.draftRequiresPreflight }
        try payload.validate()
        if target.settings.isHDREditing {
            guard context.sourceIsHDR, !context.isRaw else { throw AdjustmentTransferError.incompatible("hdr.source") }
            var settings = target.settings
            settings.hdr = try HDRAdjustmentTransfer.prepare(payload: payload, target: target.settings.hdr!)
            return target.replacing(settings: settings, preservingFilmID: target.filmID)
        }
        if payload.source.isHDR {
            return try prepare(payload: HDRAdjustmentTransfer.legacyPayload(payload), target: target, context: context)
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
        if let mode = payload[.exposureMode]?.string {
            guard context.isRaw || !payload.source.isRaw || mode == "sensor" else {
                throw AdjustmentTransferError.incompatible(Field.exposureMode.rawValue)
            }
            result.exposureMode = mode == "scene" ? .scene : mode == "preview" ? .preview : .sensor
        }
        for (field, key) in effectKeys {
            if let value = payload[field]?.number {
                guard value.rounded() == value else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
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
        if !selected.contains(.postRGBDenoise), target.settings.denoise.enabled != result.denoise.enabled,
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

    static func validate(_ settings: RawSettings) throws {
        guard EditorAdjustmentRules.valid(settings) else { throw AdjustmentTransferError.unrepresentable("native range") }
        if let id = settings.masterRecipeID, MasterRecipe.recipe(for: id) == nil {
            throw AdjustmentTransferError.missingLook("recipe:\(id)")
        }
    }
    static func isRecipeScaled(_ field: Field, version: Int = 3) -> Bool {
        [.exposure, .contrast, .highlights, .shadows, .saturation].contains(field) || version >= 4 && Field.refinementScalars.contains(field)
    }
    static func sourceEffective(_ value: Double, field: Field, recipe: AdjustmentRecipeContext?) -> Double {
        let scale = recipe?.strength ?? 1
        if field.hslLocation != nil { return min(100, max(-100, value * ((recipe?.settingsVersion ?? 2) >= 3 ? scale : 1))) }
        if field == .contrast || field == .saturation { return 1 + (value - 1) * scale }
        if (recipe?.settingsVersion ?? 3) >= 4 && Field.refinementScalars.contains(field) {
            let limit = field == .sCurve ? 1.0 : 100.0
            return min(limit, max(-limit, value * scale))
        }
        return isRecipeScaled(field) ? value * scale : value
    }
    static func assignEffective(_ value: Double, field: Field, to settings: inout RawSettings) throws {
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
    static func assignHSL(_ value: Double, field: Field, to settings: inout RawSettings) throws {
        let location = field.hslLocation!
        guard settings.hsl.setExact(HSLAxis(rawValue: location.axis)!, channel: location.channel, value: value) else {
            throw AdjustmentTransferError.unrepresentable(field.rawValue)
        }
    }
}
