@_exported import CSony2Fuji
import RawLabKit
import Foundation

public extension X3fMode {
    var core: sony2fuji_x3f_mode { self == .normal ? SONY2FUJI_X3F_NORMAL : SONY2FUJI_X3F_LEGACY }
}

public extension ProcessingIdentity {
    var core: sony2fuji_processing_version {
        switch version {
        case 1: return SONY2FUJI_PROCESSING_LEGACY
        case 2: return SONY2FUJI_PROCESSING_C5_V2
        default: return SONY2FUJI_PROCESSING_BASIC_V3
        }
    }
}

public extension ExposureMode {
    var core: sony2fuji_raw_exposure_mode {
        switch self {
        case .scene: return SONY2FUJI_EXPOSURE_SCENE
        case .preview: return SONY2FUJI_EXPOSURE_PREVIEW
        case .sensor: return SONY2FUJI_EXPOSURE_SENSOR
        }
    }
}

public extension LensMatchState {
    init(native state: sony2fuji_lens_state) {
        switch state {
        case SONY2FUJI_LENS_OFF: self = .off
        case SONY2FUJI_LENS_MATCHED: self = .matched
        case SONY2FUJI_LENS_NO_DATABASE: self = .noDatabase
        case SONY2FUJI_LENS_NO_CAMERA: self = .noCamera
        case SONY2FUJI_LENS_AMBIGUOUS: self = .ambiguous
        case SONY2FUJI_LENS_NO_CALIBRATION: self = .noCalibration
        case SONY2FUJI_LENS_MISSING_FOCAL_LENGTH: self = .missingFocalLength
        case SONY2FUJI_LENS_EMBEDDED_GEOMETRY: self = .embeddedGeometry
        case SONY2FUJI_LENS_UNSUPPORTED_INPUT: self = .unsupportedInput
        default: self = .unmatched
        }
    }
}

public extension LensInfo {
    init(state: sony2fuji_lens_state, detectedLens: String, selectedLens: String, focalLength: Float = 0,
         appliedDistortion: Bool, appliedTCA: Bool, cropScale: Float,
         candidates: [LensCandidate], appliedVignetting: Bool = false, sourceMetadata: DisplayLensMetadata? = nil) {
        self.init(
            state: LensMatchState(native: state),
            detectedLens: detectedLens,
            selectedLens: selectedLens,
            focalLength: focalLength,
            appliedDistortion: appliedDistortion,
            appliedTCA: appliedTCA,
            cropScale: cropScale,
            candidates: candidates,
            appliedVignetting: appliedVignetting,
            sourceMetadata: sourceMetadata
        )
    }
}

public struct ResolvedNativeWhiteBalance: Equatable {
    public let wbMode: sony2fuji_wb_mode
    public let temperature: Float
    public let tint: Float

    public init(wbMode: sony2fuji_wb_mode, temperature: Float, tint: Float) {
        self.wbMode = wbMode
        self.temperature = temperature
        self.tint = tint
    }
}

public struct ResolvedRenderSettings {
    public let settings: Adjustments
    public let whiteBalance: ResolvedNativeWhiteBalance?

    public init(settings: Adjustments, whiteBalance: ResolvedNativeWhiteBalance?) {
        self.settings = settings
        self.whiteBalance = whiteBalance
    }

    public func apply(to request: inout sony2fuji_request) {
        settings.apply(to: &request, resolvedWhiteBalance: whiteBalance)
    }
}

public extension Adjustments {
    var photoEffectsConfig: sony2fuji_photo_effects_config {
        let state = effectSettings
        return sony2fuji_photo_effects_config(
            version: UInt32(SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION),
            struct_size: UInt32(MemoryLayout<sony2fuji_photo_effects_config>.size),
            vignette_amount: Float(state.vignetteAmount), vignette_midpoint: Float(state.vignetteMidpoint),
            vignette_roundness: Float(state.vignetteRoundness), vignette_feather: Float(state.vignetteFeather),
            vignette_highlights: Float(state.vignetteHighlights), grain_amount: Float(state.grainAmount),
            grain_size: Float(state.grainSize), grain_roughness: Float(state.grainRoughness)
        )
    }

    var aiWhiteBalanceSignature: [Float] {
        var request = sony2fuji_request()
        apply(to: &request)
        return [Float(request.wb_mode.rawValue), request.temperature, request.tint]
    }

    func apply(to request: inout sony2fuji_request, resolvedWhiteBalance: ResolvedNativeWhiteBalance? = nil) {
        let values = resolvedRenderValues()
        request.exposure_ev = values.exposureEV
        request.brightness = values.brightness
        if let wb = resolvedWhiteBalance {
            request.wb_mode = wb.wbMode
            request.temperature = wb.wbMode == SONY2FUJI_WB_TEMPERATURE ? wb.temperature : 6500
            request.tint = wb.wbMode == SONY2FUJI_WB_TEMPERATURE ? wb.tint : 0
        } else {
            request.wb_mode = values.usesTemperatureWB ? SONY2FUJI_WB_TEMPERATURE : SONY2FUJI_WB_CAMERA
            request.temperature = values.temperature
            request.tint = values.tint
        }
        request.contrast = values.contrast
        request.saturation = values.saturation
        // The core's positive highlight value compresses light; UI positive brightens.
        request.highlights = values.highlights
        request.shadows = values.shadows
        request.tone_curve = values.toneCurve
        request.sharpening = values.sharpening
    }
}
