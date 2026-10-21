import Foundation

enum EditorToolSelection: Hashable {
    case adjustment(AdjustmentKind)
    case film, recipe, lens, geometry
}

enum EditorAdjustmentGroup: String, CaseIterable {
    case looks, light, color, effects, detail, geometry
}

enum EditorAdjustmentScope {
    case group(EditorAdjustmentGroup)
    case hslChannel(Int)
    case allHSL
    case all
}

struct EditorAdjustmentContext {
    let isRaw: Bool
    let defaultExposureMode: RawExposureMode
    var cameraTemperature: Double? = nil
    var cameraTint: Double? = nil
}

enum EditorAdjustmentResetResult {
    case unchanged
    case candidate(PhotoEditState, requiresConfirmation: Bool)
    case blocked(EditorAdjustmentResetBlock)
}

enum EditorAdjustmentResetBlock {
    case invalidInput, unknownRecipe, missingCameraWhiteBalance, unrepresentable
}

enum EditorAdjustmentRules {
    private static let toolGroups: [(group: EditorAdjustmentGroup, tools: [EditorToolSelection])] = [
        (.looks, [.film, .recipe, .adjustment(.strength)]),
        (.light, [.adjustment(.exposure), .adjustment(.highlights), .adjustment(.shadows),
                  .adjustment(.contrast), .adjustment(.toneCurve)]),
        (.color, [.adjustment(.temperature), .adjustment(.saturation), .adjustment(.hsl)]),
        (.effects, [.adjustment(.vignette), .adjustment(.grain)]),
        (.detail, [.adjustment(.noiseReduction), .adjustment(.sharpening)]),
        (.geometry, [.geometry, .lens])
    ]

    static func tools(_ group: EditorAdjustmentGroup) -> [EditorToolSelection] {
        toolGroups.first { $0.group == group }?.tools ?? []
    }

    static func groupFor(_ tool: EditorToolSelection) -> EditorAdjustmentGroup {
        if tool == .adjustment(.tint) { return .color }
        guard let group = toolGroups.first(where: { $0.tools.contains(tool) })?.group else {
            preconditionFailure("Editor tool is missing its adjustment group")
        }
        return group
    }

    static func isModified(_ scope: EditorAdjustmentScope, snapshot: PhotoEditState,
                           context: EditorAdjustmentContext) -> Bool {
        if case .group(.looks) = scope {
            return snapshot.filmID != nil || snapshot.settings.hasLook || snapshot.settings.lutStrength != 1
        }
        if case .all = scope {
            return EditorAdjustmentGroup.allCases.contains {
                isModified(.group($0), snapshot: snapshot, context: context)
            }
        }
        if case .group(.light) = scope {
            let settings = snapshot.settings
            return (context.isRaw && settings.exposureMode != context.defaultExposureMode) ||
                settings.exposure != 0 || settings.highlights != 0 || settings.shadows != 0 ||
                settings.contrast != 1 || settings.toneCurve != 0
        }
        if case .group(.color) = scope {
            let settings = snapshot.settings
            let whiteBalance = (context.isRaw && settings.whiteBalanceMode != .camera) ||
                (settings.masterRecipeID != nil && settings.tint != 0)
            return whiteBalance || settings.saturation != 1 || !settings.hsl.isIdentity
        }
        let reset = resetting(scope, settings: snapshot.settings, context: context)
        return reset != snapshot.settings
    }

    static func prepareReset(_ scope: EditorAdjustmentScope, snapshot: PhotoEditState,
                             context: EditorAdjustmentContext) -> EditorAdjustmentResetResult {
        guard valid(snapshot.settings), snapshot.updatedAt.timeIntervalSince1970.isFinite else {
            return .blocked(.invalidInput)
        }
        if let id = snapshot.settings.masterRecipeID, MasterRecipe.recipe(for: id) == nil {
            return .blocked(.unknownRecipe)
        }
        if case .hslChannel(let channel) = scope, !(0..<8).contains(channel) {
            return .blocked(.invalidInput)
        }
        if let temperature = context.cameraTemperature,
           !temperature.isFinite || !RawSettings.temperatureRange.contains(temperature) { return .blocked(.invalidInput) }
        if let tint = context.cameraTint,
           !tint.isFinite || !RawSettings.tintRange.contains(tint) { return .blocked(.invalidInput) }

        guard isModified(scope, snapshot: snapshot, context: context) else { return .unchanged }
        var settings = snapshot.settings
        var filmID = snapshot.filmID
        if case .group(.looks) = scope {
            if settings.masterRecipeID != nil {
                let needsCamera = settings.whiteBalanceMode == .custom || settings.tint * settings.recipeScale != 0
                if context.isRaw && needsCamera && (context.cameraTemperature == nil || context.cameraTint == nil) {
                    return .blocked(.missingCameraWhiteBalance)
                }
                let cameraTemperature = needsCamera ? context.cameraTemperature ?? settings.temperature : settings.temperature
                let cameraTint = needsCamera ? context.cameraTint ?? 0 : 0
                let before = settings.editorEffectiveValues(isRaw: context.isRaw,
                                                            cameraTemperature: cameraTemperature, cameraTint: cameraTint)
                let original = settings
                settings = settings.renderedRecipe(cameraTemperature: cameraTemperature, cameraTint: cameraTint)
                if !context.isRaw {
                    // 普通图片的 RAW 专属存储值仍保留；processor 最终会禁用这些字段。
                    settings.temperature = original.temperature
                    settings.tint = original.tint
                    settings.whiteBalanceMode = original.whiteBalanceMode
                }
                guard valid(settings), before == settings.editorEffectiveValues(isRaw: context.isRaw,
                    cameraTemperature: cameraTemperature, cameraTint: cameraTint) else {
                    return .blocked(.unrepresentable)
                }
            }
            settings.lutID = nil; settings.masterRecipeID = nil; settings.lutStrength = 1
            filmID = nil
        } else {
            settings = resetting(scope, settings: settings, context: context)
            if isAll(scope) { filmID = nil }
        }
        guard valid(settings) else { return .blocked(.unrepresentable) }
        let candidate = snapshot.replacing(settings: settings, preservingFilmID: filmID)
        guard candidate != snapshot else { return .unchanged }
        let confirmation: Bool
        switch scope {
        case .group, .allHSL, .all: confirmation = true
        case .hslChannel: confirmation = false
        }
        return .candidate(candidate, requiresConfirmation: confirmation)
    }

    private static func isAll(_ scope: EditorAdjustmentScope) -> Bool {
        if case .all = scope { return true }
        return false
    }

    private static func defaults(_ context: EditorAdjustmentContext, recipe: Bool = false) -> RawSettings {
        var result = RawSettings.default
        result.exposureMode = context.isRaw ? context.defaultExposureMode : .sensor
        if context.isRaw {
            result.temperature = context.cameraTemperature ?? result.temperature
            result.tint = recipe ? 0 : context.cameraTint ?? result.tint
        }
        return result
    }

    private static func resetting(_ scope: EditorAdjustmentScope, settings: RawSettings,
                                  context: EditorAdjustmentContext) -> RawSettings {
        var result = settings
        let defaults = defaults(context, recipe: settings.masterRecipeID != nil)
        switch scope {
        case .all:
            return self.defaults(context)
        case .allHSL: result.hsl = HSLSettings()
        case .hslChannel(let channel):
            if (0..<8).contains(channel) { result.hsl.reset(channel: channel) }
        case .group(let group):
            switch group {
            case .looks:
                result.lutID = nil; result.masterRecipeID = nil; result.lutStrength = 1
            case .light:
                result.exposure = defaults.exposure; result.exposureMode = defaults.exposureMode
                result.highlights = defaults.highlights; result.shadows = defaults.shadows
                result.contrast = defaults.contrast; result.toneCurve = defaults.toneCurve
            case .color:
                result.whiteBalanceMode = defaults.whiteBalanceMode
                result.temperature = defaults.temperature; result.tint = defaults.tint
                result.saturation = defaults.saturation; result.hsl = defaults.hsl
            case .effects: result.photoEffects = defaults.photoEffects
            case .detail:
                result.sharpening = defaults.sharpening; result.denoise = defaults.denoise
                result.noiseReduction = defaults.noiseReduction
                result.displayChromaDenoise = defaults.displayChromaDenoise
            case .geometry:
                result.geometry = defaults.geometry; result.lensCorrection = defaults.lensCorrection
            }
        }
        return result
    }

    private static func valid(_ settings: RawSettings) -> Bool {
        let fields: [(Double, ClosedRange<Double>)] = [
            (settings.exposure, -4...4), (settings.contrast, 0...2), (settings.saturation, 0...2),
            (settings.temperature, RawSettings.temperatureRange), (settings.tint, RawSettings.tintRange),
            (settings.highlights, -1...1), (settings.shadows, -1...1), (settings.toneCurve, -1...1),
            (settings.noiseReduction, 0...1), (settings.sharpening, 0...2),
            (settings.lutStrength, RawSettings.lutStrengthRange)
        ]
        return fields.allSatisfy { $0.0.isFinite && $0.1.contains($0.0) } &&
            settings.geometry.isValid && settings.denoise.isValid && settings.hsl.isValid &&
            settings.photoEffects.isValid && PhotoEffectParameter.allCases.allSatisfy {
                $0.range.contains(settings.photoEffects[keyPath: $0.keyPath])
            } && (0...2).contains(settings.displayChromaDenoise)
    }
}
