import CoreImage
import CryptoKit
import Darwin
import Foundation
import Metal

enum ProRAWExporter {
    @discardableResult
    static func export(url: URL, info: HDRSourceInfo, settings: HDRSettings, output: URL,
                       longEdge: Int? = nil, keepHDR: Bool, session: OpaquePointer,
                       temporaryRoot: URL = FileManager.default.temporaryDirectory,
                       cancelled: () -> Bool = { false }) throws -> sony2fuji_hdr_stream_result_v1 {
        guard let source = info.proRAW, let stamp = info.cameraStamp else {
            throw HDRSettings.ModeError.unsupportedSource
        }
        var request = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_FINAL, longEdge: longEdge)
        return try withoutActuallyEscaping(cancelled) { cancellation in
            let reader = Reader(url: url, source: source, stamp: stamp, cancelled: cancellation)
            defer { reader.releaseDecoder() }
            let digest = try reader.fingerprint()
            var input = sony2fuji_hdr_stream_source_v1()
            input.version = 1; input.struct_size = UInt32(MemoryLayout.size(ofValue: input))
            input.native_width = UInt32(source.width); input.native_height = UInt32(source.height)
            input.orientation_applied = 1; input.source_intent = UInt32(SONY2FUJI_INTENT_FINAL.rawValue)
            input.decode_revision = UInt64(ProRAWSource.decodeVersion)
            _ = withUnsafeMutableBytes(of: &input.source_sha256) { digest.copyBytes(to: $0) }
            input.context = Unmanaged.passUnretained(reader).toOpaque()
            input.read_rows = { context, hdr, first, count, output in
                let reader = Unmanaged<Reader>.fromOpaque(context!).takeUnretainedValue()
                return reader.perform { try reader.read(hdr: hdr != 0, first: Int(first), count: Int(count), output: output!) }
            }
            input.finish_decode = { context in
                let reader = Unmanaged<Reader>.fromOpaque(context!).takeUnretainedValue()
                return reader.perform {
                    reader.releaseDecoder()
                    try reader.validateSource()
                }
            }
            input.is_cancelled = { context in
                Unmanaged<Reader>.fromOpaque(context!).takeUnretainedValue().isCancelled ? 1 : 0
            }
            var config = sony2fuji_hdr_export_config_v1()
            config.version = 1; config.struct_size = UInt32(MemoryLayout.size(ofValue: config))
            config.jpeg_quality = 95; config.base_color = UInt32(SONY2FUJI_HDR_COLOR_DISPLAY_P3)
            config.metadata_policy = UInt32(SONY2FUJI_HDR_METADATA_ISO_XMP)
            config.source_sha256 = input.source_sha256
            var result = sony2fuji_hdr_stream_result_v1()
            result.version = 1; result.struct_size = UInt32(MemoryLayout.size(ofValue: result))
            var diagnostic = sony2fuji_hdr_diagnostic_v1()
            diagnostic.version = 1; diagnostic.struct_size = UInt32(MemoryLayout.size(ofValue: diagnostic))
            let status = source.decoder.withCString { decoder in
                url.path.withCString { sourcePath in
                    output.path.withCString { outputPath in
                        temporaryRoot.path.withCString { temporaryPath in
                            input.decoder_identifier = decoder
                            config.metadata_source_path = sourcePath
                            return sony2fuji_hdr_export_stream(session, &input, &request, &config, keepHDR ? 1 : 0,
                                temporaryPath, outputPath, &result, &diagnostic)
                        }
                    }
                }
            }
            if let failure = reader.failure { throw failure }
            if status == SONY2FUJI_STATUS_CANCELLED { throw CancellationError() }
            guard status == SONY2FUJI_STATUS_OK else {
                throw HDRNativeError(status: status, reason: diagnostic.reason, field: diagnostic.field)
            }
            return result
        }
    }

    private final class Reader {
        let url: URL
        let source: ProRAWSource
        let stamp: HDRSourceInfo.CameraStamp
        let cancelled: () -> Bool
        var failure: Error?
        private var raw: CIRAWFilter?
        private var context: CIContext?
        private var image: CIImage?
        private var rendition: Bool?
        private var rgba = [Float]()
        private let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        var isCancelled: Bool { cancelled() || Task.isCancelled }

        init(url: URL, source: ProRAWSource, stamp: HDRSourceInfo.CameraStamp, cancelled: @escaping () -> Bool) {
            self.url = url; self.source = source; self.stamp = stamp; self.cancelled = cancelled
        }

        func checkCancellation() throws { if isCancelled { throw CancellationError() } }

        func validateSource() throws {
            try checkCancellation()
            guard (try? HDRSourceInfo.CameraStamp(url)) == stamp else { throw ProRAWSource.changedSource }
        }

        func fingerprint() throws -> Data {
            try validateSource()
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try checkCancellation(); hash.update(data: bytes)
            }
            try validateSource()
            return Data(hash.finalize())
        }

        func perform(_ operation: () throws -> Void) -> sony2fuji_status {
            do { try operation(); return SONY2FUJI_STATUS_OK }
            catch {
                failure = error
                if error is CancellationError { return SONY2FUJI_STATUS_CANCELLED }
                return (error as? HDRNativeError)?.status ?? SONY2FUJI_STATUS_PROCESSING_ERROR
            }
        }

        func read(hdr: Bool, first: Int, count: Int, output: UnsafeMutablePointer<Float>) throws {
            try autoreleasepool {
                try validateSource()
                guard first >= 0, count > 0, count <= 256, first + count <= source.height else {
                    throw HDRRequestError.invalidSettings
                }
                if raw == nil {
                    // 仅估算系统显影和行块；后续 codec 在解码器释放后单独准入。
                    malloc_zone_pressure_relief(nil, 0)
                    try ProRAWSource.checkMemory(requiredBytes: UInt64(source.width) * UInt64(source.height) * 16 + (128 << 20))
                    guard let filter = CIRAWFilter(imageURL: url), filter.decoderVersion.rawValue == source.decoder else {
                        throw HDRSettings.ModeError.unsupportedSource
                    }
                    raw = filter
                    var options: [CIContextOption: Any] = [.workingColorSpace: color, .cacheIntermediates: false]
                    if #available(macOS 26, iOS 26, *) { options[.memoryTarget] = 256 }
                    if let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device, options: options) }
                    else { context = CIContext(options: options) }
                    rgba = [Float](repeating: .nan, count: source.width * min(256, source.height) * 4)
                }
                if rendition != hdr {
                    guard first == 0 else { throw HDRRequestError.invalidSettings }
                    context?.clearCaches()
                    raw!.extendedDynamicRangeAmount = hdr ? 1 : 0
                    image = raw!.outputImage; rendition = hdr
                }
                guard let image, let context else { throw HDRSettings.ModeError.unsupportedSource }
                let bounds = image.extent.integral
                guard bounds.width == CGFloat(source.width), bounds.height == CGFloat(source.height) else {
                    throw HDRSettings.ModeError.unsupportedSource
                }
                let tile = CGRect(x: bounds.minX, y: bounds.maxY - CGFloat(first + count),
                                  width: bounds.width, height: CGFloat(count))
                try rgba.withUnsafeMutableBufferPointer { values in
                    for i in 0..<(source.width * count) { values[i * 4 + 3] = .nan }
                    context.render(image, toBitmap: values.baseAddress!, rowBytes: source.width * 16,
                                   bounds: tile, format: .RGBAf, colorSpace: color)
                    try checkCancellation()
                    for i in 0..<(source.width * count) {
                        let r = values[i * 4], g = values[i * 4 + 1], b = values[i * 4 + 2]
                        guard values[i * 4 + 3].isFinite, r.isFinite, g.isFinite, b.isFinite else {
                            throw HDRNativeError(status: SONY2FUJI_STATUS_PROCESSING_ERROR,
                                reason: UInt32(SONY2FUJI_HDR_REASON_NONFINITE), field: UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
                        }
                        output[i * 3] = hdr ? r : min(1, max(0, r))
                        output[i * 3 + 1] = hdr ? g : min(1, max(0, g))
                        output[i * 3 + 2] = hdr ? b : min(1, max(0, b))
                    }
                }
            }
        }

        func releaseDecoder() {
            autoreleasepool {
                context?.clearCaches(); image = nil; raw = nil; context = nil
                rgba.removeAll(keepingCapacity: false)
            }
        }
    }
}
