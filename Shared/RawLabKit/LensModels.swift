import Foundation
import ImageIO

public enum LensProfileMode: String, Codable, CaseIterable, Sendable {
    case automatic, manual
}

public struct LensCorrectionSettings: Codable, Equatable, Sendable {
    public static let defringeAmountRange: ClosedRange<Double> =
        AdjustmentFieldSpec.Fields.geometryLensDefringePurpleAmount.macosModel.closedRange!
    public static let defringeHueRange: ClosedRange<Double> =
        AdjustmentFieldSpec.Fields.geometryLensDefringePurpleHue.macosModel.closedRange!

    public var distortion = false
    public var tca = false
    public var vignetting = false
    public var autoCrop = true
    public var mode = LensProfileMode.automatic
    public var profileID: String?
    public var focalLength: Double?
    public var cropFactor: Double?
    public var defringePurpleAmount = 0.0
    public var defringePurpleHue = 50.0
    public var defringeGreenAmount = 0.0
    public var defringeGreenHue = 50.0

    public var isEnabled: Bool { distortion || tca || vignetting }
    public var hasDefringeSettings: Bool {
        defringePurpleAmount != 0.0 || defringePurpleHue != 50.0
            || defringeGreenAmount != 0.0 || defringeGreenHue != 50.0
    }
    public var isValid: Bool {
        defringePurpleAmount.isFinite && Self.defringeAmountRange.contains(defringePurpleAmount)
            && defringePurpleHue.isFinite && Self.defringeHueRange.contains(defringePurpleHue)
            && defringeGreenAmount.isFinite && Self.defringeAmountRange.contains(defringeGreenAmount)
            && defringeGreenHue.isFinite && Self.defringeHueRange.contains(defringeGreenHue)
    }
    public var coreProfileID: String {
        mode == .automatic ? "" : (profileID ?? "__rawlab_manual_selection_required__")
    }

    public init(distortion: Bool = false, tca: Bool = false, autoCrop: Bool = true, mode: LensProfileMode = .automatic,
                profileID: String? = nil, focalLength: Double? = nil, cropFactor: Double? = nil, vignetting: Bool = false,
                defringePurpleAmount: Double = 0.0, defringePurpleHue: Double = 50.0,
                defringeGreenAmount: Double = 0.0, defringeGreenHue: Double = 50.0) {
        self.distortion = distortion
        self.tca = tca
        self.autoCrop = autoCrop
        self.mode = mode
        self.profileID = profileID
        self.focalLength = focalLength
        self.cropFactor = cropFactor
        self.vignetting = vignetting
        self.defringePurpleAmount = defringePurpleAmount == 0 ? 0 : defringePurpleAmount
        self.defringePurpleHue = defringePurpleHue == 0 ? 0 : defringePurpleHue
        self.defringeGreenAmount = defringeGreenAmount == 0 ? 0 : defringeGreenAmount
        self.defringeGreenHue = defringeGreenHue == 0 ? 0 : defringeGreenHue
    }

    private enum CodingKeys: String, CodingKey {
        case distortion, tca, vignetting, autoCrop, mode, profileID, focalLength, cropFactor
        case defringePurpleAmount, defringePurpleHue, defringeGreenAmount, defringeGreenHue
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func decodeChecked(_ key: CodingKeys, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
            guard let raw = try values.decodeIfPresent(Double.self, forKey: key) else { return fallback }
            guard raw.isFinite, range.contains(raw) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Out of range defringe parameter")
            }
            return raw == 0 ? 0 : raw
        }
        distortion = try values.decodeIfPresent(Bool.self, forKey: .distortion) ?? false
        tca = try values.decodeIfPresent(Bool.self, forKey: .tca) ?? false
        vignetting = values.contains(.vignetting) ? try values.decode(Bool.self, forKey: .vignetting) : false
        autoCrop = try values.decodeIfPresent(Bool.self, forKey: .autoCrop) ?? true
        mode = try values.decodeIfPresent(LensProfileMode.self, forKey: .mode) ?? .automatic
        profileID = try values.decodeIfPresent(String.self, forKey: .profileID)
        focalLength = try values.decodeIfPresent(Double.self, forKey: .focalLength)
        cropFactor = try values.decodeIfPresent(Double.self, forKey: .cropFactor)
        defringePurpleAmount = try decodeChecked(.defringePurpleAmount, default: 0.0, range: Self.defringeAmountRange)
        defringePurpleHue = try decodeChecked(.defringePurpleHue, default: 50.0, range: Self.defringeHueRange)
        defringeGreenAmount = try decodeChecked(.defringeGreenAmount, default: 0.0, range: Self.defringeAmountRange)
        defringeGreenHue = try decodeChecked(.defringeGreenHue, default: 50.0, range: Self.defringeHueRange)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(distortion, forKey: .distortion)
        try values.encode(tca, forKey: .tca)
        try values.encode(vignetting, forKey: .vignetting)
        try values.encode(autoCrop, forKey: .autoCrop)
        try values.encode(mode, forKey: .mode)
        try values.encodeIfPresent(profileID, forKey: .profileID)
        try values.encodeIfPresent(focalLength, forKey: .focalLength)
        try values.encodeIfPresent(cropFactor, forKey: .cropFactor)
        if defringePurpleAmount != 0.0 { try values.encode(defringePurpleAmount, forKey: .defringePurpleAmount) }
        if defringePurpleHue != 50.0 { try values.encode(defringePurpleHue, forKey: .defringePurpleHue) }
        if defringeGreenAmount != 0.0 { try values.encode(defringeGreenAmount, forKey: .defringeGreenAmount) }
        if defringeGreenHue != 50.0 { try values.encode(defringeGreenHue, forKey: .defringeGreenHue) }
    }
}

public struct LensCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let maker: String
    public let model: String
    public let hasDistortion: Bool
    public let hasTCA: Bool
    public let isMatch: Bool
    public var hasVignetting: Bool

    public init(id: String, maker: String, model: String, hasDistortion: Bool, hasTCA: Bool, isMatch: Bool, hasVignetting: Bool = false) {
        self.id = id
        self.maker = maker
        self.model = model
        self.hasDistortion = hasDistortion
        self.hasTCA = hasTCA
        self.isMatch = isMatch
        self.hasVignetting = hasVignetting
    }

    public var title: String { model.localizedCaseInsensitiveContains(maker) ? model : "\(maker) \(model)" }
}

public enum LensMatchState: Equatable, Sendable {
    case off
    case matched
    case noDatabase
    case noCamera
    case ambiguous
    case noCalibration
    case missingFocalLength
    case embeddedGeometry
    case unsupportedInput
    case unmatched
}

public struct DisplayLensMetadata: Equatable, Sendable {
    public let sourceURL: URL
    public var cameraMake = ""
    public var cameraModel = ""
    public var lensMake = ""
    public var lensModel = ""
    public var focalLength: Double = 0
    public var aperture: Double = 0
    public var cropFactor: Double = 0
    public var orientation: Int32 = 1

    public init(sourceURL: URL, cameraMake: String = "", cameraModel: String = "", lensMake: String = "",
                lensModel: String = "", focalLength: Double = 0, aperture: Double = 0,
                cropFactor: Double = 0, orientation: Int32 = 1) {
        self.sourceURL = sourceURL
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensMake = lensMake
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.aperture = aperture
        self.cropFactor = cropFactor
        self.orientation = orientation
    }

    public static func read(_ url: URL) -> DisplayLensMetadata {
        var result = DisplayLensMetadata(sourceURL: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return result }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let auxiliary = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        func text(_ value: Any?, limit: Int) -> String {
            let value = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return String(decoding: Array(value.utf8.prefix(limit)), as: UTF8.self)
        }
        func number(_ value: Any?) -> Double {
            guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else { return 0 }
            return number.doubleValue
        }
        result.cameraMake = text(tiff[kCGImagePropertyTIFFMake], limit: 120)
        result.cameraModel = text(tiff[kCGImagePropertyTIFFModel], limit: 120)
        result.lensMake = text(exif[kCGImagePropertyExifLensMake], limit: 120)
        result.lensModel = text(exif[kCGImagePropertyExifLensModel] ?? auxiliary[kCGImagePropertyExifAuxLensModel], limit: 248)
        result.focalLength = number(exif[kCGImagePropertyExifFocalLength])
        result.aperture = number(exif[kCGImagePropertyExifFNumber])
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        result.orientation = (1...8).contains(orientation) ? orientation : 1
        return result
    }

    public static func supportsOverride(_ settings: LensCorrectionSettings) -> Bool {
        (settings.focalLength.map { $0.isFinite && (0.1...10000).contains($0) } ?? true) &&
        (settings.cropFactor.map { $0.isFinite && (0.1...100).contains($0) } ?? true)
    }

    public func applying(_ settings: LensCorrectionSettings) -> DisplayLensMetadata? {
        guard Self.supportsOverride(settings) else { return nil }
        var value = self
        value.focalLength = settings.focalLength ?? focalLength
        value.cropFactor = settings.cropFactor ?? cropFactor
        return value
    }
}

public struct LensInfo: Equatable, Sendable {
    public let state: LensMatchState
    public let detectedLens: String
    public let selectedLens: String
    public let focalLength: Float
    public let appliedDistortion: Bool
    public let appliedTCA: Bool
    public let cropScale: Float
    public let candidates: [LensCandidate]
    public var appliedVignetting: Bool
    public var sourceMetadata: DisplayLensMetadata?

    public init(state: LensMatchState, detectedLens: String, selectedLens: String, focalLength: Float = 0,
                appliedDistortion: Bool, appliedTCA: Bool, cropScale: Float, candidates: [LensCandidate],
                appliedVignetting: Bool = false, sourceMetadata: DisplayLensMetadata? = nil) {
        self.state = state
        self.detectedLens = detectedLens
        self.selectedLens = selectedLens
        self.focalLength = focalLength
        self.appliedDistortion = appliedDistortion
        self.appliedTCA = appliedTCA
        self.cropScale = cropScale
        self.candidates = candidates
        self.appliedVignetting = appliedVignetting
        self.sourceMetadata = sourceMetadata
    }

    public var message: String {
        switch state {
        case .off: return L10n.text("镜头校正已关闭")
        case .matched:
            let applied = [appliedDistortion ? L10n.text("畸变") : nil,
                           appliedTCA ? L10n.text("横向色差") : nil,
                           appliedVignetting ? L10n.text("暗角校正") : nil].compactMap { $0 }
            return applied.isEmpty ? L10n.text("已匹配镜头") : L10n.format("已校正%@", applied.joined(separator: " / "))
        case .noDatabase: return L10n.text("镜头数据库不可用")
        case .noCamera: return L10n.text("未找到机身或传感器尺寸信息")
        case .ambiguous: return L10n.text("有多个匹配镜头，请手动选择")
        case .noCalibration: return L10n.text("此镜头没有所选校正的标定数据")
        case .missingFocalLength: return L10n.text("照片缺少有效焦距，未应用校正")
        case .embeddedGeometry: return L10n.text("DNG 已执行内嵌 Stage3 处理，未叠加校正")
        case .unsupportedInput: return L10n.text("此输入不支持镜头校正")
        case .unmatched: return L10n.text("未匹配镜头，请手动选择")
        }
    }
}
