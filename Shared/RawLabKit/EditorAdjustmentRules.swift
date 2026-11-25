import Foundation

public extension Adjustments {
    mutating func clearMasterRecipe(context: EditorAdjustmentContext) -> EditorAdjustmentResetBlock? {
        guard masterRecipeID != nil else { return nil }
        let savedStrength = strength
        switch EditorAdjustmentRules.prepareReset(.tool(.recipe), snapshot: PhotoEditState(settings: self), context: context) {
        case .candidate(let candidate, _):
            self = candidate.settings; strength = savedStrength; return nil
        case .blocked(let reason): return reason
        case .unchanged: return .unrepresentable
        }
    }
}

public enum EditorToolSelection: Hashable, Codable, Sendable {
    case adjustment(AdjustmentKind)
    case film, recipe, lens, geometry
    case hdrPeakLimit, hdrSDRExposure, hdrSDRContrast, hdrSDRSaturation

    public var hdrRenditionKeyPath: WritableKeyPath<HDRRenditionSettings, Double>? {
        switch self {
        case .hdrPeakLimit: return \.peakLimitEV
        case .hdrSDRExposure: return \.sdrExposureEV
        case .hdrSDRContrast: return \.sdrContrast
        case .hdrSDRSaturation: return \.sdrSaturation
        default: return nil
        }
    }

    public var adjustmentTool: EditorAdjustmentTool {
        switch self {
        case .film: return .film; case .recipe: return .recipe; case .lens: return .lens; case .geometry: return .geometry
        case .hdrPeakLimit: return .hdrPeakLimit; case .hdrSDRExposure: return .hdrSDRExposure
        case .hdrSDRContrast: return .hdrSDRContrast; case .hdrSDRSaturation: return .hdrSDRSaturation
        case .adjustment(.temperature), .adjustment(.tint): return .whiteBalance
        case .adjustment(.noiseReduction): return .denoise
        case .adjustment(let kind): return EditorAdjustmentTool(rawValue: kind.rawValue)!
        }
    }
}

public struct EditorToolSourceState: Equatable, Sendable {
    public var collapsedEditorTool: EditorToolSelection?
    public var choosingMasterRecipe: Bool
    public init(collapsedEditorTool: EditorToolSelection? = nil, choosingMasterRecipe: Bool = false) {
        self.collapsedEditorTool = collapsedEditorTool; self.choosingMasterRecipe = choosingMasterRecipe
    }
    public var afterSourceChange: EditorToolSourceState { EditorToolSourceState() }
}

public enum EditorAdjustmentScope: Equatable {
    case tool(EditorToolSelection), group(EditorAdjustmentGroup), hslChannel(Int), allHSL
    case gradingZone(ColorGradingZone), gradingGlobal, allGrading, all

    public var resetScope: EditorResetScope {
        switch self {
        case .tool(let s): return .tool(s.adjustmentTool)
        case .group(let g): return .group(g)
        case .hslChannel(let c): return .hslColor(c)
        case .allHSL: return .hslAll
        case .gradingZone(let z): return .gradingZone(z)
        case .gradingGlobal: return .gradingGlobal
        case .allGrading: return .allGrading
        case .all: return .all
        }
    }
}

public struct EditorAdjustmentContext: Sendable {
    public let isRaw: Bool
    public let defaultExposureMode: ExposureMode
    public var cameraTemperature: Double?
    public var cameraTint: Double?
    public let neutralFilmID: String?
    public let requireCameraWhiteBalanceForColorReset: Bool

    public init(isRaw: Bool, defaultExposureMode: ExposureMode, cameraTemperature: Double? = nil,
                cameraTint: Double? = nil, neutralFilmID: String? = nil, requireCameraWhiteBalanceForColorReset: Bool = true) {
        self.isRaw = isRaw; self.defaultExposureMode = defaultExposureMode
        self.cameraTemperature = cameraTemperature; self.cameraTint = cameraTint
        self.neutralFilmID = neutralFilmID; self.requireCameraWhiteBalanceForColorReset = requireCameraWhiteBalanceForColorReset
    }

    public init(isRaw: Bool, defaultExposureMode: ExposureMode, neutralFilmID: String) {
        self.init(isRaw: isRaw, defaultExposureMode: defaultExposureMode, neutralFilmID: neutralFilmID, requireCameraWhiteBalanceForColorReset: false)
    }
}

public typealias MacEditorAdjustmentContext = EditorAdjustmentContext

public enum EditorAdjustmentResetResult {
    case unchanged, candidate(PhotoEditState, requiresConfirmation: Bool), blocked(EditorAdjustmentResetBlock)
}

public enum EditorAdjustmentResetBlock: Sendable {
    case invalidInput, unknownRecipe, missingCameraWhiteBalance, unrepresentable
}

public enum EditorAdjustmentRules {
    private static let toolGroups: [(group: EditorAdjustmentGroup, tools: [EditorToolSelection])] = [
        (.looks, [.film, .recipe, .adjustment(.strength)]),
        (.light, [.adjustment(.exposure), .adjustment(.highlights), .adjustment(.shadows),
                  .adjustment(.blackPoint), .adjustment(.whitePoint), .adjustment(.contrast), .adjustment(.toneCurve)]),
        (.color, [.adjustment(.temperature), .adjustment(.saturation), .adjustment(.vibrance), .adjustment(.hsl), .adjustment(.colorGrading)]),
        (.effects, [.adjustment(.clarity), .adjustment(.dehaze), .adjustment(.vignette), .adjustment(.grain)]),
        (.detail, [.adjustment(.noiseReduction), .adjustment(.sharpening)]),
        (.geometry, [.geometry, .lens]),
        (.hdrRendition, [.hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation])
    ]

    public static func tools(_ group: EditorAdjustmentGroup) -> [EditorToolSelection] {
        toolGroups.first { $0.group == group }?.tools ?? []
    }
    public static func defaultTool(_ group: EditorAdjustmentGroup) -> EditorToolSelection { tools(group)[0] }
    public static func groupFor(_ tool: EditorToolSelection) -> EditorAdjustmentGroup {
        if tool == .adjustment(.tint) { return .color }
        guard let group = toolGroups.first(where: { $0.tools.contains(tool) })?.group else {
            preconditionFailure("Editor tool is missing its adjustment group")
        }
        return group
    }
    public static func normalizedTool(_ tool: EditorToolSelection, isHDREditing: Bool) -> EditorToolSelection {
        !isHDREditing && groupFor(tool) == .hdrRendition ? .adjustment(.exposure) : tool
    }

    public static func isModified(_ scope: EditorAdjustmentScope, snapshot: PhotoEditState, context: EditorAdjustmentContext) -> Bool {
        if case .tool(.adjustment(.tint)) = scope, context.requireCameraWhiteBalanceForColorReset, !snapshot.settings.isHDREditing {
            return isWhiteBalanceModified(snapshot.settings, context: context, tintOnly: true)
        }
        return isModified(scope: scope.resetScope, snapshot: snapshot, context: context)
    }

    public static func isModified(scope: EditorResetScope, snapshot: PhotoEditState, context: EditorAdjustmentContext) -> Bool {
        let settings = snapshot.settings
        if settings.isHDREditing { return resettingHDR(scope, settings: settings) != settings }
        let hasFilm = context.neutralFilmID.map { snapshot.filmID != $0 } ?? (snapshot.filmID != nil || settings.hasLook)
        switch scope {
        case .tool(let tool):
            switch tool {
            case .film: return hasFilm || snapshot.masterRecipeID != nil || settings.masterRecipeID != nil
            case .recipe: return snapshot.masterRecipeID != nil || settings.masterRecipeID != nil
            case .strength: return settings.strength != 1
            case .exposure: return settings.exposure != 0 || (context.isRaw && settings.exposureMode != context.defaultExposureMode)
            case .whiteBalance: return isWhiteBalanceModified(settings, context: context, tintOnly: false)
            case .toneCurve: return settings.toneCurve != 0 || !settings.curveSettings.isDefault
            case .colorGrading: return !settings.gradingSettings.isDefault
            case .hsl: return !settings.hslSettings.isIdentity
            case .vignette: return PhotoEffectParameter.allCases.filter(\.isVignette).contains { settings.effectSettings[keyPath: $0.keyPath] != $0.defaultValue }
            case .grain: return PhotoEffectParameter.allCases.filter { !$0.isVignette }.contains { settings.effectSettings[keyPath: $0.keyPath] != $0.defaultValue }
            case .denoise:
                return settings.aiDenoiseEnabled || settings.aiDenoiseStrength != 100 || settings.rawNoiseReduction != 0 ||
                    settings.chromaNoiseReduction != 0 || settings.waveletNoiseReduction != WaveletDenoiseSettings()
            case .geometry: return !settings.geometrySettings.isIdentity
            case .lens: return settings.lensSettings != LensCorrectionSettings()
            case .hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation: return false
            default: return settings[keyPath: tool.parameter!.spec.keyPath] != tool.parameter!.spec.defaultValue
            }
        case .all: return EditorAdjustmentGroup.allCases.contains { isModified(scope: .group($0), snapshot: snapshot, context: context) }
        case .allGrading: return !settings.gradingSettings.isDefault
        case .gradingZone(let zone): return !settings.gradingSettings[zone].isDefault
        case .gradingGlobal: return !settings.gradingSettings.global.isDefault
        case .hslAll: return !settings.hslSettings.isIdentity
        case .hslColor(let channel):
            guard (0..<8).contains(channel), settings.hslSettings.isValid else { return true }
            return HSLAxis.allCases.contains { settings.hslSettings.value($0, channel: channel) != 0 }
        case .group(let group):
            if group == .hdrRendition { return false }
            return group.tools.contains { isModified(scope: .tool($0), snapshot: snapshot, context: context) }
        }
    }

    private static func isWhiteBalanceModified(_ settings: Adjustments, context: EditorAdjustmentContext, tintOnly: Bool) -> Bool {
        if context.requireCameraWhiteBalanceForColorReset {
            if context.isRaw { return settings.whiteBalanceMode != .camera || (settings.masterRecipeID != nil && settings.tint != 0) }
            return settings.masterRecipeID == nil && settings.whiteBalanceMode == .camera &&
                ((!tintOnly && settings.temperature != 6500) || settings.tint != 0)
        }
        if context.isRaw {
            return (!settings.isWhiteBalanceDefault || !settings.usesAsShotWhiteBalance) || (settings.masterRecipe != nil && settings.tint != 0)
        }
        return settings.masterRecipe == nil && (!settings.isWhiteBalanceDefault || settings.whiteBalanceMode != .asShot)
    }

    public static func prepareReset(_ scope: EditorAdjustmentScope, snapshot: PhotoEditState, context: EditorAdjustmentContext) -> EditorAdjustmentResetResult {
        if snapshot.settings.isHDREditing {
            guard snapshot.settings.hdr?.isValid == true else { return .blocked(.invalidInput) }
            let candidate = resettingHDR(scope.resetScope, settings: snapshot.settings)
            return candidate == snapshot.settings ? .unchanged :
                .candidate(snapshot.replacing(settings: candidate, preservingFilmID: snapshot.filmID), requiresConfirmation: requiresConfirmation(scope))
        }
        guard valid(snapshot.settings), snapshot.updatedAt.timeIntervalSince1970.isFinite else { return .blocked(.invalidInput) }
        if let id = snapshot.settings.masterRecipeID, MasterRecipe.recipe(for: id) == nil { return .blocked(.unknownRecipe) }
        if case .hslChannel(let channel) = scope, !(0..<8).contains(channel) { return .blocked(.invalidInput) }
        if let temperature = context.cameraTemperature, !temperature.isFinite || !Adjustments.temperatureRange.contains(temperature) { return .blocked(.invalidInput) }
        if let tint = context.cameraTint, !tint.isFinite || !Adjustments.tintRange.contains(tint) { return .blocked(.invalidInput) }
        guard isModified(scope, snapshot: snapshot, context: context) else { return .unchanged }
        let resetsWB: Bool = { switch scope { case .group(.color), .tool(.adjustment(.temperature)), .tool(.adjustment(.tint)): return true; default: return false } }()
        if resetsWB && context.requireCameraWhiteBalanceForColorReset && context.isRaw && (context.cameraTemperature == nil || context.cameraTint == nil) {
            return .blocked(.missingCameraWhiteBalance)
        }
        var settings = snapshot.settings, filmID = snapshot.filmID
        let removesLook: Bool = { switch scope { case .group(.looks): return true; case .tool(.film), .tool(.recipe): return settings.masterRecipeID != nil; default: return false } }()
        if removesLook {
            if settings.masterRecipeID != nil {
                if context.requireCameraWhiteBalanceForColorReset {
                    let needsCamera = settings.whiteBalanceMode == .custom || settings.tint * settings.recipeScale != 0
                    if context.isRaw && needsCamera && (context.cameraTemperature == nil || context.cameraTint == nil) { return .blocked(.missingCameraWhiteBalance) }
                    let cameraTemperature = needsCamera ? context.cameraTemperature ?? settings.temperature : settings.temperature
                    let cameraTint = needsCamera ? context.cameraTint ?? 0 : 0
                    let before = settings.editorEffectiveValues(isRaw: context.isRaw, cameraTemperature: cameraTemperature, cameraTint: cameraTint)
                    let original = settings
                    settings = settings.renderedRecipe(cameraTemperature: cameraTemperature, cameraTint: cameraTint)
                    if !context.isRaw { settings.temperature = original.temperature; settings.tint = original.tint; settings.whiteBalanceMode = original.whiteBalanceMode }
                    guard valid(settings), before == settings.editorEffectiveValues(isRaw: context.isRaw, cameraTemperature: cameraTemperature, cameraTint: cameraTint) else {
                        return .blocked(.unrepresentable)
                    }
                } else {
                    guard let detached = try? settings.detachingRecipeForReset(context: context) else { return .blocked(.unrepresentable) }
                    settings = detached
                }
            }
            settings.lutID = nil; settings.masterRecipeID = nil; settings.strength = 1; filmID = context.neutralFilmID
        } else {
            settings = resetting(scope.resetScope, settings: settings, context: context)
            if case .all = scope { filmID = context.neutralFilmID }
            if case .tool(.film) = scope { settings.lutID = nil; filmID = context.neutralFilmID }
        }
        guard valid(settings) else { return .blocked(.unrepresentable) }
        let candidate = snapshot.replacing(settings: settings, preservingFilmID: filmID)
        guard candidate != snapshot else { return .unchanged }
        return .candidate(candidate, requiresConfirmation: requiresConfirmation(
            scope, hasMaterializedFields: removesLook && !materializedFields(before: snapshot.settings, after: settings).isEmpty))
    }

    public static func prepareReset(scope: EditorResetScope, snapshot: PhotoEditState, context: EditorAdjustmentContext) -> EditorResetResult {
        var result = snapshot
        do {
            try snapshot.settings.validateResetValues()
            if snapshot.settings.isHDREditing {
                result.settings = resettingHDR(scope, settings: snapshot.settings)
                return result == snapshot ? .unchanged : .candidate(result)
            }
            if case .hslColor(let channel) = scope, !(0..<8).contains(channel) { throw EditorResetBlockedReason.invalidHSLChannel }
            guard isModified(scope: scope, snapshot: snapshot, context: context) else { return .unchanged }
            let neutralFilm = context.neutralFilmID ?? ""
            switch scope {
            case .tool(.film), .tool(.recipe):
                if snapshot.masterRecipeID != nil || snapshot.settings.masterRecipeID != nil {
                    guard snapshot.masterRecipeID == snapshot.settings.masterRecipeID else { throw EditorResetBlockedReason.invalidSnapshot("masterRecipeID") }
                    result.settings = try result.settings.detachingRecipeForReset(context: context)
                    result.masterRecipeID = nil
                }
                result.settings.lutID = nil; result.filmID = neutralFilm
            case .group(.looks):
                guard snapshot.masterRecipeID == snapshot.settings.masterRecipeID else { throw EditorResetBlockedReason.invalidSnapshot("masterRecipeID") }
                result.settings = try result.settings.detachingRecipeForReset(context: context)
                result.settings.lutID = nil; result.filmID = neutralFilm; result.masterRecipeID = nil
            case .all:
                result.settings = resetting(.all, settings: result.settings, context: context)
                result.filmID = neutralFilm; result.masterRecipeID = nil
            default:
                result.settings = resetting(scope, settings: result.settings, context: context)
            }
            try result.settings.validateResetValues()
            return result == snapshot ? .unchanged : .candidate(result)
        } catch let reason as EditorResetBlockedReason {
            return .blocked(reason)
        } catch {
            return .blocked(.invalidSnapshot(String(describing: error)))
        }
    }

    private static func requiresConfirmation(_ scope: EditorAdjustmentScope, hasMaterializedFields: Bool = false) -> Bool {
        switch scope {
        case .group, .allHSL, .allGrading, .all, .tool(.adjustment(.hsl)), .tool(.adjustment(.colorGrading)): return true
        case .hslChannel, .gradingZone, .gradingGlobal: return false
        case .tool: return hasMaterializedFields
        }
    }

    public static func materializedFields(before: Adjustments, after: Adjustments) -> [String] {
        var fields = [String]()
        let scalars: [(KeyPath<Adjustments, Double>, String)] = [
            (\.exposure, "曝光"), (\.highlights, "高光"), (\.shadows, "阴影"), (\.contrast, "对比度"),
            (\.saturation, "饱和度"), (\.toneCurve, "S 曲线")
        ]
        for (kp, name) in scalars where before[keyPath: kp] != after[keyPath: kp] { fields.append(name) }
        if before.whiteBalanceMode != after.whiteBalanceMode || before.temperature != after.temperature || before.tint != after.tint { fields.append("白平衡") }
        if before.hslSettings != after.hslSettings { fields.append("HSL") }
        let extras: [(KeyPath<Adjustments, Double>, String)] = [(\.blackPoint, "黑场"), (\.whitePoint, "白场"), (\.vibrance, "鲜艳度"), (\.clarity, "清晰度"), (\.dehaze, "去朦胧")]
        for (kp, name) in extras where before[keyPath: kp] != after[keyPath: kp] { fields.append(name) }
        if before.curveSettings != after.curveSettings { fields.append("曲线") }
        if before.gradingSettings != after.gradingSettings { fields.append("颜色分级") }
        return fields
    }

    private static func defaults(_ context: EditorAdjustmentContext, recipe: Bool = false) -> Adjustments {
        var result = Adjustments.default
        result.exposureMode = context.isRaw ? context.defaultExposureMode : .sensor
        if context.isRaw {
            result.temperature = context.cameraTemperature ?? result.temperature
            result.tint = recipe ? 0 : (context.cameraTint ?? result.tint)
        }
        return result
    }

    private static func resetting(_ scope: EditorResetScope, settings: Adjustments, context: EditorAdjustmentContext) -> Adjustments {
        var result = settings
        let defaults = defaults(context, recipe: settings.masterRecipeID != nil)
        switch scope {
        case .all:
            if context.requireCameraWhiteBalanceForColorReset {
                var neutral = self.defaults(context)
                neutral.processing = settings.processing; neutral.x3fMode = settings.x3fMode
                neutral.hdr = settings.hdr; neutral.proRAWDecodeVersion = settings.proRAWDecodeVersion
                return neutral
            }
            result.resetAll(); result.exposureMode = context.defaultExposureMode
            return context.isRaw ? result : result.resolvedForRaster
        case .tool(let tool):
            switch tool {
            case .film: result.lutID = nil
            case .recipe, .hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation: break
            case .geometry: result.geometry = nil
            case .lens: result.lensCorrection = nil
            case .exposure: result.exposure = defaults.exposure; result.exposureMode = context.isRaw ? context.defaultExposureMode : defaults.exposureMode
            case .whiteBalance:
                if context.requireCameraWhiteBalanceForColorReset {
                    result.whiteBalanceMode = defaults.whiteBalanceMode; result.temperature = defaults.temperature; result.tint = defaults.tint
                } else { result.resetWhiteBalance() }
            case .toneCurve: result.toneCurve = defaults.toneCurve; result.toneCurveConfig = nil
            case .colorGrading: result.colorGrading = nil
            case .hsl: result.hsl = nil
            case .vignette: result.resetEffect(.vignetteAmount)
            case .grain: result.resetEffect(.grainAmount)
            case .denoise:
                result.aiDenoiseEnabled = false; result.aiDenoiseStrength = 100
                result.rawNoiseReduction = 0; result.chromaNoiseReduction = 0; result.waveletNoiseReduction = WaveletDenoiseSettings()
            default:
                if let parameter = tool.parameter { result[keyPath: parameter.spec.keyPath] = parameter.spec.defaultValue }
            }
        case .allGrading: result.colorGrading = nil
        case .gradingZone(let zone): result.gradingSettings[zone] = ColorGradingWheel()
        case .gradingGlobal: result.gradingSettings.global = ColorGradingWheel()
        case .hslAll: result.hsl = nil
        case .hslColor(let channel):
            if (0..<8).contains(channel) {
                var hsl = result.hslSettings; hsl.reset(channel: channel); result.hsl = hsl.isIdentity ? nil : hsl
            }
        case .group(.looks):
            result.lutID = nil; result.masterRecipeID = nil; result.strength = 1
        case .group(let group):
            for tool in group.tools { result = resetting(.tool(tool), settings: result, context: context) }
        }
        return result
    }

    private static func resettingHDR(_ scope: EditorResetScope, settings: Adjustments) -> Adjustments {
        var result = settings
        guard result.isHDREditing else { return result }
        switch scope {
        case .all: result.hdr?.reset(); result.hdrCameraAIEnabled = false
        case .group(.looks), .tool(.film): result.hdr?.lookSettings = HDRLookSettings()
        case .group(.hdrRendition): result.hdr?.renditionSettings = HDRRenditionSettings()
        case .group(let group): for tool in group.tools { result = resettingHDR(.tool(tool), settings: result) }
        case .tool(.geometry): result.setGeometrySettings(GeometrySettings())
        case .tool(.whiteBalance): result.hdr?.temperature = 6500; result.hdr?.tint = 0
        case .tool(.toneCurve): result.set(.toneCurve, to: 0); result.editingCurveSettings = ToneCurveSettings()
        case .tool(.colorGrading), .allGrading: result.editingGradingSettings = ColorGradingSettings()
        case .gradingZone(let zone): result.editingGradingSettings[zone] = ColorGradingWheel()
        case .gradingGlobal: result.editingGradingSettings.global = ColorGradingWheel()
        case .tool(.hsl), .hslAll: result.editingHSLSettings = HSLSettings()
        case .hslColor(let channel): result.editingHSLSettings.reset(channel: channel)
        case .tool(.vignette): result.hdr?.effectsSettings.reset(vignette: true)
        case .tool(.grain): result.hdr?.effectsSettings.reset(vignette: false)
        case .tool(.denoise): result.hdr?.detailSettings.denoise = 0; result.hdrCameraAIEnabled = false
        case .tool(let tool):
            if let key = tool.hdrRenditionKeyPath { result.hdr?.renditionSettings[keyPath: key] = HDRRenditionSettings()[keyPath: key] }
            else if let parameter = tool.parameter, let key = parameter.hdrKeyPath { result.hdr?[keyPath: key] = HDRSettings()[keyPath: key] }
        }
        return result
    }

    public static func valid(_ settings: Adjustments) -> Bool {
        (try? settings.validateResetValues()) != nil
    }
}

public typealias MacEditorAdjustmentRules = EditorAdjustmentRules
