import Foundation

enum RenderError: LocalizedError {
    case failed(String)
    case outputIO

    var errorDescription: String? {
        switch self {
        case .failed(let text): return text
        case .outputIO: return L10n.text("无法写入成片，请检查输出位置和剩余空间。")
        }
    }

    static func displayImage(_ status: sony2fuji_status) -> RenderError {
        switch status {
        case SONY2FUJI_STATUS_UNSUPPORTED:
            return .failed(L10n.text("普通图像仅支持不透明的 8-bit SDR JPEG、PNG、TIFF 或 HEIF。"))
        case SONY2FUJI_STATUS_IO_ERROR:
            return .failed(L10n.text("无法读取照片，请检查文件和访问权限。"))
        case SONY2FUJI_STATUS_OUT_OF_MEMORY:
            return .failed(L10n.text("内存不足，无法解码普通图片。"))
        default:
            return .failed(L10n.format("无法解码普通图片：%@", String(cString: sony2fuji_status_message(status))))
        }
    }

    static func processing(_ status: sony2fuji_status, input: URL, look: URL?, output: URL?) -> RenderError {
        switch status {
        case SONY2FUJI_STATUS_OUTPUT_IO_ERROR:
            return .outputIO
        case SONY2FUJI_STATUS_IO_ERROR:
            return .failed(L10n.text("无法读取或写入文件，请检查路径和访问权限。"))
        case SONY2FUJI_STATUS_UNSUPPORTED:
            return .failed(L10n.text("不支持此照片、外观或处理方式。请检查文件兼容性和处理设置。"))
        case SONY2FUJI_STATUS_INVALID_ARGUMENT:
            // 原生层仍负责拒绝覆盖；这里只区分覆盖保护和其他参数错误。
            if let output, aliases(input, output) || look.map({ aliases($0, output) }) == true {
                return .failed(L10n.text("不能覆盖原始文件。"))
            }
            return .failed(L10n.text("参数或输出路径无效。"))
        default:
            return .failed(L10n.format("处理失败：%@", String(cString: sony2fuji_status_message(status))))
        }
    }

    private static func aliases(_ source: URL, _ destination: URL) -> Bool {
        if source.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL {
            return true
        }
        guard let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              let destinationAttributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let sourceDevice = sourceAttributes[.systemNumber] as? NSNumber,
              let destinationDevice = destinationAttributes[.systemNumber] as? NSNumber,
              let sourceFile = sourceAttributes[.systemFileNumber] as? NSNumber,
              let destinationFile = destinationAttributes[.systemFileNumber] as? NSNumber else { return false }
        return sourceDevice == destinationDevice && sourceFile == destinationFile
    }
}
