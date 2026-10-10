import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct Sony2FujiProcessor {
    // =========================================================================
    // Types
    // =========================================================================

    struct ImageMetadata {
        let width: UInt32
        let height: UInt32
        let orientation: CGImagePropertyOrientation?
    }

    struct Buffer {
        let data: Data
        let width: Int
        let height: Int
        let stride: Int
        let pixelFormat: sony2fuji_pixel_format

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
    }

    struct RawWhiteBalance: Codable, Equatable {
        let temperature: Double
        let tint: Double
        let isCalibrated: Bool
    }

    enum ProcessorError: LocalizedError {
        case metadataUnavailable
        case invalidDimensions
        case sessionCreateFailed(String)
        case processFailed(String)
        case bufferCopyFailed
        case rasterDecodeFailed
        case histogramFailed(String)
        case invalidExportSize

        var errorDescription: String? {
            switch self {
            case .metadataUnavailable:
                return "Image metadata unavailable."
            case .invalidDimensions:
                return "Image metadata has invalid dimensions."
            case .sessionCreateFailed(let message):
                return "Sony2Fuji session create failed: \(message)"
            case .processFailed(let message):
                return "Sony2Fuji process failed: \(message)"
            case .bufferCopyFailed:
                return "Sony2Fuji output copy failed."
            case .rasterDecodeFailed:
                return "Raster decode failed."
            case .histogramFailed(let message):
                return "Histogram failed: \(message)"
            case .invalidExportSize:
                return "导出长边必须在 1 到 65535 像素之间。"
            }
        }
    }

    // =========================================================================
    // Public API
    // =========================================================================

    func processRaw(
        url: URL,
        settings: RawSettings,
        previewLongEdge: CGFloat?,
        lutURL: URL?,
        interactive: Bool = false,
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
        let session = try createSession()
        defer { destroySession(session) }
        try configureSession(session, settings: settings,
                             interactive: interactive && previewLongEdge != nil && exportLongEdge == nil)

        var request = makeBaseRequest(settings: settings, inputType: SONY2FUJI_INPUT_RAW)
        request.input_type = SONY2FUJI_INPUT_RAW
        applySize(&request, width: targetWidth, height: targetHeight,
                  previewLongEdge: previewLongEdge, exportLongEdge: exportLongEdge)
        let lutStrength = lutURL == nil ? 0 : settings.clampedLUTStrength
        request.lut_strength = lutStrength

        var buffer = sony2fuji_buffer()
        let status = processRaw(
            session: session,
            request: &request,
            inputPath: url.path,
            lutPath: lutURL?.path,
            outBuffer: &buffer
        )
        guard status == SONY2FUJI_STATUS_OK else {
            throw ProcessorError.processFailed(statusMessage(status))
        }

        let output = try copyBuffer(buffer)
        let rawWhiteBalance = readRawWhiteBalance(from: session)
        sony2fuji_release_buffer(&buffer)
        return ProcessResult(buffer: output, orientation: .up, rawWhiteBalance: rawWhiteBalance)
    }

    func processBuffer(
        buffer: Buffer,
        settings: RawSettings,
        previewLongEdge: CGFloat?,
        lutURL: URL?,
        interactive: Bool = false,
        exportLongEdge: Int? = nil
    ) throws -> Buffer {
        guard ExportSize.isValid(exportLongEdge) else {
            throw ProcessorError.invalidExportSize
        }
        let session = try createSession()
        defer { destroySession(session) }
        try configureSession(session, settings: settings,
                             interactive: interactive && previewLongEdge != nil && exportLongEdge == nil)

        var request = makeBaseRequest(settings: settings, inputType: SONY2FUJI_INPUT_BUFFER)
        request.input_type = SONY2FUJI_INPUT_BUFFER
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
        let status = processBuffer(
            session: session,
            request: &request,
            buffer: buffer,
            lutPath: lutURL?.path,
            outBuffer: &outBuffer
        )
        guard status == SONY2FUJI_STATUS_OK else {
            throw ProcessorError.processFailed(statusMessage(status))
        }

        let output = try copyBuffer(outBuffer)
        sony2fuji_release_buffer(&outBuffer)
        return output
    }

    func loadRasterBuffer(url: URL) throws -> ProcessResult {
        let metadata = try loadMetadata(from: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ProcessorError.rasterDecodeFailed
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let colorSpace = outputColorSpace()
        let bitmapInfo = bitmapInfo(for: 4)

        let didDraw = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard didDraw else {
            throw ProcessorError.rasterDecodeFailed
        }

        let buffer = Buffer(
            data: data,
            width: width,
            height: height,
            stride: bytesPerRow,
            pixelFormat: SONY2FUJI_PIXEL_RGBA8
        )
        return ProcessResult(buffer: buffer, orientation: metadata.orientation, rawWhiteBalance: nil)
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
