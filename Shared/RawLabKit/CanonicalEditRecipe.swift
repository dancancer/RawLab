import Foundation

public enum CanonicalEditRecipeError: Error, Equatable {
    case invalidToneControls
    case invalidAtmosphere
    case invalidToneCurve
    case invalidColorGrading
    case invalidHSL
    case invalidGeometry
    case invalidPhotoEffects
    case invalidWaveletDenoise
    case invalidChromaDenoise
    case invalidRawNoiseReduction
    case invalidWhiteBalance
}

public enum CanonicalEditRecipe {
    public struct State: Equatable {
        public var processing: ProcessingIdentity
        public var x3fMode: X3fMode
        public var exposureMode: String
        public var isRaster: Bool
        public var relativeTemperature: Double
        public var relativeTint: Double
        public var toneControls: ToneControlsSettings
        public var atmosphere: AtmosphereSettings
        public var toneCurve: ToneCurveSettings
        public var colorGrading: ColorGradingSettings
        public var hsl: HSLSettings
        public var geometry: GeometrySettings
        public var lensCorrection: LensCorrectionSettings
        public var photoEffects: PhotoEffectsSettings
        public var waveletDenoise: WaveletDenoiseSettings?
        public var chromaDenoise: Int
        public var rawNoiseReduction: Int
        public var outputSharpening: OutputSharpening

        public init(
            processing: ProcessingIdentity = .current,
            x3fMode: X3fMode = .normal,
            exposureMode: String = "preview",
            isRaster: Bool = false,
            relativeTemperature: Double = 6500,
            relativeTint: Double = 0,
            toneControls: ToneControlsSettings = .init(),
            atmosphere: AtmosphereSettings = .init(),
            toneCurve: ToneCurveSettings = .init(),
            colorGrading: ColorGradingSettings = .init(),
            hsl: HSLSettings = .init(),
            geometry: GeometrySettings = .init(),
            lensCorrection: LensCorrectionSettings = .init(),
            photoEffects: PhotoEffectsSettings = .init(),
            waveletDenoise: WaveletDenoiseSettings? = nil,
            chromaDenoise: Int = 0,
            rawNoiseReduction: Int = 0,
            outputSharpening: OutputSharpening = .off
        ) {
            self.processing = processing
            self.x3fMode = x3fMode
            self.exposureMode = exposureMode
            self.isRaster = isRaster
            self.relativeTemperature = relativeTemperature
            self.relativeTint = relativeTint
            self.toneControls = toneControls
            self.atmosphere = atmosphere
            self.toneCurve = toneCurve
            self.colorGrading = colorGrading
            self.hsl = hsl
            self.geometry = geometry
            self.lensCorrection = lensCorrection
            self.photoEffects = photoEffects
            self.waveletDenoise = waveletDenoise
            self.chromaDenoise = chromaDenoise
            self.rawNoiseReduction = rawNoiseReduction
            self.outputSharpening = outputSharpening
        }
    }

    public static func processingSessionStateJSON(processingVersion: Int) -> String {
        let clampedVersion = min(3, max(1, processingVersion))
        let payload = SessionProcessingPayload(
            processing: .init(family: "rawlab", version: clampedVersion, quality: "standard")
        )
        let data = try! encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    public static func encode(_ state: State) throws -> String {
        guard state.toneControls.isValid else { throw CanonicalEditRecipeError.invalidToneControls }
        guard state.atmosphere.isValid else { throw CanonicalEditRecipeError.invalidAtmosphere }
        guard state.toneCurve.isValid else { throw CanonicalEditRecipeError.invalidToneCurve }
        guard state.colorGrading.isValid else { throw CanonicalEditRecipeError.invalidColorGrading }
        guard state.hsl.isValid else { throw CanonicalEditRecipeError.invalidHSL }
        guard state.geometry.isValid else { throw CanonicalEditRecipeError.invalidGeometry }
        guard state.photoEffects.isValid else { throw CanonicalEditRecipeError.invalidPhotoEffects }
        if let wavelet = state.waveletDenoise {
            let valid = [wavelet.luma, wavelet.chroma, wavelet.coarse].allSatisfy {
                $0.isFinite && (0...100).contains($0)
            }
            guard valid else { throw CanonicalEditRecipeError.invalidWaveletDenoise }
        }
        guard (0...2).contains(state.chromaDenoise) else { throw CanonicalEditRecipeError.invalidChromaDenoise }
        guard (0...2).contains(state.rawNoiseReduction) else { throw CanonicalEditRecipeError.invalidRawNoiseReduction }

        let effectiveExposureMode = state.isRaster ? "sensor" : state.exposureMode
        let effectiveRawNR = state.isRaster ? 0 : state.rawNoiseReduction
        let profileID = state.lensCorrection.coreProfileID.isEmpty ? nil : state.lensCorrection.coreProfileID

        let channels: CurveChannelsPayload? = state.toneCurve.channels.isDefault ? nil : CurveChannelsPayload(
            red: CurveShapePayload(state.toneCurve.channels.red),
            green: CurveShapePayload(state.toneCurve.channels.green),
            blue: CurveShapePayload(state.toneCurve.channels.blue)
        )
        let rasterRelativeActive = state.isRaster && (state.relativeTemperature != 6500 || state.relativeTint != 0)
        if rasterRelativeActive {
            guard state.relativeTemperature.isFinite, (2000...50000).contains(state.relativeTemperature),
                  state.relativeTint.isFinite, (-150...150).contains(state.relativeTint) else {
                throw CanonicalEditRecipeError.invalidWhiteBalance
            }
        }
        let hasV12Features = state.toneCurve.hasV2Extensions || state.colorGrading.hasV2Extensions ||
            state.outputSharpening != .off || rasterRelativeActive

        let payload = Payload(
            schemaVersion: hasV12Features ? 17 : (state.isRaster ? 5 : 7),
            x3fMode: state.isRaster ? nil : state.x3fMode.rawValue,
            processing: .init(family: "rawlab", version: state.processing.version, quality: state.processing.quality),
            input: .init(path: nil, type: state.isRaster ? "raster" : "raw"),
            edits: .init(
                exposure: .init(mode: effectiveExposureMode, ev: 0, brightness: 1),
                whiteBalance: rasterRelativeActive
                    ? .init(mode: "relative", relativeTemperature: state.relativeTemperature, relativeTint: state.relativeTint)
                    : .init(mode: state.isRaster ? "none" : "camera"),
                look: .init(path: nil, strength: 1),
                geometry: .init(
                    crop: .init(
                        x: state.geometry.cropX,
                        y: state.geometry.cropY,
                        width: state.geometry.cropWidth,
                        height: state.geometry.cropHeight
                    ),
                    quarterTurns: state.geometry.quarterTurns,
                    flipHorizontal: state.geometry.flipHorizontal,
                    flipVertical: state.geometry.flipVertical,
                    straightenDegrees: state.geometry.straightenDegrees,
                    perspective: .init(
                        horizontal: state.geometry.perspectiveHorizontal,
                        vertical: state.geometry.perspectiveVertical
                    )
                ),
                tone: .init(
                    contrast: 1,
                    saturation: 1,
                    highlights: 0,
                    shadows: 0,
                    sCurve: 0,
                    blackPoint: state.toneControls.blackPoint / 100.0,
                    whitePoint: state.toneControls.whitePoint / 100.0,
                    curve: .init(
                        mode: state.toneCurve.mode.rawValue,
                        points: state.toneCurve.points.map { [$0.x, $0.y] },
                        channels: channels,
                        applyToLuminosity: state.toneCurve.applyToLuminosity ? true : nil,
                        parametric: state.toneCurve.parametric.isDefault ? nil : CurveParametricPayload(state.toneCurve.parametric)
                    )
                ),
                color: .init(vibrance: state.toneControls.vibrance / 100.0),
                colorGrading: .init(
                    shadows: WheelPayload(state.colorGrading.shadows),
                    midtones: WheelPayload(state.colorGrading.midtones),
                    highlights: WheelPayload(state.colorGrading.highlights),
                    global: state.colorGrading.global.isDefault ? nil : WheelPayload(state.colorGrading.global),
                    blending: state.colorGrading.blending == 50.0 ? nil : state.colorGrading.blending,
                    balance: state.colorGrading.balance == 0.0 ? nil : state.colorGrading.balance
                ),
                detail: .init(sharpening: 0),
                hsl: .init(
                    hue: state.hsl.hue,
                    saturation: state.hsl.saturation,
                    lightness: state.hsl.lightness
                ),
                effects: .init(
                    vignetteAmount: state.photoEffects.vignetteAmount,
                    vignetteMidpoint: state.photoEffects.vignetteMidpoint,
                    vignetteRoundness: state.photoEffects.vignetteRoundness,
                    vignetteFeather: state.photoEffects.vignetteFeather,
                    vignetteHighlights: state.photoEffects.vignetteHighlights,
                    grainAmount: state.photoEffects.grainAmount,
                    grainSize: state.photoEffects.grainSize,
                    grainRoughness: state.photoEffects.grainRoughness,
                    clarity: state.atmosphere.clarity / 100.0,
                    dehaze: state.atmosphere.dehaze / 100.0
                ),
                denoise: .init(
                    rawLevel: effectiveRawNR,
                    chromaMode: state.chromaDenoise,
                    wavelet: state.waveletDenoise.map {
                        WaveletPayload(enabled: $0.enabled, luma: $0.luma, chroma: $0.chroma, coarse: $0.coarse)
                    },
                    aiDenoiseBlend: nil
                ),
                lensCorrection: .init(
                    distortion: state.lensCorrection.distortion,
                    tca: state.lensCorrection.tca,
                    vignetting: state.lensCorrection.vignetting,
                    autoCrop: state.lensCorrection.autoCrop,
                    profileId: profileID
                ),
                masterRecipe: nil
            ),
            output: state.outputSharpening == .off ? nil : .init(
                path: nil,
                format: nil,
                size: nil,
                outputSharpening: state.outputSharpening.rawValue
            )
        )

        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private struct SessionProcessingPayload: Encodable {
        let processing: ProcessingPayload
    }

    private struct Payload: Encodable {
        let schemaVersion: Int
        let x3fMode: String?
        let processing: ProcessingPayload
        let input: InputPayload
        let edits: EditsPayload
        let output: OutputPayload?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case x3fMode = "x3f_mode"
            case processing, input, edits, output
        }
    }

    private struct ProcessingPayload: Encodable {
        let family: String
        let version: Int
        let quality: String
    }

    private struct InputPayload: Encodable {
        let path: String?
        let type: String
    }

    private struct OutputPayload: Encodable {
        let path: String?
        let format: String?
        let size: SizePayload?
        let outputSharpening: String?

        enum CodingKeys: String, CodingKey {
            case path, format, size
            case outputSharpening = "output_sharpening"
        }
    }

    private struct SizePayload: Encodable {
        let mode: String
    }

    private struct MasterRecipePayload: Encodable {
        let active: Bool
        let strength: Double
        let customWb: Bool
        let temperatureKelvin: Double
        let tint: Double
        let uncalibratedFallback: String

        enum CodingKeys: String, CodingKey {
            case active, strength
            case customWb = "custom_wb"
            case temperatureKelvin = "temperature_kelvin"
            case tint
            case uncalibratedFallback = "uncalibrated_fallback"
        }
    }

    private struct EditsPayload: Encodable {
        let exposure: ExposurePayload
        let whiteBalance: WhiteBalancePayload
        let look: LookPayload
        let geometry: GeometryPayload?
        let tone: TonePayload?
        let color: ColorPayload?
        let colorGrading: ColorGradingPayload?
        let detail: DetailPayload
        let hsl: HSLPayload?
        let effects: EffectsPayload?
        let denoise: DenoisePayload?
        let lensCorrection: LensCorrectionPayload?
        let masterRecipe: MasterRecipePayload?

        enum CodingKeys: String, CodingKey {
            case exposure
            case whiteBalance = "white_balance"
            case look, geometry, tone, color
            case colorGrading = "color_grading"
            case detail, hsl, effects, denoise
            case lensCorrection = "lens_correction"
            case masterRecipe = "master_recipe"
        }
    }

    private struct ExposurePayload: Encodable {
        let mode: String
        let ev: Double
        let brightness: Double
    }

    private struct WhiteBalancePayload: Encodable {
        let mode: String
        let temperatureKelvin: Double?
        let tint: Double?
        let relativeTemperature: Double?
        let relativeTint: Double?

        init(mode: String, temperatureKelvin: Double? = nil, tint: Double? = nil,
             relativeTemperature: Double? = nil, relativeTint: Double? = nil) {
            self.mode = mode
            self.temperatureKelvin = temperatureKelvin
            self.tint = tint
            self.relativeTemperature = relativeTemperature
            self.relativeTint = relativeTint
        }

        enum CodingKeys: String, CodingKey {
            case mode
            case temperatureKelvin = "temperature_kelvin"
            case tint
            case relativeTemperature = "relative_temperature"
            case relativeTint = "relative_tint"
        }
    }

    private struct LookPayload: Encodable {
        let path: String?
        let strength: Double
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(strength, forKey: .strength)
        }
        enum CodingKeys: String, CodingKey { case path, strength }
    }

    private struct GeometryPayload: Encodable {
        let crop: CropPayload
        let quarterTurns: Int
        let flipHorizontal: Bool
        let flipVertical: Bool
        let straightenDegrees: Double
        let perspective: PerspectivePayload

        enum CodingKeys: String, CodingKey {
            case crop
            case quarterTurns = "quarter_turns"
            case flipHorizontal = "flip_horizontal"
            case flipVertical = "flip_vertical"
            case straightenDegrees = "straighten_degrees"
            case perspective
        }
    }

    private struct CropPayload: Encodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct PerspectivePayload: Encodable {
        let horizontal: Double
        let vertical: Double
    }

    private struct TonePayload: Encodable {
        let contrast: Double
        let saturation: Double
        let highlights: Double
        let shadows: Double
        let sCurve: Double
        let blackPoint: Double
        let whitePoint: Double
        let curve: CurvePayload

        enum CodingKeys: String, CodingKey {
            case contrast, saturation, highlights, shadows
            case sCurve = "s_curve"
            case blackPoint = "black_point"
            case whitePoint = "white_point"
            case curve
        }
    }

    private struct CurveShapePayload: Encodable {
        let mode: String
        let points: [[Double]]
        init(_ shape: ToneCurveShape) {
            mode = shape.mode.rawValue
            points = shape.points.map { [$0.x, $0.y] }
        }
    }

    private struct CurveChannelsPayload: Encodable {
        let red: CurveShapePayload
        let green: CurveShapePayload
        let blue: CurveShapePayload
    }

    private struct CurveParametricPayload: Encodable {
        let highlights: Double
        let lights: Double
        let darks: Double
        let shadows: Double
        let splitShadow: Double
        let splitMidtone: Double
        let splitHighlight: Double

        init(_ p: ToneCurveParametric) {
            highlights = p.highlights
            lights = p.lights
            darks = p.darks
            shadows = p.shadows
            splitShadow = p.splitShadow
            splitMidtone = p.splitMidtone
            splitHighlight = p.splitHighlight
        }

        enum CodingKeys: String, CodingKey {
            case highlights, lights, darks, shadows
            case splitShadow = "split_shadow"
            case splitMidtone = "split_midtone"
            case splitHighlight = "split_highlight"
        }
    }

    private struct CurvePayload: Encodable {
        let mode: String
        let points: [[Double]]
        let channels: CurveChannelsPayload?
        let applyToLuminosity: Bool?
        let parametric: CurveParametricPayload?

        enum CodingKeys: String, CodingKey {
            case mode, points, channels
            case applyToLuminosity = "apply_to_luminosity"
            case parametric
        }
    }

    private struct ColorPayload: Encodable {
        let vibrance: Double
    }

    private struct WheelPayload: Encodable {
        let hue: Double
        let saturation: Double
        let luminance: Double?

        init(_ wheel: ColorGradingWheel) {
            hue = wheel.hue
            saturation = wheel.saturation
            luminance = wheel.luminance == 0.0 ? nil : wheel.luminance
        }
    }

    private struct ColorGradingPayload: Encodable {
        let shadows: WheelPayload
        let midtones: WheelPayload
        let highlights: WheelPayload
        let global: WheelPayload?
        let blending: Double?
        let balance: Double?
    }

    private struct DetailPayload: Encodable {
        let sharpening: Double
    }

    private struct HSLPayload: Encodable {
        let hue: [Double]
        let saturation: [Double]
        let lightness: [Double]
    }

    private struct EffectsPayload: Encodable {
        let vignetteAmount: Double
        let vignetteMidpoint: Double
        let vignetteRoundness: Double
        let vignetteFeather: Double
        let vignetteHighlights: Double
        let grainAmount: Double
        let grainSize: Double
        let grainRoughness: Double
        let clarity: Double
        let dehaze: Double

        enum CodingKeys: String, CodingKey {
            case vignetteAmount = "vignette_amount"
            case vignetteMidpoint = "vignette_midpoint"
            case vignetteRoundness = "vignette_roundness"
            case vignetteFeather = "vignette_feather"
            case vignetteHighlights = "vignette_highlights"
            case grainAmount = "grain_amount"
            case grainSize = "grain_size"
            case grainRoughness = "grain_roughness"
            case clarity, dehaze
        }
    }

    private struct WaveletPayload: Encodable {
        let enabled: Bool
        let luma: Double
        let chroma: Double
        let coarse: Double
    }

    private struct DenoisePayload: Encodable {
        let rawLevel: Int
        let chromaMode: Int
        let wavelet: WaveletPayload?
        let aiDenoiseBlend: Double?

        enum CodingKeys: String, CodingKey {
            case rawLevel = "raw_level"
            case chromaMode = "chroma_mode"
            case wavelet
            case aiDenoiseBlend = "ai_denoise_blend"
        }
    }

    private struct LensCorrectionPayload: Encodable {
        let distortion: Bool
        let tca: Bool
        let vignetting: Bool
        let autoCrop: Bool
        let profileId: String?

        enum CodingKeys: String, CodingKey {
            case distortion, tca, vignetting
            case autoCrop = "auto_crop"
            case profileId = "profile_id"
        }
    }

    static func encodeSDRSessionState(
        _ state: State,
        resolved: ResolvedRenderValues,
        lutPath: String?,
        lutStrength: Double,
        masterRecipe: (active: Bool, customWB: Bool, temperature: Double, tint: Double)?,
        aiDenoiseBlend: Double?
    ) throws -> String {
        guard state.toneControls.isValid else { throw CanonicalEditRecipeError.invalidToneControls }
        guard state.atmosphere.isValid else { throw CanonicalEditRecipeError.invalidAtmosphere }
        guard state.toneCurve.isValid else { throw CanonicalEditRecipeError.invalidToneCurve }
        guard state.colorGrading.isValid else { throw CanonicalEditRecipeError.invalidColorGrading }
        guard state.hsl.isValid else { throw CanonicalEditRecipeError.invalidHSL }
        guard state.geometry.isValid else { throw CanonicalEditRecipeError.invalidGeometry }
        guard state.photoEffects.isValid else { throw CanonicalEditRecipeError.invalidPhotoEffects }
        if let wavelet = state.waveletDenoise {
            let valid = [wavelet.luma, wavelet.chroma, wavelet.coarse].allSatisfy {
                $0.isFinite && (0...100).contains($0)
            }
            guard valid else { throw CanonicalEditRecipeError.invalidWaveletDenoise }
        }
        guard (0...2).contains(state.chromaDenoise) else { throw CanonicalEditRecipeError.invalidChromaDenoise }
        guard (0...2).contains(state.rawNoiseReduction) else { throw CanonicalEditRecipeError.invalidRawNoiseReduction }

        let effectiveExposureMode = state.isRaster ? "sensor" : state.exposureMode
        let effectiveRawNR = state.isRaster ? 0 : state.rawNoiseReduction
        let profileID = state.lensCorrection.coreProfileID.isEmpty ? nil : state.lensCorrection.coreProfileID
        let channels: CurveChannelsPayload? = state.toneCurve.channels.isDefault ? nil : CurveChannelsPayload(
            red: CurveShapePayload(state.toneCurve.channels.red),
            green: CurveShapePayload(state.toneCurve.channels.green),
            blue: CurveShapePayload(state.toneCurve.channels.blue)
        )

        let whiteBalance: WhiteBalancePayload
        let masterRecipePayload: MasterRecipePayload?
        if state.isRaster {
            masterRecipePayload = nil
            let rasterRelativeActive = state.relativeTemperature != 6500 || state.relativeTint != 0
            if rasterRelativeActive {
                guard state.relativeTemperature.isFinite, (2000...50000).contains(state.relativeTemperature),
                      state.relativeTint.isFinite, (-150...150).contains(state.relativeTint) else {
                    throw CanonicalEditRecipeError.invalidWhiteBalance
                }
                whiteBalance = .init(
                    mode: "relative",
                    relativeTemperature: state.relativeTemperature,
                    relativeTint: state.relativeTint
                )
            } else {
                whiteBalance = .init(mode: "none")
            }
        } else if let masterRecipe, masterRecipe.active {
            guard masterRecipe.temperature.isFinite, (2000...50000).contains(masterRecipe.temperature),
                  masterRecipe.tint.isFinite, (-150...150).contains(masterRecipe.tint) else {
                throw CanonicalEditRecipeError.invalidWhiteBalance
            }
            whiteBalance = masterRecipe.customWB
                ? .init(mode: "temperature", temperatureKelvin: masterRecipe.temperature, tint: masterRecipe.tint)
                : .init(mode: "camera")
            masterRecipePayload = MasterRecipePayload(
                active: true,
                strength: lutStrength,
                customWb: masterRecipe.customWB,
                temperatureKelvin: masterRecipe.temperature,
                tint: masterRecipe.tint,
                uncalibratedFallback: "error"
            )
        } else {
            masterRecipePayload = nil
            if resolved.usesTemperatureWB {
                guard resolved.temperature.isFinite, (2000...50000).contains(Double(resolved.temperature)),
                      resolved.tint.isFinite, (-150...150).contains(Double(resolved.tint)) else {
                    throw CanonicalEditRecipeError.invalidWhiteBalance
                }
                whiteBalance = .init(
                    mode: "temperature",
                    temperatureKelvin: Double(resolved.temperature),
                    tint: Double(resolved.tint)
                )
            } else {
                whiteBalance = .init(mode: "camera")
            }
        }

        let payload = Payload(
            schemaVersion: 17,
            x3fMode: state.isRaster ? nil : state.x3fMode.rawValue,
            processing: .init(family: "rawlab", version: state.processing.version, quality: state.processing.quality),
            input: .init(path: nil, type: state.isRaster ? "raster" : "raw"),
            edits: .init(
                exposure: .init(
                    mode: effectiveExposureMode,
                    ev: Double(resolved.exposureEV),
                    brightness: Double(resolved.brightness)
                ),
                whiteBalance: whiteBalance,
                look: .init(path: lutPath, strength: lutPath == nil ? 0 : lutStrength),
                geometry: .init(
                    crop: .init(
                        x: state.geometry.cropX,
                        y: state.geometry.cropY,
                        width: state.geometry.cropWidth,
                        height: state.geometry.cropHeight
                    ),
                    quarterTurns: state.geometry.quarterTurns,
                    flipHorizontal: state.geometry.flipHorizontal,
                    flipVertical: state.geometry.flipVertical,
                    straightenDegrees: state.geometry.straightenDegrees,
                    perspective: .init(
                        horizontal: state.geometry.perspectiveHorizontal,
                        vertical: state.geometry.perspectiveVertical
                    )
                ),
                tone: .init(
                    contrast: min(2, max(0, Double(resolved.contrast))),
                    saturation: min(2, max(0, Double(resolved.saturation))),
                    highlights: min(1, max(-1, Double(resolved.highlights))),
                    shadows: min(1, max(-1, Double(resolved.shadows))),
                    sCurve: Double(resolved.toneCurve),
                    blackPoint: state.toneControls.blackPoint / 100.0,
                    whitePoint: state.toneControls.whitePoint / 100.0,
                    curve: .init(
                        mode: state.toneCurve.mode.rawValue,
                        points: state.toneCurve.points.map { [$0.x, $0.y] },
                        channels: channels,
                        applyToLuminosity: state.toneCurve.applyToLuminosity ? true : nil,
                        parametric: state.toneCurve.parametric.isDefault ? nil : CurveParametricPayload(state.toneCurve.parametric)
                    )
                ),
                color: .init(vibrance: state.toneControls.vibrance / 100.0),
                colorGrading: .init(
                    shadows: WheelPayload(state.colorGrading.shadows),
                    midtones: WheelPayload(state.colorGrading.midtones),
                    highlights: WheelPayload(state.colorGrading.highlights),
                    global: state.colorGrading.global.isDefault ? nil : WheelPayload(state.colorGrading.global),
                    blending: state.colorGrading.blending == 50.0 ? nil : state.colorGrading.blending,
                    balance: state.colorGrading.balance == 0.0 ? nil : state.colorGrading.balance
                ),
                detail: .init(sharpening: min(2, max(0, Double(resolved.sharpening)))),
                hsl: .init(
                    hue: state.hsl.hue,
                    saturation: state.hsl.saturation,
                    lightness: state.hsl.lightness
                ),
                effects: .init(
                    vignetteAmount: state.photoEffects.vignetteAmount,
                    vignetteMidpoint: state.photoEffects.vignetteMidpoint,
                    vignetteRoundness: state.photoEffects.vignetteRoundness,
                    vignetteFeather: state.photoEffects.vignetteFeather,
                    vignetteHighlights: state.photoEffects.vignetteHighlights,
                    grainAmount: state.photoEffects.grainAmount,
                    grainSize: state.photoEffects.grainSize,
                    grainRoughness: state.photoEffects.grainRoughness,
                    clarity: state.atmosphere.clarity / 100.0,
                    dehaze: state.atmosphere.dehaze / 100.0
                ),
                denoise: .init(
                    rawLevel: effectiveRawNR,
                    chromaMode: state.chromaDenoise,
                    wavelet: state.waveletDenoise.map {
                        WaveletPayload(enabled: $0.enabled, luma: $0.luma, chroma: $0.chroma, coarse: $0.coarse)
                    },
                    aiDenoiseBlend: aiDenoiseBlend.map { min(1.0, max(0.0, $0)) }
                ),
                lensCorrection: .init(
                    distortion: state.lensCorrection.distortion,
                    tca: state.lensCorrection.tca,
                    vignetting: state.lensCorrection.vignetting,
                    autoCrop: state.lensCorrection.autoCrop,
                    profileId: profileID
                ),
                masterRecipe: masterRecipePayload
            ),
            output: state.outputSharpening == .off ? nil : .init(
                path: nil,
                format: nil,
                size: nil,
                outputSharpening: state.outputSharpening.rawValue
            )
        )

        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    public static func hdrCameraDevelopmentJSON(
        camera: HDRCameraDevelopmentSettings = HDRCameraDevelopmentSettings(),
        cameraProfileURL: URL? = nil,
        processingVersion: Int,
        useAI: Bool = false
    ) throws -> String {
        guard camera.isValid else { throw HDRRecipe.Failure.invalidSettings }
        let root: [String: Any] = [
            "camera_development": cameraDevelopmentObject(
                camera: camera,
                cameraProfileURL: cameraProfileURL,
                processingVersion: processingVersion,
                useAI: useAI
            )
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public static func hdrSessionStateJSON(
        settings: HDRSettings,
        outputSharpening: OutputSharpening = .off,
        lookDirectory: URL = HDRLookSettings.directory,
        camera: HDRCameraDevelopmentSettings? = nil,
        cameraProfileURL: URL? = nil,
        cameraProcessingVersion: Int? = nil,
        useCameraAI: Bool = false
    ) throws -> String {
        guard settings.mode == .hdr, settings.isValid, camera?.isValid ?? true else {
            throw HDRRecipe.Failure.invalidSettings
        }
        let g = settings.geometry
        let version = max(settings.processingVersion, outputSharpening != .off ? 9 : 1)
        let schemaVersion = version == 9 ? 16 : version == 8 ? 15 : version == 1 ? 6 : version + 6

        var tone: [String: Any] = [
            "contrast": 1 + settings.contrast / 100,
            "saturation": 1 + settings.saturation / 100,
            "highlights": -settings.highlights / 100,
            "shadows": settings.shadows / 100
        ]
        if version >= 2 {
            let current = settings.toneSettings
            tone["black_point"] = current.blackPoint / 100
            tone["white_point"] = current.whitePoint / 100
            tone["s_curve"] = current.curve.mode == .custom ? 0 : current.curveStrength / 100
            tone["curve"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current.curve))
        }
        var edits: [String: Any] = [
            "exposure": ["ev": settings.exposure],
            "white_balance": [
                "mode": "relative",
                "relative_temperature": settings.temperature,
                "relative_tint": settings.tint
            ],
            "tone": tone,
            "geometry": [
                "crop": ["x": g.cropX, "y": g.cropY, "width": g.cropWidth, "height": g.cropHeight],
                "quarter_turns": g.quarterTurns,
                "flip_horizontal": g.flipHorizontal,
                "flip_vertical": g.flipVertical,
                "straighten_degrees": g.straightenDegrees,
                "perspective": ["horizontal": g.perspectiveHorizontal, "vertical": g.perspectiveVertical]
            ]
        ]
        if version >= 3 {
            let color = settings.colorSettings
            edits["color"] = ["vibrance": color.vibrance / 100]
            edits["hsl"] = ["hue": color.hsl.hue, "saturation": color.hsl.saturation, "lightness": color.hsl.lightness]
            var gradingDict: [String: Any] = Dictionary(uniqueKeysWithValues: ColorGradingZone.allCases.map { zone in
                let wheel = color.grading[zone]
                var wheelDict: [String: Any] = ["hue": wheel.hue, "saturation": wheel.saturation]
                if wheel.luminance != 0.0 { wheelDict["luminance"] = wheel.luminance }
                return (zone.rawValue, wheelDict)
            })
            if !color.grading.global.isDefault {
                var globalDict: [String: Any] = ["hue": color.grading.global.hue, "saturation": color.grading.global.saturation]
                if color.grading.global.luminance != 0.0 { globalDict["luminance"] = color.grading.global.luminance }
                gradingDict["global"] = globalDict
            }
            if color.grading.blending != 50.0 { gradingDict["blending"] = color.grading.blending }
            if color.grading.balance != 0.0 { gradingDict["balance"] = color.grading.balance }
            edits["color_grading"] = gradingDict
        }
        if version >= 4 {
            let rendition = settings.renditionSettings
            edits["rendition"] = [
                "peak_limit_ev": rendition.peakLimitEV,
                "sdr_exposure_ev": rendition.sdrExposureEV,
                "sdr_contrast": rendition.sdrContrast / 100,
                "sdr_saturation": rendition.sdrSaturation / 100
            ]
        }
        if version >= 5 {
            let fx = settings.effectsSettings
            edits["effects"] = [
                "vignette_amount": fx.vignetteAmount,
                "vignette_midpoint": fx.vignetteMidpoint,
                "vignette_roundness": fx.vignetteRoundness,
                "vignette_feather": fx.vignetteFeather,
                "vignette_highlights": fx.vignetteHighlights,
                "grain_amount": fx.grainAmount,
                "grain_size": fx.grainSize,
                "grain_roughness": fx.grainRoughness
            ]
        }
        if version >= 6 {
            let detail = settings.detailSettings
            edits["detail"] = [
                "sharpening": detail.sharpening,
                "clarity": detail.clarity,
                "dehaze": detail.dehaze,
                "denoise": detail.denoise
            ]
        }
        if version >= 7 {
            var look: [String: Any] = ["strength": settings.lookSettings.strength]
            if let asset = settings.lookSettings.asset(in: lookDirectory) {
                look["path"] = asset.path
            }
            if let sha = settings.lookSettings.sha256 {
                look["sha256"] = sha
            }
            edits["look"] = look
        }
        var root: [String: Any] = [
            "schema_version": schemaVersion,
            "processing": ["family": "rawlab_hdr", "version": version, "quality": "standard"],
            "edits": edits
        ]
        if outputSharpening != .off {
            root["output"] = ["output_sharpening": outputSharpening.rawValue]
        }
        if let camera {
            root["camera_development"] = cameraDevelopmentObject(
                camera: camera,
                cameraProfileURL: cameraProfileURL,
                processingVersion: cameraProcessingVersion ?? 3,
                useAI: useCameraAI
            )
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func cameraDevelopmentObject(
        camera: HDRCameraDevelopmentSettings,
        cameraProfileURL: URL?,
        processingVersion: Int,
        useAI: Bool
    ) -> [String: Any] {
        var object: [String: Any] = [
            "version": 1,
            "wb_mode": camera.whiteBalance == .asShot ? "as_shot" : "temperature",
            "temperature": camera.temperature,
            "tint": camera.tint,
            "exposure_reference": camera.exposureReference == .metadata ? "metadata" : "sensor",
            "fbdd_level": camera.fbddLevel,
            "lens_distortion": camera.lensDistortion,
            "lens_tca": camera.lensTCA,
            "lens_vignetting": camera.lensVignetting,
            "lens_auto_crop": camera.lensAutoCrop,
            "use_ai": useAI,
            "processing_version": min(3, max(1, processingVersion))
        ]
        if let lensProfile = camera.lensProfile {
            object["lens_profile_id"] = lensProfile
        }
        if let profile = camera.cameraProfile, let cameraProfileURL {
            object["camera_profile"] = [
                "path": cameraProfileURL.path,
                "sha256": profile.sha256
            ]
        }
        return object
    }
}

public extension Adjustments {
    func canonicalEditState(isRaster: Bool = false, includeDenoise: Bool = true, outputSharpening: OutputSharpening = .off) -> CanonicalEditRecipe.State {
        let exposureString: String
        switch exposureMode {
        case .scene: exposureString = "scene"
        case .preview: exposureString = "preview"
        case .sensor: exposureString = "sensor"
        }
        let hasWavelet = waveletNoiseReduction != WaveletDenoiseSettings()
        let wavelet: WaveletDenoiseSettings? = (includeDenoise && hasWavelet) ? waveletNoiseReduction : nil
        let chromaMode = (includeDenoise && !hasWavelet) ? chromaNoiseReduction : 0
        let legacyLevel = (includeDenoise && !hasWavelet && chromaMode == 0) ? Int(rawNoiseReduction) : 0
        return CanonicalEditRecipe.State(
            processing: processing,
            x3fMode: x3fMode,
            exposureMode: isRaster ? "sensor" : exposureString,
            isRaster: isRaster,
            relativeTemperature: isRaster && masterRecipe == nil ? temperature : 6500,
            relativeTint: isRaster && masterRecipe == nil ? tint : 0,
            toneControls: renderToneSettings,
            atmosphere: renderAtmosphereSettings,
            toneCurve: renderCurveSettings,
            colorGrading: renderGradingSettings,
            hsl: renderHSLSettings,
            geometry: geometrySettings,
            lensCorrection: lensSettings,
            photoEffects: effectSettings,
            waveletDenoise: wavelet,
            chromaDenoise: chromaMode,
            rawNoiseReduction: legacyLevel,
            outputSharpening: outputSharpening
        )
    }

    func canonicalParamsJSON(isRaster: Bool = false, includeDenoise: Bool = true, outputSharpening: OutputSharpening = .off) throws -> String {
        try CanonicalEditRecipe.encode(canonicalEditState(isRaster: isRaster, includeDenoise: includeDenoise, outputSharpening: outputSharpening))
    }

    func sdrSessionStateJSON(
        isRaster: Bool = false,
        lutPath: String? = nil,
        includeDenoise: Bool = true,
        aiDenoiseBlend: Double? = nil,
        outputSharpening: OutputSharpening = .off
    ) throws -> String {
        let state = canonicalEditState(isRaster: isRaster, includeDenoise: includeDenoise, outputSharpening: outputSharpening)
        let resolved = resolvedRenderValues()
        let customWB = !usesAsShotWhiteBalance
        let effectiveMasterTemp = customWB ? temperature : 6500
        let effectiveMasterTint = (!customWB && clampedLUTStrength == 0) ? 0 : tint
        let master = (!isRaster && masterRecipe != nil)
            ? (active: true, customWB: customWB, temperature: effectiveMasterTemp, tint: effectiveMasterTint)
            : nil
        let effectiveBlend: Double?
        if let aiDenoiseBlend {
            effectiveBlend = aiDenoiseBlend
        } else if includeDenoise {
            effectiveBlend = aiDenoiseEnabled ? (aiDenoiseStrength / 100.0) : 1.0
        } else {
            effectiveBlend = nil
        }
        return try CanonicalEditRecipe.encodeSDRSessionState(
            state,
            resolved: resolved,
            lutPath: lutPath,
            lutStrength: Double(clampedLUTStrength),
            masterRecipe: master,
            aiDenoiseBlend: effectiveBlend
        )
    }
}
