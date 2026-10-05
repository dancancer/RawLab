import AppKit
import ImageIO
import Foundation

enum ExposureMode: String, CaseIterable, Identifiable {
    case scene = "标准显影"
    case preview = "匹配内嵌预览"
    case sensor = "传感器基准"
    var id: String { rawValue }
    var core: sony2fuji_raw_exposure_mode {
        switch self {
        case .scene: return SONY2FUJI_EXPOSURE_SCENE
        case .preview: return SONY2FUJI_EXPOSURE_PREVIEW
        case .sensor: return SONY2FUJI_EXPOSURE_SENSOR
        }
    }
}

struct RenderedImage {
    let image: CGImage
    let isFullResolution: Bool
    let clipping: CGImage
    let histogram: [[Double]]
    let shadows: Double
    let highlights: Double
    let baselineEV: Double
    let metadataEV: Double
    let asShotWhiteBalance: WhiteBalance?
}

enum RenderError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
}

final class RenderEngine {
    private var session: OpaquePointer?
    private let gpuMode: sony2fuji_gpu_mode
    init(gpuMode: sony2fuji_gpu_mode = SONY2FUJI_GPU_AUTO) throws {
        self.gpuMode = gpuMode
        guard sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed("无法创建处理会话")
        }
        var config = sony2fuji_gpu_config()
        config.version = SONY2FUJI_GPU_CONFIG_VERSION
        config.struct_size = UInt32(MemoryLayout<sony2fuji_gpu_config>.size)
        config.mode = gpuMode
        _ = sony2fuji_session_set_gpu_config(session, &config)
    }
    deinit { sony2fuji_session_destroy(session) }

    func render(_ url: URL, settings: Adjustments, lut: URL?, edge: Int?, output: URL? = nil, interactive: Bool = false) throws -> RenderedImage? {
        guard sony2fuji_session_set_interactive_preview(session, interactive && output == nil ? 1 : 0) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed("无效的预览模式")
        }
        guard sony2fuji_session_set_raw_exposure_mode(session, settings.exposureMode.core) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed("无效的曝光基准")
        }
        var request = sony2fuji_request()
        request.version = SONY2FUJI_REQUEST_VERSION
        request.struct_size = UInt32(MemoryLayout<sony2fuji_request>.size)
        request.input_type = SONY2FUJI_INPUT_RAW
        request.wb_mode = SONY2FUJI_WB_CAMERA
        request.wb_mul = (1,1,1,1)
        settings.apply(to: &request)
        request.lut_strength = lut == nil ? 0 : Float(settings.strength)
        request.intent = edge == nil ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW
        request.size_mode = SONY2FUJI_SIZE_NATIVE
        if let edge { request.preview_long_edge = UInt32(edge) }
        request.output_target = output == nil ? SONY2FUJI_TARGET_BUFFER : SONY2FUJI_TARGET_FILE
        request.output_format = output == nil ? SONY2FUJI_OUTPUT_RGBA8 :
            (output!.pathExtension.lowercased() == "png" ? SONY2FUJI_OUTPUT_PNG : SONY2FUJI_OUTPUT_JPEG)
        request.jpeg_quality = 95
        var buffer = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&buffer) }
        let status = url.path.withCString { input in
            (lut?.path ?? "").withCString { lutPath in
                (output?.path ?? "").withCString { destination in
                    request.input_path = input
                    request.lut_path = lut == nil ? nil : lutPath
                    request.output_path = output == nil ? nil : destination
                    return sony2fuji_process(session, &request, &buffer)
                }
            }
        }
        guard status == SONY2FUJI_STATUS_OK else {
            let message = String(cString: sony2fuji_status_message(status))
            if status == SONY2FUJI_STATUS_IO_ERROR {
                throw RenderError.failed("无法读取或写入文件，请检查路径和访问权限。")
            }
            if status == SONY2FUJI_STATUS_UNSUPPORTED {
                throw RenderError.failed("不支持此 RAW 或外观文件。请选择兼容的 F-Gamut / F-Log2 CUBE 或有效的 .rlook 文件。")
            }
            if status == SONY2FUJI_STATUS_INVALID_ARGUMENT {
                throw RenderError.failed("参数或输出路径无效，不能覆盖原始 RAW。")
            }
            throw RenderError.failed("处理失败：\(message)")
        }
        if let output {
            try ExportMetadata.preserve(from: url, in: output)
            return nil
        }
        var baseline: Float = 0, metadata: Float = 0
        guard sony2fuji_session_get_raw_exposure(session, &baseline, &metadata) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed("无法读取基础曝光")
        }
        guard let pointer = buffer.data else { throw RenderError.failed("处理结果为空") }
        var temperature: Float = 0, tint: Float = 0
        let calibrated = sony2fuji_session_get_raw_white_balance(session, &temperature, &tint) == SONY2FUJI_STATUS_OK
        let cameraWhiteBalance = calibrated ? WhiteBalance(temperature: Double(temperature).rounded(), tint: Double(tint).rounded()) : nil
        let width = Int(buffer.width), height = Int(buffer.height)
        let data = Data(bytes: pointer, count: buffer.size_bytes)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: Int(buffer.stride_bytes), space: space,
                bitmapInfo: bitmap, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw RenderError.failed("无法显示处理结果") }
        var bins = [UInt32](repeating: 0, count: 768)
        var black: UInt32 = 0, white: UInt32 = 0
        var clippingBuffer = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&clippingBuffer) }
        guard sony2fuji_analyze_image(&buffer, gpuMode, &bins, &black, &white, &clippingBuffer) == SONY2FUJI_STATUS_OK,
              let clippingPixels = clippingBuffer.data else { throw RenderError.failed("无法计算直方图") }
        let histogram = (0..<3).map { channel in (0..<256).map { Double(bins[channel*256+$0]) } }
        let overlay = Data(bytes: clippingPixels, count: clippingBuffer.size_bytes)
        let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width*4, space: space, bitmapInfo: bitmap,
            provider: CGDataProvider(data: overlay as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return RenderedImage(image: image, isFullResolution: edge == nil, clipping: mask, histogram: histogram,
            shadows: Double(black)/Double(width*height), highlights: Double(white)/Double(width*height),
            baselineEV: Double(baseline), metadataEV: Double(metadata), asShotWhiteBalance: cameraWhiteBalance)
    }
}

struct Film: Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let url: URL
    static func bundled() -> [Film] {
        let root = Bundle.main.resourceURL!.appendingPathComponent("LUTs")
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "cube" }
            .map { Film(name: $0.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "FLog2_to_", with: "")
                .replacingOccurrences(of: "_65grid_V.1.00", with: "")
                .replacingOccurrences(of: "-", with: " "), url: $0) }
            .sorted { $0.name < $1.name }
    }
}
