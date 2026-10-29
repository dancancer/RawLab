import AppKit
import ImageIO
import Foundation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Codable, Identifiable {
    case jpeg, png
    case hdrJPEG = "hdr_jpeg"
    case renderedDNG = "dng"

    var id: String { rawValue }
    static func available(isHDR: Bool) -> [ExportFormat] { isHDR ? [.hdrJPEG,.jpeg,.png,.renderedDNG] : [.jpeg,.png,.renderedDNG] }
    var suffix: String { self == .jpeg || self == .hdrJPEG ? "jpg" : rawValue }
    var title: String {
        switch self {
        case .hdrJPEG: return L10n.text("HDR JPEG")
        case .jpeg: return "JPEG"
        case .png: return L10n.text("16-bit PNG")
        case .renderedDNG: return L10n.text("DNG · 渲染型")
        }
    }
    var contentType: UTType {
        switch self {
        case .hdrJPEG: return .jpeg
        case .jpeg: return .jpeg
        case .png: return .png
        case .renderedDNG: return UTType(filenameExtension: "dng") ?? .rawImage
        }
    }
    var nativeFormat: sony2fuji_output_format {
        switch self {
        case .hdrJPEG: return SONY2FUJI_OUTPUT_JPEG
        case .jpeg: return SONY2FUJI_OUTPUT_JPEG
        case .png: return SONY2FUJI_OUTPUT_PNG
        case .renderedDNG: return SONY2FUJI_OUTPUT_DNG
        }
    }
    static func forOutput(_ url: URL) -> ExportFormat {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "dng": return .renderedDNG
        default: return .jpeg
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
        guard let url, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .rawImage)
    }

    private func withInput(_ url: URL, request: inout sony2fuji_request,
                           operation: (inout sony2fuji_request) -> sony2fuji_status) throws -> sony2fuji_status {
        if Self.isRasterInput(url) {
            let key = try RawWhiteBalanceCacheKey(url)
            let edge=request.intent==SONY2FUJI_INTENT_PREVIEW && request.preview_long_edge>0 ? Int(request.preview_long_edge) : nil
            if displayCache?.key != key || (displayCache?.image.nativeSize != nil && displayCache?.edge != edge) {
                displayCache = (key,edge,try DisplayImage(url,edge:edge,sources:hdrSources))
            }
            if displayCache?.image.nativeSize == nil { hdrSources.clear() }
            let image = displayCache!.image.buffer
            request.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER
            request.input_pixels = image.data.map(UnsafeRawPointer.init)
            request.input_width = image.width
            request.input_height = image.height
            request.input_pixel_format = image.pixel_format
            request.input_color_space = SONY2FUJI_COLOR_SRGB
            request.input_is_linear = 0
        } else { hdrSources.clear() }
        return url.path.withCString { path in
            request.input_path = path
            return operation(&request)
        }
    }
    private var session: OpaquePointer?
    private let aiModelDirectory: URL?
    private let aiCacheDirectory: URL
    private let aiBackend: sony2fuji_ai_backend
    static var aiAvailable: Bool { sony2fuji_ai_available() != 0 }
    static var bundledAIModel: URL? { Bundle.main.url(forResource: "DualDn", withExtension: nil, subdirectory: "AI") }
    private let gpuMode: sony2fuji_gpu_mode
    private let statisticsProvider: (inout sony2fuji_buffer) -> PreviewStatistics?
    private var whiteBalanceCache: (key: RawWhiteBalanceCacheKey, processing: ProcessingIdentity, value: WhiteBalance?)?
    private let lensDatabaseURL: URL?
    private struct LensCatalogKey: Equatable {
        let url: URL
        let modified: Date?
        let size: Int?
    }
    private var lensCatalogKey: LensCatalogKey?
    private var lensCandidates: [LensCandidate] = []
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
        try resetSession()
    }

    private func resetSession() throws {
        sony2fuji_session_destroy(session)
        session = nil
        whiteBalanceCache = nil
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

    private func configureCurve(_ settings: ToneCurveSettings) throws {
        guard settings.isValid else { throw RenderError.failed(L10n.text("无效的曲线参数")) }
        var config = settings.nativeConfig
        guard sony2fuji_session_set_tone_curve(session, &config) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的曲线参数"))
        }
    }

    private func configureGrading(_ settings: ColorGradingSettings) throws {
        guard settings.isValid else { throw RenderError.failed(L10n.text("无效的颜色分级参数")) }
        var config = settings.nativeConfig
        guard sony2fuji_session_set_color_grading(session, &config) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的颜色分级参数"))
        }
    }

    private func configureTone(_ settings: ToneControlsSettings) throws {
        guard settings.isValid else { throw RenderError.failed(L10n.text("无效的黑白场或鲜艳度参数")) }
        var config = settings.nativeConfig
        guard sony2fuji_session_set_tone_controls(session, &config) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的黑白场或鲜艳度参数"))
        }
    }

    private func configureAtmosphere(_ settings: AtmosphereSettings) throws {
        guard settings.isValid else { throw RenderError.failed(L10n.text("无效的清晰度或去朦胧参数")) }
        var config = settings.nativeConfig
        guard sony2fuji_session_set_atmosphere(session, &config) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的清晰度或去朦胧参数"))
        }
    }

    private func configureProcessing(_ identity: ProcessingIdentity) throws {
        guard sony2fuji_session_set_processing_version(session, identity.core) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("不支持此处理版本，原有记录未被覆盖。"))
        }
    }

    static func validateAIInput(_ url: URL) throws {
        guard !isRasterInput(url) else { throw RenderError.failed(L10n.text("AI 降噪仅支持 RAW 照片。")) }
        guard aiAvailable, bundledAIModel != nil else { throw RenderError.aiFailed(L10n.text("此构建未安装 AI 降噪模型。")) }
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

    func prepareAI(_ url: URL, settings: Adjustments, progress: AIPreparation) throws {
        guard !progress.isCancelled else { throw RenderError.aiCancelled }
        guard !Self.isRasterInput(url) else { throw RenderError.failed(L10n.text("AI 降噪仅支持 RAW 照片。")) }
        let settings = try resolvedSettings(url, settings: settings)
        try configureProcessing(settings.processing)
        try configureTone(settings.renderToneSettings)
        try configureAtmosphere(settings.renderAtmosphereSettings)
        try configureCurve(settings.renderCurveSettings)
        try configureGrading(settings.renderGradingSettings)
        try configureLens(settings.lensSettings)
        try configureAI(enabled: true)
        var request = sony2fuji_request()
        request.version = SONY2FUJI_REQUEST_VERSION
        request.struct_size = UInt32(MemoryLayout<sony2fuji_request>.size)
        request.input_type = SONY2FUJI_INPUT_RAW
        request.wb_mul = (1,1,1,1)
        settings.apply(to: &request)
        let context = Unmanaged.passUnretained(progress).toOpaque()
        let status = url.path.withCString { path in
            request.input_path = path
            return sony2fuji_session_prepare_ai(session, &request, { context, phase, done, total in
                guard let context else { return 0 }
                return Unmanaged<AIPreparation>.fromOpaque(context).takeUnretainedValue()
                    .report(phase: Int(phase), completed: done, total: total)
            }, context)
        }
        guard status == SONY2FUJI_STATUS_OK else { throw aiError(status) }
        guard !progress.isCancelled else { throw RenderError.aiCancelled }
    }

    func autoExposure(_ url: URL, settings: Adjustments) throws -> Double {
        let settings = try resolvedSettings(url, settings: settings)
        try configureProcessing(settings.processing)
        try configureTone(settings.renderToneSettings)
        try configureAtmosphere(settings.renderAtmosphereSettings)
        try configureCurve(settings.renderCurveSettings)
        try configureGrading(settings.renderGradingSettings)
        try configureAI(enabled: settings.aiDenoiseEnabled)
        try configureLens(settings.lensSettings)
        try configureGeometry(settings.geometrySettings)
        guard sony2fuji_session_set_raw_exposure_mode(session, settings.exposureMode.core) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的曝光基准"))
        }
        var request = sony2fuji_request()
        request.version = SONY2FUJI_REQUEST_VERSION
        request.struct_size = UInt32(MemoryLayout<sony2fuji_request>.size)
        request.input_type = SONY2FUJI_INPUT_RAW
        request.wb_mode = SONY2FUJI_WB_CAMERA
        request.wb_mul = (1,1,1,1)
        settings.apply(to: &request)
        request.output_target = SONY2FUJI_TARGET_BUFFER
        // 栅格测光仅采样有限像素，HDR 双图解码前也需限制尺寸。
        if Self.isRasterInput(url) {
            request.intent = SONY2FUJI_INTENT_PREVIEW
            request.preview_long_edge = 1280
        }
        var ev: Float = 0
        let status = try withInput(url, request: &request) { input in
            sony2fuji_session_estimate_auto_exposure(session, &input, &ev)
        }
        if status == SONY2FUJI_STATUS_AI_NOT_READY { throw aiError(status) }
        guard status == SONY2FUJI_STATUS_OK else { throw RenderError.failed(L10n.format("无法自动调整曝光：%@", String(describing: String(cString: sony2fuji_status_message(status))))) }
        return Double(ev)
    }

    func resolvedSettings(_ url: URL, settings: Adjustments) throws -> Adjustments {
        if Self.isRasterInput(url) {
            // 批量可混合两类输入；相机专属状态不解释成普通图像的 RGB 白平衡或镜头参数。
            return settings.resolvedForRaster
        }
        let key = try? RawWhiteBalanceCacheKey(url)
        if let key, let cached = whiteBalanceCache, cached.key.file == key.file,
           cached.key.fileNumber != key.fileNumber {
            // 原生 RAW 缓存只按路径、大小、时间识别文件，inode 更换时需同时重建会话。
            try resetSession()
        }
        var settings = settings
        if settings.masterRecipe != nil,
           settings.tint * settings.strength != 0 || !settings.usesAsShotWhiteBalance {
            let camera: WhiteBalance?
            if let key, let cache = whiteBalanceCache, cache.key == key, cache.processing == settings.processing {
                camera = cache.value
            } else {
                // 拍摄白平衡属于当前 RAW，不能沿用批量任务或恢复记录里的源照片元数据。
                camera = try render(url, settings: settings.neutralSettings, lut: nil, edge: 32)?.asShotWhiteBalance
            }
            guard let camera else {
                throw RenderError.failed(L10n.text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"))
            }
            settings.resolveWhiteBalance(camera)
        }
        return settings
    }

    private func photoRequest(_ url: URL, settings: Adjustments, lut: URL?, edge: Int?, output: URL?,
                              interactive: Bool, exportLongEdge: Int?, viewportPreview: Bool) throws -> (Adjustments, sony2fuji_request) {
        if let exportLongEdge, !(1...65535).contains(exportLongEdge) {
            throw RenderError.failed(L10n.text("导出长边必须为 1-65535 像素。"))
        }
        let settings = try resolvedSettings(url, settings: settings)
        try configureProcessing(settings.processing)
        try configureTone(settings.renderToneSettings)
        try configureAtmosphere(settings.renderAtmosphereSettings)
        try configureCurve(settings.renderCurveSettings)
        try configureGrading(settings.renderGradingSettings)
        if settings.aiDenoiseEnabled && Self.isRasterInput(url) {
            throw RenderError.failed(L10n.text("AI 降噪仅支持 RAW 照片。"))
        }
        try configureAI(enabled: settings.aiDenoiseEnabled)
        let allowsProxy = settings.geometrySettings.isIdentity
        guard sony2fuji_session_set_interactive_preview(session, interactive && allowsProxy && output == nil ? 1 : 0) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的预览模式"))
        }
        guard sony2fuji_session_set_viewport_preview(session, viewportPreview && edge != nil && output == nil ? 1 : 0) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的视口预览模式"))
        }
        guard sony2fuji_session_set_raw_exposure_mode(session, settings.exposureMode.core) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的曝光基准"))
        }
        guard settings.hslSettings.isValid else { throw RenderError.failed(L10n.text("无效的 HSL 参数")) }
        var hslConfig = settings.renderHSLSettings.nativeConfig
        guard sony2fuji_session_set_hsl(session, &hslConfig) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的 HSL 参数"))
        }
        try configureLens(settings.lensSettings)
        try configureGeometry(settings.geometrySettings)
        let wavelet = settings.waveletNoiseReduction
        var effectsConfig = settings.photoEffectsConfig
        guard sony2fuji_session_set_photo_effects(session, &effectsConfig) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的暗角或颗粒参数"))
        }
        var waveletConfig = sony2fuji_wavelet_denoise_config()
        waveletConfig.version = UInt32(SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION)
        waveletConfig.struct_size = UInt32(MemoryLayout<sony2fuji_wavelet_denoise_config>.size)
        waveletConfig.enabled = wavelet?.enabled == true ? 1 : 0
        waveletConfig.luma = Float(wavelet?.luma ?? 0)
        waveletConfig.chroma = Float(wavelet?.chroma ?? 0)
        waveletConfig.coarse = Float(wavelet?.coarse ?? 0)
        guard sony2fuji_session_set_wavelet_denoise(session, &waveletConfig) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效或不可用的降噪参数"))
        }
        let chromaMode = wavelet == nil ? (settings.chromaNoiseReduction ?? 0) : 0
        guard let chroma = Int32(exactly: chromaMode),
              sony2fuji_session_set_chroma_denoise(session, chroma) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效或不可用的色度降噪模式"))
        }
        let legacyLevel = wavelet == nil && chromaMode == 0 ? settings.rawNoiseReduction : 0
        guard let noiseReduction = Int32(exactly: legacyLevel),
              sony2fuji_session_set_raw_noise_reduction(session, noiseReduction) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的 RAW 降噪档位"))
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
        if output != nil, let exportLongEdge {
            request.intent = SONY2FUJI_INTENT_FINAL
            request.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE
            request.long_edge = UInt32(exportLongEdge)
        }
        if let edge { request.preview_long_edge = UInt32(edge) }
        request.output_target = output == nil ? SONY2FUJI_TARGET_BUFFER : SONY2FUJI_TARGET_FILE
        request.output_format = output == nil ? SONY2FUJI_OUTPUT_RGBA8 :
            ExportFormat.forOutput(output!).nativeFormat
        request.jpeg_quality = 95
        return (settings, request)
    }

    func sampleHSL(_ url: URL, settings: Adjustments, lut: URL?, edge: Int?, interactive: Bool,
                   revision: HSLTargetRevision, point: CGPoint) throws -> HSLTargetSample {
        let (_, prepared) = try photoRequest(url, settings: settings, lut: lut, edge: edge, output: nil,
            interactive: interactive, exportLongEdge: nil, viewportPreview: edge != nil)
        var request = prepared
        var sample: HSLTargetSample?
        _ = try withInput(url, request: &request) { input in
            (lut?.path ?? "").withCString { path in
                input.lut_path = lut == nil ? nil : path
                if let session {
                    sample = HSLTargetSample.capture(session: session, request: &input,
                        revision: revision, x: point.x, y: point.y)
                }
                return SONY2FUJI_STATUS_OK
            }
        }
        guard let sample else { throw RenderError.failed(L10n.text("无法创建处理会话")) }
        return sample
    }

    func render(_ url: URL, settings: Adjustments, lut: URL?, edge: Int?, output: URL? = nil, interactive: Bool = false, exportLongEdge: Int? = nil, viewportPreview: Bool = false, exportFormat: ExportFormat? = nil) throws -> RenderedImage? {
        if settings.isHDREditing {
            return try renderHDR(url,settings:settings,edge:edge,output:output,longEdge:exportLongEdge,format:exportFormat)
        }
        if exportFormat == .hdrJPEG { throw RenderError.failed(L10n.text("HDR JPEG 需要启用 HDR 编辑。")) }
        let (settings, prepared) = try photoRequest(url, settings: settings, lut: lut, edge: edge, output: output,
            interactive: interactive, exportLongEdge: exportLongEdge, viewportPreview: viewportPreview)
        var request = prepared
        let key = try? RawWhiteBalanceCacheKey(url)
        var buffer = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&buffer) }
        let status = try withInput(url, request: &request) { inputRequest in
            (lut?.path ?? "").withCString { lutPath in
                (output?.path ?? "").withCString { destination in
                    inputRequest.lut_path = lut == nil ? nil : lutPath
                    inputRequest.output_path = output == nil ? nil : destination
                    return sony2fuji_process(session, &inputRequest, &buffer)
                }
            }
        }
        guard status == SONY2FUJI_STATUS_OK else {
            if status == SONY2FUJI_STATUS_AI_NOT_READY ||
                (settings.aiDenoiseEnabled && sony2fuji_session_get_ai_error(session).pointee != 0) {
                throw aiError(status)
            }
            throw RenderError.processing(status, input: url, look: lut, output: output)
        }
        if let output {
            if ExportFormat.forOutput(output) != .renderedDNG {
                try ExportMetadata.preserve(from: url, in: output)
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
        let calibrated = !raster && sony2fuji_session_get_raw_white_balance(session, &temperature, &tint) == SONY2FUJI_STATUS_OK
        var noiseReductionSupported: Int32 = 0
        if !raster { _ = sony2fuji_session_get_raw_noise_reduction_support(session, &noiseReductionSupported) }
        let cameraWhiteBalance = calibrated ? WhiteBalance(temperature: Double(temperature).rounded(), tint: Double(tint).rounded()) : nil
        if !raster { whiteBalanceCache = key.map { ($0, settings.processing, cameraWhiteBalance) } }
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
        return RenderedImage(image: image, isFullResolution: edge == nil, clipping: statistics?.clipping, histogram: statistics?.histogram ?? [],
            shadows: statistics?.shadows, highlights: statistics?.highlights,
            baselineEV: Double(baseline), metadataEV: Double(metadata), asShotWhiteBalance: cameraWhiteBalance,
            supportsRawNoiseReduction: noiseReductionSupported == 1, lensInfo: raster ? nil : lensInfo(for: url),
            nativeWidth: Int(nativeWidth), nativeHeight: Int(nativeHeight))
    }

    private func renderHDR(_ url: URL,settings: Adjustments,edge: Int?,output: URL?,longEdge: Int?,format: ExportFormat?) throws -> RenderedImage? {
        guard gpuMode != SONY2FUJI_GPU_FORCE else {
            throw HDRNativeError(status:SONY2FUJI_STATUS_UNSUPPORTED,reason:UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU),field:UInt32(SONY2FUJI_HDR_FIELD_SESSION))
        }
        guard let session,let record=settings.hdr,record.isValid,
              let info=try HDRSourceInfo.probe(url) else {
            throw RenderError.failed(L10n.text("此照片没有可编辑的 HDR 增益图。"))
        }
        displayCache=nil
        let final=edge==nil
        let source=try final ? HDRImage.decode(url,info:info,intent:SONY2FUJI_INTENT_FINAL) :
            hdrSources.preview(url,info:info,longEdge:edge!)
        let rendered: HDRImage
        if record==HDRSettings() && longEdge==nil {
            rendered=source
        } else {
            rendered=try source.rendered(session:session,settings:record,
                intent:final ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW,longEdge:final ? longEdge : edge)
        }
        if let output {
            let selected=format ?? (ExportFormat.forOutput(output) == .jpeg ? .hdrJPEG : ExportFormat.forOutput(output))
            if selected == .hdrJPEG { try rendered.exportJPEG(to:output) }
            else { try rendered.exportSDR(to:output,format:selected.nativeFormat) }
            return nil
        }
        let presentation=try HDRPresentation(rendered)
        return RenderedImage(image:presentation.sdrImage,isFullResolution:final,clipping:nil,histogram:[],
            shadows:nil,highlights:Double(presentation.statistics.aboveWhite)/Double(presentation.statistics.pixels),
            baselineEV:0,metadataEV:0,asShotWhiteBalance:nil,supportsRawNoiseReduction:false,
            nativeWidth:rendered.outputNativeWidth,nativeHeight:rendered.outputNativeHeight,hdr:presentation)
    }

    private func configureGeometry(_ settings: GeometrySettings) throws {
        guard settings.isValid else { throw RenderError.failed(L10n.text("无效的几何参数")) }
        var config = sony2fuji_geometry_config()
        config.version = UInt32(SONY2FUJI_GEOMETRY_CONFIG_VERSION)
        config.struct_size = UInt32(MemoryLayout<sony2fuji_geometry_config>.size)
        config.crop_x = Float(settings.cropX)
        config.crop_y = Float(settings.cropY)
        config.crop_width = Float(settings.cropWidth)
        config.crop_height = Float(settings.cropHeight)
        config.quarter_turns = Int32(settings.quarterTurns)
        config.flip_horizontal = settings.flipHorizontal ? 1 : 0
        config.flip_vertical = settings.flipVertical ? 1 : 0
        config.straighten_degrees = Float(settings.straightenDegrees)
        guard sony2fuji_session_set_geometry(session, &config) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的几何参数"))
        }
        var perspective = sony2fuji_perspective_config()
        perspective.version = UInt32(SONY2FUJI_PERSPECTIVE_CONFIG_VERSION)
        perspective.struct_size = UInt32(MemoryLayout<sony2fuji_perspective_config>.size)
        perspective.horizontal = Float(settings.perspectiveHorizontal)
        perspective.vertical = Float(settings.perspectiveVertical)
        // The additive setter preserves geometry and must receive zero on reset
        // as well, because this session is reused for previews and exports.
        guard sony2fuji_session_set_perspective(session, &perspective) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的透视参数"))
        }
    }

    private func configureLens(_ lens: LensCorrectionSettings) throws {
        var lensConfig = sony2fuji_lens_correction_config()
        lensConfig.version = SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION
        lensConfig.struct_size = UInt32(MemoryLayout<sony2fuji_lens_correction_config>.size)
        lensConfig.distortion = lens.distortion ? 1 : 0
        lensConfig.tca = lens.tca ? 1 : 0
        lensConfig.auto_crop = lens.autoCrop ? 1 : 0
        let lensStatus = lens.coreProfileID.withCString { profile in
            lensConfig.profile_id = profile
            return sony2fuji_session_set_lens_correction(session, &lensConfig)
        }
        guard lensStatus == SONY2FUJI_STATUS_OK else { throw RenderError.failed(L10n.text("无效或不可用的镜头校正设置")) }
    }

    private func lensInfo(for url: URL) -> LensInfo? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = LensCatalogKey(url: url.standardizedFileURL, modified: values?.contentModificationDate, size: values?.fileSize)
        if lensCatalogKey != key {
            var inspection = sony2fuji_lens_report()
            var count: UInt32 = 0
            let status = url.path.withCString { sony2fuji_session_inspect_lens(session, $0, &inspection, nil, 0, &count) }
            guard status == SONY2FUJI_STATUS_OK else { return nil }
            var profiles = [sony2fuji_lens_profile](repeating: sony2fuji_lens_profile(), count: Int(count))
            let filled = url.path.withCString { input in
                profiles.withUnsafeMutableBufferPointer { storage in
                    sony2fuji_session_inspect_lens(session, input, &inspection, storage.baseAddress, count, &count)
                }
            }
            guard filled == SONY2FUJI_STATUS_OK else { return nil }
            lensCandidates = profiles.map { LensCandidate(id: nativeText($0.id), maker: nativeText($0.maker),
                model: nativeText($0.model), hasDistortion: $0.has_distortion != 0,
                hasTCA: $0.has_tca != 0, isMatch: $0.is_match != 0) }
            lensCatalogKey = key
        }
        var report = sony2fuji_lens_report()
        guard sony2fuji_session_get_lens_report(session, &report) == SONY2FUJI_STATUS_OK else { return nil }
        return LensInfo(state: report.state, detectedLens: nativeText(report.lens_model),
            selectedLens: nativeText(report.profile.model), focalLength: report.focal_length,
            appliedDistortion: report.applied_distortion != 0, appliedTCA: report.applied_tca != 0,
            cropScale: report.crop_scale, candidates: lensCandidates)
    }
}

private func nativeText<T>(_ value: T) -> String {
    var copy = value
    return withUnsafeBytes(of: &copy) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
}
