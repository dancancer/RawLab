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

    enum HDRPhotoFormat { case sdrJPEG, hdrJPEG, hdrHEIF }

    func exportHDR(url: URL, settings: HDRSettings, output: URL, longEdge: Int? = nil,
                   processing: ProcessingIdentity = .current,
                   proRAWDecodeVersion: Int? = nil, format: HDRPhotoFormat,
                   progress: ((Double) -> Void)? = nil,
                   cancelled: () -> Bool = { false }) throws {
        guard settings.mode == .hdr, settings.isValid else { throw HDRRequestError.invalidSettings }
        guard gpuMode != SONY2FUJI_GPU_FORCE else {
            throw HDRNativeError(status: SONY2FUJI_STATUS_UNSUPPORTED,
                reason: UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU), field: UInt32(SONY2FUJI_HDR_FIELD_SESSION))
        }
        if format == .hdrHEIF {
            try exportTiledHDR(url: url, settings: settings, output: output, longEdge: longEdge, processing: processing,
                proRAWDecodeVersion: proRAWDecodeVersion, format: UInt32(SONY2FUJI_HDR_TILED_HEIF),
                progress: progress, cancelled: cancelled)
            return
        }
        if format != .hdrHEIF, url.pathExtension.lowercased() == "dng",
           let info = try HDRSourceInfo.probeRAW(url), info.proRAW != nil {
            try ProRAWSource.validatedDecodeVersion(proRAWDecodeVersion)
            hdrSources.clear()
            try withRawSession(reuse: false, inputType: SONY2FUJI_INPUT_DISPLAY_BUFFER) { session in
                _ = try ProRAWExporter.export(url: url, info: info, settings: settings, output: output,
                    longEdge: longEdge, keepHDR: format == .hdrJPEG, session: session,
                    cancelled: cancelled, progress: progress)
            }
            return
        }
        try withoutActuallyEscaping(cancelled) { cancelled in
            try withRawSession(reuse: false, inputType: SONY2FUJI_INPUT_DISPLAY_BUFFER) { session in
                let pair = try processHDR(url: url, settings: settings, previewLongEdge: nil, exportLongEdge: longEdge,
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
        guard settings.mode == .hdr, settings.isValid else { throw HDRRequestError.invalidSettings }
        guard gpuMode != SONY2FUJI_GPU_FORCE else {
            throw HDRNativeError(status: SONY2FUJI_STATUS_UNSUPPORTED,
                reason: UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU), field: UInt32(SONY2FUJI_HDR_FIELD_SESSION))
        }
        try exportTiledHDR(url: url, settings: settings, output: output, longEdge: longEdge, processing: processing,
            proRAWDecodeVersion: proRAWDecodeVersion, format: UInt32(SONY2FUJI_HDR_TILED_SDR_DNG),
            progress: progress, cancelled: cancelled)
    }

    private func exportTiledHDR(url: URL, settings: HDRSettings, output: URL, longEdge: Int?,
                                processing: ProcessingIdentity, proRAWDecodeVersion: Int?, format: UInt32,
                                progress: ((Double) -> Void)? = nil,
                                cancelled: () -> Bool) throws {
        guard let info = try HDRSourceInfo.probe(url) ?? HDRSourceInfo.probeRAW(url, processing: processing.core) else {
            throw HDRSettings.ModeError.unsupportedSource
        }
        let inputType = info.isCameraRAW ? SONY2FUJI_INPUT_RAW : SONY2FUJI_INPUT_DISPLAY_BUFFER
        try withRawSession(reuse: false, inputType: inputType) { session in
            if info.proRAW != nil {
                try ProRAWSource.validatedDecodeVersion(proRAWDecodeVersion)
                hdrSources.clear()
                _ = try ProRAWExporter.export(url: url, info: info, settings: settings, output: output, longEdge: longEdge,
                    format: format == UInt32(SONY2FUJI_HDR_TILED_HEIF) ? .hdrHEIF : .renderedDNG,
                    session: session, cancelled: cancelled, progress: progress)
            } else {
                _ = try HDRImage.exportTiled(url, info: info, settings: settings, output: output,
                    longEdge: longEdge, format: format, session: session, cancelled: cancelled, progress: progress)
            }
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
                    processing: ProcessingIdentity = .current,
                    proRAWDecodeVersion: Int? = nil,
                    sessionOverride: OpaquePointer? = nil,
                    progress: ((Double) -> Void)? = nil,
                    cancelled: () -> Bool = { false }) throws -> HDRImage {
        try withoutActuallyEscaping(cancelled) { cancelled in
            guard settings.mode == .hdr,settings.isValid else { throw HDRRequestError.invalidSettings }
            guard gpuMode != SONY2FUJI_GPU_FORCE else {
                throw HDRNativeError(status:SONY2FUJI_STATUS_UNSUPPORTED,reason:UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU),field:UInt32(SONY2FUJI_HDR_FIELD_SESSION))
            }
            guard let info = try HDRSourceInfo.probe(url) ?? HDRSourceInfo.probeRAW(url, processing: processing.core) else {
                throw HDRSettings.ModeError.unsupportedSource
            }
            if info.proRAW != nil { try ProRAWSource.validatedDecodeVersion(proRAWDecodeVersion) }
            if previewLongEdge == nil, info.proRAW != nil { hdrSources.clear() }
            let inputType = info.isCameraRAW ? SONY2FUJI_INPUT_RAW : SONY2FUJI_INPUT_DISPLAY_BUFFER
            let run: (OpaquePointer) throws -> HDRImage = { session in
                let decodeWeight = 0.4
                let source = try previewLongEdge.map {
                    try hdrPreviewSource(url, info: info, settings: settings, edge: $0, session: session, cancelled: cancelled)
                } ?? HDRImage.decode(url,info:info,intent:SONY2FUJI_INTENT_FINAL,
                                     session:session, camera:settings.cameraDevelopmentSettings,
                                     progress: progress.map { report in { report($0 * decodeWeight) } },
                                     cancelled:cancelled)
                if cancelled() { throw CancellationError() }
                if settings.isIdentity && exportLongEdge==nil &&
                    (previewLongEdge == nil || max(source.width, source.height) <= previewLongEdge!) {
                    progress?(1.0)
                    return source
                }
                let result = try source.rendered(
                    session:session, settings:settings,
                    intent:previewLongEdge==nil ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW,
                    longEdge:previewLongEdge ?? exportLongEdge,
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
        guard settings.mode == .hdr, settings.isValid else { throw HDRRequestError.invalidSettings }
        guard gpuMode != SONY2FUJI_GPU_FORCE else {
            throw HDRNativeError(status: SONY2FUJI_STATUS_UNSUPPORTED,
                                 reason: UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU),
                                 field: UInt32(SONY2FUJI_HDR_FIELD_SESSION))
        }
        guard let info = try HDRSourceInfo.probe(url) ?? HDRSourceInfo.probeRAW(url, processing: processing.core) else {
            throw HDRSettings.ModeError.unsupportedSource
        }
        if info.proRAW != nil { try ProRAWSource.validatedDecodeVersion(proRAWDecodeVersion) }
        if cancelled() { throw CancellationError() }
        let inputType = info.isCameraRAW ? SONY2FUJI_INPUT_RAW : SONY2FUJI_INPUT_DISPLAY_BUFFER
        return try withRawSession(reuse: true, inputType: inputType) { session in
            if let proRAW = info.proRAW, let stamp = info.cameraStamp {
                let bounds = try HDRImage.roiSourceBounds(
                    nativeWidth: proRAW.width, nativeHeight: proRAW.height,
                    settings: settings, roi: roi, longEdge: nil
                )
                if cancelled() { throw CancellationError() }
                let decoded = try proRAW.decodeROI(
                    url, stamp: stamp,
                    sourceX0: bounds.sourceX0, sourceY0: bounds.sourceY0,
                    sourceX1: bounds.sourceX1, sourceY1: bounds.sourceY1,
                    cancelled: cancelled
                )
                let tile = HDRImage.fromProRAW(pair: decoded.pair, url: url, info: info,
                                              buffers: (decoded.hdr, decoded.sdr))
                var tileRoi = roi
                tileRoi.sourceX0 = bounds.sourceX0
                tileRoi.sourceY0 = bounds.sourceY0
                tileRoi.fullSourceWidth = proRAW.width
                tileRoi.fullSourceHeight = proRAW.height
                let rendered = try tile.renderedROI(session: session, settings: settings, roi: tileRoi, longEdge: nil)
                return HDRROIRenderOutput(image: rendered.image, roi: rendered.result)
            }
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
        let sourceEdge = info.proRAW == nil ? edge : settings.geometry.isIdentity ? max(1280, edge) : ProRAWSource.previewLimit
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
        if info.proRAW != nil { try ProRAWSource.validatedDecodeVersion(proRAWDecodeVersion) }
        let inputType = info.isCameraRAW ? SONY2FUJI_INPUT_RAW : SONY2FUJI_INPUT_DISPLAY_BUFFER
        return try withRawSession(reuse: false, inputType: inputType) { session in
            let source = try hdrPreviewSource(url, info: info, settings: settings, edge: previewLongEdge, session: session)
            let request = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_PREVIEW, longEdge: previewLongEdge)
            return source.withPair {
                HSLTargetSample.capture(session: session, pair: $0, request: request, revision: revision, x: point.x, y: point.y)
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
        var sourceLensMetadata: DisplayLensMetadata? = nil
        var lensInfo: LensInfo? = nil

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
            var result = self
            result = Buffer(data: data, width: width, height: height, stride: stride,
                            pixelFormat: pixelFormat, semantic: semantic, nativeSize: nativeSize, isProxy: isProxy)
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
            let settings = try effectiveSettings(settings, session: session, url: url, inputType: inputType)
            try configureDisplayLens(session, metadata: buffer?.sourceLensMetadata, settings: settings.lensSettings)
            try applySessionParams(session, settings: settings, isRaster: inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER)
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
            // 仅确认源文件可读，原生尺寸由单次解包的 sony2fuji_process 自行读取。
            _ = try url.checkResourceIsReachable()
            inputType = SONY2FUJI_INPUT_RAW
            width = 0; height = 0
        } else if let buffer {
            inputType = semanticInputType(for: buffer)
            width = UInt32(buffer.width); height = UInt32(buffer.height)
        } else { throw ProcessorError.rasterDecodeFailed }
        return try withRawSession(reuse: url != nil, inputType: inputType) { session in
            let effective = try effectiveSettings(settings, session: session, url: url, inputType: inputType)
            try configureDisplayLens(session, metadata: buffer?.sourceLensMetadata, settings: effective.lensSettings)
            try configureSession(session, settings: effective, interactive: interactive, viewportPreview: true,
                                 isRaster: inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER)
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
            let effective = try effectiveSettings(settings, session: session, url: url, inputType: inputType)
            try configureDisplayLens(session, metadata: buffer?.sourceLensMetadata, settings: effective.lensSettings)
            try configureSession(session, settings: effective, interactive: interactive, viewportPreview: true,
                                 isRaster: inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER)
            var request = makeBaseRequest(settings: effective, inputType: inputType)
            request.input_type = inputType
            applySize(&request, width: width, height: height, previewLongEdge: previewLongEdge, exportLongEdge: nil)
            request.lut_strength = lutURL == nil ? 0 : effective.clampedLUTStrength
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
            let status: sony2fuji_status = (lutURL?.path ?? "").withCString { look in
                request.lut_path = lutURL == nil ? nil : look
                if let url {
                    return url.path.withCString { path in
                        request.input_path = path
                        return sony2fuji_session_sample_wb_probe(session, &request, &query, &result)
                    }
                }
                guard let buffer else { return SONY2FUJI_STATUS_INVALID_ARGUMENT }
                request.input_width = UInt32(buffer.width); request.input_height = UInt32(buffer.height)
                request.input_pixel_format = buffer.pixelFormat; request.input_color_space = SONY2FUJI_COLOR_SRGB
                return buffer.data.withUnsafeBytes { bytes in
                    request.input_pixels = bytes.baseAddress
                    return sony2fuji_session_sample_wb_probe(session, &request, &query, &result)
                }
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
            let effective = try effectiveSettings(settings, session: session, url: isRaw ? url : nil, inputType: inputType)
            try configureDisplayLens(session, metadata: raster?.sourceLensMetadata, settings: effective.lensSettings)
            try configureSession(session, settings: effective, interactive: false, viewportPreview: false,
                                 isRaster: inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER)
            var request = makeBaseRequest(settings: effective, inputType: inputType)
            request.input_type = inputType
            request.intent = SONY2FUJI_INTENT_FINAL
            request.size_mode = SONY2FUJI_SIZE_NATIVE
            request.lut_strength = lutURL == nil ? 0 : effective.clampedLUTStrength
            let context = Unmanaged.passUnretained(cancellation).toOpaque()
            _ = sony2fuji_session_set_cancellation_callback(session, { pointer in
                guard let pointer else { return 0 }
                return Unmanaged<ProcessingMigrationCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
            }, context)
            defer { _ = sony2fuji_session_set_cancellation_callback(session, nil, nil) }
            var native = sony2fuji_processing_migration_result()
            let status = (lutURL?.path ?? "").withCString { look in
                request.lut_path = lutURL == nil ? nil : look
                if let raster {
                    request.input_width = UInt32(raster.width); request.input_height = UInt32(raster.height)
                    request.input_pixel_format = raster.pixelFormat
                    request.input_color_space = SONY2FUJI_COLOR_SRGB
                    request.input_is_linear = 0
                    return raster.data.withUnsafeBytes { bytes in
                        request.input_pixels = bytes.baseAddress
                        return sony2fuji_session_migrate_processing(session, &request, &native)
                    }
                }
                return url.path.withCString { path in
                    request.input_path = path
                    return sony2fuji_session_migrate_processing(session, &request, &native)
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
                    let settings = try prepareRecipe(settings, session: session, url: url)
                    if box.check() { throw CancellationError() }
                    try configureSession(session, settings: settings,
                                         interactive: interactive && previewLongEdge != nil && exportLongEdge == nil,
                                         viewportPreview: viewportPreview && previewLongEdge != nil && exportLongEdge == nil)

                    var request = makeBaseRequest(settings: settings, inputType: SONY2FUJI_INPUT_RAW)
                    request.input_type = SONY2FUJI_INPUT_RAW
                    applySize(&request, width: 0, height: 0,
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
                    if status == SONY2FUJI_STATUS_CANCELLED || box.check() {
                        throw CancellationError()
                    }
                    guard status == SONY2FUJI_STATUS_OK else {
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

    func canFastMetalFullRes(url: URL, settings: RawSettings, lutURL: URL?) -> Bool {
        guard gpuMode != SONY2FUJI_GPU_OFF,
              !settings.isHDREditing,
              !settings.denoise.enabled,
              settings.displayChromaDenoise == 0 else {
            return false
        }
        let resolved = settings.masterRecipeID == nil
            ? settings
            : settings.renderedRecipe(cameraTemperature: 6500, cameraTint: 0)
        guard resolved.geometrySettings.isIdentity,
              resolved.atmosphereSettings.isIdentity,
              resolved.curveSettings.channels.isIdentity,
              (resolved.curveSettings.mode != .custom || resolved.curveSettings.master.isIdentity),
              !(resolved.processing.core == SONY2FUJI_PROCESSING_BASIC_V3 &&
                (resolved.highlights != 0 || resolved.shadows != 0 || resolved.contrast != 1 || !resolved.toneSettings.isIdentity)),
              !isNormalX3f(url, settings: resolved) else {
            return false
        }
        if let lutURL {
            let ext = lutURL.pathExtension.lowercased()
            if ext != "cube" && ext != "rlook" {
                return false
            }
        }
        return true
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
                let prepared = try prepareRecipe(settings, session: session, url: url)
                if isCancelled() { throw CancellationError() }
                try configureSession(session, settings: prepared, interactive: false, viewportPreview: viewportPreview)
                let roiStatus = applyViewportROI(session: session, roi: nil)
                guard roiStatus == SONY2FUJI_STATUS_OK else {
                    throw processingFailure(roiStatus, session: session)
                }

                var request = makeBaseRequest(settings: prepared, inputType: SONY2FUJI_INPUT_RAW)
                request.input_type = SONY2FUJI_INPUT_RAW
                applySize(&request, width: 0, height: 0, previewLongEdge: CGFloat(max(1, longEdge)), exportLongEdge: nil)
                request.lut_strength = lutURL == nil ? 0 : prepared.clampedLUTStrength

                var buffer = sony2fuji_buffer()
                defer { sony2fuji_release_buffer(&buffer) }
                let status = processRaw(
                    session: session,
                    request: &request,
                    inputPath: url.path,
                    lutPath: lutURL?.path,
                    outBuffer: &buffer
                )
                if status == SONY2FUJI_STATUS_CANCELLED || isCancelled() {
                    throw CancellationError()
                }
                guard status == SONY2FUJI_STATUS_OK else {
                    throw processingFailure(status, session: session)
                }
                let normalX3f = isNormalX3f(url, settings: prepared)
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
                let settings = try prepareRecipe(settings, session: session, url: url)
                if isCancelled() { throw CancellationError() }
                try configureSession(session, settings: settings, interactive: false, viewportPreview: true)
                let roiStatus = applyViewportROI(session: session, roi: roi)
                guard roiStatus == SONY2FUJI_STATUS_OK else {
                    throw processingFailure(roiStatus, session: session)
                }
                defer { _ = applyViewportROI(session: session, roi: nil) }

                var request = makeBaseRequest(settings: settings, inputType: SONY2FUJI_INPUT_RAW)
                request.input_type = SONY2FUJI_INPUT_RAW
                applySize(&request, width: 0, height: 0, previewLongEdge: 1280, exportLongEdge: nil)
                request.lut_strength = lutURL == nil ? 0 : settings.clampedLUTStrength

                var buffer = sony2fuji_buffer()
                defer { sony2fuji_release_buffer(&buffer) }
                let status = processRaw(
                    session: session,
                    request: &request,
                    inputPath: url.path,
                    lutPath: lutURL?.path,
                    outBuffer: &buffer
                )
                if status == SONY2FUJI_STATUS_CANCELLED || isCancelled() {
                    throw CancellationError()
                }
                guard status == SONY2FUJI_STATUS_OK else {
                    throw processingFailure(status, session: session)
                }
                guard let result = readViewportROIResult(session: session) else {
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
            try configureDisplayLens(session, metadata: buffer.sourceLensMetadata, settings: settings.lensSettings)
            try configureSession(session, settings: settings,
                                 interactive: interactive && previewLongEdge != nil && exportLongEdge == nil,
                                 viewportPreview: viewportPreview && previewLongEdge != nil && exportLongEdge == nil,
                                 isRaster: inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER)

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
                let settings = try effectiveSettings(settings, session: session, url: nil, inputType: inputType)
                try configureDisplayLens(session, metadata: buffer.sourceLensMetadata, settings: settings.lensSettings)
                try configureSession(session, settings: settings, interactive: false, viewportPreview: true,
                                     isRaster: inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER)
                let roiStatus = applyViewportROI(session: session, roi: nil)
                guard roiStatus == SONY2FUJI_STATUS_OK else {
                    throw processingFailure(roiStatus, session: session)
                }

                var request = makeBaseRequest(settings: settings, inputType: inputType)
                request.input_type = inputType
                request.input_width = UInt32(buffer.width)
                request.input_height = UInt32(buffer.height)
                request.input_pixel_format = buffer.pixelFormat
                request.input_color_space = SONY2FUJI_COLOR_SRGB
                request.input_is_linear = 0
                applySize(&request, width: UInt32(buffer.width), height: UInt32(buffer.height),
                          previewLongEdge: CGFloat(max(1, longEdge)), exportLongEdge: nil)
                request.lut_strength = lutURL == nil ? 0 : settings.clampedLUTStrength

                var outBuffer = sony2fuji_buffer()
                defer { sony2fuji_release_buffer(&outBuffer) }
                let status = processBuffer(
                    session: session,
                    request: &request,
                    buffer: buffer,
                    lutPath: lutURL?.path,
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
                let settings = try effectiveSettings(settings, session: session, url: nil, inputType: inputType)
                try configureDisplayLens(session, metadata: buffer.sourceLensMetadata, settings: settings.lensSettings)
                try configureSession(session, settings: settings, interactive: false, viewportPreview: true,
                                     isRaster: inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER)
                let roiStatus = applyViewportROI(session: session, roi: roi)
                guard roiStatus == SONY2FUJI_STATUS_OK else {
                    throw processingFailure(roiStatus, session: session)
                }
                defer { _ = applyViewportROI(session: session, roi: nil) }

                var request = makeBaseRequest(settings: settings, inputType: inputType)
                request.input_type = inputType
                request.input_width = UInt32(buffer.width)
                request.input_height = UInt32(buffer.height)
                request.input_pixel_format = buffer.pixelFormat
                request.input_color_space = SONY2FUJI_COLOR_SRGB
                request.input_is_linear = 0
                applySize(&request, width: UInt32(buffer.width), height: UInt32(buffer.height),
                          previewLongEdge: 1280, exportLongEdge: nil)
                request.lut_strength = lutURL == nil ? 0 : settings.clampedLUTStrength

                var outBuffer = sony2fuji_buffer()
                defer { sony2fuji_release_buffer(&outBuffer) }
                let status = processBuffer(
                    session: session,
                    request: &request,
                    buffer: buffer,
                    lutPath: lutURL?.path,
                    outBuffer: &outBuffer
                )
                if status == SONY2FUJI_STATUS_CANCELLED || isCancelled() {
                    throw CancellationError()
                }
                guard status == SONY2FUJI_STATUS_OK else {
                    throw processingFailure(status, session: session)
                }
                guard let result = readViewportROIResult(session: session) else {
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
            let settings = try prepareRecipe(settings, session: session, url: url)
            try configureSession(session, settings: settings, interactive: false)

            var request = makeBaseRequest(settings: settings, inputType: SONY2FUJI_INPUT_RAW)
            request.input_type = SONY2FUJI_INPUT_RAW
            applySize(&request, width: 0, height: 0, previewLongEdge: nil, exportLongEdge: exportLongEdge)
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
            try configureDisplayLens(session, metadata: buffer.sourceLensMetadata, settings: settings.lensSettings)
            try configureSession(session, settings: settings, interactive: false,
                                 isRaster: inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER)

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
                throw processingFailure(status, look: lutURL, output: outputURL, session: session)
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
        _ = applyingOrientation
        if let edge = previewLongEdge {
            let meta = try validateDisplayImageMetadata(url: url)
            if meta.orientedMax > edge {
                let nativeSize = CGSize(width: meta.orientedWidth, height: meta.orientedHeight)
                if !meta.rgb16 && !meta.hasAlpha && !meta.tiffPair {
                    let buffer = try autoreleasepool { () throws -> Buffer in
                        let options: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: edge,
                            kCGImageSourceShouldCacheImmediately: true
                        ]
                        guard var image = CGImageSourceCreateThumbnailAtIndex(meta.imageSource, 0, options as CFDictionary) else {
                            throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR)
                        }
                        guard image.bitsPerComponent == 8,
                              !image.bitmapInfo.contains(.floatComponents),
                              let decodedSpace = image.colorSpace,
                              decodedSpace.model == .rgb,
                              !isHDRColorSpace(decodedSpace) else {
                            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
                        }
                        if let expectedName = meta.pngColorSpaceName {
                            guard let expectedSpace = CGColorSpace(name: expectedName),
                                  expectedSpace == decodedSpace else {
                                throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
                            }
                        }
                        if !meta.hasProfile && meta.pngColorSpaceName == nil {
                            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                                  let retagged = image.copy(colorSpace: sRGB) else {
                                throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR)
                            }
                            image = retagged
                        }
                        return try renderDisplayRGBA8Buffer(
                            from: image,
                            targetWidth: image.width,
                            targetHeight: image.height,
                            checkOpaqueAlpha: !isOpaqueAlphaInfo(image.alphaInfo),
                            nativeSize: nativeSize,
                            isProxy: true,
                            sourceURL: url
                        )
                    }
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
                let buffer = try autoreleasepool { () throws -> Buffer in
                    guard let fullImage = makeDisplayCGImage(from: native) else {
                        throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR)
                    }
                    let scale = Double(edge) / Double(max(Int(native.width), Int(native.height)))
                    let targetWidth = max(1, Int((Double(native.width) * scale).rounded()))
                    let targetHeight = max(1, Int((Double(native.height) * scale).rounded()))
                    return try renderDisplayRGBA8Buffer(
                        from: fullImage,
                        targetWidth: targetWidth,
                        targetHeight: targetHeight,
                        checkOpaqueAlpha: false,
                        nativeSize: nativeSize,
                        isProxy: true,
                        sourceURL: url
                    )
                }
                return ProcessResult(buffer: buffer, orientation: .up, rawWhiteBalance: nil)
            }
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
