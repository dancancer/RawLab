import RawLabKit
import AppKit
import ImageIO
import Foundation
import UniformTypeIdentifiers

extension ExportFormat {
    static func available(isHDR: Bool) -> [ExportFormat] {
        let sdr: [ExportFormat] = [.jpeg, .png, .renderedDNG]
        guard isHDR else { return sdr }
        return (HDRImage.heifExportAvailable ? [.hdrJPEG, .hdrHEIF] : [.hdrJPEG]) + sdr
    }

    var nativeFormat: sony2fuji_output_format? {
        switch self {
        case .hdrJPEG, .hdrHEIF: return nil
        case .jpeg: return SONY2FUJI_OUTPUT_JPEG
        case .png: return SONY2FUJI_OUTPUT_PNG
        case .renderedDNG: return SONY2FUJI_OUTPUT_DNG
        }
    }
}


struct RenderedImage {
    let image: CGImage
    let isFullResolution: Bool
    let clipping: CGImage?
    let histogram: [[Double]]
    let shadows: Double?
    let highlights: Double?
    let baselineEV: Double
    let metadataEV: Double
    let asShotWhiteBalance: WhiteBalance?
    let supportsRawNoiseReduction: Bool
    var lensInfo: LensInfo? = nil
    var nativeWidth: Int? = nil
    var nativeHeight: Int? = nil
    var hdr: HDRPresentation? = nil
}

struct PreviewStatistics {
    let histogram: [[Double]]
    let clipping: CGImage
    let shadows: Double
    let highlights: Double

    static func analyze(_ buffer: inout sony2fuji_buffer) -> PreviewStatistics? {
        var bins = [UInt32](repeating: 0, count: 768)
        var black: UInt32 = 0, white: UInt32 = 0
        var mask = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&mask) }
        // 显示像素已在 CPU；统计失败不改变照片渲染的 GPU 模式或丢弃照片。
        guard sony2fuji_analyze_image(&buffer, SONY2FUJI_GPU_OFF, &bins, &black, &white, &mask) == SONY2FUJI_STATUS_OK,
              let pixels = mask.data else { return nil }
        let width = Int(buffer.width), height = Int(buffer.height), count = Double(width * height)
        let histogram = (0..<3).map { channel in (0..<256).map { Double(bins[channel * 256 + $0]) } }
        guard count > 0, histogram.allSatisfy({ $0.reduce(0, +) == count }) else { return nil }
        let data = Data(bytes: pixels, count: mask.size_bytes)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: Int(mask.stride_bytes), space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return PreviewStatistics(histogram: histogram, clipping: image,
            shadows: Double(black) / count, highlights: Double(white) / count)
    }
}

struct RawWhiteBalanceCacheKey: Equatable {
    let file: URL
    let modified: Date?
    let size: UInt64?
    let fileNumber: UInt64

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        file = url.standardizedFileURL
        modified = attributes[.modificationDate] as? Date
        size = (attributes[.size] as? NSNumber)?.uint64Value
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

final class AIPreparation {
    private let lock = NSLock()
    private var cancelled = false
    let progress: (Int, UInt64, UInt64) -> Void
    init(progress: @escaping (Int, UInt64, UInt64) -> Void) { self.progress = progress }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func report(phase: Int, completed: UInt64, total: UInt64) -> Int32 {
        guard !isCancelled else { return 0 }
        progress(phase, completed, total)
        return isCancelled ? 0 : 1
    }
}

final class RenderEngine {
    private final class DisplayImage {
        var buffer = sony2fuji_buffer()
        var nativeSize: CGSize?
        var isProxy=false
        init(_ url: URL,edge: Int?,sources: HDRSourceCache) throws {
            if let info=try HDRSourceInfo.probe(url) {
                let image: HDRImage
                if let edge { image=try sources.preview(url,info:info,longEdge:edge) }
                else { sources.clear(); image=try HDRImage.decode(url,info:info,intent:SONY2FUJI_INTENT_FINAL) }
                let data=try HDRPresentation.makeSDRImage(image).dataProvider!.data!
                let count=CFDataGetLength(data)
                guard let owned=malloc(count) else { throw HDRDisplayFailure.invalidBuffer }
                memcpy(owned,CFDataGetBytePtr(data),count)
                buffer.data=owned
                buffer.width=UInt32(image.width); buffer.height=UInt32(image.height)
                buffer.stride_bytes=UInt32(image.width*4); buffer.size_bytes=count
                buffer.pixel_format=SONY2FUJI_PIXEL_RGBA8
                nativeSize=CGSize(width:image.nativeWidth,height:image.nativeHeight); isProxy=image.isProxy
                return
            }
            sources.clear()
            let status = url.path.withCString { sony2fuji_load_display_image($0, &buffer) }
            guard status == SONY2FUJI_STATUS_OK else {
                throw RenderError.displayImage(status)
            }
        }
        deinit { sony2fuji_release_buffer(&buffer) }
    }
    private var displayCache: (key: RawWhiteBalanceCacheKey, edge: Int?, image: DisplayImage)?
    var cachedRasterBytes: Int { Int(displayCache?.image.buffer.size_bytes ?? 0) }
    private let hdrSources=HDRSourceCache.shared

    static func isRasterInput(_ url: URL?) -> Bool {
        PhotoInputClassification.isRasterInput(url)
    }

    private func withInput(_ url: URL, options: inout sony2fuji_render_options_v1,
                           operation: (inout sony2fuji_render_options_v1) -> sony2fuji_status) throws -> sony2fuji_status {
        if Self.isRasterInput(url) {
            let key = try RawWhiteBalanceCacheKey(url)
            let edge=options.intent==SONY2FUJI_INTENT_PREVIEW && options.preview_long_edge>0 ? Int(options.preview_long_edge) : nil
            if displayCache?.key != key || (displayCache?.image.nativeSize != nil && displayCache?.edge != edge) {
                displayCache = (key,edge,try DisplayImage(url,edge:edge,sources:hdrSources))
            }
            if displayCache?.image.nativeSize == nil { hdrSources.clear() }
            let image = displayCache!.image.buffer
            options.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER
            options.input_pixels = image.data.map(UnsafeRawPointer.init)
            options.input_width = image.width
            options.input_height = image.height
            options.input_pixel_format = image.pixel_format
            options.input_color_space = SONY2FUJI_COLOR_SRGB
            options.input_is_linear = 0
        } else { hdrSources.clear() }
        return url.path.withCString { path in
            options.input_path = path
            return operation(&options)
        }
    }
    private var session: OpaquePointer?
    private let aiModelDirectory: URL?
    private let aiCacheDirectory: URL
    private let aiBackend: sony2fuji_ai_backend
    static var aiAvailable: Bool { sony2fuji_ai_available() != 0 }
    static var hdrCameraAIAvailable: Bool { sony2fuji_hdr_camera_ai_available() != 0 }
    static var bundledAIModel: URL? { Bundle.main.url(forResource: "DualDn", withExtension: nil, subdirectory: "AI") }
    private let gpuMode: sony2fuji_gpu_mode
    private let statisticsProvider: (inout sony2fuji_buffer) -> PreviewStatistics?
    static var x3fAvailable: Bool { sony2fuji_x3f_available() != 0 }
    static func isX3fInput(_ url: URL?) -> Bool { url?.pathExtension.lowercased() == "x3f" }
    static func isNormalX3f(_ url: URL, settings: Adjustments) -> Bool {
        url.path.withCString { sony2fuji_is_normal_x3f($0, settings.x3fMode.core) != 0 }
    }

    /// 覆盖保护复核：真实输出与原片或外观是同一文件（标准化同路径、符号链接或硬链接别名）时，
    /// 抛出与核心层拒绝覆盖一致的 INVALID_ARGUMENT 保护错误，绝不静默覆盖损毁原片。
    static func rejectSourceOverwrite(_ output: URL, input: URL, look: URL?) throws {
        if RenderError.aliases(input, output) || (look.map { RenderError.aliases($0, output) } ?? false) {
            throw RenderError.processing(SONY2FUJI_STATUS_INVALID_ARGUMENT, input: input, look: look, output: output)
        }
    }

    /// 与核心层发布语义一致（output_file_mode.h + raw_processor.cpp）：覆盖已存在的普通文件时
    /// 保留目标文件原有 POSIX 权限位，并以单次 rename 原子发布；目标为符号链接时替换链接本身，
    /// 不跟随写穿；失败统一映射为 RenderError.outputIO，不留裸 CocoaError。
    static func publish(staging: URL, to output: URL) throws {
        // 与核心一致：跟随符号链接 stat；目标已是普通文件时把其权限位带到暂存文件再发布。
        if let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
           attributes[.type] as? FileAttributeType == .typeRegular,
           let mode = attributes[.posixPermissions] as? NSNumber {
            Darwin.chmod(staging.path, mode_t(mode.int32Value & 0o777))
        }
        guard Darwin.rename(staging.path, output.path) == 0 else { throw RenderError.outputIO }
    }

    static func defaultSettings(for url: URL,
                                probeHDRSource: HDRSourceInfo.Probe = { try HDRSourceInfo.probe($0, onSDRFallback: $1) }) throws -> Adjustments {
        try defaultSettings(for: url, sourceIsHDR: probeHDRSource(url, {}) != nil)
    }
    static func defaultSettings(for url: URL, sourceIsHDR: Bool) throws -> Adjustments {
        var settings = Adjustments()
        if isRasterInput(url) { settings.exposureMode = .sensor }
        if isX3fInput(url) { settings.x3fMode = try x3fDefaultMode(for: url) }
        if sourceIsHDR { settings.hdr = HDRSettings() }
        return settings
    }
    static func x3fDefaultMode(for url: URL) throws -> X3fMode {
        var mode = SONY2FUJI_X3F_NORMAL
        let status = url.path.withCString { sony2fuji_x3f_default_mode($0, &mode) }
        guard status == SONY2FUJI_STATUS_OK else {
            if status == SONY2FUJI_STATUS_IO_ERROR {
                throw RenderError.processing(status, input: url, look: nil, output: nil)
            }
            throw RenderError.failed(L10n.format("无法正常显影 X3F：%@", String(cString: sony2fuji_status_message(status))))
        }
        return mode == SONY2FUJI_X3F_NORMAL ? .normal : .legacy
    }
    private let lensDatabaseURL: URL?
    private struct LensCatalogKey: Equatable {
        let url: URL
        let modified: Date?
        let size: Int?
    }
    private var lensCatalogKey: LensCatalogKey?
    private var lensCandidates: [LensCandidate] = []
    var metadataPreserver: (URL, URL, [CFString: Any]?) throws -> Void = { source, destination, fallback in
        try ExportMetadata.preserve(from: source, in: destination, fallbackSourceProperties: fallback)
    }
    init(gpuMode: sony2fuji_gpu_mode = SONY2FUJI_GPU_AUTO, lensDatabaseURL: URL? = nil,
         statisticsProvider: @escaping (inout sony2fuji_buffer) -> PreviewStatistics? = PreviewStatistics.analyze,
         aiModelDirectory: URL? = RenderEngine.bundledAIModel, aiCacheDirectory: URL? = nil,
         aiBackend: sony2fuji_ai_backend = SONY2FUJI_AI_AUTO) throws {
        self.gpuMode = gpuMode
        self.statisticsProvider = statisticsProvider
        self.lensDatabaseURL = lensDatabaseURL
        self.aiModelDirectory = aiModelDirectory
        self.aiBackend = aiBackend
        self.aiCacheDirectory = aiCacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/DualDn", isDirectory: true)
        MacBatchExportEnvironment.defaultX3fMode = RenderEngine.x3fDefaultMode(for:)
        try resetSession()
    }

    private func resetSession() throws {
        sony2fuji_session_destroy(session)
        session = nil
        lensCatalogKey = nil
        lensCandidates = []
        guard sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无法创建处理会话"))
        }
        var config = sony2fuji_gpu_config()
        config.version = SONY2FUJI_GPU_CONFIG_VERSION
        config.struct_size = UInt32(MemoryLayout<sony2fuji_gpu_config>.size)
        config.mode = gpuMode
        _ = sony2fuji_session_set_gpu_config(session, &config)
        if let database = lensDatabaseURL ?? Bundle.main.url(forResource: "Lensfun", withExtension: nil) {
            guard database.path.withCString({ sony2fuji_session_set_lens_database(session, $0) }) == SONY2FUJI_STATUS_OK else {
                sony2fuji_session_destroy(session); session = nil
                throw RenderError.failed(L10n.text("镜头数据库不可用"))
            }
        }
    }
    deinit { sony2fuji_session_destroy(session) }

    var lastBackend: sony2fuji_render_backend { sony2fuji_session_get_last_backend(session) }
    var lastAIBackend: String { String(cString: sony2fuji_session_get_ai_backend(session)) }
    var rawDecodeCount: UInt64 { sony2fuji_session_get_raw_decode_count(session) }

    private func validationMessage(for error: CanonicalEditRecipeError) -> String {
        switch error {
        case .invalidToneCurve: return L10n.text("无效的曲线参数")
        case .invalidColorGrading: return L10n.text("无效的颜色分级参数")
        case .invalidToneControls: return L10n.text("无效的黑白场或鲜艳度参数")
        case .invalidAtmosphere: return L10n.text("无效的清晰度或去朦胧参数")
        case .invalidHSL: return L10n.text("无效的 HSL 参数")
        case .invalidGeometry: return L10n.text("无效的几何参数")
        case .invalidPhotoEffects: return L10n.text("无效的暗角或颗粒参数")
        case .invalidWaveletDenoise: return L10n.text("无效或不可用的降噪参数")
        case .invalidChromaDenoise: return L10n.text("无效或不可用的色度降噪模式")
        case .invalidRawNoiseReduction: return L10n.text("无效的 RAW 降噪档位")
        case .invalidWhiteBalance: return L10n.text("无效的白平衡参数")
        }
    }

    private func applyProcessingOnly(_ identity: ProcessingIdentity) throws {
        let json = CanonicalEditRecipe.processingSessionStateJSON(processingVersion: identity.version)
        guard json.withCString({ sony2fuji_apply_params(session, $0) }) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("不支持此处理版本，原有记录未被覆盖。"))
        }
    }

    private func encodeSessionState(_ settings: Adjustments, isRaster: Bool, lut: URL?, includeDenoise: Bool,
                                    aiDenoiseBlend: Double? = nil,
                                    outputSharpening: OutputSharpening = .off) throws -> String {
        do {
            return try settings.sdrSessionStateJSON(
                isRaster: isRaster,
                lutPath: lut?.path,
                includeDenoise: includeDenoise,
                aiDenoiseBlend: aiDenoiseBlend,
                outputSharpening: outputSharpening
            )
        } catch let error as CanonicalEditRecipeError {
            throw RenderError.failed(validationMessage(for: error))
        } catch is EncodingError {
            throw RenderError.processing(SONY2FUJI_STATUS_INVALID_ARGUMENT)
        }
    }

    static func validateAIInput(_ url: URL, settings: Adjustments) throws {
        if settings.isHDREditing {
            guard hdrCameraAIAvailable, bundledAIModel != nil,
                  isHDRCameraAICandidate(info: try HDRSourceInfo.probeRAW(url), settings: settings) else {
                throw RenderError.aiFailed(L10n.text("此照片或构建尚不能使用 AI 降噪。"))
            }
            return
        }
        guard !isRasterInput(url) else { throw RenderError.failed(L10n.text("AI 降噪仅支持 RAW 照片。")) }
        guard !isNormalX3f(url, settings: settings) else {
            throw RenderError.failed(L10n.text("此 X3F 显影模式不支持 AI 降噪。"))
        }
        guard aiAvailable, bundledAIModel != nil else { throw RenderError.aiFailed(L10n.text("此构建未安装 AI 降噪模型。")) }
    }

    static func isHDRCameraAICandidate(info: HDRSourceInfo?, settings: Adjustments) -> Bool {
        info?.supportsBayerDevelopment == true &&
            settings.hdr?.cameraDevelopmentSettings.fbddLevel == 0 && settings.hdr?.cameraDevelopmentSettings.cameraProfile == nil
    }

    private func configureAI(enabled: Bool) throws {
        if enabled && (!Self.aiAvailable || aiModelDirectory == nil) {
            throw RenderError.aiFailed(L10n.text("此构建未安装 AI 降噪模型。"))
        }
        var config = sony2fuji_ai_denoise_config()
        config.version = SONY2FUJI_AI_DENOISE_CONFIG_VERSION
        config.struct_size = UInt32(MemoryLayout<sony2fuji_ai_denoise_config>.size)
        config.enabled = enabled ? 1 : 0
        config.backend = aiBackend
        let status = (aiModelDirectory?.path ?? "").withCString { model in
            aiCacheDirectory.path.withCString { cache in
                config.model_directory = model; config.cache_directory = cache
                return sony2fuji_session_set_ai_denoise(session, &config)
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { throw aiError(status) }
    }

    private func aiError(_ status: sony2fuji_status) -> RenderError {
        if status == SONY2FUJI_STATUS_CANCELLED { return .aiCancelled }
        let detail = String(cString: sony2fuji_session_get_ai_error(session))
        let message = detail.isEmpty ? String(cString: sony2fuji_status_message(status)) : detail
        if status == SONY2FUJI_STATUS_AI_NOT_READY {
            return .aiNotReady(L10n.text("请先完成此照片的 AI 降噪，再预览或导出。") + "\n" + message)
        }
        return .aiFailed(L10n.format("AI 降噪失败：%@", message))
    }

    private func withHDRCameraAI<T>(_ url: URL, settings: Adjustments, info: HDRSourceInfo?,
                                   operation: (String?) throws -> T) throws -> T {
        guard settings.hdrCameraAIEnabled else { return try operation(nil) }
        guard Self.hdrCameraAIAvailable, Self.isHDRCameraAICandidate(info: info, settings: settings) else {
            throw RenderError.aiFailed(L10n.text("此照片或构建尚不能使用 AI 降噪。"))
        }
        try applyProcessingOnly(settings.processing)
        try configureAI(enabled: true)
        do { return try operation(HDRImage.cameraAIKey(url, session: session)) }
        catch let error as HDRNativeError where error.reason == UInt32(SONY2FUJI_HDR_REASON_CAMERA_AI) {
            throw aiError(error.status)
        }
    }

    func prepareAI(_ url: URL, settings: Adjustments, progress: AIPreparation) throws {
        guard !progress.isCancelled else { throw RenderError.aiCancelled }
        if settings.isHDREditing {
            guard Self.hdrCameraAIAvailable,
                  Self.isHDRCameraAICandidate(info: try HDRSourceInfo.probeRAW(url), settings: settings) else {
                throw RenderError.aiFailed(L10n.text("此照片或构建尚不能使用 AI 降噪。"))
            }
            try applyProcessingOnly(settings.processing)
            try configureAI(enabled: true)
            let context = Unmanaged.passUnretained(progress).toOpaque()
            _ = sony2fuji_session_set_cancellation_callback(session, { context in
                guard let context else { return 0 }
                return Unmanaged<AIPreparation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
            }, context)
            defer { _ = sony2fuji_session_set_cancellation_callback(session, nil, nil) }
            let status = url.path.withCString { path in
                sony2fuji_hdr_prepare_camera_raw_ai(session, path, { context, phase, done, total in
                    guard let context else { return 0 }
                    return Unmanaged<AIPreparation>.fromOpaque(context).takeUnretainedValue()
                        .report(phase: Int(phase), completed: done, total: total)
                }, context, nil)
            }
            guard status == SONY2FUJI_STATUS_OK else { throw aiError(status) }
            guard !progress.isCancelled else { throw RenderError.aiCancelled }
            return
        }
        guard !Self.isRasterInput(url) else { throw RenderError.failed(L10n.text("AI 降噪仅支持 RAW 照片。")) }
        guard !Self.isNormalX3f(url, settings: settings) else {
            throw RenderError.failed(L10n.text("此 X3F 显影模式不支持 AI 降噪。"))
        }
        let editStateJSON = try encodeSessionState(settings, isRaster: false, lut: nil, includeDenoise: false)
        try configureAI(enabled: true)
        var options = sony2fuji_render_options_v1()
        options.version = UInt32(SONY2FUJI_RENDER_OPTIONS_V1_VERSION)
        options.struct_size = UInt32(MemoryLayout<sony2fuji_render_options_v1>.size)
        options.input_type = SONY2FUJI_INPUT_RAW
        options.intent = SONY2FUJI_INTENT_FINAL
        options.size_mode = SONY2FUJI_SIZE_NATIVE
        options.output_target = SONY2FUJI_TARGET_BUFFER
        options.output_format = SONY2FUJI_OUTPUT_RGBA8
        options.jpeg_quality = 95
        let context = Unmanaged.passUnretained(progress).toOpaque()
        let status = url.path.withCString { path in
            options.input_path = path
            return editStateJSON.withCString { json in
                sony2fuji_session_prepare_ai_json(session, &options, json, { context, phase, done, total in
                    guard let context else { return 0 }
                    return Unmanaged<AIPreparation>.fromOpaque(context).takeUnretainedValue()
                        .report(phase: Int(phase), completed: done, total: total)
                }, context)
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { throw aiError(status) }
        guard !progress.isCancelled else { throw RenderError.aiCancelled }
    }

    func autoExposure(_ url: URL, settings: Adjustments) throws -> Double {
        if let hdr = settings.hdr, hdr.mode == .hdr {
            guard gpuMode != SONY2FUJI_GPU_FORCE else {
                throw HDRNativeError(status: SONY2FUJI_STATUS_UNSUPPORTED,
                    reason: UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU), field: UInt32(SONY2FUJI_HDR_FIELD_SESSION))
            }
            let info = settings.hdrCameraAIEnabled ? try HDRSourceInfo.probeRAW(url) : nil
            return try withHDRCameraAI(url, settings: settings, info: info) { key in
                try hdrSources.autoExposure(url, settings: hdr, proRAWDecodeVersion: settings.proRAWDecodeVersion,
                    session: session, lensDatabase: lensDatabaseURL, cameraAIKey: key, processing: settings.processing.core)
            }
        }
        let isRaster = Self.isRasterInput(url)
        let activeSettings = isRaster ? settings.resolvedForRaster : settings
        let blend = (!isRaster && activeSettings.aiDenoiseEnabled) ? (activeSettings.aiDenoiseStrength / 100.0) : 1.0
        let editStateJSON = try encodeSessionState(activeSettings, isRaster: isRaster, lut: nil,
                                                   includeDenoise: false, aiDenoiseBlend: blend)
        try configureAI(enabled: !isRaster && activeSettings.aiDenoiseEnabled)
        var options = sony2fuji_render_options_v1()
        options.version = UInt32(SONY2FUJI_RENDER_OPTIONS_V1_VERSION)
        options.struct_size = UInt32(MemoryLayout<sony2fuji_render_options_v1>.size)
        options.input_type = SONY2FUJI_INPUT_RAW
        options.output_target = SONY2FUJI_TARGET_BUFFER
        options.output_format = SONY2FUJI_OUTPUT_RGBA8
        options.size_mode = SONY2FUJI_SIZE_NATIVE
        // 栅格测光仅采样有限像素，HDR 双图解码前也需限制尺寸。
        if isRaster {
            options.intent = SONY2FUJI_INTENT_PREVIEW
            options.preview_long_edge = 1280
        } else {
            options.intent = SONY2FUJI_INTENT_FINAL
        }
        var ev: Float = 0
        let status = try withInput(url, options: &options) { input in
            editStateJSON.withCString { json in
                sony2fuji_session_estimate_auto_exposure_json(session, &input, json, &ev)
            }
        }
        if status == SONY2FUJI_STATUS_AI_NOT_READY { throw aiError(status) }
        if status == SONY2FUJI_STATUS_UNSUPPORTED,
           sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_FORCE_GPU {
            throw RenderError.processing(status, session: session)
        }
        if !isRaster && activeSettings.masterRecipe != nil && status == SONY2FUJI_STATUS_UNSUPPORTED {
            throw RenderError.failed(L10n.text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"))
        }
        guard status == SONY2FUJI_STATUS_OK else { throw RenderError.failed(L10n.format("无法自动调整曝光：%@", String(describing: String(cString: sony2fuji_status_message(status))))) }
        return Double(ev)
    }

    func resolvedRenderSettings(_ url: URL, settings: Adjustments) throws -> ResolvedRenderSettings {
        if Self.isRasterInput(url) {
            // 批量可混合两类输入；相机专属状态不解释成普通图像的 RGB 白平衡或镜头参数。
            return ResolvedRenderSettings(settings: settings.resolvedForRaster, whiteBalance: nil)
        }
        guard settings.masterRecipe != nil else {
            return ResolvedRenderSettings(settings: settings, whiteBalance: nil)
        }
        var settings = settings
        var req = sony2fuji_recipe_wb_request()
        req.version = SONY2FUJI_RECIPE_WB_REQUEST_VERSION
        req.struct_size = UInt32(MemoryLayout<sony2fuji_recipe_wb_request>.size)
        req.processing_version = settings.processing.core
        req.x3f_mode = settings.x3fMode.core
        req.exposure_mode = settings.exposureMode.core
        req.recipe_active = 1
        req.recipe_strength = Float(settings.strength)
        req.custom_wb = settings.usesAsShotWhiteBalance ? 0 : 1
        req.temperature = Float(settings.temperature)
        req.tint = Float(settings.tint)
        var res = sony2fuji_recipe_wb_result()
        let status = url.path.withCString { pathPtr -> sony2fuji_status in
            req.input_path = pathPtr
            return sony2fuji_session_resolve_recipe_wb(session, &req, &res)
        }
        if status == SONY2FUJI_STATUS_UNSUPPORTED {
            throw RenderError.failed(L10n.text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"))
        }
        guard status == SONY2FUJI_STATUS_OK else {
            throw RenderError.processing(status, input: url, look: nil, output: nil)
        }
        if res.camera_calibrated != 0 {
            settings.resolveWhiteBalance(
                WhiteBalance(temperature: Double(res.camera_temperature), tint: Double(res.camera_tint))
            )
        }
        let whiteBalance = ResolvedNativeWhiteBalance(
            wbMode: res.wb_mode,
            temperature: res.wb_mode == SONY2FUJI_WB_TEMPERATURE ? res.temperature : 6500,
            tint: res.wb_mode == SONY2FUJI_WB_TEMPERATURE ? res.tint : 0
        )
        return ResolvedRenderSettings(settings: settings, whiteBalance: whiteBalance)
    }

    func resolvedSettings(_ url: URL, settings: Adjustments) throws -> Adjustments {
        try resolvedRenderSettings(url, settings: settings).settings
    }

    private func photoRenderPlan(_ url: URL, settings: Adjustments, lut: URL?, edge: Int?, output: URL?,
                                 interactive: Bool, exportLongEdge: Int?, viewportPreview: Bool,
                                 referenceLongEdge: Int? = nil,
                                 outputSharpening: OutputSharpening = .off) throws -> (settings: Adjustments, options: sony2fuji_render_options_v1, editStateJSON: String) {
        if let exportLongEdge, !(1...65535).contains(exportLongEdge) {
            throw RenderError.failed(L10n.text("导出长边必须为 1-65535 像素。"))
        }
        let isRaster = Self.isRasterInput(url)
        let activeSettings = isRaster ? settings.resolvedForRaster : settings
        if activeSettings.aiDenoiseEnabled && isRaster {
            throw RenderError.failed(L10n.text("AI 降噪仅支持 RAW 照片。"))
        }
        if activeSettings.aiDenoiseEnabled && Self.isNormalX3f(url, settings: activeSettings) {
            throw RenderError.failed(L10n.text("此 X3F 显影模式不支持 AI 降噪。"))
        }
        let effectiveSharpening: OutputSharpening = (output != nil && ExportFormat.forOutput(output!) != .renderedDNG)
            ? outputSharpening : .off
        let aiBlend = activeSettings.aiDenoiseEnabled ? (activeSettings.aiDenoiseStrength / 100.0) : 1.0
        let editStateJSON = try encodeSessionState(activeSettings, isRaster: isRaster, lut: lut,
                                                   includeDenoise: true, aiDenoiseBlend: aiBlend,
                                                   outputSharpening: effectiveSharpening)
        try configureAI(enabled: activeSettings.aiDenoiseEnabled)
        let allowsProxy = activeSettings.geometrySettings.isIdentity
        var options = sony2fuji_render_options_v1()
        options.version = UInt32(SONY2FUJI_RENDER_OPTIONS_V1_VERSION)
        options.struct_size = UInt32(MemoryLayout<sony2fuji_render_options_v1>.size)
        options.input_type = SONY2FUJI_INPUT_RAW
        options.intent = edge == nil ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW
        options.size_mode = SONY2FUJI_SIZE_NATIVE
        if output != nil, let exportLongEdge {
            options.intent = SONY2FUJI_INTENT_FINAL
            options.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE
            options.long_edge = UInt32(exportLongEdge)
        }
        // Q8：中性参考帧的 FINAL 基准只按长边上限降采样、绝不放大
        // （SIZE_LIMIT_LONG_EDGE），与 PREVIEW 的按需缩放语义区分开。
        // 参照帧封顶只适用于无输出文件的基准渲染；复用导出合同的 1-65535 校验。
        if edge == nil, let referenceLongEdge {
            guard output == nil, (1...65535).contains(referenceLongEdge) else {
                throw RenderError.failed(L10n.text("导出长边必须为 1-65535 像素。"))
            }
            options.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE
            options.long_edge = UInt32(referenceLongEdge)
        }
        if let edge { options.preview_long_edge = UInt32(edge) }
        options.interactive_preview = interactive && allowsProxy && output == nil ? 1 : 0
        options.viewport_preview = viewportPreview && edge != nil && output == nil ? 1 : 0
        options.output_target = output == nil ? SONY2FUJI_TARGET_BUFFER : SONY2FUJI_TARGET_FILE
        if let output {
            let format = ExportFormat.forOutput(output)
            guard let nativeFormat = format.nativeFormat else { throw RenderError.failed(format.hdrRequiredMessage) }
            options.output_format = nativeFormat
        } else {
            options.output_format = SONY2FUJI_OUTPUT_RGBA8
        }
        options.jpeg_quality = 95
        return (activeSettings, options, editStateJSON)
    }

    func sampleHSL(_ url: URL, settings: Adjustments, lut: URL?, edge: Int?, interactive: Bool,
                   revision: HSLTargetRevision, point: CGPoint) throws -> HSLTargetSample {
        if settings.isHDREditing {
            guard gpuMode != SONY2FUJI_GPU_FORCE else {
                throw HDRNativeError(status: SONY2FUJI_STATUS_UNSUPPORTED,
                    reason: UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU), field: UInt32(SONY2FUJI_HDR_FIELD_SESSION))
            }
            guard let session, let record = settings.hdr,
                  let info = try HDRSourceInfo.probe(url) ?? HDRSourceInfo.probeRAW(url, processing: settings.processing.core) else {
                throw HDRSettings.ModeError.unsupportedSource
            }
            if info.proRAW != nil { try ProRAWSource.validatedDecodeVersion(settings.proRAWDecodeVersion) }
            let previewEdge = edge ?? 2000
            let source = try withHDRCameraAI(url, settings: settings, info: info) { key in
                try hdrSources.preview(url, info: info, longEdge: previewEdge, session: session,
                    camera: record.cameraDevelopmentSettings, lensDatabase: lensDatabaseURL, cameraAIKey: key)
            }
            var options = try HDRImage.makeRenderOptions(intent: SONY2FUJI_INTENT_PREVIEW, longEdge: previewEdge)
            let editStateJSON = try HDRImage.hdrEditStateJSON(settings: record)
            return source.withPair {
                HSLTargetSample.capture(session: session, pair: $0, options: &options, editStateJSON: editStateJSON,
                                        revision: revision, x: point.x, y: point.y)
            }
        }
        let plan = try photoRenderPlan(url, settings: settings, lut: lut, edge: edge, output: nil,
            interactive: interactive, exportLongEdge: nil, viewportPreview: edge != nil)
        var options = plan.options
        var sample: HSLTargetSample?
        _ = try withInput(url, options: &options) { input in
            if let session {
                sample = HSLTargetSample.capture(session: session, options: &input, editStateJSON: plan.editStateJSON,
                    revision: revision, x: point.x, y: point.y)
            }
            return SONY2FUJI_STATUS_OK
        }
        guard let sample else { throw RenderError.failed(L10n.text("无法创建处理会话")) }
        return sample
    }

    struct WBProbeSample {
        let availability: sony2fuji_wb_probe_availability
        let temperature: Double
        let tint: Double
        let validPixelCount: Int
    }

    func sampleWBProbe(_ url: URL, settings: Adjustments, lut: URL?, edge: Int?, interactive: Bool,
                       point: CGPoint) throws -> WBProbeSample {
        let plan = try photoRenderPlan(url, settings: settings, lut: lut, edge: edge, output: nil,
            interactive: interactive, exportLongEdge: nil, viewportPreview: edge != nil)
        var options = plan.options
        var query = sony2fuji_wb_probe_query()
        query.version = UInt32(SONY2FUJI_WB_PROBE_VERSION)
        query.struct_size = UInt32(MemoryLayout<sony2fuji_wb_probe_query>.size)
        query.norm_x = Float(point.x)
        query.norm_y = Float(point.y)
        query.window_size = 3
        query.reserved = 0
        var result = sony2fuji_wb_probe_result()
        result.version = UInt32(SONY2FUJI_WB_PROBE_VERSION)
        result.struct_size = UInt32(MemoryLayout<sony2fuji_wb_probe_result>.size)
        let status = try withInput(url, options: &options) { input in
            guard let session else { return SONY2FUJI_STATUS_INVALID_ARGUMENT }
            return plan.editStateJSON.withCString { json in
                sony2fuji_session_sample_wb_probe_json(session, &input, json, &query, &result)
            }
        }
        if status == SONY2FUJI_STATUS_AI_NOT_READY { throw aiError(status) }
        if !Self.isRasterInput(url) && plan.settings.masterRecipe != nil && status == SONY2FUJI_STATUS_UNSUPPORTED &&
            sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_NONE {
            throw RenderError.failed(L10n.text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"))
        }
        guard status == SONY2FUJI_STATUS_OK else {
            throw RenderError.processing(status, input: url, look: lut, output: nil, session: session)
        }
        return WBProbeSample(
            availability: result.availability,
            temperature: Double(result.temperature),
            tint: Double(result.tint),
            validPixelCount: Int(result.valid_pixel_count)
        )
    }

    func migrateProcessing(_ url: URL, settings: Adjustments, lut: URL?,
                           cancellation: ProcessingMigrationCancellation) throws -> ProcessingMigrationOutcome {
        guard !settings.isHDREditing, !settings.activeAIDenoise, settings.masterRecipeID == nil else {
            throw RenderError.failed(L10n.text("此照片的调整保留原处理版本。"))
        }
        let plan = try photoRenderPlan(url, settings: settings, lut: lut, edge: nil, output: nil,
            interactive: false, exportLongEdge: nil, viewportPreview: false)
        var options = plan.options
        let context = Unmanaged.passUnretained(cancellation).toOpaque()
        _ = sony2fuji_session_set_cancellation_callback(session, { pointer in
            guard let pointer else { return 0 }
            return Unmanaged<ProcessingMigrationCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
        }, context)
        defer { _ = sony2fuji_session_set_cancellation_callback(session, nil, nil) }
        var native = sony2fuji_processing_migration_result()
        let status = try withInput(url, options: &options) { input in
            plan.editStateJSON.withCString { json in
                sony2fuji_session_migrate_processing_json(session, &input, json, &native)
            }
        }
        guard status == SONY2FUJI_STATUS_OK else {
            if status == SONY2FUJI_STATUS_UNSUPPORTED,
               sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_FORCE_GPU {
                throw RenderError.processing(status, session: session)
            }
            throw RenderError.failed(String(cString: sony2fuji_status_message(status)))
        }
        return ProcessingMigrationOutcome(native)
    }

    /// `referenceLongEdge` 仅用于 `edge == nil` 的中性基准帧：FINAL 质量路径加
    /// 「只降不放大」的长边封顶（Q8）；`edge != nil` 的按需预览不受影响。
    func render(_ url: URL, settings: Adjustments, lut: URL?, edge: Int?, output: URL? = nil, stageOutput: Bool = true, interactive: Bool = false, exportLongEdge: Int? = nil, viewportPreview: Bool = false, referenceLongEdge: Int? = nil, exportFormat: ExportFormat? = nil, outputSharpening: OutputSharpening = .off) throws -> RenderedImage? {
        if settings.isHDREditing {
            return try renderHDR(url, settings: settings, edge: edge, output: output, longEdge: exportLongEdge,
                                 format: exportFormat, outputSharpening: outputSharpening)
        }
        if let exportFormat, exportFormat.requiresHDR {
            throw RenderError.failed(exportFormat.hdrRequiredMessage)
        }
        let effectiveSharpening: OutputSharpening = (output != nil && exportFormat != .renderedDNG) ? outputSharpening : .off
        let plan = try photoRenderPlan(url, settings: settings, lut: lut, edge: edge, output: output,
            interactive: interactive, exportLongEdge: exportLongEdge, viewportPreview: viewportPreview,
            referenceLongEdge: referenceLongEdge, outputSharpening: effectiveSharpening)
        var options = plan.options
        var buffer = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&buffer) }
        var stagingURL: URL?
        var destinationURL = output
        if let output, stageOutput, ExportFormat.forOutput(output) != .renderedDNG {
            // 核心层的覆盖保护检查的是真实输出；暂存重定向后它只会看到全新暂存文件，
            // 因此创建暂存前先在真实目标上复核「目标已存在且与原片/外观是同一路径或别名」，
            // 命中时映射到与核心一致的 INVALID_ARGUMENT 覆盖保护错误。
            try Self.rejectSourceOverwrite(output, input: url, look: lut)
            let directory = output.deletingLastPathComponent()
            let suffix = output.pathExtension.isEmpty ? ExportFormat.forOutput(output).suffix : output.pathExtension
            let staging = directory.appendingPathComponent(".rawlab-\(UUID().uuidString).\(suffix)")
            stagingURL = staging
            destinationURL = staging
        }
        var cleanupStaging: URL? = stagingURL
        defer {
            if let cleanupStaging {
                try? FileManager.default.removeItem(at: cleanupStaging)
            }
        }
        let status = try withInput(url, options: &options) { inputOptions in
            (destinationURL?.path ?? "").withCString { destination in
                inputOptions.output_path = destinationURL == nil ? nil : destination
                return plan.editStateJSON.withCString { json in
                    sony2fuji_session_render(session, &inputOptions, json, &buffer, nil)
                }
            }
        }
        guard status == SONY2FUJI_STATUS_OK else {
            let x3fError = String(cString: sony2fuji_session_x3f_error(session))
            if !x3fError.isEmpty {
                throw RenderError.failed(L10n.format("无法正常显影 X3F：%@", x3fError))
            }
            if status == SONY2FUJI_STATUS_AI_NOT_READY ||
                (plan.settings.aiDenoiseEnabled && sony2fuji_session_get_ai_error(session).pointee != 0) {
                throw aiError(status)
            }
            if !Self.isRasterInput(url) && plan.settings.masterRecipe != nil && status == SONY2FUJI_STATUS_UNSUPPORTED &&
                sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_NONE {
                throw RenderError.failed(L10n.text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"))
            }
            throw RenderError.processing(status, input: url, look: lut, output: output, session: session)
        }
        if let output {
            let targetURL = destinationURL ?? output
            if ExportFormat.forOutput(targetURL) != .renderedDNG {
                // 核心已成功解码；ImageIO 不识别的 RAW 仍写入输出尺寸和方向，不捏造拍摄 EXIF。
                let fallback: [CFString: Any]? = Self.isRasterInput(url) ? nil : [:]
                try metadataPreserver(url, targetURL, fallback)
            }
            if let stagingURL {
                // 发布前复核（TOCTOU）：元数据补写期间真实目标可能被换成原片/外观的别名，不得静默覆盖。
                try Self.rejectSourceOverwrite(output, input: url, look: lut)
                try Self.publish(staging: stagingURL, to: output)
                cleanupStaging = nil
            }
            return nil
        }
        var baseline: Float = 0, metadata: Float = 0
        let raster = Self.isRasterInput(url)
        guard raster || sony2fuji_session_get_raw_exposure(session, &baseline, &metadata) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无法读取基础曝光"))
        }
        guard let pointer = buffer.data else { throw RenderError.failed(L10n.text("处理结果为空")) }
        var temperature: Float = 0, tint: Float = 0
        let calibrated = !raster && sony2fuji_session_get_effective_raw_white_balance(session, &temperature, &tint) == SONY2FUJI_STATUS_OK
        var noiseReductionSupported: Int32 = 0
        if !raster { _ = sony2fuji_session_get_raw_noise_reduction_support(session, &noiseReductionSupported) }
        let cameraWhiteBalance = calibrated ? WhiteBalance(temperature: Double(temperature), tint: Double(tint)) : nil
        let width = Int(buffer.width), height = Int(buffer.height)
        var nativeWidth: UInt32 = 0, nativeHeight: UInt32 = 0
        guard sony2fuji_session_get_geometry_size(session, &nativeWidth, &nativeHeight) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的几何参数"))
        }
        if raster,let cached=displayCache?.image,cached.isProxy,let sourceSize=cached.nativeSize {
            let native=try hdrNativeGeometrySize(sourceSize,geometry:settings.geometrySettings)
            nativeWidth=UInt32(native.width); nativeHeight=UInt32(native.height)
        }
        let data = Data(bytes: pointer, count: buffer.size_bytes)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: Int(buffer.stride_bytes), space: space,
                bitmapInfo: bitmap, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw RenderError.failed(L10n.text("无法显示处理结果")) }
        let statistics = statisticsProvider(&buffer)
        // Q8：被长边上限降过样的参考帧如实标记为非原生帧；参考缓存的键不含面板
        // 尺寸（见 EditorModel+Rendering），面板变化直接命中封顶基准，不靠此标志兜底。
        let nativeLongEdge = max(Int(nativeWidth), Int(nativeHeight))
        let referenceDownsampled = edge == nil && referenceLongEdge.map { nativeLongEdge > $0 } == true
        return RenderedImage(image: image, isFullResolution: edge == nil && !referenceDownsampled, clipping: statistics?.clipping, histogram: statistics?.histogram ?? [],
            shadows: statistics?.shadows, highlights: statistics?.highlights,
            baselineEV: Double(baseline), metadataEV: Double(metadata), asShotWhiteBalance: cameraWhiteBalance,
            supportsRawNoiseReduction: noiseReductionSupported == 1, lensInfo: raster ? nil : lensInfo(for: url),
            nativeWidth: Int(nativeWidth), nativeHeight: Int(nativeHeight))
    }

    private func renderHDR(_ url: URL,settings: Adjustments,edge: Int?,output: URL?,longEdge: Int?,format: ExportFormat?,outputSharpening: OutputSharpening = .off) throws -> RenderedImage? {
        guard gpuMode != SONY2FUJI_GPU_FORCE else {
            throw HDRNativeError(status:SONY2FUJI_STATUS_UNSUPPORTED,reason:UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU),field:UInt32(SONY2FUJI_HDR_FIELD_SESSION))
        }
        guard let session,let record=settings.hdr,record.isValid,
              let info=try HDRSourceInfo.probe(url) ?? HDRSourceInfo.probeRAW(url, processing: settings.processing.core) else {
            throw RenderError.failed(L10n.text("此照片没有可编辑的 HDR 增益图。"))
        }
        if info.proRAW != nil { try ProRAWSource.validatedDecodeVersion(settings.proRAWDecodeVersion) }
        displayCache=nil
        let previewEdge = edge ?? (info.isDevelopedRAW && output == nil ? 2000 : nil)
        let final = previewEdge == nil
        if final && info.isDevelopedRAW { hdrSources.clear() }
        let selected = output.map { format ?? (ExportFormat.forOutput($0) == .jpeg ? .hdrJPEG : ExportFormat.forOutput($0)) }
        let effectiveSharpening: OutputSharpening = (output != nil && selected != .renderedDNG) ? outputSharpening : .off
        if selected == .hdrHEIF && !HDRImage.heifExportAvailable {
            throw RenderError.failed(L10n.text("不支持此 HDR 格式或颜色描述。"))
        }
        if info.proRAW != nil, !settings.hdrCameraAIEnabled, let output, let selected {
            if selected == .hdrJPEG || selected == .jpeg {
                try ProRAWExporter.export(url: url, info: info, settings: record, output: output,
                    longEdge: longEdge, outputSharpening: effectiveSharpening,
                    keepHDR: selected == .hdrJPEG, session: session)
                return nil
            }
        }
        let source = try withHDRCameraAI(url, settings: settings, info: info) { key in
            if final {
                return try HDRImage.decode(url, info: info, intent: SONY2FUJI_INTENT_FINAL, session: session,
                    camera: record.cameraDevelopmentSettings, cameraAIKey: key)
            }
            return try hdrSources.preview(url, info: info, longEdge: previewEdge!, session: session,
                camera: record.cameraDevelopmentSettings, lensDatabase: lensDatabaseURL, cameraAIKey: key)
        }
        let rendered: HDRImage
        if record==HDRSettings() && longEdge==nil && effectiveSharpening == .off {
            rendered=source
        } else {
            rendered=try source.rendered(session:session,settings:record,
                intent:final ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW,
                longEdge:final ? longEdge : previewEdge,
                outputSharpening: effectiveSharpening)
        }
        if let output, let selected {
            switch selected {
            case .hdrJPEG: try rendered.exportJPEG(to:output)
            case .hdrHEIF: try rendered.exportHEIF(to:output)
            default:
                guard let native = selected.nativeFormat else { throw RenderError.failed(selected.hdrRequiredMessage) }
                try rendered.exportSDR(to:output,format:native)
            }
            return nil
        }
        let presentation=try HDRPresentation(rendered)
        return RenderedImage(image:presentation.sdrImage,isFullResolution:final,clipping:nil,histogram:[],
            shadows:nil,highlights:Double(presentation.statistics.aboveWhite)/Double(presentation.statistics.pixels),
            baselineEV:0,metadataEV:0,asShotWhiteBalance:nil,supportsRawNoiseReduction:false,
            nativeWidth:rendered.outputNativeWidth,nativeHeight:rendered.outputNativeHeight,hdr:presentation)
    }

    private func lensInfo(for url: URL) -> LensInfo? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = LensCatalogKey(url: url.standardizedFileURL, modified: values?.contentModificationDate, size: values?.fileSize)
        if lensCatalogKey != key {
            var inspection = sony2fuji_lens_report_v2()
            var count: UInt32 = 0
            let status = url.path.withCString { sony2fuji_session_inspect_lens_v2(session, $0, &inspection, nil, 0, &count) }
            guard status == SONY2FUJI_STATUS_OK else { return nil }
            var profiles = [sony2fuji_lens_profile_v2](repeating: sony2fuji_lens_profile_v2(), count: Int(count))
            let filled = url.path.withCString { input in
                profiles.withUnsafeMutableBufferPointer { storage in
                    sony2fuji_session_inspect_lens_v2(session, input, &inspection, storage.baseAddress, count, &count)
                }
            }
            guard filled == SONY2FUJI_STATUS_OK else { return nil }
            lensCandidates = profiles.map { LensCandidate(id: nativeText($0.base.id), maker: nativeText($0.base.maker),
                model: nativeText($0.base.model), hasDistortion: $0.base.has_distortion != 0,
                hasTCA: $0.base.has_tca != 0, isMatch: $0.base.is_match != 0, hasVignetting: $0.has_vignetting != 0) }
            lensCatalogKey = key
        }
        var extended = sony2fuji_lens_report_v2()
        var report = sony2fuji_lens_report()
        guard sony2fuji_session_get_lens_report_v2(session, &extended) == SONY2FUJI_STATUS_OK else { return nil }
        report = extended.base
        return LensInfo(state: report.state, detectedLens: nativeText(report.lens_model),
            selectedLens: nativeText(report.profile.model), focalLength: report.focal_length,
            appliedDistortion: report.applied_distortion != 0, appliedTCA: report.applied_tca != 0,
            cropScale: report.crop_scale, candidates: lensCandidates, appliedVignetting: extended.applied_vignetting != 0)
    }
}

private func nativeText<T>(_ value: T) -> String {
    var copy = value
    return withUnsafeBytes(of: &copy) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
}
