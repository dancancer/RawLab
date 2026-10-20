import AppKit
import ImageIO
import Foundation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Codable, Identifiable {
    case jpeg, png
    case renderedDNG = "dng"

    var id: String { rawValue }
    var suffix: String { self == .jpeg ? "jpg" : rawValue }
    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return L10n.text("16-bit PNG")
        case .renderedDNG: return L10n.text("DNG · 渲染型")
        }
    }
    var contentType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .renderedDNG: return UTType(filenameExtension: "dng") ?? .rawImage
        }
    }
    var nativeFormat: sony2fuji_output_format {
        switch self {
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
    let clipping: CGImage
    let histogram: [[Double]]
    let shadows: Double
    let highlights: Double
    let baselineEV: Double
    let metadataEV: Double
    let asShotWhiteBalance: WhiteBalance?
    let supportsRawNoiseReduction: Bool
    var lensInfo: LensInfo? = nil
    var nativeWidth: Int? = nil
    var nativeHeight: Int? = nil
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

final class RenderEngine {
    private final class DisplayImage {
        var buffer = sony2fuji_buffer()
        init(_ url: URL) throws {
            let status = url.path.withCString { sony2fuji_load_display_image($0, &buffer) }
            guard status == SONY2FUJI_STATUS_OK else {
                throw RenderError.displayImage(status)
            }
        }
        deinit { sony2fuji_release_buffer(&buffer) }
    }
    private var displayCache: (key: RawWhiteBalanceCacheKey, image: DisplayImage)?

    static func isRasterInput(_ url: URL?) -> Bool {
        guard let url, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .rawImage)
    }

    private func withInput(_ url: URL, request: inout sony2fuji_request,
                           operation: (inout sony2fuji_request) -> sony2fuji_status) throws -> sony2fuji_status {
        if Self.isRasterInput(url) {
            let key = try RawWhiteBalanceCacheKey(url)
            if displayCache?.key != key { displayCache = (key, try DisplayImage(url)) }
            let image = displayCache!.image.buffer
            request.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER
            request.input_pixels = image.data.map(UnsafeRawPointer.init)
            request.input_width = image.width
            request.input_height = image.height
            request.input_pixel_format = image.pixel_format
            request.input_color_space = SONY2FUJI_COLOR_SRGB
            request.input_is_linear = 0
        }
        return url.path.withCString { path in
            request.input_path = path
            return operation(&request)
        }
    }
    private var session: OpaquePointer?
    private let gpuMode: sony2fuji_gpu_mode
    private var whiteBalanceCache: (key: RawWhiteBalanceCacheKey, value: WhiteBalance?)?
    private let lensDatabaseURL: URL?
    private struct LensCatalogKey: Equatable {
        let url: URL
        let modified: Date?
        let size: Int?
    }
    private var lensCatalogKey: LensCatalogKey?
    private var lensCandidates: [LensCandidate] = []
    init(gpuMode: sony2fuji_gpu_mode = SONY2FUJI_GPU_AUTO, lensDatabaseURL: URL? = nil) throws {
        self.gpuMode = gpuMode
        self.lensDatabaseURL = lensDatabaseURL
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

    func autoExposure(_ url: URL, settings: Adjustments) throws -> Double {
        let settings = try resolvedSettings(url, settings: settings)
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
        var ev: Float = 0
        let status = try withInput(url, request: &request) { input in
            sony2fuji_session_estimate_auto_exposure(session, &input, &ev)
        }
        guard status == SONY2FUJI_STATUS_OK else { throw RenderError.failed(L10n.format("无法自动调整曝光：%@", String(describing: String(cString: sony2fuji_status_message(status))))) }
        return Double(ev)
    }

    func resolvedSettings(_ url: URL, settings: Adjustments) throws -> Adjustments {
        if Self.isRasterInput(url) {
            // 批量可混合两类输入；相机专属状态不解释成普通图像的 RGB 白平衡或镜头参数。
            var state = settings
            state.exposureMode = .sensor
            state.whiteBalanceMode = .asShot
            state.resolveWhiteBalance(nil)
            state.temperature = 6500
            state.tint = 0
            state.rawNoiseReduction = 0
            state.lensCorrection = nil
            return state
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
            if let key, let cache = whiteBalanceCache, cache.key == key {
                camera = cache.value
            } else {
                // 拍摄白平衡属于当前 RAW，不能沿用批量任务或恢复记录里的源照片元数据。
                camera = try render(url, settings: Adjustments(), lut: nil, edge: 32)?.asShotWhiteBalance
            }
            guard let camera else {
                throw RenderError.failed(L10n.text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"))
            }
            settings.resolveWhiteBalance(camera)
        }
        return settings
    }

    func render(_ url: URL, settings: Adjustments, lut: URL?, edge: Int?, output: URL? = nil, interactive: Bool = false, exportLongEdge: Int? = nil, viewportPreview: Bool = false) throws -> RenderedImage? {
        if let exportLongEdge, !(1...65535).contains(exportLongEdge) {
            throw RenderError.failed(L10n.text("导出长边必须为 1-65535 像素。"))
        }
        let settings = try resolvedSettings(url, settings: settings)
        let key = try? RawWhiteBalanceCacheKey(url)
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
        if !raster { whiteBalanceCache = key.map { ($0, cameraWhiteBalance) } }
        let width = Int(buffer.width), height = Int(buffer.height)
        var nativeWidth: UInt32 = 0, nativeHeight: UInt32 = 0
        guard sony2fuji_session_get_geometry_size(session, &nativeWidth, &nativeHeight) == SONY2FUJI_STATUS_OK else {
            throw RenderError.failed(L10n.text("无效的几何参数"))
        }
        let data = Data(bytes: pointer, count: buffer.size_bytes)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: Int(buffer.stride_bytes), space: space,
                bitmapInfo: bitmap, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw RenderError.failed(L10n.text("无法显示处理结果")) }
        var bins = [UInt32](repeating: 0, count: 768)
        var black: UInt32 = 0, white: UInt32 = 0
        var clippingBuffer = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&clippingBuffer) }
        guard sony2fuji_analyze_image(&buffer, gpuMode, &bins, &black, &white, &clippingBuffer) == SONY2FUJI_STATUS_OK,
              let clippingPixels = clippingBuffer.data else { throw RenderError.failed(L10n.text("无法计算直方图")) }
        let histogram = (0..<3).map { channel in (0..<256).map { Double(bins[channel*256+$0]) } }
        let overlay = Data(bytes: clippingPixels, count: clippingBuffer.size_bytes)
        let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width*4, space: space, bitmapInfo: bitmap,
            provider: CGDataProvider(data: overlay as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return RenderedImage(image: image, isFullResolution: edge == nil, clipping: mask, histogram: histogram,
            shadows: Double(black)/Double(width*height), highlights: Double(white)/Double(width*height),
            baselineEV: Double(baseline), metadataEV: Double(metadata), asShotWhiteBalance: cameraWhiteBalance,
            supportsRawNoiseReduction: noiseReductionSupported == 1, lensInfo: raster ? nil : lensInfo(for: url),
            nativeWidth: Int(nativeWidth), nativeHeight: Int(nativeHeight))
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
