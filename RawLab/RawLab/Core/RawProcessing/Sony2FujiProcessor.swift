import RawLabKit
import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct Sony2FujiProcessor {
    let gpuMode: sony2fuji_gpu_mode
    let lensDatabaseURL: URL?
    let lensCatalog = LensCatalogCache()

    init(gpuMode: sony2fuji_gpu_mode = SONY2FUJI_GPU_AUTO, lensDatabaseURL: URL? = nil) {
        self.gpuMode = gpuMode
        self.lensDatabaseURL = lensDatabaseURL
    }

    private let previewSession = PreviewSession()
    private let hdrSources=HDRSourceCache.shared

    enum HDRPhotoFormat { case sdrJPEG, sdrPNG, hdrJPEG, hdrHEIF }

    func exportHDR(url: URL, settings: HDRSettings, output: URL, longEdge: Int? = nil,
                   outputSharpening: OutputSharpening = .off,
                   processing: ProcessingIdentity = .current,
                   proRAWDecodeVersion: Int? = nil, format: HDRPhotoFormat,
                   progress: ((Double) -> Void)? = nil,
                   cancelled: () -> Bool = { false }) throws {
        guard settings.mode == .hdr, settings.isValid else { throw HDRNativeError.invalidSettings }
        guard gpuMode != SONY2FUJI_GPU_FORCE else {
            throw HDRNativeError(status: SONY2FUJI_STATUS_UNSUPPORTED,
                reason: UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU), field: UInt32(SONY2FUJI_HDR_FIELD_SESSION))
        }
        if format == .hdrHEIF {
            try exportTiledHDR(url: url, settings: settings, output: output, longEdge: longEdge,
                outputSharpening: outputSharpening, processing: processing,
                proRAWDecodeVersion: proRAWDecodeVersion, format: UInt32(SONY2FUJI_HDR_TILED_HEIF),
                progress: progress, cancelled: cancelled)
            return
        }
        if (format == .sdrJPEG || format == .hdrJPEG), url.pathExtension.lowercased() == "dng",
           let info = try HDRSourceInfo.probeRAW(url), info.isProRAW {
            try HDRSourceInfo.validatedProRAWDecodeVersion(proRAWDecodeVersion)
            hdrSources.clear()
            try withRawSession(reuse: false, inputType: SONY2FUJI_INPUT_DISPLAY_BUFFER) { session in
                _ = try HDRImage.exportProRAWStream(url: url, info: info, settings: settings, output: output,
                    longEdge: longEdge, outputSharpening: outputSharpening,
                    keepHDR: format == .hdrJPEG, session: session,
                    cancelled: cancelled, progress: progress)
            }
            return
        }
        try withoutActuallyEscaping(cancelled) { cancelled in
            try withRawSession(reuse: false, inputType: SONY2FUJI_INPUT_DISPLAY_BUFFER) { session in
                let pair = try processHDR(url: url, settings: settings, previewLongEdge: nil, exportLongEdge: longEdge,
                                          outputSharpening: outputSharpening,
                                          processing: processing, proRAWDecodeVersion: proRAWDecodeVersion,
                                          sessionOverride: session,
                                          progress: progress.map { report in { report($0 * 0.75) } },
                                          cancelled: cancelled)
                if cancelled() { throw CancellationError() }
                let encodeProgress: ((Double) -> Void)? = progress.map { report in { report(0.75 + $0 * 0.25) } }
                switch format {
                case .sdrJPEG:
                    try pair.exportSDR(to: output, format: SONY2FUJI_OUTPUT_JPEG,
                                       session: session, cancelled: cancelled, progress: encodeProgress)
                case .sdrPNG:
                    try pair.exportSDR(to: output, format: SONY2FUJI_OUTPUT_PNG,
                                       session: session, cancelled: cancelled, progress: encodeProgress)
                case .hdrJPEG:
                    try pair.exportJPEG(to: output, session: session, cancelled: cancelled, progress: encodeProgress)
                case .hdrHEIF:
                    try pair.exportHEIF(to: output, session: session, cancelled: cancelled, progress: encodeProgress)
                }
            }
        }
    }

    func exportHDRDNG(url: URL, settings: HDRSettings, output: URL, longEdge: Int? = nil,
                      processing: ProcessingIdentity = .current, proRAWDecodeVersion: Int? = nil,
                      progress: ((Double) -> Void)? = nil,
                      cancelled: () -> Bool = { false }) throws {
        guard settings.mode == .hdr, settings.isValid else { throw HDRNativeError.invalidSettings }
        guard gpuMode != SONY2FUJI_GPU_FORCE else {
            throw HDRNativeError(status: SONY2FUJI_STATUS_UNSUPPORTED,
                reason: UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU), field: UInt32(SONY2FUJI_HDR_FIELD_SESSION))
        }
        try exportTiledHDR(url: url, settings: settings, output: output, longEdge: longEdge, processing: processing,
            proRAWDecodeVersion: proRAWDecodeVersion, format: UInt32(SONY2FUJI_HDR_TILED_SDR_DNG),
            progress: progress, cancelled: cancelled)
    }

    private func exportTiledHDR(url: URL, settings: HDRSettings, output: URL, longEdge: Int?,
                                outputSharpening: OutputSharpening = .off,
                                processing: ProcessingIdentity, proRAWDecodeVersion: Int?, format: UInt32,
                                progress: ((Double) -> Void)? = nil,
                                cancelled: () -> Bool) throws {
        guard let info = try HDRSourceInfo.probe(url) ?? HDRSourceInfo.probeRAW(url, processing: processing.core) else {
            throw HDRSettings.ModeError.unsupportedSource
        }
        let inputType = info.isCameraRAW ? SONY2FUJI_INPUT_RAW : SONY2FUJI_INPUT_DISPLAY_BUFFER
        try withRawSession(reuse: false, inputType: inputType) { session in
            let effectiveSharpening: OutputSharpening = format == UInt32(SONY2FUJI_HDR_TILED_SDR_DNG) ? .off : outputSharpening
            if info.isProRAW {
                try HDRSourceInfo.validatedProRAWDecodeVersion(proRAWDecodeVersion)
                hdrSources.clear()
            }
            _ = try HDRImage.exportTiled(url, info: info, settings: settings, output: output,
                longEdge: longEdge, outputSharpening: effectiveSharpening, format: format,
                session: session, cancelled: cancelled, progress: progress)
        }
    }

    struct ViewportROI: Equatable, Sendable {
        let normalizedRect: CGRect
        let maxOutputLongEdge: Int
    }

    struct ViewportROIResult: Equatable, Sendable {
        let nativeX0: Int
        let nativeY0: Int
        let nativeX1: Int
        let nativeY1: Int
        let fullNativeWidth: Int
        let fullNativeHeight: Int

        var normalizedRect: CGRect {
            let w = CGFloat(max(1, fullNativeWidth))
            let h = CGFloat(max(1, fullNativeHeight))
            return CGRect(
                x: CGFloat(nativeX0) / w,
                y: CGFloat(nativeY0) / h,
                width: CGFloat(nativeX1 - nativeX0) / w,
                height: CGFloat(nativeY1 - nativeY0) / h
            )
        }
    }

    struct ViewportROIRenderOutput {
        let image: UIImage
        let roi: ViewportROIResult
    }

    struct HDRROIRenderOutput {
        let image: HDRImage
        let roi: HDRViewportROIResult
    }

    func processHDR(url: URL,settings: HDRSettings,previewLongEdge: Int?, exportLongEdge: Int? = nil,
                    outputSharpening: OutputSharpening = .off,
                    processing: ProcessingIdentity = .current,
                    proRAWDecodeVersion: Int? = nil,
                    sessionOverride: OpaquePointer? = nil,
                    progress: ((Double) -> Void)? = nil,
                    cancelled: () -> Bool = { false }) throws -> HDRImage {
        try withoutActuallyEscaping(cancelled) { cancelled in
            guard settings.mode == .hdr,settings.isValid else { throw HDRNativeError.invalidSettings }
            guard gpuMode != SONY2FUJI_GPU_FORCE else {
                throw HDRNativeError(status:SONY2FUJI_STATUS_UNSUPPORTED,reason:UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU),field:UInt32(SONY2FUJI_HDR_FIELD_SESSION))
            }
            guard let info = try HDRSourceInfo.probe(url) ?? HDRSourceInfo.probeRAW(url, processing: processing.core) else {
                throw HDRSettings.ModeError.unsupportedSource
            }
            if info.isProRAW { try HDRSourceInfo.validatedProRAWDecodeVersion(proRAWDecodeVersion) }
            if previewLongEdge == nil, info.isProRAW { hdrSources.clear() }
            let inputType = info.isCameraRAW ? SONY2FUJI_INPUT_RAW : SONY2FUJI_INPUT_DISPLAY_BUFFER
            let effectiveSharpening: OutputSharpening = previewLongEdge == nil ? outputSharpening : .off
            let run: (OpaquePointer) throws -> HDRImage = { session in
                let decodeWeight = 0.4
                let source = try previewLongEdge.map {
                    try hdrPreviewSource(url, info: info, settings: settings, edge: $0, session: session, cancelled: cancelled)
                } ?? HDRImage.decode(url,info:info,intent:SONY2FUJI_INTENT_FINAL,
                                     session:session, camera:settings.cameraDevelopmentSettings,
                                     progress: progress.map { report in { report($0 * decodeWeight) } },
                                     cancelled:cancelled)
                if cancelled() { throw CancellationError() }
                if settings.isIdentity && exportLongEdge==nil && effectiveSharpening == .off &&
                    (previewLongEdge == nil || max(source.width, source.height) <= previewLongEdge!) {
                    progress?(1.0)
                    return source
                }
                let result = try source.rendered(
                    session:session, settings:settings,
                    intent:previewLongEdge==nil ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW,
                    longEdge:previewLongEdge ?? exportLongEdge,
                    outputSharpening: effectiveSharpening,
                    cancelled: cancelled,
                    progress: progress.map { report in { report(decodeWeight + $0 * (1.0 - decodeWeight)) } })
                if cancelled() { throw CancellationError() }
                return result
            }
            if let sessionOverride { return try run(sessionOverride) }
            return try withRawSession(reuse: false, inputType: inputType, body: run)
        }
    }

    func processHDRROI(
        url: URL,
        settings: HDRSettings,
        roi: HDRViewportROI,
        processing: ProcessingIdentity = .current,
        proRAWDecodeVersion: Int? = nil,
        cancelled: () -> Bool = { false }
    ) throws -> HDRROIRenderOutput {
        guard settings.mode == .hdr, settings.isValid else { throw HDRNativeError.invalidSettings }
        guard gpuMode != SONY2FUJI_GPU_FORCE else {
            throw HDRNativeError(status: SONY2FUJI_STATUS_UNSUPPORTED,
                                 reason: UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU),
                                 field: UInt32(SONY2FUJI_HDR_FIELD_SESSION))
        }
        guard let info = try HDRSourceInfo.probe(url) ?? HDRSourceInfo.probeRAW(url, processing: processing.core) else {
            throw HDRSettings.ModeError.unsupportedSource
        }
        if info.isProRAW { try HDRSourceInfo.validatedProRAWDecodeVersion(proRAWDecodeVersion) }
        if cancelled() { throw CancellationError() }
        let inputType = info.isCameraRAW ? SONY2FUJI_INPUT_RAW : SONY2FUJI_INPUT_DISPLAY_BUFFER
        return try withRawSession(reuse: true, inputType: inputType) { session in
            if info.isCameraRAW {
                let rendered = try HDRImage.renderCameraRawROI(
                    session: session, url: url, info: info,
                    settings: settings, roi: roi, longEdge: nil
                )
                return HDRROIRenderOutput(image: rendered.image, roi: rendered.result)
            }
            let rendered = try HDRImage.renderFileROI(
                session: session, url: url, info: info,
                settings: settings, roi: roi, longEdge: nil
            )
            return HDRROIRenderOutput(image: rendered.image, roi: rendered.result)
        }
    }

    func clearHDRSessionCache() {
        previewSession.clearHDRCacheIfActive()
    }

    private func hdrPreviewSource(_ url: URL, info: HDRSourceInfo, settings: HDRSettings, edge: Int,
                                  session: OpaquePointer, cancelled: () -> Bool = { false }) throws -> HDRImage {
        // 几何编辑沿用固定的 ProRAW 来源尺寸，避免预览随裁剪反复缩小。
        let sourceEdge = !info.isProRAW ? edge : settings.geometry.isIdentity ? max(1280, edge) : HDRSourceInfo.proRAWPreviewLimit
        return try hdrSources.preview(url, info: info, longEdge: sourceEdge,
            session: info.isCameraRAW ? session : nil, camera: settings.cameraDevelopmentSettings,
            lensDatabase: lensDatabaseURL, cancelled: cancelled)
    }

    func sampleHDRHSL(url: URL, settings: HDRSettings, processing: ProcessingIdentity,
                      proRAWDecodeVersion: Int?, previewLongEdge: Int,
                      revision: HSLTargetRevision, point: CGPoint) throws -> HSLTargetSample {
        guard gpuMode != SONY2FUJI_GPU_FORCE else {
            throw HDRNativeError(status: SONY2FUJI_STATUS_UNSUPPORTED,
                reason: UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU), field: UInt32(SONY2FUJI_HDR_FIELD_SESSION))
        }
        guard let info = try HDRSourceInfo.probe(url) ?? HDRSourceInfo.probeRAW(url, processing: processing.core) else {
            throw HDRSettings.ModeError.unsupportedSource
        }
        if info.isProRAW { try HDRSourceInfo.validatedProRAWDecodeVersion(proRAWDecodeVersion) }
        let inputType = info.isCameraRAW ? SONY2FUJI_INPUT_RAW : SONY2FUJI_INPUT_DISPLAY_BUFFER
        return try withRawSession(reuse: false, inputType: inputType) { session in
            let source = try hdrPreviewSource(url, info: info, settings: settings, edge: previewLongEdge, session: session)
            var options = try HDRImage.makeRenderOptions(intent: SONY2FUJI_INTENT_PREVIEW, longEdge: previewLongEdge)
            let editStateJSON = try HDRImage.hdrEditStateJSON(settings: settings)
            return source.withPair {
                HSLTargetSample.capture(session: session, pair: $0, options: &options, editStateJSON: editStateJSON,
                                        revision: revision, x: point.x, y: point.y)
            }
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

        func clearHDRCacheIfActive() {
            lock.lock()
            defer { lock.unlock() }
            if let session {
                HDRImage.clearSessionCache(session: session)
            }
        }
    }

    func withRawSession<T>(reuse: Bool, inputType: sony2fuji_input_type = SONY2FUJI_INPUT_RAW, body: (OpaquePointer) throws -> T) throws -> T {
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
        var hasFullBitDepth: Bool = true
        var sourceLensMetadata: DisplayLensMetadata? = nil
        var lensInfo: LensInfo? = nil

        init(data: Data, width: Int, height: Int, stride: Int,
             pixelFormat: sony2fuji_pixel_format, semantic: Semantic = .legacy,
             nativeSize: CGSize? = nil, isProxy: Bool = false, hasFullBitDepth: Bool = true) {
            self.data = data
            self.width = width
            self.height = height
            self.stride = stride
            self.pixelFormat = pixelFormat
            self.semantic = semantic
            self.nativeSize = nativeSize
            self.isProxy = isProxy
            self.hasFullBitDepth = hasFullBitDepth
        }

        func withSemantic(_ semantic: Semantic) -> Buffer {
            var result = self
            result = Buffer(data: data, width: width, height: height, stride: stride,
                            pixelFormat: pixelFormat, semantic: semantic, nativeSize: nativeSize,
                            isProxy: isProxy, hasFullBitDepth: hasFullBitDepth)
            result.sourceLensMetadata = semantic == .display ? sourceLensMetadata : nil
            result.lensInfo = semantic == .display ? lensInfo : nil
            return result
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
        if let hdr = settings.hdr, hdr.mode == .hdr {
            guard let url else { throw HDRSettings.ModeError.unsupportedSource }
            guard gpuMode != SONY2FUJI_GPU_FORCE else {
                throw HDRNativeError(status: SONY2FUJI_STATUS_UNSUPPORTED,
                    reason: UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU), field: UInt32(SONY2FUJI_HDR_FIELD_SESSION))
            }
            return try withRawSession(reuse: false) { session in
                try hdrSources.autoExposure(url, settings: hdr, proRAWDecodeVersion: settings.proRAWDecodeVersion,
                    session: session, lensDatabase: lensDatabaseURL, processing: settings.processing.core)
            }
        }
        let inputType: sony2fuji_input_type
        if url != nil {
            inputType = SONY2FUJI_INPUT_RAW
        } else if let buffer {
            inputType = semanticInputType(for: buffer)
        } else {
            throw ProcessorError.rasterDecodeFailed
        }
        return try withRawSession(reuse: false, inputType: inputType) { session in
            try configureGPU(session)
            try configureDisplayLens(session, metadata: buffer?.sourceLensMetadata, settings: settings.lensSettings)
            let editStateJSON = try encodeSessionState(settings, inputType: inputType, lutPath: nil)
            var options = makeRenderOptions(inputType: inputType)
            var ev: Float = 0
            let status: sony2fuji_status
            if let url {
                status = url.path.withCString { path in
                    options.input_path = path
                    return editStateJSON.withCString { json in
                        sony2fuji_session_estimate_auto_exposure_json(session, &options, json, &ev)
                    }
                }
            } else if let buffer {
                options.input_width = UInt32(buffer.width)
                options.input_height = UInt32(buffer.height)
                options.input_pixel_format = buffer.pixelFormat
                options.input_color_space = SONY2FUJI_COLOR_SRGB
                options.input_is_linear = 0
                status = buffer.data.withUnsafeBytes { bytes in
                    options.input_pixels = bytes.baseAddress
                    return editStateJSON.withCString { json in
                        sony2fuji_session_estimate_auto_exposure_json(session, &options, json, &ev)
                    }
                }
            } else { throw ProcessorError.rasterDecodeFailed }
            guard status == SONY2FUJI_STATUS_OK else {
                if let failure = masterRecipeFailureIfNeeded(status, settings: settings, inputType: inputType, session: session) {
                    throw failure
                }
                if status == SONY2FUJI_STATUS_UNSUPPORTED,
                   sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_FORCE_GPU {
                    throw processingFailure(status, session: session)
                }
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
            // 仅确认源文件可读，原生尺寸由单次解包的 sony2fuji_session_render 自行读取。
            _ = try url.checkResourceIsReachable()
            inputType = SONY2FUJI_INPUT_RAW
            width = 0; height = 0
        } else if let buffer {
            inputType = semanticInputType(for: buffer)
            width = UInt32(buffer.width); height = UInt32(buffer.height)
        } else { throw ProcessorError.rasterDecodeFailed }
        return try withRawSession(reuse: url != nil, inputType: inputType) { session in
            try configureGPU(session)
            try configureDisplayLens(session, metadata: buffer?.sourceLensMetadata, settings: settings.lensSettings)
            let editStateJSON = try encodeSessionState(settings, inputType: inputType, lutPath: lutURL?.path)
            var options = makeRenderOptions(
                inputType: inputType,
                width: width,
                height: height,
                previewLongEdge: previewLongEdge,
                exportLongEdge: nil,
                interactive: interactive,
                viewportPreview: true
            )
            if let url {
                return url.path.withCString { path in
                    options.input_path = path
                    return HSLTargetSample.capture(session: session, options: &options, editStateJSON: editStateJSON,
                                                   revision: revision, x: point.x, y: point.y)
                }
            }
            guard let buffer else {
                return HSLTargetSample(revision: revision, availability: .failed, rgb: [], weights: [], preview: true)
            }
            options.input_width = UInt32(buffer.width); options.input_height = UInt32(buffer.height)
            options.input_pixel_format = buffer.pixelFormat; options.input_color_space = SONY2FUJI_COLOR_SRGB
            return buffer.data.withUnsafeBytes { bytes in
                options.input_pixels = bytes.baseAddress
                return HSLTargetSample.capture(session: session, options: &options, editStateJSON: editStateJSON,
                                               revision: revision, x: point.x, y: point.y)
            }
        }
    }

    func sampleWBProbe(url: URL?, buffer: Buffer?, settings: RawSettings, previewLongEdge: CGFloat,
                       lutURL: URL?, interactive: Bool, point: CGPoint) throws -> (availability: sony2fuji_wb_probe_availability, temperature: Double, tint: Double) {
        let inputType: sony2fuji_input_type
        let width: UInt32, height: UInt32
        if let url {
            _ = try url.checkResourceIsReachable()
            inputType = SONY2FUJI_INPUT_RAW
            width = 0; height = 0
        } else if let buffer {
            inputType = semanticInputType(for: buffer)
            width = UInt32(buffer.width); height = UInt32(buffer.height)
        } else { throw ProcessorError.rasterDecodeFailed }
        return try withRawSession(reuse: url != nil, inputType: inputType) { session in
            try configureGPU(session)
            try configureDisplayLens(session, metadata: buffer?.sourceLensMetadata, settings: settings.lensSettings)
            let editStateJSON = try encodeSessionState(settings, inputType: inputType, lutPath: lutURL?.path)
            var options = makeRenderOptions(
                inputType: inputType,
                width: width,
                height: height,
                previewLongEdge: previewLongEdge,
                exportLongEdge: nil,
                interactive: interactive,
                viewportPreview: true
            )
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
            let status: sony2fuji_status = editStateJSON.withCString { json in
                if let url {
                    return url.path.withCString { path in
                        options.input_path = path
                        return sony2fuji_session_sample_wb_probe_json(session, &options, json, &query, &result)
                    }
                }
                guard let buffer else { return SONY2FUJI_STATUS_INVALID_ARGUMENT }
                options.input_width = UInt32(buffer.width); options.input_height = UInt32(buffer.height)
                options.input_pixel_format = buffer.pixelFormat; options.input_color_space = SONY2FUJI_COLOR_SRGB
                return buffer.data.withUnsafeBytes { bytes in
                    options.input_pixels = bytes.baseAddress
                    return sony2fuji_session_sample_wb_probe_json(session, &options, json, &query, &result)
                }
            }
            if let failure = masterRecipeFailureIfNeeded(status, settings: settings, inputType: inputType, session: session) {
                throw failure
            }
            guard status == SONY2FUJI_STATUS_OK else { throw processingFailure(status, session: session) }
            return (result.availability, Double(result.temperature), Double(result.tint))
        }
    }

    func migrateProcessing(url: URL, isRaw: Bool, settings: RawSettings, lutURL: URL?,
                           cancellation: ProcessingMigrationCancellation) throws -> ProcessingMigrationOutcome {
        guard !settings.isHDREditing, settings.masterRecipeID == nil, (1...2).contains(settings.processing.version) else {
            throw ProcessorError.processFailed(L10n.text("此照片的调整保留原处理版本。"))
        }
        let raster = isRaw ? nil : try loadRasterBuffer(url: url, applyingOrientation: true).buffer
        let inputType = raster.map { semanticInputType(for: $0) } ?? SONY2FUJI_INPUT_RAW
        return try withRawSession(reuse: false, inputType: inputType) { session in
            try configureGPU(session)
            try configureDisplayLens(session, metadata: raster?.sourceLensMetadata, settings: settings.lensSettings)
            let editStateJSON = try encodeSessionState(settings, inputType: inputType, lutPath: lutURL?.path)
            var options = makeRenderOptions(inputType: inputType, interactive: false, viewportPreview: false)
            let context = Unmanaged.passUnretained(cancellation).toOpaque()
            _ = sony2fuji_session_set_cancellation_callback(session, { pointer in
                guard let pointer else { return 0 }
                return Unmanaged<ProcessingMigrationCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
            }, context)
            defer { _ = sony2fuji_session_set_cancellation_callback(session, nil, nil) }
            var native = sony2fuji_processing_migration_result()
            let status = editStateJSON.withCString { json in
                if let raster {
                    options.input_width = UInt32(raster.width); options.input_height = UInt32(raster.height)
                    options.input_pixel_format = raster.pixelFormat
                    options.input_color_space = SONY2FUJI_COLOR_SRGB
                    options.input_is_linear = 0
                    return raster.data.withUnsafeBytes { bytes in
                        options.input_pixels = bytes.baseAddress
                        return sony2fuji_session_migrate_processing_json(session, &options, json, &native)
                    }
                }
                return url.path.withCString { path in
                    options.input_path = path
                    return sony2fuji_session_migrate_processing_json(session, &options, json, &native)
                }
            }
            guard status == SONY2FUJI_STATUS_OK else { throw processingFailure(status, input: url, look: lutURL, session: session) }
            return ProcessingMigrationOutcome(native)
        }
    }

    func processRaw(
        url: URL,
        settings: RawSettings,
        previewLongEdge: CGFloat?,
        lutURL: URL?,
        interactive: Bool = false,
        viewportPreview: Bool = false,
        exportLongEdge: Int? = nil,
        outputSharpening: OutputSharpening = .off,
        cancelled: () -> Bool = { false }
    ) throws -> ProcessResult {
        guard ExportSize.isValid(exportLongEdge) else {
            throw ProcessorError.invalidExportSize
        }
        if cancelled() { throw CancellationError() }
        // 原生/缩放尺寸由 sony2fuji_process 在同一次 session 解包中确定，避免导出前二次读头/解包。
        _ = try url.checkResourceIsReachable()
        return try withRawSession(reuse: previewLongEdge != nil && exportLongEdge == nil) { session in
            try withoutActuallyEscaping(cancelled) { escapingCancelled in
                final class CancellationBox {
                    let check: () -> Bool
                    init(_ check: @escaping () -> Bool) { self.check = check }
                }
                let box = CancellationBox(escapingCancelled)
                return try withExtendedLifetime(box) {
                    let context = Unmanaged.passUnretained(box).toOpaque()
                    _ = sony2fuji_session_set_cancellation_callback(session, { pointer in
                        guard let pointer else { return 0 }
                        return Unmanaged<CancellationBox>.fromOpaque(pointer).takeUnretainedValue().check() ? 1 : 0
                    }, context)
                    defer { _ = sony2fuji_session_set_cancellation_callback(session, nil, nil) }

                    if box.check() { throw CancellationError() }
                    try configureGPU(session)
                    let effectiveSharpening: OutputSharpening = (previewLongEdge == nil || exportLongEdge != nil) ? outputSharpening : .off
                    let editStateJSON = try encodeSessionState(settings, inputType: SONY2FUJI_INPUT_RAW, lutPath: lutURL?.path,
                                                               outputSharpening: effectiveSharpening)
                    var options = makeRenderOptions(
                        inputType: SONY2FUJI_INPUT_RAW,
                        previewLongEdge: previewLongEdge,
                        exportLongEdge: exportLongEdge,
                        interactive: interactive && previewLongEdge != nil && exportLongEdge == nil,
                        viewportPreview: viewportPreview && previewLongEdge != nil && exportLongEdge == nil
                    )

                    var buffer = sony2fuji_buffer()
                    defer { sony2fuji_release_buffer(&buffer) }
                    let status = renderSessionRaw(
                        session: session,
                        options: &options,
                        editStateJSON: editStateJSON,
                        inputPath: url.path,
                        outBuffer: &buffer
                    )
                    if status == SONY2FUJI_STATUS_CANCELLED || box.check() {
                        throw CancellationError()
                    }
                    guard status == SONY2FUJI_STATUS_OK else {
                        if let failure = masterRecipeFailureIfNeeded(status, settings: settings, inputType: SONY2FUJI_INPUT_RAW, session: session) {
                            throw failure
                        }
                        throw processingFailure(status, session: session)
                    }

                    let normalX3f = isNormalX3f(url, settings: settings)
                    var output = try takeBuffer(&buffer, semantic: normalX3f ? .display : .legacy)
                    output.nativeSize = geometrySize(session)
                    let rawWhiteBalance = readRawWhiteBalance(from: session)
                    return ProcessResult(buffer: output, orientation: .up, rawWhiteBalance: rawWhiteBalance, lensInfo: normalX3f ? nil : try readLens(session, url: url))
                }
            }
        }
    }

    private final class SessionCancellationBox {
        let check: () -> Bool
        init(_ check: @escaping () -> Bool) { self.check = check }
    }

    private func withSessionCancellation<T>(
        _ session: OpaquePointer,
        cancelled: () -> Bool,
        body: (() -> Bool) throws -> T
    ) throws -> T {
        try withoutActuallyEscaping(cancelled) { escapingCancelled in
            let box = SessionCancellationBox(escapingCancelled)
            return try withExtendedLifetime(box) {
                let context = Unmanaged.passUnretained(box).toOpaque()
                _ = sony2fuji_session_set_cancellation_callback(session, { pointer in
                    guard let pointer else { return 0 }
                    return Unmanaged<SessionCancellationBox>.fromOpaque(pointer).takeUnretainedValue().check() ? 1 : 0
                }, context)
                defer { _ = sony2fuji_session_set_cancellation_callback(session, nil, nil) }
                return try body(box.check)
            }
        }
    }

    func supportsFastFullResGpu(
        url: URL,
        settings: RawSettings,
        lutURL: URL?,
        nativeSize: CGSize,
        maxPixels: Int
    ) -> Bool {
        guard gpuMode != SONY2FUJI_GPU_OFF,
              !settings.isHDREditing,
              nativeSize.width > 0, nativeSize.height > 0,
              maxPixels >= 0 else {
            return false
        }
        let fullW = UInt32(max(0, Int(nativeSize.width.rounded())))
        let fullH = UInt32(max(0, Int(nativeSize.height.rounded())))
        guard fullW > 0, fullH > 0 else { return false }
        let cappedPixels = UInt32(min(Int(UInt32.max), maxPixels))
        do {
            let json = try encodeSessionState(settings, inputType: SONY2FUJI_INPUT_RAW, lutPath: lutURL?.path)
            return try withRawSession(reuse: true) { session in
                try configureGPU(session)
                return url.path.withCString { pathPtr in
                    var query = sony2fuji_fast_gpu_query_v1()
                    query.version = SONY2FUJI_FAST_GPU_QUERY_V1_VERSION
                    query.struct_size = UInt32(MemoryLayout<sony2fuji_fast_gpu_query_v1>.size)
                    query.input_type = SONY2FUJI_INPUT_RAW
                    query.input_width = fullW
                    query.input_height = fullH
                    query.max_pixels = cappedPixels
                    query.input_path = pathPtr
                    var supported: Int32 = 0
                    return json.withCString { jsonPtr in
                        let status = sony2fuji_session_supports_fast_full_res_gpu(session, &query, jsonPtr, &supported)
                        return status == SONY2FUJI_STATUS_OK && supported != 0
                    }
                }
            }
        } catch {
            return false
        }
    }

    func processRawDisplayBacking(
        url: URL,
        settings: RawSettings,
        lutURL: URL?,
        longEdge: Int,
        viewportPreview: Bool,
        cancelled: () -> Bool = { false }
    ) throws -> (cgImage: CGImage, nativeSize: CGSize) {
        if cancelled() { throw CancellationError() }
        _ = try url.checkResourceIsReachable()
        return try withRawSession(reuse: true) { session in
            try withSessionCancellation(session, cancelled: cancelled) { isCancelled in
                if isCancelled() { throw CancellationError() }
                try configureGPU(session)
                let editStateJSON = try encodeSessionState(settings, inputType: SONY2FUJI_INPUT_RAW, lutPath: lutURL?.path)
                var options = makeRenderOptions(
                    inputType: SONY2FUJI_INPUT_RAW,
                    previewLongEdge: CGFloat(max(1, longEdge)),
                    interactive: false,
                    viewportPreview: viewportPreview
                )

                var buffer = sony2fuji_buffer()
                defer { sony2fuji_release_buffer(&buffer) }
                let status = renderSessionRaw(
                    session: session,
                    options: &options,
                    editStateJSON: editStateJSON,
                    inputPath: url.path,
                    outBuffer: &buffer
                )
                if status == SONY2FUJI_STATUS_CANCELLED || isCancelled() {
                    throw CancellationError()
                }
                guard status == SONY2FUJI_STATUS_OK else {
                    if let failure = masterRecipeFailureIfNeeded(status, settings: settings, inputType: SONY2FUJI_INPUT_RAW, session: session) {
                        throw failure
                    }
                    throw processingFailure(status, session: session)
                }
                let normalX3f = isNormalX3f(url, settings: settings)
                guard let cgImage = makeNativeBGRADisplayCGImage(consuming: &buffer, semantic: normalX3f ? .display : .legacy) else {
                    throw ProcessorError.bufferCopyFailed
                }
                let nativeSize = geometrySize(session) ?? CGSize(width: cgImage.width, height: cgImage.height)
                return (cgImage, nativeSize)
            }
        }
    }

    func processRawROI(
        url: URL,
        settings: RawSettings,
        lutURL: URL?,
        roi: ViewportROI,
        cancelled: () -> Bool = { false }
    ) throws -> ViewportROIRenderOutput {
        if cancelled() { throw CancellationError() }
        _ = try url.checkResourceIsReachable()
        return try withRawSession(reuse: true) { session in
            try withSessionCancellation(session, cancelled: cancelled) { isCancelled in
                if isCancelled() { throw CancellationError() }
                try configureGPU(session)
                let editStateJSON = try encodeSessionState(settings, inputType: SONY2FUJI_INPUT_RAW, lutPath: lutURL?.path)
                var options = makeRenderOptions(
                    inputType: SONY2FUJI_INPUT_RAW,
                    previewLongEdge: 1280,
                    interactive: false,
                    viewportPreview: true
                )
                var nativeRoi = makeNativeViewportROI(roi)
                var outRoiResult = sony2fuji_viewport_roi_result()
                outRoiResult.struct_size = UInt32(MemoryLayout<sony2fuji_viewport_roi_result>.size)

                var buffer = sony2fuji_buffer()
                defer { sony2fuji_release_buffer(&buffer) }
                let status = withUnsafePointer(to: &nativeRoi) { roiPtr in
                    options.viewport_roi = roiPtr
                    return renderSessionRaw(
                        session: session,
                        options: &options,
                        editStateJSON: editStateJSON,
                        inputPath: url.path,
                        outBuffer: &buffer,
                        outROI: &outRoiResult
                    )
                }
                if status == SONY2FUJI_STATUS_CANCELLED || isCancelled() {
                    throw CancellationError()
                }
                guard status == SONY2FUJI_STATUS_OK else {
                    if let failure = masterRecipeFailureIfNeeded(status, settings: settings, inputType: SONY2FUJI_INPUT_RAW, session: session) {
                        throw failure
                    }
                    throw processingFailure(status, session: session)
                }
                guard let result = makeViewportROIResult(outRoiResult) else {
                    throw ProcessorError.invalidDimensions
                }
                let normalX3f = isNormalX3f(url, settings: settings)
                guard let cgImage = makeNativeBGRADisplayCGImage(consuming: &buffer, semantic: normalX3f ? .display : .legacy) else {
                    throw ProcessorError.bufferCopyFailed
                }
                return ViewportROIRenderOutput(image: UIImage(cgImage: cgImage, scale: 1, orientation: .up), roi: result)
            }
        }
    }

    func processBuffer(
        buffer: Buffer,
        settings: RawSettings,
        previewLongEdge: CGFloat?,
        lutURL: URL?,
        interactive: Bool = false,
        viewportPreview: Bool = false,
        exportLongEdge: Int? = nil,
        outputSharpening: OutputSharpening = .off
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
            try configureGPU(session)
            try configureDisplayLens(session, metadata: buffer.sourceLensMetadata, settings: settings.lensSettings)
            let effectiveSharpening: OutputSharpening = (previewLongEdge == nil || exportLongEdge != nil) ? outputSharpening : .off
            let editStateJSON = try encodeSessionState(settings, inputType: inputType, lutPath: lutURL?.path,
                                                       outputSharpening: effectiveSharpening)
            var options = makeRenderOptions(
                inputType: inputType,
                width: UInt32(buffer.width),
                height: UInt32(buffer.height),
                previewLongEdge: previewLongEdge,
                exportLongEdge: exportLongEdge,
                interactive: interactive && previewLongEdge != nil && exportLongEdge == nil,
                viewportPreview: viewportPreview && previewLongEdge != nil && exportLongEdge == nil
            )

            var outBuffer = sony2fuji_buffer()
            defer { sony2fuji_release_buffer(&outBuffer) }
            let status = renderSessionBuffer(
                session: session,
                options: &options,
                editStateJSON: editStateJSON,
                buffer: buffer,
                outBuffer: &outBuffer
            )
            guard status == SONY2FUJI_STATUS_OK else {
                throw processingFailure(status, session: session)
            }

            var output = try takeBuffer(&outBuffer, semantic: buffer.semantic)
            if buffer.isProxy,let native=buffer.nativeSize {
                output.nativeSize=try hdrNativeGeometrySize(native,geometry:settings.geometrySettings)
            } else { output.nativeSize=geometrySize(session) }
            output.isProxy = buffer.isProxy
            if let metadata = buffer.sourceLensMetadata {
                output.lensInfo = try readLens(session, url: metadata.sourceURL, metadata: metadata.overriding(settings.lensSettings))
            }
            return output
        }
    }

    func processBufferDisplayBacking(
        buffer: Buffer,
        settings: RawSettings,
        lutURL: URL?,
        longEdge: Int,
        cancelled: () -> Bool = { false }
    ) throws -> (cgImage: CGImage, nativeSize: CGSize) {
        guard !buffer.isProxy else {
            throw HDRNativeError(status: SONY2FUJI_STATUS_INVALID_ARGUMENT,
                                 reason: UInt32(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE),
                                 field: UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
        }
        if cancelled() { throw CancellationError() }
        let inputType = semanticInputType(for: buffer)
        return try withRawSession(reuse: true, inputType: inputType) { session in
            try withSessionCancellation(session, cancelled: cancelled) { isCancelled in
                if isCancelled() { throw CancellationError() }
                try configureGPU(session)
                try configureDisplayLens(session, metadata: buffer.sourceLensMetadata, settings: settings.lensSettings)
                let editStateJSON = try encodeSessionState(settings, inputType: inputType, lutPath: lutURL?.path)
                var options = makeRenderOptions(
                    inputType: inputType,
                    width: UInt32(buffer.width),
                    height: UInt32(buffer.height),
                    previewLongEdge: CGFloat(max(1, longEdge)),
                    interactive: false,
                    viewportPreview: true
                )

                var outBuffer = sony2fuji_buffer()
                defer { sony2fuji_release_buffer(&outBuffer) }
                let status = renderSessionBuffer(
                    session: session,
                    options: &options,
                    editStateJSON: editStateJSON,
                    buffer: buffer,
                    outBuffer: &outBuffer
                )
                if status == SONY2FUJI_STATUS_CANCELLED || isCancelled() {
                    throw CancellationError()
                }
                guard status == SONY2FUJI_STATUS_OK else {
                    throw processingFailure(status, session: session)
                }
                guard let cgImage = makeNativeBGRADisplayCGImage(consuming: &outBuffer, semantic: buffer.semantic) else {
                    throw ProcessorError.bufferCopyFailed
                }
                let nativeSize = geometrySize(session) ?? CGSize(width: buffer.width, height: buffer.height)
                return (cgImage, nativeSize)
            }
        }
    }

    func processBufferROI(
        buffer: Buffer,
        settings: RawSettings,
        lutURL: URL?,
        roi: ViewportROI,
        cancelled: () -> Bool = { false }
    ) throws -> ViewportROIRenderOutput {
        guard !buffer.isProxy else {
            throw HDRNativeError(status: SONY2FUJI_STATUS_INVALID_ARGUMENT,
                                 reason: UInt32(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE),
                                 field: UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
        }
        if cancelled() { throw CancellationError() }
        let inputType = semanticInputType(for: buffer)
        return try withRawSession(reuse: true, inputType: inputType) { session in
            try withSessionCancellation(session, cancelled: cancelled) { isCancelled in
                if isCancelled() { throw CancellationError() }
                try configureGPU(session)
                try configureDisplayLens(session, metadata: buffer.sourceLensMetadata, settings: settings.lensSettings)
                let editStateJSON = try encodeSessionState(settings, inputType: inputType, lutPath: lutURL?.path)
                var options = makeRenderOptions(
                    inputType: inputType,
                    width: UInt32(buffer.width),
                    height: UInt32(buffer.height),
                    previewLongEdge: 1280,
                    interactive: false,
                    viewportPreview: true
                )
                var nativeRoi = makeNativeViewportROI(roi)
                var outRoiResult = sony2fuji_viewport_roi_result()
                outRoiResult.struct_size = UInt32(MemoryLayout<sony2fuji_viewport_roi_result>.size)

                var outBuffer = sony2fuji_buffer()
                defer { sony2fuji_release_buffer(&outBuffer) }
                let status = withUnsafePointer(to: &nativeRoi) { roiPtr in
                    options.viewport_roi = roiPtr
                    return renderSessionBuffer(
                        session: session,
                        options: &options,
                        editStateJSON: editStateJSON,
                        buffer: buffer,
                        outBuffer: &outBuffer,
                        outROI: &outRoiResult
                    )
                }
                if status == SONY2FUJI_STATUS_CANCELLED || isCancelled() {
                    throw CancellationError()
                }
                guard status == SONY2FUJI_STATUS_OK else {
                    throw processingFailure(status, session: session)
                }
                guard let result = makeViewportROIResult(outRoiResult) else {
                    throw ProcessorError.invalidDimensions
                }
                guard let cgImage = makeNativeBGRADisplayCGImage(consuming: &outBuffer, semantic: buffer.semantic) else {
                    throw ProcessorError.bufferCopyFailed
                }
                return ViewportROIRenderOutput(image: UIImage(cgImage: cgImage, scale: 1, orientation: .up), roi: result)
            }
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
        // DNG 导出尺寸由 sony2fuji_process 单次解包直接计算，不再预读取 rawlab_get_raw_dimensions。
        _ = try url.checkResourceIsReachable()
        try withRawSession(reuse: false) { session in
            try configureGPU(session)
            let editStateJSON = try encodeSessionState(settings, inputType: SONY2FUJI_INPUT_RAW, lutPath: lutURL?.path)
            var options = makeRenderOptions(
                inputType: SONY2FUJI_INPUT_RAW,
                exportLongEdge: exportLongEdge,
                interactive: false,
                outputTarget: SONY2FUJI_TARGET_FILE,
                outputFormat: SONY2FUJI_OUTPUT_DNG
            )
            let status = renderSessionRaw(
                session: session,
                options: &options,
                editStateJSON: editStateJSON,
                inputPath: url.path,
                outputPath: outputURL.path
            )
            if status == SONY2FUJI_STATUS_OUTPUT_IO_ERROR { throw ProcessorError.outputIO }
            guard status == SONY2FUJI_STATUS_OK else {
                if let failure = masterRecipeFailureIfNeeded(status, settings: settings, inputType: SONY2FUJI_INPUT_RAW, session: session) {
                    throw failure
                }
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
            try configureGPU(session)
            try configureDisplayLens(session, metadata: buffer.sourceLensMetadata, settings: settings.lensSettings)
            let editStateJSON = try encodeSessionState(settings, inputType: inputType, lutPath: lutURL?.path)
            var options = makeRenderOptions(
                inputType: inputType,
                width: UInt32(buffer.width),
                height: UInt32(buffer.height),
                exportLongEdge: exportLongEdge,
                interactive: false,
                outputTarget: SONY2FUJI_TARGET_FILE,
                outputFormat: SONY2FUJI_OUTPUT_DNG
            )
            let status = renderSessionBuffer(
                session: session,
                options: &options,
                editStateJSON: editStateJSON,
                buffer: buffer,
                outputPath: outputURL.path
            )
            if status == SONY2FUJI_STATUS_OUTPUT_IO_ERROR { throw ProcessorError.outputIO }
            guard status == SONY2FUJI_STATUS_OK else {
                throw processingFailure(status, look: lutURL, output: outputURL, session: session)
            }
        }
    }

    func exportPNG(
        url: URL,
        settings: RawSettings,
        lutURL: URL?,
        outputURL: URL,
        exportLongEdge: Int? = nil,
        outputSharpening: OutputSharpening = .off
    ) throws {
        guard ExportSize.isValid(exportLongEdge) else {
            throw ProcessorError.invalidExportSize
        }
        _ = try url.checkResourceIsReachable()
        try withRawSession(reuse: false) { session in
            try configureGPU(session)
            let editStateJSON = try encodeSessionState(settings, inputType: SONY2FUJI_INPUT_RAW, lutPath: lutURL?.path,
                                                       outputSharpening: outputSharpening)
            var options = makeRenderOptions(
                inputType: SONY2FUJI_INPUT_RAW,
                exportLongEdge: exportLongEdge,
                interactive: false,
                outputTarget: SONY2FUJI_TARGET_FILE,
                outputFormat: SONY2FUJI_OUTPUT_PNG
            )
            let status = renderSessionRaw(
                session: session,
                options: &options,
                editStateJSON: editStateJSON,
                inputPath: url.path,
                outputPath: outputURL.path
            )
            if status == SONY2FUJI_STATUS_OUTPUT_IO_ERROR { throw ProcessorError.outputIO }
            guard status == SONY2FUJI_STATUS_OK else {
                if let failure = masterRecipeFailureIfNeeded(status, settings: settings, inputType: SONY2FUJI_INPUT_RAW, session: session) {
                    throw failure
                }
                throw processingFailure(status, input: url, look: lutURL, output: outputURL, session: session)
            }
        }
        try ExportMetadata.preserve(from: url, in: outputURL, fallbackSourceProperties: [:])
    }

    func exportPNG(
        buffer: Buffer,
        settings: RawSettings,
        lutURL: URL?,
        sourceURL: URL,
        outputURL: URL,
        exportLongEdge: Int? = nil,
        outputSharpening: OutputSharpening = .off
    ) throws {
        guard !buffer.isProxy else {
            throw HDRNativeError(status: SONY2FUJI_STATUS_INVALID_ARGUMENT,
                reason: UInt32(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE), field: UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
        }
        guard ExportSize.isValid(exportLongEdge) else {
            throw ProcessorError.invalidExportSize
        }
        let inputType = semanticInputType(for: buffer)
        try withRawSession(reuse: false, inputType: inputType) { session in
            try configureGPU(session)
            try configureDisplayLens(session, metadata: buffer.sourceLensMetadata, settings: settings.lensSettings)
            let editStateJSON = try encodeSessionState(settings, inputType: inputType, lutPath: lutURL?.path,
                                                       outputSharpening: outputSharpening)
            var options = makeRenderOptions(
                inputType: inputType,
                width: UInt32(buffer.width),
                height: UInt32(buffer.height),
                exportLongEdge: exportLongEdge,
                interactive: false,
                outputTarget: SONY2FUJI_TARGET_FILE,
                outputFormat: SONY2FUJI_OUTPUT_PNG
            )
            let status = renderSessionBuffer(
                session: session,
                options: &options,
                editStateJSON: editStateJSON,
                buffer: buffer,
                outputPath: outputURL.path
            )
            if status == SONY2FUJI_STATUS_OUTPUT_IO_ERROR { throw ProcessorError.outputIO }
            guard status == SONY2FUJI_STATUS_OK else {
                throw processingFailure(status, look: lutURL, output: outputURL, session: session)
            }
        }
        try ExportMetadata.preserve(from: sourceURL, in: outputURL, fallbackSourceProperties: nil)
    }

    func loadRasterBuffer(url: URL, applyingOrientation: Bool = true, previewLongEdge: Int? = nil) throws -> ProcessResult {
        guard previewLongEdge.map({ (1...65535).contains($0) }) ?? true else { throw HDRNativeError.invalidSettings }
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
        _ = applyingOrientation
        if let edge = previewLongEdge {
            var native = sony2fuji_buffer()
            defer { sony2fuji_release_buffer(&native) }
            var sourceWidth: UInt32 = 0
            var sourceHeight: UInt32 = 0
            let status = url.path.withCString { path in
                sony2fuji_load_display_preview(path, UInt32(edge), &native, &sourceWidth, &sourceHeight)
            }
            guard status == SONY2FUJI_STATUS_OK else {
                throw displayImageFailure(status)
            }
            let nativeSize = CGSize(width: Int(sourceWidth), height: Int(sourceHeight))
            let isProxy = max(Int(sourceWidth), Int(sourceHeight)) > edge
            var hasFullBitDepth = true
            if !isProxy,
               let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
               (props[kCGImagePropertyDepth] as? NSNumber)?.intValue == 16 {
                hasFullBitDepth = false
            }
            var buffer = try takeBuffer(&native, semantic: .display)
            buffer.nativeSize = nativeSize
            buffer.isProxy = isProxy
            buffer.hasFullBitDepth = hasFullBitDepth
            buffer.sourceLensMetadata = DisplayLensMetadata.read(url)
            return ProcessResult(buffer: buffer, orientation: .up, rawWhiteBalance: nil)
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
        var buffer = try takeBuffer(&native, semantic: .display)
        buffer.sourceLensMetadata = DisplayLensMetadata.read(url)
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
        quality: CGFloat,
        sourceIsRaw: Bool = false
    ) throws -> Data {
        guard let cgImage = makeCGImage(from: buffer) else {
            throw ProcessorError.rasterDecodeFailed
        }
        // RAW 已由核心成功解码，ImageIO 不支持其原容器时仍可写出像素。
        return try ExportMetadata.jpegData(image: cgImage, sourceURL: sourceURL,
                                          orientation: orientation ?? .up, quality: quality,
                                          fallbackSourceProperties: sourceIsRaw || sourceURL.pathExtension.lowercased() == "x3f" ? [:] : nil)
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
