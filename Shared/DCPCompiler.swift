import Foundation

enum DCPCompilerError: Error, LocalizedError, Equatable {
    case malformed, tooLarge, invalidCalibration, missingToneCurve, automaticBlack
    case tripleIlluminant, unsupportedStages, invalidTable, invalidToneCurve, invalidExposure

    var errorDescription: String? {
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

    init(reason: sony2fuji_dcp_error) {
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

struct DCPImportOptions: Equatable {
    var toneCurveJSON: Data?
    var omitAutomaticBlack: Bool

    init(toneCurveJSON: Data? = nil, omitAutomaticBlack: Bool = false) {
        self.toneCurveJSON = toneCurveJSON
        self.omitAutomaticBlack = omitAutomaticBlack
    }
}

enum DCPCompiler {
    private static let maxSourceBytes = 128 * 1024 * 1024

    static func compile(source: URL, options: DCPImportOptions = .init()) throws -> Data {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxSourceBytes + 1) ?? Data()
        return try compile(data: data, sourceName: source.lastPathComponent, options: options)
    }

    static func compile(data: Data, sourceName: String, options: DCPImportOptions = .init()) throws -> Data {
        var blob = sony2fuji_blob()
        defer { sony2fuji_release_blob(&blob) }
        var reason = SONY2FUJI_DCP_ERROR_NONE
        let status = sourceName.withCString { name in
            data.withUnsafeBytes { bytes in
                let compile = { (curve: UnsafeRawPointer?, curveSize: Int) in
                    sony2fuji_compile_dcp_with_options(bytes.baseAddress, bytes.count, name,
                                                       curve, curveSize,
                                                       options.omitAutomaticBlack ? 1 : 0,
                                                       &blob, &reason)
                }
                guard let curve = options.toneCurveJSON else { return compile(nil, 0) }
                return curve.withUnsafeBytes { curveBytes in
                    compile(curveBytes.baseAddress, curveBytes.count)
                }
            }
        }
        guard status == SONY2FUJI_STATUS_OK else {
            if reason != SONY2FUJI_DCP_ERROR_NONE { throw DCPCompilerError(reason: reason) }
            if status == SONY2FUJI_STATUS_OUT_OF_MEMORY {
                throw POSIXError(.ENOMEM)
            }
            throw DCPCompilerError.malformed
        }
        guard let bytes = blob.data, blob.size_bytes > 0 else { throw DCPCompilerError.malformed }
        return Data(bytes: bytes, count: blob.size_bytes)
    }
}
