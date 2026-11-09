import Foundation

extension Sony2FujiProcessor {
    enum ProcessorError: LocalizedError {
        case metadataUnavailable, invalidDimensions
        case sessionCreateFailed(String)
        case processFailed(String, status: sony2fuji_status? = nil)
        case nativeFailure(sony2fuji_status, String)
        case outputIO, bufferCopyFailed, rasterDecodeFailed, invalidExportSize

        var diagnosticStatus: sony2fuji_status? {
            switch self {
            case .processFailed(_, let status): return status
            case .nativeFailure(let status, _): return status
            case .outputIO: return SONY2FUJI_STATUS_OUTPUT_IO_ERROR
            default: return nil
            }
        }

        var errorDescription: String? {
            switch self {
            case .metadataUnavailable: return L10n.text("Image metadata unavailable.")
            case .invalidDimensions: return L10n.text("Image metadata has invalid dimensions.")
            case .sessionCreateFailed(let message):
                return L10n.format("Sony2Fuji session create failed: %@", String(describing: message))
            case .processFailed(let message, _): return L10n.format("处理失败：%@", message)
            case .nativeFailure(_, let message): return message
            case .outputIO: return L10n.text("无法写入成片，请检查输出位置和剩余空间。")
            case .bufferCopyFailed: return L10n.text("Sony2Fuji output copy failed.")
            case .rasterDecodeFailed: return L10n.text("Raster decode failed.")
            case .invalidExportSize: return L10n.text("导出长边必须为 1-65535 像素。")
            }
        }
    }

    func processingFailure(_ status: sony2fuji_status, input: URL? = nil, look: URL? = nil,
                           output: URL? = nil, session: OpaquePointer? = nil) -> ProcessorError {
        if let session, let message = sony2fuji_session_x3f_error(session), message.pointee != 0 {
            return .processFailed(String(cString: message), status: status)
        }
        switch status {
        case SONY2FUJI_STATUS_OUTPUT_IO_ERROR: return .outputIO
        case SONY2FUJI_STATUS_IO_ERROR:
            return .nativeFailure(status, L10n.text("无法读取或写入文件，请检查路径和访问权限。"))
        case SONY2FUJI_STATUS_UNSUPPORTED:
            return .nativeFailure(status, L10n.text("不支持此照片、外观或处理方式。请检查文件兼容性和处理设置。"))
        case SONY2FUJI_STATUS_INVALID_ARGUMENT:
            if let output, [input, look].compactMap({ $0 }).contains(where: { aliases($0, output) }) {
                return .nativeFailure(status, L10n.text("不能覆盖原始文件。"))
            }
            return .nativeFailure(status, L10n.text("参数或输出路径无效。"))
        default: return .processFailed(statusMessage(status), status: status)
        }
    }

    func displayImageFailure(_ status: sony2fuji_status) -> ProcessorError {
        switch status {
        case SONY2FUJI_STATUS_UNSUPPORTED:
            return .nativeFailure(status, L10n.text("请选择不透明的 SDR 图像：8 位 JPEG、PNG、TIFF、HEIF，或 16 位 RGB PNG、TIFF。"))
        case SONY2FUJI_STATUS_IO_ERROR:
            return .nativeFailure(status, L10n.text("无法读取照片，请检查文件和访问权限。"))
        case SONY2FUJI_STATUS_OUT_OF_MEMORY:
            return .nativeFailure(status, L10n.text("内存不足，无法解码普通图片。"))
        default:
            return .nativeFailure(status, L10n.format("无法解码普通图片：%@", statusMessage(status)))
        }
    }

    private func aliases(_ source: URL, _ destination: URL) -> Bool {
        if source.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL {
            return true
        }
        guard let a = try? FileManager.default.attributesOfItem(atPath: source.path),
              let b = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let aDevice = a[.systemNumber] as? NSNumber, let bDevice = b[.systemNumber] as? NSNumber,
              let aFile = a[.systemFileNumber] as? NSNumber, let bFile = b[.systemFileNumber] as? NSNumber else { return false }
        return aDevice == bDevice && aFile == bFile
    }
}
