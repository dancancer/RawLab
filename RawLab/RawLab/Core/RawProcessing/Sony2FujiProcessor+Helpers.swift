import CoreGraphics
import Foundation
import ImageIO
import UIKit

extension Sony2FujiProcessor {
    func loadMetadata(from url: URL) throws -> ImageMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw ProcessorError.metadataUnavailable
        }

        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint32Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint32Value,
              width > 0,
              height > 0
        else {
            throw ProcessorError.invalidDimensions
        }

        let orientationValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        let orientation = orientationValue.flatMap { CGImagePropertyOrientation(rawValue: $0) }
        return ImageMetadata(width: width, height: height, orientation: orientation)
    }

    func createSession() throws -> OpaquePointer {
        var session: OpaquePointer?
        let status = sony2fuji_session_create(&session)
        guard status == SONY2FUJI_STATUS_OK, let session else {
            throw ProcessorError.sessionCreateFailed(statusMessage(status))
        }
        return session
    }

    func destroySession(_ session: OpaquePointer) {
        _ = sony2fuji_session_destroy(session)
    }

    func configureSession(_ session: OpaquePointer, settings: RawSettings, interactive: Bool) throws {
        var config = sony2fuji_gpu_config()
        config.version = SONY2FUJI_GPU_CONFIG_VERSION
        config.struct_size = UInt32(MemoryLayout<sony2fuji_gpu_config>.size)
        config.mode = SONY2FUJI_GPU_OFF
        _ = sony2fuji_session_set_gpu_config(session, &config)
        guard settings.denoise.isValid else { throw ProcessorError.processFailed("Invalid denoise strengths.") }
        var denoise = sony2fuji_wavelet_denoise_config()
        denoise.version = UInt32(SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION)
        denoise.struct_size = UInt32(MemoryLayout<sony2fuji_wavelet_denoise_config>.size)
        denoise.enabled = settings.denoise.enabled ? 1 : 0
        denoise.luma = Float(settings.denoise.luma)
        denoise.chroma = Float(settings.denoise.chroma)
        denoise.coarse = Float(settings.denoise.coarse)
        let status = sony2fuji_session_set_wavelet_denoise(session, &denoise)
        guard status == SONY2FUJI_STATUS_OK else { throw ProcessorError.processFailed(statusMessage(status)) }
        let previewStatus = sony2fuji_session_set_interactive_preview(session, interactive ? 1 : 0)
        guard previewStatus == SONY2FUJI_STATUS_OK else { throw ProcessorError.processFailed(statusMessage(previewStatus)) }
    }

    func makeBaseRequest(settings: RawSettings) -> sony2fuji_request {
        var request = sony2fuji_request()
        request.version = SONY2FUJI_REQUEST_VERSION
        request.struct_size = UInt32(MemoryLayout<sony2fuji_request>.size)
        request.output_target = SONY2FUJI_TARGET_BUFFER
        request.output_format = SONY2FUJI_OUTPUT_RGBA8
        request.jpeg_quality = 95
        request.wb_mode = SONY2FUJI_WB_CAMERA
        request.wb_mul = (1, 1, 1, 1)
        request.exposure_ev = Float(settings.exposure)
        request.brightness = 1
        request.contrast = Float(settings.contrast)
        request.saturation = Float(settings.saturation)
        request.temperature = Float(settings.temperature)
        request.tint = Float(settings.tint)
        request.highlights = Float(settings.highlights)
        request.shadows = Float(settings.shadows)
        request.tone_curve = Float(settings.toneCurve)
        request.noise_reduction = settings.denoise.enabled ? 0 : Float(settings.noiseReduction)
        request.sharpening = Float(settings.sharpening)
        return request
    }

    func applySize(
        _ request: inout sony2fuji_request,
        width: UInt32,
        height: UInt32,
        previewLongEdge: CGFloat?
    ) {
        if let edge = previewLongEdge, edge > 0 {
            let edgeValue = UInt32(edge.rounded())
            request.intent = SONY2FUJI_INTENT_PREVIEW
            request.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE
            request.long_edge = edgeValue
            request.preview_long_edge = edgeValue
        } else {
            request.intent = SONY2FUJI_INTENT_FINAL
            request.size_mode = SONY2FUJI_SIZE_NATIVE
            request.target_width = width
            request.target_height = height
        }
    }

    func processRaw(
        session: OpaquePointer,
        request: inout sony2fuji_request,
        inputPath: String,
        lutPath: String?,
        outBuffer: inout sony2fuji_buffer
    ) -> sony2fuji_status {
        inputPath.withCString { inputPtr in
            request.input_path = inputPtr
            if let lutPath {
                return lutPath.withCString { lutPtr in
                    request.lut_path = lutPtr
                    return sony2fuji_process(session, &request, &outBuffer)
                }
            }
            request.lut_path = nil
            return sony2fuji_process(session, &request, &outBuffer)
        }
    }

    func processBuffer(
        session: OpaquePointer,
        request: inout sony2fuji_request,
        buffer: Buffer,
        lutPath: String?,
        outBuffer: inout sony2fuji_buffer
    ) -> sony2fuji_status {
        buffer.data.withUnsafeBytes { bytes in
            request.input_pixels = bytes.baseAddress
            if let lutPath {
                return lutPath.withCString { lutPtr in
                    request.lut_path = lutPtr
                    return sony2fuji_process(session, &request, &outBuffer)
                }
            }
            request.lut_path = nil
            return sony2fuji_process(session, &request, &outBuffer)
        }
    }

    func copyBuffer(_ buffer: sony2fuji_buffer) throws -> Buffer {
        guard let baseAddress = buffer.data,
              buffer.width > 0,
              buffer.height > 0,
              buffer.size_bytes > 0
        else {
            throw ProcessorError.bufferCopyFailed
        }

        let data = Data(bytes: baseAddress, count: Int(buffer.size_bytes))
        return Buffer(
            data: data,
            width: Int(buffer.width),
            height: Int(buffer.height),
            stride: Int(buffer.stride_bytes),
            pixelFormat: buffer.pixel_format
        )
    }

    func makeCGImage(from buffer: Buffer) -> CGImage? {
        guard let provider = CGDataProvider(data: buffer.data as CFData) else {
            return nil
        }

        let bitsPerComponent = 8
        let channels = buffer.pixelFormat == SONY2FUJI_PIXEL_RGBA8 ? 4 : 3
        let bitsPerPixel = bitsPerComponent * channels

        return CGImage(
            width: buffer.width,
            height: buffer.height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: buffer.stride,
            space: outputColorSpace(),
            bitmapInfo: bitmapInfo(for: channels),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    func outputColorSpace() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    func bitmapInfo(for channels: Int) -> CGBitmapInfo {
        if channels == 4 {
            let alphaInfo = CGImageAlphaInfo.premultipliedLast
            return CGBitmapInfo(rawValue: alphaInfo.rawValue).union(.byteOrder32Big)
        }
        let alphaInfo = CGImageAlphaInfo.none
        return CGBitmapInfo(rawValue: alphaInfo.rawValue)
    }

    func statusMessage(_ status: sony2fuji_status) -> String {
        guard let message = sony2fuji_status_message(status) else {
            return "unknown"
        }
        return String(cString: message)
    }
}

extension UIImage.Orientation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up:
            self = .up
        case .upMirrored:
            self = .upMirrored
        case .down:
            self = .down
        case .downMirrored:
            self = .downMirrored
        case .left:
            self = .left
        case .leftMirrored:
            self = .leftMirrored
        case .right:
            self = .right
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
