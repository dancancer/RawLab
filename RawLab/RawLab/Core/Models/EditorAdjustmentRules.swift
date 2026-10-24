import Foundation

enum EditorToolSelection: Hashable {
    case adjustment(AdjustmentKind)
    case film, recipe, lens, geometry
}

enum EditorAdjustmentGroup: String, CaseIterable {
    case looks, light, color, effects, detail, geometry
}

enum EditorAdjustmentScope: Equatable {
    case tool(EditorToolSelection)
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
                  .adjustment(.blackPoint), .adjustment(.whitePoint), .adjustment(.contrast), .adjustment(.toneCurve)]),
        (.color, [.adjustment(.temperature), .adjustment(.saturation), .adjustment(.vibrance), .adjustment(.hsl)]),
        (.effects, [.adjustment(.vignette), .adjustment(.grain)]),
        (.detail, [.adjustment(.noiseReduction), .adjustment(.sharpening)]),
        (.geometry, [.geometry, .lens])
    ]

    static func tools(_ group: EditorAdjustmentGroup) -> [EditorToolSelection] {
        toolGroups.first { $0.group == group }?.tools ?? []
    }

    static func defaultTool(_ group: EditorAdjustmentGroup) -> EditorToolSelection {
        tools(group)[0]
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
        if case .tool(let tool) = scope {
            switch tool {
            case .film: return snapshot.filmID != nil || snapshot.settings.hasLook
            case .recipe: return snapshot.settings.masterRecipeID != nil
            case .adjustment(.exposure):
                return snapshot.settings.exposure != 0 ||
                    (context.isRaw && snapshot.settings.exposureMode != context.defaultExposureMode)
            case .adjustment(.temperature), .adjustment(.tint):
                return context.isRaw && (snapshot.settings.whiteBalanceMode != .camera ||
                    (snapshot.settings.masterRecipeID != nil && snapshot.settings.tint != 0))
            default: return resetting(scope, settings: snapshot.settings, context: context) != snapshot.settings
            }
        }
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
                settings.contrast != 1 || settings.toneCurve != 0 || settings.blackPoint != 0 || settings.whitePoint != 0
        }
        if case .group(.color) = scope {
            let settings = snapshot.settings
            let whiteBalance = (context.isRaw && settings.whiteBalanceMode != .camera) ||
                (settings.masterRecipeID != nil && settings.tint != 0)
            return whiteBalance || settings.saturation != 1 || settings.vibrance != 0 || !settings.hsl.isIdentity
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
        let resetsWhiteBalance: Bool
        switch scope {
        case .group(.color), .tool(.adjustment(.temperature)), .tool(.adjustment(.tint)): resetsWhiteBalance = true
        default: resetsWhiteBalance = false
        }
        if resetsWhiteBalance && context.isRaw &&
            (context.cameraTemperature == nil || context.cameraTint == nil) {
            return .blocked(.missingCameraWhiteBalance)
        }
        var settings = snapshot.settings
        var filmID = snapshot.filmID
        let removesLook: Bool
        switch scope {
        case .group(.looks): removesLook = true
        case .tool(.film), .tool(.recipe): removesLook = settings.masterRecipeID != nil
        default: removesLook = false
        }
        if removesLook {
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
            if case .tool(.film) = scope { settings.lutID = nil; filmID = nil }
        }
        guard valid(settings) else { return .blocked(.unrepresentable) }
        let candidate = snapshot.replacing(settings: settings, preservingFilmID: filmID)
        guard candidate != snapshot else { return .unchanged }
        let confirmation: Bool
        switch scope {
        case .group, .allHSL, .all: confirmation = true
        case .hslChannel: confirmation = false
        case .tool(.adjustment(.hsl)): confirmation = true
        case .tool:
            confirmation = removesLook && !materializedFields(before: snapshot.settings, after: settings).isEmpty
        }
        return .candidate(candidate, requiresConfirmation: confirmation)
    }

    static func materializedFields(before: RawSettings, after: RawSettings) -> [String] {
        var fields = [String]()
        if before.exposure != after.exposure { fields.append("曝光") }
        if before.highlights != after.highlights { fields.append("高光") }
        if before.shadows != after.shadows { fields.append("阴影") }
        if before.contrast != after.contrast { fields.append("对比度") }
        if before.saturation != after.saturation { fields.append("饱和度") }
        if before.toneCurve != after.toneCurve { fields.append("S 曲线") }
        if before.whiteBalanceMode != after.whiteBalanceMode || before.temperature != after.temperature || before.tint != after.tint {
            fields.append("白平衡")
        }
        if before.hsl != after.hsl { fields.append("HSL") }
        return fields
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
            var neutral = self.defaults(context)
            neutral.processing = settings.processing
            return neutral
        case .tool(let tool):
            switch tool {
            case .film: result.lutID = nil
            case .recipe: break // 无配方时为 NoChange；有配方时走同一无损独立化。
            case .geometry: result.geometry = defaults.geometry
            case .lens: result.lensCorrection = defaults.lensCorrection
            case .adjustment(let kind):
                switch kind {
                case .exposure: result.exposure = defaults.exposure; result.exposureMode = defaults.exposureMode
                case .temperature, .tint:
                    result.whiteBalanceMode = defaults.whiteBalanceMode
                    result.temperature = defaults.temperature; result.tint = defaults.tint
                case .noiseReduction:
                    result.noiseReduction = defaults.noiseReduction; result.denoise = defaults.denoise
                    result.displayChromaDenoise = defaults.displayChromaDenoise
                default: kind.reset(in: &result)
                }
            }
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
                result.blackPoint = 0; result.whitePoint = 0
            case .color:
                result.whiteBalanceMode = defaults.whiteBalanceMode
                result.temperature = defaults.temperature; result.tint = defaults.tint
                result.saturation = defaults.saturation; result.hsl = defaults.hsl; result.vibrance = 0
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

    static func valid(_ settings: RawSettings) -> Bool {
        let fields: [(Double, ClosedRange<Double>)] = [
            (settings.exposure, -4...4), (settings.contrast, 0...2), (settings.saturation, 0...2),
            (settings.temperature, RawSettings.temperatureRange), (settings.tint, RawSettings.tintRange),
            (settings.highlights, -1...1), (settings.shadows, -1...1), (settings.toneCurve, -1...1),
            (settings.noiseReduction, 0...1), (settings.sharpening, 0...2),
            (settings.lutStrength, RawSettings.lutStrengthRange)
        ]
        return fields.allSatisfy { $0.0.isFinite && $0.1.contains($0.0) } &&
            settings.geometry.isValid && settings.denoise.isValid && settings.hsl.isValid && settings.toneSettings.isValid &&
            settings.photoEffects.isValid && PhotoEffectParameter.allCases.allSatisfy {
                $0.range.contains(settings.photoEffects[keyPath: $0.keyPath])
            } && (0...2).contains(settings.displayChromaDenoise)
    }
}
