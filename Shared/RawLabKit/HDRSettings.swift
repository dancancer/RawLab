import Foundation
import CryptoKit

public struct HDRToneSettings: Equatable, Codable {
    public var blackPoint = 0.0
    public var whitePoint = 0.0
    public var curveStrength = 0.0
    public var curve = ToneCurveSettings()

    public var isDefault: Bool { blackPoint == 0 && whitePoint == 0 && curveStrength == 0 && curve.isDefault }
    public var isIdentity: Bool {
        blackPoint == 0 && whitePoint == 0 && (curve.mode == .custom ? curve.master.isIdentity : curveStrength == 0) && curve.channels.isIdentity
    }
    public var isValid: Bool { [blackPoint, whitePoint, curveStrength].allSatisfy { (-100...100).contains($0) } && curve.isValid }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case blackPoint = "black_point", whitePoint = "white_point", curveStrength = "curve_strength", curve
    }

    public init(blackPoint: Double = 0.0, whitePoint: Double = 0.0, curveStrength: Double = 0.0, curve: ToneCurveSettings = ToneCurveSettings()) {
        self.blackPoint = blackPoint; self.whitePoint = whitePoint; self.curveStrength = curveStrength; self.curve = curve
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: HDRSettingsField.self).allKeys.map(\.stringValue)
        guard Set(fields) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported HDR tone field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        blackPoint = try values.decode(Double.self, forKey: .blackPoint)
        whitePoint = try values.decode(Double.self, forKey: .whitePoint)
        curveStrength = try values.decode(Double.self, forKey: .curveStrength)
        curve = try values.decode(ToneCurveSettings.self, forKey: .curve)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid HDR tone settings"))
        }
    }
}

public struct HDRColorSettings: Equatable, Codable {
    public var vibrance = 0.0
    public var hsl = HSLSettings()
    public var grading = ColorGradingSettings()

    public var isDefault: Bool { vibrance == 0 && hsl.isIdentity && grading.isDefault }
    public var isIdentity: Bool { vibrance == 0 && hsl.isIdentity && grading.isIdentity }
    public var isValid: Bool { (-100...100).contains(vibrance) && hsl.isValid && grading.isValid }

    private enum CodingKeys: String, CodingKey, CaseIterable { case vibrance, hsl, grading }

    public init(vibrance: Double = 0.0, hsl: HSLSettings = HSLSettings(), grading: ColorGradingSettings = ColorGradingSettings()) {
        self.vibrance = vibrance; self.hsl = hsl; self.grading = grading
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: HDRSettingsField.self).allKeys.map(\.stringValue)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let hslFields = try values.nestedContainer(keyedBy: HDRSettingsField.self, forKey: .hsl).allKeys.map(\.stringValue)
        guard Set(fields) == Set(CodingKeys.allCases.map(\.rawValue)),
              Set(hslFields) == Set(HSLAxis.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported HDR color field"))
        }
        vibrance = try values.decode(Double.self, forKey: .vibrance)
        hsl = try values.decode(HSLSettings.self, forKey: .hsl)
        grading = try values.decode(ColorGradingSettings.self, forKey: .grading)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid HDR color settings"))
        }
    }
}

public struct HDRRenditionSettings: Equatable, Codable {
    public var peakLimitEV = 0.0
    public var sdrExposureEV = 0.0
    public var sdrContrast = 0.0
    public var sdrSaturation = 0.0

    public var isDefault: Bool { peakLimitEV == 0 && sdrExposureEV == 0 && sdrContrast == 0 && sdrSaturation == 0 }
    public var isValid: Bool {
        AdjustmentFieldSpec.Fields.hdrPeakLimitEv.macosModel.closedRange!.contains(peakLimitEV) &&
        AdjustmentFieldSpec.Fields.hdrSdrExposureEv.macosModel.closedRange!.contains(sdrExposureEV) &&
        AdjustmentFieldSpec.Fields.hdrSdrContrast.macosModel.closedRange!.contains(sdrContrast) &&
        AdjustmentFieldSpec.Fields.hdrSdrSaturation.macosModel.closedRange!.contains(sdrSaturation)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case peakLimitEV = "peak_limit_ev", sdrExposureEV = "sdr_exposure_ev"
        case sdrContrast = "sdr_contrast", sdrSaturation = "sdr_saturation"
    }

    public init(peakLimitEV: Double = 0.0, sdrExposureEV: Double = 0.0, sdrContrast: Double = 0.0, sdrSaturation: Double = 0.0) {
        self.peakLimitEV = peakLimitEV; self.sdrExposureEV = sdrExposureEV; self.sdrContrast = sdrContrast; self.sdrSaturation = sdrSaturation
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: HDRSettingsField.self).allKeys.map(\.stringValue)
        guard Set(fields) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported HDR rendition field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        peakLimitEV = try values.decode(Double.self, forKey: .peakLimitEV)
        sdrExposureEV = try values.decode(Double.self, forKey: .sdrExposureEV)
        sdrContrast = try values.decode(Double.self, forKey: .sdrContrast)
        sdrSaturation = try values.decode(Double.self, forKey: .sdrSaturation)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid HDR rendition settings"))
        }
    }
}

public struct HDRPhotoEffectsSettings: Equatable {
    public var vignetteAmount = 0.0
    public var vignetteMidpoint = 50.0
    public var vignetteRoundness = 0.0
    public var vignetteFeather = 50.0
    public var vignetteHighlights = 0.0
    public var grainAmount = 0.0
    public var grainSize = 25.0
    public var grainRoughness = 50.0

    public init(vignetteAmount: Double = 0.0, vignetteMidpoint: Double = 50.0, vignetteRoundness: Double = 0.0,
                vignetteFeather: Double = 50.0, vignetteHighlights: Double = 0.0,
                grainAmount: Double = 0.0, grainSize: Double = 25.0, grainRoughness: Double = 50.0) {
        self.vignetteAmount = vignetteAmount; self.vignetteMidpoint = vignetteMidpoint
        self.vignetteRoundness = vignetteRoundness; self.vignetteFeather = vignetteFeather
        self.vignetteHighlights = vignetteHighlights; self.grainAmount = grainAmount
        self.grainSize = grainSize; self.grainRoughness = grainRoughness
    }

    public var isDefault: Bool { self == Self() }
    public var isIdentity: Bool { vignetteAmount == 0 && grainAmount == 0 }
    public var isValid: Bool {
        (-100...100).contains(vignetteAmount) && (-100...100).contains(vignetteRoundness) &&
        [vignetteMidpoint, vignetteFeather, vignetteHighlights, grainAmount, grainSize, grainRoughness]
            .allSatisfy { (0...100).contains($0) }
    }

    public mutating func reset(vignette: Bool) {
        if vignette {
            vignetteAmount = 0; vignetteMidpoint = 50; vignetteRoundness = 0
            vignetteFeather = 50; vignetteHighlights = 0
        } else {
            grainAmount = 0; grainSize = 25; grainRoughness = 50
        }
    }
}

extension HDRPhotoEffectsSettings: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case vignetteAmount = "vignette_amount", vignetteMidpoint = "vignette_midpoint"
        case vignetteRoundness = "vignette_roundness", vignetteFeather = "vignette_feather"
        case vignetteHighlights = "vignette_highlights", grainAmount = "grain_amount"
        case grainSize = "grain_size", grainRoughness = "grain_roughness"
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: HDRSettingsField.self).allKeys.map(\.stringValue)
        guard Set(fields) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported HDR effects field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vignetteAmount = try values.decode(Double.self, forKey: .vignetteAmount)
        vignetteMidpoint = try values.decode(Double.self, forKey: .vignetteMidpoint)
        vignetteRoundness = try values.decode(Double.self, forKey: .vignetteRoundness)
        vignetteFeather = try values.decode(Double.self, forKey: .vignetteFeather)
        vignetteHighlights = try values.decode(Double.self, forKey: .vignetteHighlights)
        grainAmount = try values.decode(Double.self, forKey: .grainAmount)
        grainSize = try values.decode(Double.self, forKey: .grainSize)
        grainRoughness = try values.decode(Double.self, forKey: .grainRoughness)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid HDR effects settings"))
        }
    }
}

public struct HDRDetailSettings: Equatable {
    public var sharpening = 0.0
    public var clarity = 0.0
    public var dehaze = 0.0
    public var denoise = 0.0

    public init(sharpening: Double = 0.0, clarity: Double = 0.0, dehaze: Double = 0.0, denoise: Double = 0.0) {
        self.sharpening = sharpening; self.clarity = clarity; self.dehaze = dehaze; self.denoise = denoise
    }

    public var sharpeningPercent: Double {
        get { sharpening * 100 }
        set { sharpening = newValue / 100 }
    }
    public var clarityPercent: Double {
        get { clarity * 100 }
        set { clarity = newValue / 100 }
    }
    public var dehazePercent: Double {
        get { dehaze * 100 }
        set { dehaze = newValue / 100 }
    }

    public var isDefault: Bool { self == Self() }
    public var isValid: Bool {
        (0...2).contains(sharpening) && (-1...1).contains(clarity) && (-1...1).contains(dehaze) &&
        (0...1).contains(denoise)
    }
}

extension HDRDetailSettings: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case sharpening, clarity, dehaze, denoise }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: HDRSettingsField.self).allKeys.map(\.stringValue)
        guard Set(fields) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported HDR detail field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sharpening = try values.decode(Double.self, forKey: .sharpening)
        clarity = try values.decode(Double.self, forKey: .clarity)
        dehaze = try values.decode(Double.self, forKey: .dehaze)
        denoise = try values.decode(Double.self, forKey: .denoise)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid HDR detail settings"))
        }
    }
}

public struct HDRLookSettings: Equatable {
    public var sha256: String? = nil
    public var name: String? = nil
    public var strength = 0.0

    public init(sha256: String? = nil, name: String? = nil, strength: Double = 0.0) {
        self.sha256 = sha256; self.name = name; self.strength = strength
    }

    public static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public var isDefault: Bool { sha256 == nil && name == nil && strength == 0 }
    public var isValid: Bool {
        if isDefault { return true }
        guard let sha256, Self.isFingerprint(sha256), let name, (1...512).contains(name.utf8.count),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return (0...2).contains(strength)
    }

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Looks/HDR", isDirectory: true)
    }

    public func asset(in directory: URL = Self.directory) -> URL? {
        guard let sha256, Self.isFingerprint(sha256) else { return nil }
        return directory.appendingPathComponent(sha256).appendingPathExtension("cube")
    }

    public static func readAssetBytes(_ url: URL) throws -> Data {
        let limit = 32 * 1024 * 1024
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard let data = try input.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    public func assetIsAvailable(in directory: URL = Self.directory) -> Bool {
        guard isValid else { return false }
        guard let asset = asset(in: directory) else { return isDefault }
        guard let data = try? Self.readAssetBytes(asset) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }
}

extension HDRLookSettings: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case sha256, name, strength }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: HDRSettingsField.self).allKeys.map(\.stringValue)
        guard Set(fields) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported HDR look field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = try values.decodeIfPresent(String.self, forKey: .sha256)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        strength = try values.decode(Double.self, forKey: .strength)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid HDR look settings"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sha256, forKey: .sha256)
        try values.encode(name, forKey: .name)
        try values.encode(strength, forKey: .strength)
    }
}

private struct HDRSettingsField: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct HDRCameraProfile: Codable, Hashable {
    public let sha256: String
    public let name: String

    private enum CodingKeys: String, CodingKey, CaseIterable { case sha256, name }

    public init(sha256: String, name: String) {
        self.sha256 = sha256
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: HDRSettingsField.self).allKeys.map(\.stringValue)
        guard Set(fields) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported HDR camera profile field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = try values.decode(String.self, forKey: .sha256)
        name = try values.decode(String.self, forKey: .name)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid HDR camera profile settings"))
        }
    }

    public var isValid: Bool {
        HDRLookSettings.isFingerprint(sha256) && (1...512).contains(name.utf8.count) &&
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

public struct HDRCameraDevelopmentSettings: Codable, Hashable {
    public enum WhiteBalance: String, Codable { case asShot = "as_shot", temperature }
    public enum ExposureReference: String, Codable { case metadata, sensor }
    public var version = 1
    public var whiteBalance = WhiteBalance.asShot
    public var temperature = 0.0
    public var tint = 0.0
    public var exposureReference = ExposureReference.metadata
    public var fbddLevel = 0
    public var lensDistortion = false
    public var lensTCA = false
    public var lensVignetting = false
    public var lensAutoCrop = true
    public var lensProfile: String?
    public var cameraProfile: HDRCameraProfile?

    public mutating func selectWhiteBalance(_ mode: WhiteBalance) {
        guard whiteBalance != mode else { return }
        whiteBalance = mode
        temperature = mode == .asShot ? 0 : 6500
        tint = 0
    }

    public var lensActive: Bool { lensDistortion || lensTCA || lensVignetting }
    public var isDefault: Bool { self == Self() }
    public var isValid: Bool {
        let validWB = whiteBalance == .asShot ? temperature == 0 && tint == 0
            : (2000...50000).contains(temperature) && (-150...150).contains(tint)
        let validProfile = lensProfile.map { lensActive && (1...1024).contains($0.utf8.count) &&
            !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) } ?? true
        return version == 1 && validWB && (0...2).contains(fbddLevel) && validProfile &&
            (cameraProfile?.isValid ?? true)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, whiteBalance = "white_balance_mode", temperature, tint, exposureReference = "exposure_reference"
        case fbddLevel = "fbdd_level", lensDistortion = "lens_distortion", lensTCA = "lens_tca"
        case lensVignetting = "lens_vignetting"
        case lensAutoCrop = "lens_auto_crop", lensProfile = "lens_profile", cameraProfile = "camera_profile"
    }
    public init() {}
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: HDRSettingsField.self).allKeys
        let keys = Set(fields.map(\.stringValue))
        let optional: Set<String> = [CodingKeys.lensProfile.rawValue, CodingKeys.cameraProfile.rawValue, CodingKeys.lensVignetting.rawValue]
        let supported = Set(CodingKeys.allCases.map(\.rawValue))
        guard supported.subtracting(optional).isSubset(of: keys), keys.isSubset(of: supported) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported camera development fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        whiteBalance = try values.decode(WhiteBalance.self, forKey: .whiteBalance)
        temperature = try values.decode(Double.self, forKey: .temperature)
        tint = try values.decode(Double.self, forKey: .tint)
        exposureReference = try values.decode(ExposureReference.self, forKey: .exposureReference)
        fbddLevel = try values.decode(Int.self, forKey: .fbddLevel)
        lensDistortion = try values.decode(Bool.self, forKey: .lensDistortion)
        lensTCA = try values.decode(Bool.self, forKey: .lensTCA)
        lensVignetting = values.contains(.lensVignetting) ? try values.decode(Bool.self, forKey: .lensVignetting) : false
        lensAutoCrop = try values.decode(Bool.self, forKey: .lensAutoCrop)
        lensProfile = try values.decodeIfPresent(String.self, forKey: .lensProfile)
        cameraProfile = try values.decodeIfPresent(HDRCameraProfile.self, forKey: .cameraProfile)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid camera development settings"))
        }
    }
}

public struct HDRSettings: Equatable, Codable {
    public enum Mode: String, Codable { case sdr, hdr }
    public enum ModeError: Error, Equatable { case unsupportedSource, invalidSettings }

    public var recordVersion: Int { processingVersion == 8 ? 9 : cameraDevelopment == nil ? processingVersion : 8 }
    public var processingVersion: Int {
        if tone?.curve.hasChannelCurves == true { return 8 }
        if look != nil { return 7 }
        if detail != nil { return 6 }
        if effects != nil { return 5 }
        if rendition != nil { return 4 }
        if color != nil { return 3 }
        return tone == nil ? 1 : 2
    }
    public var mode = Mode.hdr
    public var exposure = 0.0
    public var temperature = 6500.0
    public var tint = 0.0
    public var contrast = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    public var saturation = 0.0
    public var geometry = GeometrySettings()
    private var tone: HDRToneSettings?
    private var color: HDRColorSettings?
    private var rendition: HDRRenditionSettings?
    private var effects: HDRPhotoEffectsSettings?
    private var detail: HDRDetailSettings?
    private var look: HDRLookSettings?
    private var cameraDevelopment: HDRCameraDevelopmentSettings?

    public var toneSettings: HDRToneSettings {
        get { tone ?? HDRToneSettings() }
        set {
            guard tone != nil || !newValue.isDefault else { return }
            tone = newValue
            if newValue.curve.hasChannelCurves {
                color = color ?? HDRColorSettings(); rendition = rendition ?? HDRRenditionSettings()
                effects = effects ?? HDRPhotoEffectsSettings(); detail = detail ?? HDRDetailSettings(); look = look ?? HDRLookSettings()
            }
        }
    }
    public var colorSettings: HDRColorSettings {
        get { color ?? HDRColorSettings() }
        set {
            guard color != nil || !newValue.isDefault else { return }
            color = newValue
            if tone == nil { tone = HDRToneSettings() }
        }
    }
    public var renditionSettings: HDRRenditionSettings {
        get { rendition ?? HDRRenditionSettings() }
        set {
            guard rendition != nil || !newValue.isDefault else { return }
            rendition = newValue
            if tone == nil { tone = HDRToneSettings() }
            if color == nil { color = HDRColorSettings() }
        }
    }
    public var effectsSettings: HDRPhotoEffectsSettings {
        get { effects ?? HDRPhotoEffectsSettings() }
        set {
            guard effects != nil || !newValue.isDefault else { return }
            effects = newValue
            if tone == nil { tone = HDRToneSettings() }
            if color == nil { color = HDRColorSettings() }
            if rendition == nil { rendition = HDRRenditionSettings() }
        }
    }

    public var detailSettings: HDRDetailSettings {
        get { detail ?? HDRDetailSettings() }
        set {
            guard detail != nil || !newValue.isDefault else { return }
            detail = newValue
            if tone == nil { tone = HDRToneSettings() }
            if color == nil { color = HDRColorSettings() }
            if rendition == nil { rendition = HDRRenditionSettings() }
            if effects == nil { effects = HDRPhotoEffectsSettings() }
        }
    }

    public var lookSettings: HDRLookSettings {
        get { look ?? HDRLookSettings() }
        set {
            guard look != nil || !newValue.isDefault else { return }
            look = newValue
            if tone == nil { tone = HDRToneSettings() }
            if color == nil { color = HDRColorSettings() }
            if rendition == nil { rendition = HDRRenditionSettings() }
            if effects == nil { effects = HDRPhotoEffectsSettings() }
            if detail == nil { detail = HDRDetailSettings() }
        }
    }

    public var cameraDevelopmentSettings: HDRCameraDevelopmentSettings {
        get { cameraDevelopment ?? HDRCameraDevelopmentSettings() }
        set { if cameraDevelopment != nil || !newValue.isDefault { cameraDevelopment = newValue } }
    }

    public init() {}

    public var isValid: Bool {
        [exposure, temperature, tint, contrast, highlights, shadows, saturation].allSatisfy(\.isFinite) &&
        (-4...4).contains(exposure) && (2000...50000).contains(temperature) && (-150...150).contains(tint) &&
        (-100...100).contains(contrast) && (-100...100).contains(highlights) &&
        (-100...100).contains(shadows) && (-100...100).contains(saturation) && geometry.isValid &&
        (tone?.isValid ?? true) && (color?.isValid ?? true) && (rendition?.isValid ?? true) &&
        (effects?.isValid ?? true) && (detail?.isValid ?? true) && (look?.isValid ?? true) &&
        (cameraDevelopment?.isValid ?? true)
    }
    public var isIdentity: Bool {
        var base = self; base.tone = nil; base.color = nil; base.rendition = nil; base.effects = nil; base.detail = nil; base.look = nil
        base.cameraDevelopment = nil
        var neutral = HDRSettings(); neutral.mode = mode
        return base == neutral && (tone?.isIdentity ?? true) && (color?.isIdentity ?? true) &&
            (rendition?.isDefault ?? true) && (effects?.isIdentity ?? true) && (detail?.isDefault ?? true) &&
            lookSettings.isDefault && cameraDevelopmentSettings.isDefault
    }

    public mutating func reset() {
        let currentMode = mode, version = processingVersion, hasCameraDevelopment = cameraDevelopment != nil
        self = HDRSettings(); mode = currentMode
        if version >= 2 { tone = HDRToneSettings() }
        if version >= 3 { color = HDRColorSettings() }
        if version >= 4 { rendition = HDRRenditionSettings() }
        if version >= 5 { effects = HDRPhotoEffectsSettings() }
        if version >= 6 { detail = HDRDetailSettings() }
        if version >= 7 { look = HDRLookSettings() }
        if hasCameraDevelopment { cameraDevelopment = HDRCameraDevelopmentSettings() }
    }

    public var neutralGeometrySettings: HDRSettings {
        var neutral = self
        neutral.reset()
        neutral.geometry = geometry
        // 对比颜色时沿用同一镜头画框，避免畸变和自动裁切造成错位。
        neutral.cameraDevelopmentSettings.lensDistortion = cameraDevelopmentSettings.lensDistortion
        neutral.cameraDevelopmentSettings.lensTCA = cameraDevelopmentSettings.lensTCA
        neutral.cameraDevelopmentSettings.lensVignetting = cameraDevelopmentSettings.lensVignetting
        neutral.cameraDevelopmentSettings.lensAutoCrop = cameraDevelopmentSettings.lensAutoCrop
        neutral.cameraDevelopmentSettings.lensProfile = cameraDevelopmentSettings.lensProfile
        return neutral
    }

    public static func enabling(stored: HDRSettings?, initial: HDRSettings, sourceIsHDR: Bool) throws -> HDRSettings {
        guard sourceIsHDR else { throw ModeError.unsupportedSource }
        if var existing = stored {
            guard existing.isValid else { throw ModeError.invalidSettings }
            existing.mode = .hdr
            return existing
        }
        var result = initial
        result.mode = .hdr; result.temperature = 6500; result.tint = 0
        guard result.isValid else { throw ModeError.invalidSettings }
        return result
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case recordVersion = "record_version", processingVersion = "hdr_processing_version"
        case mode, exposure = "exposure_ev", temperature = "relative_temperature", tint = "relative_tint"
        case contrast, highlights, shadows, saturation, geometry, tone, color, rendition, effects, detail, look
        case cameraDevelopment = "camera_development"
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: HDRSettingsField.self).allKeys
        guard fields.allSatisfy({ CodingKeys(stringValue: $0.stringValue) != nil }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported HDR settings field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .recordVersion)
        let processing = try values.decode(Int.self, forKey: .processingVersion)
        guard (1...8).contains(processing), version == (processing == 8 ? 9 : values.contains(.cameraDevelopment) ? 8 : processing),
              values.contains(.tone) == (processing >= 2), values.contains(.color) == (processing >= 3),
              values.contains(.rendition) == (processing >= 4), values.contains(.effects) == (processing >= 5),
              values.contains(.detail) == (processing >= 6), values.contains(.look) == (processing >= 7) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported HDR settings version"))
        }
        mode = try values.decode(Mode.self, forKey: .mode)
        exposure = try values.decode(Double.self, forKey: .exposure)
        temperature = try values.decode(Double.self, forKey: .temperature)
        tint = try values.decode(Double.self, forKey: .tint)
        contrast = try values.decode(Double.self, forKey: .contrast)
        highlights = try values.decode(Double.self, forKey: .highlights)
        shadows = try values.decode(Double.self, forKey: .shadows)
        saturation = try values.decode(Double.self, forKey: .saturation)
        geometry = try values.decode(GeometrySettings.self, forKey: .geometry)
        if processing >= 2 { tone = try values.decode(HDRToneSettings.self, forKey: .tone) }
        if processing >= 3 { color = try values.decode(HDRColorSettings.self, forKey: .color) }
        if processing >= 4 { rendition = try values.decode(HDRRenditionSettings.self, forKey: .rendition) }
        if processing >= 5 { effects = try values.decode(HDRPhotoEffectsSettings.self, forKey: .effects) }
        if processing >= 6 { detail = try values.decode(HDRDetailSettings.self, forKey: .detail) }
        if processing >= 7 { look = try values.decode(HDRLookSettings.self, forKey: .look) }
        if values.contains(.cameraDevelopment) { cameraDevelopment = try values.decode(HDRCameraDevelopmentSettings.self, forKey: .cameraDevelopment) }
        guard isValid, processingVersion == processing else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid HDR settings parameters"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(recordVersion, forKey: .recordVersion)
        try values.encode(processingVersion, forKey: .processingVersion)
        try values.encode(mode, forKey: .mode)
        try values.encode(exposure, forKey: .exposure)
        try values.encode(temperature, forKey: .temperature)
        try values.encode(tint, forKey: .tint)
        try values.encode(contrast, forKey: .contrast)
        try values.encode(highlights, forKey: .highlights)
        try values.encode(shadows, forKey: .shadows)
        try values.encode(saturation, forKey: .saturation)
        try values.encode(geometry, forKey: .geometry)
        try values.encodeIfPresent(tone, forKey: .tone)
        try values.encodeIfPresent(color, forKey: .color)
        try values.encodeIfPresent(rendition, forKey: .rendition)
        try values.encodeIfPresent(effects, forKey: .effects)
        try values.encodeIfPresent(detail, forKey: .detail)
        try values.encodeIfPresent(look, forKey: .look)
        try values.encodeIfPresent(cameraDevelopment, forKey: .cameraDevelopment)
    }
}
