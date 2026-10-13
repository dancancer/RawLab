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

    func configureSession(_ session: OpaquePointer, settings: RawSettings, interactive: Bool,
                          viewportPreview: Bool = false) throws {
        try configureLens(session, settings: settings.lensSettings)
        let exposureMode = sony2fuji_raw_exposure_mode(rawValue: UInt32(settings.exposureMode.rawValue))
        guard sony2fuji_session_set_raw_exposure_mode(session, exposureMode) == SONY2FUJI_STATUS_OK,
              settings.hsl.isValid else { throw ProcessorError.processFailed(L10n.text("Invalid exposure mode or HSL parameters.")) }
        var hsl = settings.hsl.nativeConfig
        guard sony2fuji_session_set_hsl(session, &hsl) == SONY2FUJI_STATUS_OK else {
            throw ProcessorError.processFailed(L10n.text("Invalid HSL parameters."))
        }
        var config = sony2fuji_gpu_config()
        config.version = SONY2FUJI_GPU_CONFIG_VERSION
        config.struct_size = UInt32(MemoryLayout<sony2fuji_gpu_config>.size)
        config.mode = gpuMode
        let gpuStatus = sony2fuji_session_set_gpu_config(session, &config)
        guard gpuStatus == SONY2FUJI_STATUS_OK else {
            throw ProcessorError.processFailed(L10n.format("Invalid GPU configuration: %@", statusMessage(gpuStatus)))
        }
        guard settings.photoEffects.isValid else { throw ProcessorError.processFailed(L10n.text("Invalid photo effects.")) }
        var effects = sony2fuji_photo_effects_config()
        effects.version = UInt32(SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION)
        effects.struct_size = UInt32(MemoryLayout<sony2fuji_photo_effects_config>.size)
        effects.vignette_amount = Float(settings.photoEffects.vignetteAmount)
        effects.vignette_midpoint = Float(settings.photoEffects.vignetteMidpoint)
        effects.vignette_roundness = Float(settings.photoEffects.vignetteRoundness)
        effects.vignette_feather = Float(settings.photoEffects.vignetteFeather)
        effects.vignette_highlights = Float(settings.photoEffects.vignetteHighlights)
        effects.grain_amount = Float(settings.photoEffects.grainAmount)
        effects.grain_size = Float(settings.photoEffects.grainSize)
        effects.grain_roughness = Float(settings.photoEffects.grainRoughness)
        let effectsStatus = sony2fuji_session_set_photo_effects(session, &effects)
        guard effectsStatus == SONY2FUJI_STATUS_OK else {
            throw ProcessorError.processFailed(L10n.format("Invalid photo effects: %@", statusMessage(effectsStatus)))
        }
        let chromaMode = Int32(settings.displayChromaDenoise)
        let chromaStatus = sony2fuji_session_set_chroma_denoise(session, chromaMode)
        guard chromaStatus == SONY2FUJI_STATUS_OK else {
            throw ProcessorError.processFailed(L10n.format("Invalid display chroma denoise mode: %@", statusMessage(chromaStatus)))
        }
        guard settings.denoise.isValid else { throw ProcessorError.processFailed(L10n.text("Invalid denoise strengths.")) }
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
        let viewportStatus = sony2fuji_session_set_viewport_preview(session, viewportPreview ? 1 : 0)
        guard viewportStatus == SONY2FUJI_STATUS_OK else { throw ProcessorError.processFailed(statusMessage(viewportStatus)) }
    }

    func prepareRecipe(_ settings: RawSettings, session: OpaquePointer, url: URL?) throws -> RawSettings {
        guard settings.masterRecipeID != nil else { return settings }
        guard let url else { return settings.renderedRecipe(cameraTemperature: 6500, cameraTint: 0) }
        if settings.whiteBalanceMode == .camera && settings.tint * settings.recipeScale == 0 {
            return settings.renderedRecipe(cameraTemperature: settings.temperature, cameraTint: 0)
        }
        // 相机基线必须来自本次目标 RAW，而非源照片的保存记录。
        var neutral = RawSettings.default
        neutral.exposureMode = settings.exposureMode
        try configureSession(session, settings: neutral, interactive: false)
        var request = makeBaseRequest(settings: neutral, inputType: SONY2FUJI_INPUT_RAW)
        request.preview_long_edge = 32
        var buffer = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&buffer) }
        let status = processRaw(session: session, request: &request, inputPath: url.path, lutPath: nil, outBuffer: &buffer)
        guard status == SONY2FUJI_STATUS_OK, let camera = readRawWhiteBalance(from: session), camera.isCalibrated else {
            throw ProcessorError.processFailed(L10n.text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"))
        }
        return settings.renderedRecipe(cameraTemperature: camera.temperature, cameraTint: camera.tint)
    }

    func makeBaseRequest(settings: RawSettings, inputType: sony2fuji_input_type) -> sony2fuji_request {
        var request = sony2fuji_request()
        request.version = SONY2FUJI_REQUEST_VERSION
        request.struct_size = UInt32(MemoryLayout<sony2fuji_request>.size)
        request.output_target = SONY2FUJI_TARGET_BUFFER
        request.output_format = SONY2FUJI_OUTPUT_RGBA8
        request.jpeg_quality = 95
        request.wb_mode = inputType == SONY2FUJI_INPUT_RAW && settings.whiteBalanceMode == .custom
            ? SONY2FUJI_WB_TEMPERATURE
            : SONY2FUJI_WB_CAMERA
        request.wb_mul = (1, 1, 1, 1)
        request.exposure_ev = Float(settings.exposure)
        request.brightness = 1
        request.contrast = Float(settings.contrast)
        request.saturation = Float(settings.saturation)
        // Camera RAW WB is already applied before demosaic. Raster inputs keep
        // the old post-RGB temperature/tint path and therefore remain separate.
        request.temperature = request.wb_mode == SONY2FUJI_WB_CAMERA && inputType == SONY2FUJI_INPUT_RAW
            ? 6500
            : Float(settings.temperature)
        request.tint = request.wb_mode == SONY2FUJI_WB_CAMERA && inputType == SONY2FUJI_INPUT_RAW
            ? 0
            : Float(settings.tint)
        request.highlights = Float(settings.highlights)
        request.shadows = Float(settings.shadows)
        request.tone_curve = Float(settings.toneCurve)
        request.noise_reduction = settings.denoise.enabled ? 0 : Float(settings.noiseReduction)
        request.sharpening = Float(settings.sharpening)
        return request
    }

    func configureDNGFile(_ request: inout sony2fuji_request) {
        request.output_target = SONY2FUJI_TARGET_FILE
        request.output_format = SONY2FUJI_OUTPUT_DNG
    }

    func applySize(
        _ request: inout sony2fuji_request,
        width: UInt32,
        height: UInt32,
        previewLongEdge: CGFloat?,
        exportLongEdge: Int?
    ) {
        if let edge = exportLongEdge {
            request.intent = SONY2FUJI_INTENT_FINAL
            request.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE
            request.long_edge = UInt32(edge)
            request.preview_long_edge = 0
        } else if let edge = previewLongEdge, edge > 0 {
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

    func processRawToFile(
        session: OpaquePointer,
        request: inout sony2fuji_request,
        inputPath: String,
        lutPath: String?,
        outputPath: String
    ) -> sony2fuji_status {
        inputPath.withCString { inputPtr in
            outputPath.withCString { outputPtr in
                request.input_path = inputPtr
                request.output_path = outputPtr
                if let lutPath {
                    return lutPath.withCString { lutPtr in
                        request.lut_path = lutPtr
                        return sony2fuji_process(session, &request, nil)
                    }
                }
                request.lut_path = nil
                return sony2fuji_process(session, &request, nil)
            }
        }
    }

    func processBufferToFile(
        session: OpaquePointer,
        request: inout sony2fuji_request,
        buffer: Buffer,
        lutPath: String?,
        outputPath: String
    ) -> sony2fuji_status {
        buffer.data.withUnsafeBytes { bytes in
            outputPath.withCString { outputPtr in
                request.input_pixels = bytes.baseAddress
                request.output_path = outputPtr
                if let lutPath {
                    return lutPath.withCString { lutPtr in
                        request.lut_path = lutPtr
                        return sony2fuji_process(session, &request, nil)
                    }
                }
                request.lut_path = nil
                return sony2fuji_process(session, &request, nil)
            }
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

    func orientedCGImage(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        guard orientation != .up else { return image }
        let oriented = UIImage(cgImage: image, scale: 1, orientation: UIImage.Orientation(orientation))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: oriented.size, format: format).image { _ in
            oriented.draw(in: CGRect(origin: .zero, size: oriented.size))
        }.cgImage
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

    func readRawWhiteBalance(from session: OpaquePointer) -> Sony2FujiProcessor.RawWhiteBalance? {
        var temperature: Float = 6500
        var tint: Float = 0
        let status = sony2fuji_session_get_raw_white_balance(session, &temperature, &tint)
        guard status == SONY2FUJI_STATUS_OK else { return nil }
        return Sony2FujiProcessor.RawWhiteBalance(
            temperature: Double(temperature).rounded(), tint: Double(tint).rounded(), isCalibrated: true
        )
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
