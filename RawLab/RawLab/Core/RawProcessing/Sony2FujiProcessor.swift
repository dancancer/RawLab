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

        init(data: Data, width: Int, height: Int, stride: Int,
             pixelFormat: sony2fuji_pixel_format, semantic: Semantic = .legacy,
             nativeSize: CGSize? = nil) {
            self.data = data
            self.width = width
            self.height = height
            self.stride = stride
            self.pixelFormat = pixelFormat
            self.semantic = semantic
            self.nativeSize = nativeSize
        }

        func withSemantic(_ semantic: Semantic) -> Buffer {
            Buffer(data: data, width: width, height: height, stride: stride,
                   pixelFormat: pixelFormat, semantic: semantic, nativeSize: nativeSize)
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
                throw ProcessorError.processFailed(L10n.format("无法自动调整曝光：%@", String(describing: statusMessage(status))))
            }
            return Double(ev)
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
                throw processingFailure(status)
            }

            var output = try takeBuffer(&buffer, semantic: .legacy)
            output.nativeSize = geometrySize(session)
            let rawWhiteBalance = readRawWhiteBalance(from: session)
            return ProcessResult(buffer: output, orientation: .up, rawWhiteBalance: rawWhiteBalance, lensInfo: try readLens(session, url: url))
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
            output.nativeSize = geometrySize(session)
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
                throw processingFailure(status, input: url, look: lutURL, output: outputURL)
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

    func loadRasterBuffer(url: URL, applyingOrientation: Bool = true) throws -> ProcessResult {
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
                                          orientation: orientation ?? .up, quality: quality)
    }

    func computeHistogram(from buffer: Buffer, bins: Int) -> [CGFloat] {
        guard bins > 0 else {
            return []
        }
        var histogram = [Float](repeating: 0, count: bins)
        let status = buffer.withCBuffer { cBuffer in
            histogram.withUnsafeMutableBufferPointer { pointer in
                sony2fuji_compute_histogram(&cBuffer, UInt32(bins), pointer.baseAddress)
            }
        }
        guard status == SONY2FUJI_STATUS_OK else {
            return []
        }
        return histogram.map { CGFloat($0) }
    }
}
