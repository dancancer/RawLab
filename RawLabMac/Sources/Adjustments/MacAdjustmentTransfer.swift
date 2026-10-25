import Foundation

struct MacAdjustmentTransferContext {
    var identifier: String
    var isRaw: Bool
    var availableLookIDs: Set<String> = []
    var defaultExposureMode = ExposureMode.preview
    var hasUncommittedDraft = false
    var validateLensRequest: ((LensCorrectionSettings) throws -> Void)? = nil
}

enum MacAdjustmentTransfer {
    typealias Field = AdjustmentTransferField
    typealias Value = AdjustmentTransferValue

    static func capture(scope: AdjustmentTransferScope, snapshot: PhotoEditState,
                        context: MacAdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        guard !context.hasUncommittedDraft else { throw AdjustmentTransferError.draftRequiresPreflight }
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
        let neutral = values(PhotoEditState(settings: defaults, filmID: ""), isRaw: context.isRaw)
        let selected: Set<Field>
        switch scope {
        case .all: selected = Set(Field.allCases)
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

    static func prepare(payload: AdjustmentTransferPayload, target: PhotoEditState,
                        context: MacAdjustmentTransferContext) throws -> PhotoEditState {
        guard !context.hasUncommittedDraft else { throw AdjustmentTransferError.draftRequiresPreflight }
        try payload.validate()
        if target.settings.aiDenoiseEnabled && !payload.fields.isDisjoint(with: Field.denoiseFields) {
            throw AdjustmentTransferError.incompatible("ai.target_denoise")
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
            fullRecipe = kind == "recipe" && Field.recipeDependencies.isSubset(of: selected)
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
                if contextChanged && isRecipeScaled(field) && effectiveNumbers(result.settings)[field] != oldEffective[field] {
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
        if let mode = payload[.exposureMode]?.string {
            if !context.isRaw && payload.source.isRaw && mode != "sensor" {
                throw AdjustmentTransferError.incompatible(Field.exposureMode.rawValue)
            }
            result.settings.exposureMode = mode == "scene" ? .scene : mode == "sensor" ? .sensor : .preview
        }
        for (field, key) in effectKeys {
            if let value = payload[field]?.number, result.settings.effectSettings[keyPath: key] != value {
                var effects = result.settings.effectSettings
                effects[keyPath: key] = value
                result.settings.photoEffects = effects == PhotoEffectsSettings() ? nil : effects
            }
        }
        try applyObjects(payload, to: &result.settings, context: context)
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
            && result.settings.recipeSettingsVersion == target.settings.recipeSettingsVersion {
            return target
        }
        return result
    }

    static func isRecipeScaled(_ field: Field) -> Bool {
        [.exposure, .contrast, .highlights, .shadows, .saturation].contains(field)
    }

    static func sourceEffective(_ value: Double, field: Field, recipe: AdjustmentRecipeContext?) -> Double {
        let scale = recipe?.strength ?? 1
        if field.hslLocation != nil {
            return min(100, max(-100, value * ((recipe?.settingsVersion ?? 2) >= 3 ? scale : 1)))
        }
        if field == .contrast || field == .saturation { return 1 + (value - 1) * scale }
        return isRecipeScaled(field) ? value * scale : value
    }

    static func assignEffective(_ value: Double, field: Field, to settings: inout Adjustments) throws {
        let scale = settings.masterRecipe == nil ? 1 : settings.strength
        if field.hslLocation != nil {
            let hslScale = settings.masterRecipe != nil && settings.recipeSettingsVersion >= 3 ? scale : 1
            guard hslScale != 0 || value == 0 else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            try assignHSL(hslScale == 0 ? 0 : value / hslScale, field: field, to: &settings)
            return
        }
        let identity: Double = field == .contrast || field == .saturation ? 1 : 0
        if isRecipeScaled(field) {
            guard scale != 0 || value == identity else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }
            assignLogical(scale == 0 ? identity : identity + (value - identity) / scale, field: field, to: &settings)
        } else { assignLogical(value, field: field, to: &settings) }
    }

    static func assignHSL(_ value: Double, field: Field, to settings: inout Adjustments) throws {
        let location = field.hslLocation!
        var hsl = settings.hslSettings
        if hsl.value(HSLAxis(rawValue: location.axis)!, channel: location.channel) == value { return }
        guard hsl.setExact(HSLAxis(rawValue: location.axis)!, channel: location.channel, value: value) else {
            throw AdjustmentTransferError.unrepresentable(field.rawValue)
        }
        settings.hsl = hsl.isIdentity ? nil : hsl
    }

}
