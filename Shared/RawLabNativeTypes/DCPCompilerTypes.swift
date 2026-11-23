@_exported import CSony2Fuji
import RawLabKit
import Foundation

public enum DCPCompilerError: Error, LocalizedError, Equatable, Sendable {
    case malformed, tooLarge, invalidCalibration, missingToneCurve, automaticBlack
    case tripleIlluminant, unsupportedStages, invalidTable, invalidToneCurve, invalidExposure

    public var errorDescription: String? {
        switch self {
        case .malformed: return L10n.text("DCP 文件损坏，或使用了不支持的 TIFF 结构。")
        case .tooLarge: return L10n.text("DCP 文件或外观数据超过安全大小限制。")
        case .invalidCalibration: return L10n.text("DCP 缺少唯一、有效的 D65 ColorMatrix/ForwardMatrix，无法转换。")
        case .missingToneCurve: return L10n.text("DCP 没有内嵌色调曲线。")
        case .automaticBlack: return L10n.text("DCP 要求自动黑位处理。")
        case .tripleIlluminant: return L10n.text("DCP 使用三光源 HueSatMap，暂不支持转换。")
        case .unsupportedStages: return L10n.text("DCP 包含暂不支持的空间增益、HDR 或 RGB 表处理，无法转换。")
        case .invalidTable: return L10n.text("DCP 的 HueSatMap/LookTable 数据、维度或编码不受支持。")
        case .invalidToneCurve: return L10n.text("DCP 曲线无效；需要 2 至 8192 个有限、范围为 0 至 1 且横坐标递增的点。")
        case .invalidExposure: return L10n.text("DCP 曝光偏移无效；需要 -16 至 +16 EV 的有限数值。")
        }
    }

    public init(reason: sony2fuji_dcp_error) {
        switch reason {
        case SONY2FUJI_DCP_ERROR_TOO_LARGE: self = .tooLarge
        case SONY2FUJI_DCP_ERROR_INVALID_CALIBRATION: self = .invalidCalibration
        case SONY2FUJI_DCP_ERROR_MISSING_TONE_CURVE: self = .missingToneCurve
        case SONY2FUJI_DCP_ERROR_AUTOMATIC_BLACK: self = .automaticBlack
        case SONY2FUJI_DCP_ERROR_TRIPLE_ILLUMINANT: self = .tripleIlluminant
        case SONY2FUJI_DCP_ERROR_UNSUPPORTED_STAGES: self = .unsupportedStages
        case SONY2FUJI_DCP_ERROR_INVALID_TABLE: self = .invalidTable
        case SONY2FUJI_DCP_ERROR_INVALID_TONE_CURVE: self = .invalidToneCurve
        case SONY2FUJI_DCP_ERROR_INVALID_EXPOSURE: self = .invalidExposure
        default: self = .malformed
        }
    }
}

public struct DCPImportOptions: Equatable, Sendable {
    public var toneCurveJSON: Data?
    public var omitAutomaticBlack: Bool

    public init(toneCurveJSON: Data? = nil, omitAutomaticBlack: Bool = false) {
        self.toneCurveJSON = toneCurveJSON
        self.omitAutomaticBlack = omitAutomaticBlack
    }
}
