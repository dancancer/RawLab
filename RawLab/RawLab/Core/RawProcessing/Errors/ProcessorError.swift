import Foundation

extension Sony2FujiProcessor {
    enum ProcessorError: LocalizedError {
        case metadataUnavailable, invalidDimensions
        case sessionCreateFailed(String), processFailed(String), localizedFailure(String)
        case outputIO, bufferCopyFailed, rasterDecodeFailed, invalidExportSize

        var errorDescription: String? {
            switch self {
            case .metadataUnavailable: return L10n.text("Image metadata unavailable.")
            case .invalidDimensions: return L10n.text("Image metadata has invalid dimensions.")
            case .sessionCreateFailed(let message):
                return L10n.format("Sony2Fuji session create failed: %@", String(describing: message))
            case .processFailed(let message): return L10n.format("处理失败：%@", message)
            case .localizedFailure(let message): return message
            case .outputIO: return L10n.text("无法写入成片，请检查输出位置和剩余空间。")
            case .bufferCopyFailed: return L10n.text("Sony2Fuji output copy failed.")
            case .rasterDecodeFailed: return L10n.text("Raster decode failed.")
            case .invalidExportSize: return L10n.text("导出长边必须为 1-65535 像素。")
            }
        }
    }

    func processingFailure(_ status: sony2fuji_status, input: URL? = nil, look: URL? = nil,
                           output: URL? = nil) -> ProcessorError {
        switch status {
        case SONY2FUJI_STATUS_OUTPUT_IO_ERROR: return .outputIO
        case SONY2FUJI_STATUS_IO_ERROR:
            return .localizedFailure(L10n.text("无法读取或写入文件，请检查路径和访问权限。"))
        case SONY2FUJI_STATUS_UNSUPPORTED:
            return .localizedFailure(L10n.text("不支持此照片、外观或处理方式。请检查文件兼容性和处理设置。"))
        case SONY2FUJI_STATUS_INVALID_ARGUMENT:
            if let output, [input, look].compactMap({ $0 }).contains(where: { aliases($0, output) }) {
                return .localizedFailure(L10n.text("不能覆盖原始文件。"))
            }
            return .localizedFailure(L10n.text("参数或输出路径无效。"))
        default: return .processFailed(statusMessage(status))
        }
    }

    func displayImageFailure(_ status: sony2fuji_status) -> ProcessorError {
        switch status {
        case SONY2FUJI_STATUS_UNSUPPORTED:
            return .localizedFailure(L10n.text("普通图像仅支持不透明的 8-bit SDR JPEG、PNG、TIFF 或 HEIF。"))
        case SONY2FUJI_STATUS_IO_ERROR:
            return .localizedFailure(L10n.text("无法读取照片，请检查文件和访问权限。"))
        case SONY2FUJI_STATUS_OUT_OF_MEMORY:
            return .localizedFailure(L10n.text("内存不足，无法解码普通图片。"))
        default:
            return .localizedFailure(L10n.format("无法解码普通图片：%@", statusMessage(status)))
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
