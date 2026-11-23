import Foundation

public enum MacEditorAdjustmentRules {
    public static func isModified(scope: EditorResetScope, snapshot: MacPhotoEditState, context: MacEditorAdjustmentContext) -> Bool {
        let settings = snapshot.settings
        if settings.isHDREditing { return resettingHDR(scope, settings: settings) != settings }
        switch scope {
        case .tool(let tool):
            switch tool {
            case .film: return snapshot.filmID != context.neutralFilmID || snapshot.masterRecipeID != nil || settings.masterRecipeID != nil
            case .recipe: return snapshot.masterRecipeID != nil || settings.masterRecipeID != nil
            case .strength: return settings.strength != 1
            case .exposure: return settings.exposure != 0 || (context.isRaw && settings.exposureMode != context.defaultExposureMode)
            case .whiteBalance:
                if context.isRaw {
                    return (!settings.isWhiteBalanceDefault || !settings.usesAsShotWhiteBalance) || (settings.masterRecipe != nil && settings.tint != 0)
                }
                return settings.masterRecipe == nil && (!settings.isWhiteBalanceDefault || settings.whiteBalanceMode != .asShot)
            case .toneCurve: return settings.toneCurve != 0 || !settings.curveSettings.isDefault
            case .colorGrading: return !settings.gradingSettings.isDefault
            case .hsl: return !settings.hslSettings.isIdentity
            case .vignette: return PhotoEffectParameter.allCases.filter(\.isVignette).contains { settings.effectSettings[keyPath: $0.keyPath] != $0.defaultValue }
            case .grain: return PhotoEffectParameter.allCases.filter { !$0.isVignette }.contains { settings.effectSettings[keyPath: $0.keyPath] != $0.defaultValue }
            case .denoise: return settings.aiDenoiseEnabled || settings.aiDenoiseStrength != 100 || settings.rawNoiseReduction != 0 || settings.chromaNoiseReduction != 0 || settings.waveletNoiseReduction != WaveletDenoiseSettings()
            case .geometry: return !settings.geometrySettings.isIdentity
            case .lens: return settings.lensSettings != LensCorrectionSettings()
            case .hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation: return false
            default: return settings[keyPath: tool.parameter!.spec.keyPath] != tool.parameter!.spec.defaultValue
            }
        case .all:
            return EditorAdjustmentGroup.allCases.contains { isModified(scope: .group($0), snapshot: snapshot, context: context) }
        case .allGrading: return !settings.gradingSettings.isDefault
        case .gradingZone(let zone): return !settings.gradingSettings[zone].isDefault
        case .gradingGlobal: return !settings.gradingSettings.global.isDefault
        case .hslAll: return !settings.hslSettings.isIdentity
        case .hslColor(let channel):
            guard (0..<8).contains(channel), settings.hslSettings.isValid else { return true }
            return HSLAxis.allCases.contains { settings.hslSettings.value($0, channel: channel) != 0 }
        case .group(.looks):
            return snapshot.filmID != context.neutralFilmID || snapshot.masterRecipeID != nil ||
                settings.masterRecipeID != nil || settings.strength != 1
        case .group(.light):
            return (context.isRaw && settings.exposureMode != context.defaultExposureMode) || settings.exposure != 0 ||
                settings.contrast != 1 || settings.highlights != 0 || settings.shadows != 0 || settings.toneCurve != 0 || !settings.curveSettings.isDefault ||
                settings.blackPoint != 0 || settings.whitePoint != 0
        case .group(.color):
            let wbModified = context.isRaw
                ? ((!settings.isWhiteBalanceDefault || !settings.usesAsShotWhiteBalance) || (settings.masterRecipe != nil && settings.tint != 0))
                : (settings.masterRecipe == nil && (!settings.isWhiteBalanceDefault || settings.whiteBalanceMode != .asShot))
            return settings.saturation != 1 || settings.vibrance != 0 || !settings.hslSettings.isIdentity || !settings.gradingSettings.isDefault || wbModified
        case .group(.effects): return settings.effectSettings != PhotoEffectsSettings() || !settings.atmosphereSettings.isIdentity
        case .group(.detail):
            return settings.aiDenoiseEnabled || settings.aiDenoiseStrength != 100 || settings.sharpening != 0 || settings.rawNoiseReduction != 0 ||
                settings.chromaNoiseReduction != 0 || settings.waveletNoiseReduction != WaveletDenoiseSettings()
        case .group(.geometry):
            return !settings.geometrySettings.isIdentity || settings.lensSettings != LensCorrectionSettings()
        case .group(.hdrRendition):
            return false
        }
    }

    public static func prepareReset(scope: EditorResetScope, snapshot: MacPhotoEditState, context: MacEditorAdjustmentContext) -> EditorResetResult {
        var result = snapshot
        do {
            try snapshot.settings.validateResetValues()
            if snapshot.settings.isHDREditing {
                result.settings = resettingHDR(scope, settings: snapshot.settings)
                return result == snapshot ? .unchanged : .candidate(result)
            }
            if case .hslColor(let channel) = scope, !(0..<8).contains(channel) {
                throw EditorResetBlockedReason.invalidHSLChannel
            }
            guard isModified(scope: scope, snapshot: snapshot, context: context) else { return .unchanged }
            switch scope {
            case .tool(let tool):
                switch tool {
                case .film, .recipe:
                    if snapshot.masterRecipeID != nil || snapshot.settings.masterRecipeID != nil {
                        guard snapshot.masterRecipeID == snapshot.settings.masterRecipeID else { throw EditorResetBlockedReason.invalidSnapshot("masterRecipeID") }
                        result.settings = try result.settings.detachingRecipeForReset(context: context)
                        result.masterRecipeID = nil
                    }
                    result.filmID = context.neutralFilmID
                case .exposure: result.settings.exposure = 0; result.settings.exposureMode = context.defaultExposureMode
                case .whiteBalance: result.settings.resetWhiteBalance()
                case .toneCurve: result.settings.toneCurve = 0; result.settings.toneCurveConfig = nil
                case .colorGrading: result.settings.colorGrading = nil
                case .hsl: result.settings.hsl = nil
                case .vignette: result.settings.resetEffect(.vignetteAmount)
                case .grain: result.settings.resetEffect(.grainAmount)
                case .denoise:
                    result.settings.aiDenoiseEnabled = false
                    result.settings.aiDenoiseStrength = 100
                    result.settings.rawNoiseReduction = 0; result.settings.chromaNoiseReduction = 0; result.settings.waveletNoiseReduction = WaveletDenoiseSettings()
                case .geometry: result.settings.geometry = nil
                case .lens: result.settings.lensCorrection = nil
                case .hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation: break
                default: result.settings[keyPath: tool.parameter!.spec.keyPath] = tool.parameter!.spec.defaultValue
                }
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
                result.settings.exposure = 0; result.settings.contrast = 1
                result.settings.highlights = 0; result.settings.shadows = 0; result.settings.toneCurve = 0; result.settings.toneCurveConfig = nil
                result.settings.blackPoint = 0; result.settings.whitePoint = 0
            case .group(.color):
                result.settings.saturation = 1; result.settings.vibrance = 0; result.settings.colorGrading = nil
                result.settings.resetWhiteBalance()
                result.settings.hsl = nil
            case .group(.effects): result.settings.photoEffects = nil; result.settings.atmosphere = nil
            case .group(.detail):
                result.settings.aiDenoiseEnabled = false
                result.settings.aiDenoiseStrength = 100
                result.settings.sharpening = 0; result.settings.rawNoiseReduction = 0
                result.settings.chromaNoiseReduction = 0; result.settings.waveletNoiseReduction = WaveletDenoiseSettings()
            case .group(.geometry): result.settings.geometry = nil; result.settings.lensCorrection = nil
            case .group(.hdrRendition): break
            case .allGrading: result.settings.colorGrading = nil
            case .gradingZone(let zone): result.settings.gradingSettings[zone] = ColorGradingWheel()
            case .gradingGlobal: result.settings.gradingSettings.global = ColorGradingWheel()
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

    private static func resettingHDR(_ scope: EditorResetScope, settings: Adjustments) -> Adjustments {
        var result = settings
        switch scope {
        case .all:
            result.hdr?.reset()
            result.hdrCameraAIEnabled = false
        case .group(.looks), .tool(.film): result.hdr?.lookSettings = HDRLookSettings()
        case .group(.hdrRendition): result.hdr?.renditionSettings = HDRRenditionSettings()
        case .group(let group):
            for tool in group.tools { result = resettingHDR(.tool(tool), settings: result) }
        case .tool(.geometry): result.setGeometrySettings(GeometrySettings())
        case .tool(.whiteBalance): result.hdr?.temperature = 6500; result.hdr?.tint = 0
        case .tool(.toneCurve):
            result.set(.toneCurve, to: 0)
            result.editingCurveSettings = ToneCurveSettings()
        case .tool(.colorGrading), .allGrading:
            result.editingGradingSettings = ColorGradingSettings()
        case .gradingZone(let zone):
            result.editingGradingSettings[zone] = ColorGradingWheel()
        case .gradingGlobal:
            result.editingGradingSettings.global = ColorGradingWheel()
        case .tool(.hsl), .hslAll:
            result.editingHSLSettings = HSLSettings()
        case .hslColor(let channel):
            result.editingHSLSettings.reset(channel: channel)
        case .tool(.vignette): result.hdr?.effectsSettings.reset(vignette: true)
        case .tool(.grain): result.hdr?.effectsSettings.reset(vignette: false)
        case .tool(.denoise):
            result.hdr?.detailSettings.denoise = 0
            result.hdrCameraAIEnabled = false
        case .tool(let tool):
            if let key = tool.hdrRenditionKeyPath { result.hdr?.renditionSettings[keyPath: key] = HDRRenditionSettings()[keyPath: key] }
            else if let parameter = tool.parameter, let key = parameter.hdrKeyPath { result.hdr?[keyPath: key] = HDRSettings()[keyPath: key] }
        }
        return result
    }
}
