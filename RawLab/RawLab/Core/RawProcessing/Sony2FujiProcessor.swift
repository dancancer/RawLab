import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct Sony2FujiProcessor {
    let gpuMode: sony2fuji_gpu_mode
    let lensDatabaseURL: URL?
    let lensCatalog = LensCatalogCache()
    let recipeWhiteBalance = RecipeWhiteBalanceCache()

    init(gpuMode: sony2fuji_gpu_mode = SONY2FUJI_GPU_AUTO, lensDatabaseURL: URL? = nil) {
        self.gpuMode = gpuMode
        self.lensDatabaseURL = lensDatabaseURL
    }

    private let previewSession = PreviewSession()
    private let hdrSources=HDRSourceCache.shared

    func processHDR(url: URL,settings: HDRSettings,previewLongEdge: Int?,exportLongEdge: Int? = nil) throws -> HDRImage {
        guard settings.mode == .hdr,settings.isValid else { throw HDRRequestError.invalidSettings }
        guard gpuMode != SONY2FUJI_GPU_FORCE else {
            throw HDRNativeError(status:SONY2FUJI_STATUS_UNSUPPORTED,reason:UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU),field:UInt32(SONY2FUJI_HDR_FIELD_SESSION))
        }
        return try withRawSession(reuse:false,inputType:SONY2FUJI_INPUT_DISPLAY_BUFFER) { session in
            guard let info=try HDRSourceInfo.probe(url) else { throw HDRSettings.ModeError.unsupportedSource }
            let source=try previewLongEdge.map { try hdrSources.preview(url,info:info,longEdge:$0) } ??
                HDRImage.decode(url,info:info,intent:SONY2FUJI_INTENT_FINAL)
            if settings.isIdentity && exportLongEdge==nil { return source }
            return try source.rendered(session:session,settings:settings,
                intent:previewLongEdge==nil ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW,
                longEdge:previewLongEdge ?? exportLongEdge)
        }
    }

    private final class PreviewSession {
        private let lock = NSLock()
        private var session: OpaquePointer?

        deinit { if let session { sony2fuji_session_destroy(session) } }

        func use<T>(reuse: Bool, create: () throws -> OpaquePointer,
                    body: (OpaquePointer) throws -> T) throws -> T {
            lock.lock()
            defer { lock.unlock() }
            if !reuse {
                // 导出与预览共享这把锁，先释放预览 RAW 再创建临时 session。
                if let session { sony2fuji_session_destroy(session) }
                session = nil
                let temporary = try create()
                defer { sony2fuji_session_destroy(temporary) }
                return try body(temporary)
            }
            if session == nil { session = try create() }
            do { return try body(session!) }
            catch {
                if let session { sony2fuji_session_destroy(session) }
                session = nil
                throw error
            }
        }
    }

    private func withRawSession<T>(reuse: Bool, inputType: sony2fuji_input_type = SONY2FUJI_INPUT_RAW, body: (OpaquePointer) throws -> T) throws -> T {
        let create = { () throws -> OpaquePointer in
            let session = try createSession()
            do { try loadLensDatabase(session, inputType: inputType) }
            catch { destroySession(session); throw error }
            return session
        }
        return try previewSession.use(reuse: reuse, create: create, body: body)
    }
    // =========================================================================
    // Types
    // =========================================================================

    struct ImageMetadata {
        let width: UInt32
        let height: UInt32
        let orientation: CGImagePropertyOrientation?
    }

    struct Buffer {
        enum Semantic: Equatable {
            case legacy
            case display
        }

        let data: Data
        let width: Int
        let height: Int
        let stride: Int
        let pixelFormat: sony2fuji_pixel_format
        let semantic: Semantic
        var nativeSize: CGSize? = nil
        var isProxy: Bool = false

        init(data: Data, width: Int, height: Int, stride: Int,
             pixelFormat: sony2fuji_pixel_format, semantic: Semantic = .legacy,
             nativeSize: CGSize? = nil, isProxy: Bool = false) {
            self.data = data
            self.width = width
            self.height = height
            self.stride = stride
            self.pixelFormat = pixelFormat
            self.semantic = semantic
            self.nativeSize = nativeSize
            self.isProxy = isProxy
        }

        func withSemantic(_ semantic: Semantic) -> Buffer {
            Buffer(data: data, width: width, height: height, stride: stride,
                   pixelFormat: pixelFormat, semantic: semantic, nativeSize: nativeSize, isProxy: isProxy)
        }

        func withCBuffer<T>(_ body: (inout sony2fuji_buffer) -> T) -> T? {
            data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return nil
                }
                var buffer = sony2fuji_buffer()
                buffer.data = UnsafeMutableRawPointer(mutating: baseAddress)
                buffer.size_bytes = data.count
                buffer.width = UInt32(width)
                buffer.height = UInt32(height)
                buffer.stride_bytes = UInt32(stride)
                buffer.pixel_format = pixelFormat
                return body(&buffer)
            }
        }
    }

    struct ProcessResult {
        let buffer: Buffer
        let orientation: CGImagePropertyOrientation?
        let rawWhiteBalance: RawWhiteBalance?
        var lensInfo: LensInfo? = nil
    }

    struct RGBHistogram: Equatable {
        let width: Int
        let height: Int
        let counts: [UInt32]
        let peak: UInt32

        init?(width: Int, height: Int, counts: [UInt32]) {
            guard width > 0, height > 0, width <= UInt32.max, height <= UInt32.max,
                  counts.count == 768 else { return nil }
            let pixels = UInt64(width) * UInt64(height)
            guard pixels <= UInt32.max, (0..<3).allSatisfy({ channel in
                counts[(channel * 256)..<((channel + 1) * 256)].reduce(UInt64(0)) { $0 + UInt64($1) } == pixels
            }) else { return nil }
            self.width = width
            self.height = height
            self.counts = counts
            peak = counts.max()!
        }

        struct Segment: Equatable {
            let lower: Double
            let upper: Double
            let channels: Int
        }

        func segments(at bin: Int) -> [Segment] {
            guard (0..<256).contains(bin) else { return [] }
            let heights = (0..<3).map { Double(counts[$0 * 256 + bin]) / Double(peak) }
            let thresholds = Set(heights.filter { $0 > 0 }).sorted()
            var lower = 0.0
            return thresholds.map { upper in
                let channels = (0..<3).reduce(0) { $0 | (heights[$1] >= upper ? 1 << $1 : 0) }
                defer { lower = upper }
                return Segment(lower: lower, upper: upper, channels: channels)
            }
        }
    }

    struct RawWhiteBalance: Codable, Equatable {
        let temperature: Double
        let tint: Double
        let isCalibrated: Bool
    }

    // =========================================================================
    // Public API
    // =========================================================================

    func autoExposure(url: URL?, buffer: Buffer?, settings: RawSettings) throws -> Double {
        let inputType: sony2fuji_input_type
        if url != nil {
            inputType = SONY2FUJI_INPUT_RAW
        } else if let buffer {
            inputType = semanticInputType(for: buffer)
        } else {
            throw ProcessorError.rasterDecodeFailed
        }
        return try withRawSession(reuse: false, inputType: inputType) { session in
            let settings = try effectiveSettings(settings, session: session, url: url, inputType: inputType)
            try configureProcessing(session, identity: settings.processing)
            try configureX3f(session, mode: settings.x3fMode)
            try configureTone(session, settings: settings.toneSettings)
            try configureAtmosphere(session, settings: settings.atmosphereSettings)
            try configureLens(session, settings: settings.lensSettings)
            let mode = sony2fuji_raw_exposure_mode(rawValue: UInt32(settings.exposureMode.rawValue))
            guard sony2fuji_session_set_raw_exposure_mode(session, mode) == SONY2FUJI_STATUS_OK else {
                throw ProcessorError.processFailed(L10n.text("无效的曝光基准"))
            }
            var request = makeBaseRequest(settings: settings, inputType: inputType)
            request.input_type = inputType
            var ev: Float = 0
            let status: sony2fuji_status
            if let url {
                status = url.path.withCString { path in
                    request.input_path = path
                    return sony2fuji_session_estimate_auto_exposure(session, &request, &ev)
                }
            } else if let buffer {
                request.input_width = UInt32(buffer.width)
                request.input_height = UInt32(buffer.height)
                request.input_pixel_format = buffer.pixelFormat
                request.input_color_space = SONY2FUJI_COLOR_SRGB
                status = buffer.data.withUnsafeBytes { bytes in
                    request.input_pixels = bytes.baseAddress
                    return sony2fuji_session_estimate_auto_exposure(session, &request, &ev)
                }
            } else { throw ProcessorError.rasterDecodeFailed }
            guard status == SONY2FUJI_STATUS_OK else {
                let detail = sony2fuji_session_x3f_error(session).map { String(cString: $0) } ?? ""
                throw ProcessorError.processFailed(L10n.format("无法自动调整曝光：%@", detail.isEmpty ? statusMessage(status) : detail))
            }
            return Double(ev)
        }
    }

    func sampleHSL(url: URL?, buffer: Buffer?, settings: RawSettings, previewLongEdge: CGFloat,
                   lutURL: URL?, interactive: Bool, revision: HSLTargetRevision, point: CGPoint) throws -> HSLTargetSample {
        let inputType: sony2fuji_input_type
        let width: UInt32, height: UInt32
        if let url {
            inputType = SONY2FUJI_INPUT_RAW
            let metadata = try loadMetadata(from: url)
            width = metadata.width; height = metadata.height
        } else if let buffer {
            inputType = semanticInputType(for: buffer)
            width = UInt32(buffer.width); height = UInt32(buffer.height)
        } else { throw ProcessorError.rasterDecodeFailed }
        return try withRawSession(reuse: url != nil, inputType: inputType) { session in
            let effective = try effectiveSettings(settings, session: session, url: url, inputType: inputType)
            try configureSession(session, settings: effective, interactive: interactive, viewportPreview: true)
            var request = makeBaseRequest(settings: effective, inputType: inputType)
            request.input_type = inputType
            applySize(&request, width: width, height: height, previewLongEdge: previewLongEdge, exportLongEdge: nil)
            request.lut_strength = lutURL == nil ? 0 : effective.clampedLUTStrength
            return (lutURL?.path ?? "").withCString { look in
                request.lut_path = lutURL == nil ? nil : look
                if let url {
                    return url.path.withCString { path in
                        request.input_path = path
                        return HSLTargetSample.capture(session: session, request: &request, revision: revision, x: point.x, y: point.y)
                    }
                }
                guard let buffer else {
                    return HSLTargetSample(revision: revision, availability: .failed, rgb: [], weights: [], preview: true)
                }
                request.input_width = UInt32(buffer.width); request.input_height = UInt32(buffer.height)
                request.input_pixel_format = buffer.pixelFormat; request.input_color_space = SONY2FUJI_COLOR_SRGB
                return buffer.data.withUnsafeBytes { bytes in
                    request.input_pixels = bytes.baseAddress
                    return HSLTargetSample.capture(session: session, request: &request, revision: revision, x: point.x, y: point.y)
                }
            }
        }
    }

    func processRaw(
        url: URL,
        settings: RawSettings,
        previewLongEdge: CGFloat?,
        lutURL: URL?,
        interactive: Bool = false,
        viewportPreview: Bool = false,
        exportLongEdge: Int? = nil
    ) throws -> ProcessResult {
        guard ExportSize.isValid(exportLongEdge) else {
            throw ProcessorError.invalidExportSize
        }
        let metadata = try loadMetadata(from: url)
        let targetWidth: UInt32
        let targetHeight: UInt32
        if previewLongEdge == nil {
            let rawDimensions = url.path.withCString { rawlab_get_raw_dimensions($0) }
            targetWidth = rawDimensions.width > 0 ? rawDimensions.width : metadata.width
            targetHeight = rawDimensions.height > 0 ? rawDimensions.height : metadata.height
        } else {
            targetWidth = metadata.width
            targetHeight = metadata.height
        }
        return try withRawSession(reuse: previewLongEdge != nil && exportLongEdge == nil) { session in
            let settings = try prepareRecipe(settings, session: session, url: url)
            try configureSession(session, settings: settings,
                                 interactive: interactive && previewLongEdge != nil && exportLongEdge == nil,
                                 viewportPreview: viewportPreview && previewLongEdge != nil && exportLongEdge == nil)

            var request = makeBaseRequest(settings: settings, inputType: SONY2FUJI_INPUT_RAW)
            request.input_type = SONY2FUJI_INPUT_RAW
            applySize(&request, width: targetWidth, height: targetHeight,
                      previewLongEdge: previewLongEdge, exportLongEdge: exportLongEdge)
            let lutStrength = lutURL == nil ? 0 : settings.clampedLUTStrength
            request.lut_strength = lutStrength

            var buffer = sony2fuji_buffer()
            defer { sony2fuji_release_buffer(&buffer) }
            let status = processRaw(
                session: session,
                request: &request,
                inputPath: url.path,
                lutPath: lutURL?.path,
                outBuffer: &buffer
            )
            guard status == SONY2FUJI_STATUS_OK else {
                throw processingFailure(status, session: session)
            }

            let normalX3f = isNormalX3f(url, settings: settings)
            var output = try takeBuffer(&buffer, semantic: normalX3f ? .display : .legacy)
            output.nativeSize = geometrySize(session)
            let rawWhiteBalance = normalX3f ? RawWhiteBalance(temperature: 6500, tint: 0, isCalibrated: true)
                : readRawWhiteBalance(from: session)
            return ProcessResult(buffer: output, orientation: .up, rawWhiteBalance: rawWhiteBalance, lensInfo: normalX3f ? nil : try readLens(session, url: url))
        }
    }

    func processBuffer(
        buffer: Buffer,
        settings: RawSettings,
        previewLongEdge: CGFloat?,
        lutURL: URL?,
        interactive: Bool = false,
        viewportPreview: Bool = false,
        exportLongEdge: Int? = nil
    ) throws -> Buffer {
        if buffer.isProxy && (exportLongEdge != nil || (previewLongEdge.map({ $0 <= 0 }) ?? true)) {
            throw HDRNativeError(status:SONY2FUJI_STATUS_INVALID_ARGUMENT,
                reason:UInt32(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE),field:UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
        }
        guard ExportSize.isValid(exportLongEdge) else {
            throw ProcessorError.invalidExportSize
        }
        let inputType = semanticInputType(for: buffer)
        return try withRawSession(reuse: false, inputType: inputType) { session in
            let settings = try effectiveSettings(settings, session: session, url: nil, inputType: inputType)
            try configureSession(session, settings: settings,
                                 interactive: interactive && previewLongEdge != nil && exportLongEdge == nil,
                                 viewportPreview: viewportPreview && previewLongEdge != nil && exportLongEdge == nil)

            var request = makeBaseRequest(settings: settings, inputType: inputType)
            request.input_type = inputType
            request.input_width = UInt32(buffer.width)
            request.input_height = UInt32(buffer.height)
            request.input_pixel_format = buffer.pixelFormat
            request.input_color_space = SONY2FUJI_COLOR_SRGB
            request.input_is_linear = 0
            applySize(&request, width: UInt32(buffer.width), height: UInt32(buffer.height),
                      previewLongEdge: previewLongEdge, exportLongEdge: exportLongEdge)
            let lutStrength = lutURL == nil ? 0 : settings.clampedLUTStrength
            request.lut_strength = lutStrength

            var outBuffer = sony2fuji_buffer()
            defer { sony2fuji_release_buffer(&outBuffer) }
            let status = processBuffer(
                session: session,
                request: &request,
                buffer: buffer,
                lutPath: lutURL?.path,
                outBuffer: &outBuffer
            )
            guard status == SONY2FUJI_STATUS_OK else {
                throw processingFailure(status)
            }

            var output = try takeBuffer(&outBuffer, semantic: buffer.semantic)
            if buffer.isProxy,let native=buffer.nativeSize {
                output.nativeSize=try hdrNativeGeometrySize(native,geometry:settings.geometrySettings)
            } else { output.nativeSize=geometrySize(session) }
            output.isProxy = buffer.isProxy
            return output
        }
    }

    func exportDNG(
        url: URL,
        settings: RawSettings,
        lutURL: URL?,
        outputURL: URL,
        exportLongEdge: Int? = nil
    ) throws {
        guard ExportSize.isValid(exportLongEdge) else {
            throw ProcessorError.invalidExportSize
        }
        let metadata = try loadMetadata(from: url)
        let rawDimensions = url.path.withCString { rawlab_get_raw_dimensions($0) }
        let width = rawDimensions.width > 0 ? rawDimensions.width : metadata.width
        let height = rawDimensions.height > 0 ? rawDimensions.height : metadata.height
        try withRawSession(reuse: false) { session in
            let settings = try prepareRecipe(settings, session: session, url: url)
            try configureSession(session, settings: settings, interactive: false)

            var request = makeBaseRequest(settings: settings, inputType: SONY2FUJI_INPUT_RAW)
            request.input_type = SONY2FUJI_INPUT_RAW
            applySize(&request, width: width, height: height, previewLongEdge: nil, exportLongEdge: exportLongEdge)
            request.lut_strength = lutURL == nil ? 0 : settings.clampedLUTStrength
            configureDNGFile(&request)
            let status = processRawToFile(session: session, request: &request,
                                          inputPath: url.path, lutPath: lutURL?.path, outputPath: outputURL.path)
            if status == SONY2FUJI_STATUS_OUTPUT_IO_ERROR { throw ProcessorError.outputIO }
            guard status == SONY2FUJI_STATUS_OK else {
                throw processingFailure(status, input: url, look: lutURL, output: outputURL, session: session)
            }
        }
    }

    func exportDNG(
        buffer: Buffer,
        settings: RawSettings,
        lutURL: URL?,
        outputURL: URL,
        exportLongEdge: Int? = nil
    ) throws {
        guard !buffer.isProxy else {
            throw HDRNativeError(status:SONY2FUJI_STATUS_INVALID_ARGUMENT,
                reason:UInt32(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE),field:UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
        }
        guard ExportSize.isValid(exportLongEdge) else {
            throw ProcessorError.invalidExportSize
        }
        let inputType = semanticInputType(for: buffer)
        try withRawSession(reuse: false, inputType: inputType) { session in
            let settings = try effectiveSettings(settings, session: session, url: nil, inputType: inputType)
            try configureSession(session, settings: settings, interactive: false)

            var request = makeBaseRequest(settings: settings, inputType: inputType)
            request.input_type = inputType
            request.input_width = UInt32(buffer.width)
            request.input_height = UInt32(buffer.height)
            request.input_pixel_format = buffer.pixelFormat
            request.input_color_space = SONY2FUJI_COLOR_SRGB
            request.input_is_linear = 0
            applySize(&request, width: UInt32(buffer.width), height: UInt32(buffer.height),
                      previewLongEdge: nil, exportLongEdge: exportLongEdge)
            request.lut_strength = lutURL == nil ? 0 : settings.clampedLUTStrength
            configureDNGFile(&request)
            let status = processBufferToFile(session: session, request: &request, buffer: buffer,
                                             lutPath: lutURL?.path, outputPath: outputURL.path)
            if status == SONY2FUJI_STATUS_OUTPUT_IO_ERROR { throw ProcessorError.outputIO }
            guard status == SONY2FUJI_STATUS_OK else {
                throw processingFailure(status, look: lutURL, output: outputURL)
            }
        }
    }

    func loadRasterBuffer(url: URL, applyingOrientation: Bool = true, previewLongEdge: Int? = nil) throws -> ProcessResult {
        guard previewLongEdge.map({ (1...65535).contains($0) }) ?? true else { throw HDRRequestError.invalidSettings }
        if let info=try HDRSourceInfo.probe(url) {
            let pair: HDRImage
            if let edge=previewLongEdge { pair=try hdrSources.preview(url,info:info,longEdge:edge) }
            else { hdrSources.clear(); pair=try HDRImage.decode(url,info:info,intent:SONY2FUJI_INTENT_FINAL) }
            let image=try HDRPresentation.makeSDRImage(pair)
            guard let bytes=image.dataProvider?.data else { throw HDRDisplayFailure.invalidBuffer }
            return ProcessResult(buffer:Buffer(data:bytes as Data,width:image.width,height:image.height,
                stride:image.bytesPerRow,pixelFormat:SONY2FUJI_PIXEL_RGBA8,semantic:.display,
                nativeSize:CGSize(width:pair.nativeWidth,height:pair.nativeHeight),isProxy:pair.isProxy),orientation:.up,rawWhiteBalance:nil)
        }
        var native = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&native) }
        let status = url.path.withCString { path in
            sony2fuji_load_display_image(path, &native)
        }
        guard status == SONY2FUJI_STATUS_OK else {
            throw displayImageFailure(status)
        }
        // The shared adapter has already validated color/alpha/depth and applied
        // EXIF orientation. Keep the parameter for source compatibility, but do
        // not permit a second orientation pass.
        _ = applyingOrientation
        let buffer = try takeBuffer(&native, semantic: .display)
        return ProcessResult(buffer: buffer, orientation: .up, rawWhiteBalance: nil)
    }

    func makeUIImage(from buffer: Buffer, orientation: CGImagePropertyOrientation?) -> UIImage? {
        guard let cgImage = makeCGImage(from: buffer) else {
            return nil
        }
        let uiOrientation = orientation.map(UIImage.Orientation.init) ?? .up
        return UIImage(cgImage: cgImage, scale: 1, orientation: uiOrientation)
    }

    func makeJPEGData(
        from buffer: Buffer,
        sourceURL: URL,
        orientation: CGImagePropertyOrientation?,
        quality: CGFloat
    ) throws -> Data {
        guard let cgImage = makeCGImage(from: buffer) else {
            throw ProcessorError.rasterDecodeFailed
        }
        return try ExportMetadata.jpegData(image: cgImage, sourceURL: sourceURL,
                                          orientation: orientation ?? .up, quality: quality,
                                          fallbackSourceProperties: sourceURL.pathExtension.lowercased() == "x3f" ? [:] : nil)
    }

    func computeRGBHistogram(from buffer: Buffer) -> RGBHistogram? {
        guard buffer.width > 0, buffer.height > 0, buffer.stride > 0,
              buffer.width <= UInt32.max, buffer.height <= UInt32.max,
              buffer.stride <= UInt32.max else { return nil }
        var counts = [UInt32](repeating: 0, count: 768)
        var shadows: UInt32 = 0, highlights: UInt32 = 0
        // Data 在闭包内持有显示像素；统计独立于照片 GPU 模式，不上传或读取截图。
        let status = buffer.withCBuffer { cBuffer in
            counts.withUnsafeMutableBufferPointer { pointer in
                sony2fuji_analyze_image(&cBuffer, SONY2FUJI_GPU_OFF, pointer.baseAddress,
                                       &shadows, &highlights, nil)
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { return nil }
        return RGBHistogram(width: buffer.width, height: buffer.height, counts: counts)
    }
}
