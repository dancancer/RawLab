import RawLabKit
import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

extension ProcessingIdentity {
    var core: sony2fuji_processing_version {
        switch version {
        case 1: return SONY2FUJI_PROCESSING_LEGACY
        case 2: return SONY2FUJI_PROCESSING_C5_V2
        default: return SONY2FUJI_PROCESSING_BASIC_V3
        }
    }
}

extension X3fMode {
    var core: sony2fuji_x3f_mode {
        self == .normal ? SONY2FUJI_X3F_NORMAL : SONY2FUJI_X3F_LEGACY
    }
}

extension RawExposureMode {
    var core: sony2fuji_raw_exposure_mode {
        switch self {
        case .scene: return SONY2FUJI_EXPOSURE_SCENE
        case .preview: return SONY2FUJI_EXPOSURE_PREVIEW
        case .sensor: return SONY2FUJI_EXPOSURE_SENSOR
        }
    }
}

extension Sony2FujiProcessor {
    func semanticInputType(for buffer: Buffer) -> sony2fuji_input_type {
        buffer.semantic == .display ? SONY2FUJI_INPUT_DISPLAY_BUFFER : SONY2FUJI_INPUT_BUFFER
    }

    func loadMetadata(from url: URL) throws -> ImageMetadata {
        // Generic TIFF metadata can describe only an embedded RAW preview.
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetType(source) as String? != UTType.tiff.identifier,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint32Value,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint32Value,
                  width > 0, height > 0 else { throw ProcessorError.invalidDimensions }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)
                .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) }
            return ImageMetadata(width: width, height: height, orientation: orientation)
        }

        if let camera = try HDRSourceInfo.probeCameraRAW(url) {
            return ImageMetadata(width: camera.native.width, height: camera.native.height,
                                 orientation: CGImagePropertyOrientation(rawValue: camera.native.orientation) ?? .up)
        }
        let dimensions = url.path.withCString { rawlab_get_raw_dimensions($0) }
        guard dimensions.width > 0, dimensions.height > 0 else { throw ProcessorError.metadataUnavailable }
        return ImageMetadata(width: dimensions.width, height: dimensions.height, orientation: .up)
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

    func isNormalX3f(_ url: URL, settings: RawSettings) -> Bool {
        url.path.withCString { sony2fuji_is_normal_x3f($0, settings.x3fMode.core) != 0 }
    }

    func defaultSettings(for url: URL, isRaw: Bool, x3fModeOverride: X3fMode? = nil) throws -> RawSettings {
        try RawSettings.sourceDefaults(for: url, isRaw: isRaw, sourceIsHDR: HDRSourceInfo.probe(url) != nil,
            x3fDefaultMode: { try x3fModeOverride ?? self.x3fDefaultMode(for: $0) })
    }

    func x3fDefaultMode(for url: URL) throws -> X3fMode {
        var mode = SONY2FUJI_X3F_NORMAL
        let status = url.path.withCString { sony2fuji_x3f_default_mode($0, &mode) }
        guard status == SONY2FUJI_STATUS_OK else { throw processingFailure(status) }
        return mode == SONY2FUJI_X3F_NORMAL ? .normal : .legacy
    }

    private func validationMessage(for error: CanonicalEditRecipeError) -> String {
        switch error {
        case .invalidToneCurve: return L10n.text("无效的曲线参数")
        case .invalidColorGrading: return L10n.text("无效的颜色分级参数")
        case .invalidToneControls: return L10n.text("无效的黑白场或鲜艳度参数")
        case .invalidAtmosphere: return L10n.text("无效的清晰度或去朦胧参数")
        case .invalidHSL: return L10n.text("无效的 HSL 参数")
        case .invalidGeometry: return L10n.text("无效的几何参数")
        case .invalidPhotoEffects: return L10n.text("无效的暗角或颗粒参数")
        case .invalidWaveletDenoise, .invalidChromaDenoise, .invalidRawNoiseReduction:
            return L10n.text("无效或不可用的降噪参数")
        }
    }

    func applySessionParams(_ session: OpaquePointer, settings: RawSettings,
                            isRaster: Bool = false) throws {
        let recipeJSON: String
        do {
            recipeJSON = try settings.canonicalParamsJSON(isRaster: isRaster)
        } catch let error as CanonicalEditRecipeError {
            throw ProcessorError.processFailed(validationMessage(for: error))
        }
        let status = recipeJSON.withCString { sony2fuji_apply_params(session, $0) }
        guard status == SONY2FUJI_STATUS_OK else { throw processingFailure(status, session: session) }
    }

    func configureSession(_ session: OpaquePointer, settings: RawSettings, interactive: Bool,
                          viewportPreview: Bool = false) throws {
        try applySessionParams(session, settings: settings, isRaster: false)
        var config = sony2fuji_gpu_config()
        config.version = SONY2FUJI_GPU_CONFIG_VERSION
        config.struct_size = UInt32(MemoryLayout<sony2fuji_gpu_config>.size)
        config.mode = gpuMode
        let gpuStatus = sony2fuji_session_set_gpu_config(session, &config)
        guard gpuStatus == SONY2FUJI_STATUS_OK else {
            throw ProcessorError.processFailed(L10n.format("Invalid GPU configuration: %@", statusMessage(gpuStatus)))
        }
        let previewStatus = sony2fuji_session_set_interactive_preview(session, interactive ? 1 : 0)
        guard previewStatus == SONY2FUJI_STATUS_OK else { throw ProcessorError.processFailed(statusMessage(previewStatus)) }
        let viewportStatus = sony2fuji_session_set_viewport_preview(session, viewportPreview ? 1 : 0)
        guard viewportStatus == SONY2FUJI_STATUS_OK else { throw ProcessorError.processFailed(statusMessage(viewportStatus)) }
    }

    func geometrySize(_ session: OpaquePointer) -> CGSize? {
        var width: UInt32 = 0, height: UInt32 = 0
        guard sony2fuji_session_get_geometry_size(session, &width, &height) == SONY2FUJI_STATUS_OK,
              width > 0, height > 0 else { return nil }
        return CGSize(width: Int(width), height: Int(height))
    }

    func prepareRecipe(_ settings: RawSettings, session: OpaquePointer, url: URL?) throws -> RawSettings {
        guard settings.masterRecipeID != nil else { return settings }
        guard let url else { return settings.renderedRecipe(cameraTemperature: 6500, cameraTint: 0) }
        var req = sony2fuji_recipe_wb_request()
        req.version = SONY2FUJI_RECIPE_WB_REQUEST_VERSION
        req.struct_size = UInt32(MemoryLayout<sony2fuji_recipe_wb_request>.size)
        req.processing_version = settings.processing.core
        req.x3f_mode = settings.x3fMode.core
        req.exposure_mode = settings.exposureMode.core
        req.recipe_active = 1
        req.recipe_strength = Float(settings.recipeScale)
        req.custom_wb = settings.whiteBalanceMode == .camera ? 0 : 1
        req.temperature = Float(settings.temperature)
        req.tint = Float(settings.tint)
        var res = sony2fuji_recipe_wb_result()
        let status = url.path.withCString { pathPtr -> sony2fuji_status in
            req.input_path = pathPtr
            return sony2fuji_session_resolve_recipe_wb(session, &req, &res)
        }
        if status == SONY2FUJI_STATUS_UNSUPPORTED {
            throw ProcessorError.processFailed(L10n.text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"))
        }
        guard status == SONY2FUJI_STATUS_OK else {
            throw processingFailure(status, session: session)
        }
        var result = settings.renderedRecipe(
            cameraTemperature: Double(res.camera_temperature),
            cameraTint: Double(res.camera_tint)
        )
        result.whiteBalanceMode = res.wb_mode == SONY2FUJI_WB_TEMPERATURE ? .custom : .camera
        result.temperature = Double(res.temperature)
        result.tint = Double(res.tint)
        return result
    }

    func effectiveSettings(_ settings: RawSettings, session: OpaquePointer, url: URL?,
                           inputType: sony2fuji_input_type) throws -> RawSettings {
        var result = try prepareRecipe(settings, session: session, url: url)
        guard inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER else { return result }
        result.exposureMode = .sensor
        result.whiteBalanceMode = .camera
        result.temperature = 6500
        result.tint = 0
        result.noiseReduction = 0
        return result
    }

    func makeBaseRequest(settings: RawSettings, inputType: sony2fuji_input_type) -> sony2fuji_request {
        var request = sony2fuji_request()
        request.version = SONY2FUJI_REQUEST_VERSION
        request.struct_size = UInt32(MemoryLayout<sony2fuji_request>.size)
        request.output_target = SONY2FUJI_TARGET_BUFFER
        request.output_format = SONY2FUJI_OUTPUT_RGBA8
        request.jpeg_quality = 95
        let displayInput = inputType == SONY2FUJI_INPUT_DISPLAY_BUFFER
        request.wb_mode = inputType == SONY2FUJI_INPUT_RAW && settings.whiteBalanceMode == .custom
            ? SONY2FUJI_WB_TEMPERATURE
            : SONY2FUJI_WB_CAMERA
        request.wb_mul = (1, 1, 1, 1)
        request.exposure_ev = Float(settings.exposure)
        request.brightness = 1
        request.contrast = Float(settings.contrast)
        request.saturation = Float(settings.saturation)
        // RAW white balance is applied before demosaic. Display input stays
        // neutral; legacy scene buffers retain their existing post-RGB path.
        request.temperature = displayInput || (request.wb_mode == SONY2FUJI_WB_CAMERA && inputType == SONY2FUJI_INPUT_RAW)
            ? 6500
            : Float(settings.temperature)
        request.tint = displayInput || (request.wb_mode == SONY2FUJI_WB_CAMERA && inputType == SONY2FUJI_INPUT_RAW)
            ? 0
            : Float(settings.tint)
        request.highlights = Float(settings.highlights)
        request.shadows = Float(settings.shadows)
        request.tone_curve = settings.curveSettings.mode == .custom ? 0 : Float(settings.toneCurve)
        request.noise_reduction = displayInput || settings.denoise.enabled ? 0 : Float(settings.noiseReduction)
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

    func takeBuffer(_ buffer: inout sony2fuji_buffer, semantic: Buffer.Semantic = .legacy) throws -> Buffer {
        guard let baseAddress = buffer.data,
              buffer.width > 0,
              buffer.height > 0,
              buffer.size_bytes > 0
        else {
            throw ProcessorError.bufferCopyFailed
        }

        let native = buffer
        let data = Data(bytesNoCopy: baseAddress, count: Int(native.size_bytes), deallocator: .custom { pointer, _ in
            var released = sony2fuji_buffer()
            released.data = pointer
            sony2fuji_release_buffer(&released)
        })
        // 保留调用方 defer 的错误路径清理；成功后只由 Data 释放原生内存。
        buffer = sony2fuji_buffer()
        return Buffer(
            data: data,
            width: Int(native.width),
            height: Int(native.height),
            stride: Int(native.stride_bytes),
            pixelFormat: native.pixel_format,
            semantic: semantic
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
        var temperature: Float = 0
        var tint: Float = 0
        let status = sony2fuji_session_get_effective_raw_white_balance(session, &temperature, &tint)
        guard status == SONY2FUJI_STATUS_OK else { return nil }
        return Sony2FujiProcessor.RawWhiteBalance(
            temperature: Double(temperature), tint: Double(tint), isCalibrated: true
        )
    }

    struct DisplayImageMetadata {
        let type: String
        let imageSource: CGImageSource
        let properties: [CFString: Any]
        let width: Int
        let height: Int
        let depth: Int
        let orientation: Int
        let rgb16: Bool
        let tiffPair: Bool
        let hasAlpha: Bool
        let hasProfile: Bool
        let pngColorSpaceName: CFString?

        var orientedWidth: Int { orientation >= 5 ? height : width }
        var orientedHeight: Int { orientation >= 5 ? width : height }
        var orientedMax: Int { max(orientedWidth, orientedHeight) }
    }

    func validateDisplayImageMetadata(url: URL) throws -> DisplayImageMetadata {
        guard !url.path.isEmpty else { throw displayImageFailure(SONY2FUJI_STATUS_INVALID_ARGUMENT) }
        guard url.pathExtension.lowercased() != "dng" else {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        let resolved = url.resolvingSymlinksInPath()
        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw displayImageFailure(SONY2FUJI_STATUS_IO_ERROR)
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR)
        }
        guard let type = CGImageSourceGetType(imageSource) as String?,
              ["public.jpeg", "public.png", "public.tiff", "public.heif", "public.heic"].contains(type) else {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        var pngColorSpaceName: CFString? = nil
        if type == "public.png" {
            pngColorSpaceName = try parsePNGColorMetadata(url: resolved)
        }
        let imageCount = CGImageSourceGetCount(imageSource)
        let tiffPair = imageCount == 2 && type == "public.tiff"
        let mpfCount = type == "public.jpeg" ? Int(url.path.withCString { sony2fuji_inspect_sdr_jpeg_mpf($0) }) : 0
        guard mpfCount >= 0 && (imageCount == 1 || tiffPair || (mpfCount > 0 && imageCount == mpfCount)) else {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        if #available(iOS 18.0, macOS 15.0, *),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR)
        }
        guard let widthNum = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNum = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR)
        }
        let width = widthNum.int64Value
        let height = heightNum.int64Value
        guard width > 0, height > 0 else { throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR) }
        let maxDisplayPixels: UInt64 = 128_000_000
        guard UInt64(width) <= maxDisplayPixels / UInt64(height),
              UInt64(width) * UInt64(height) <= maxDisplayPixels,
              width <= Int64(UInt32.max / 4) else {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
        let tiff16 = depth == 16 && type == "public.tiff"
        let rgb16 = tiff16 || (depth == 16 && type == "public.png")
        guard depth == 8 || rgb16 else {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        if tiffPair {
            guard tiff16, hasValidSigmaTIFFMetadata(imageSource: imageSource, properties: properties, width: width, height: height) else {
                throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
            }
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        if let colorModel = properties[kCGImagePropertyColorModel] as? String,
           colorModel != (kCGImagePropertyColorModelRGB as String) {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        if (properties[kCGImagePropertyIsFloat] as? Bool) == true {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        if let profileName = properties[kCGImagePropertyProfileName] as? String,
           isHDRColorSpaceName(profileName) {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let hasProfile = properties[kCGImagePropertyProfileName] != nil
        return DisplayImageMetadata(
            type: type,
            imageSource: imageSource,
            properties: properties,
            width: Int(width),
            height: Int(height),
            depth: depth,
            orientation: orientation,
            rgb16: rgb16,
            tiffPair: tiffPair,
            hasAlpha: hasAlpha,
            hasProfile: hasProfile,
            pngColorSpaceName: pngColorSpaceName
        )
    }

    private func parsePNGColorMetadata(url: URL) throws -> CFString? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw displayImageFailure(SONY2FUJI_STATUS_IO_ERROR)
        }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize >= 8 else { throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR) }
        try handle.seek(toOffset: 8)
        var colorSpaceName: CFString? = nil
        while true {
            guard let header = try? handle.read(upToCount: 8), header.count == 8 else {
                throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR)
            }
            let length = (UInt32(header[0]) << 24) | (UInt32(header[1]) << 16) |
                (UInt32(header[2]) << 8) | UInt32(header[3])
            let chunkType = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            if chunkType == "mDCv" || chunkType == "mDCV" || chunkType == "cLLi" || chunkType == "cLLI" {
                throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
            }
            if chunkType == "cICP" {
                guard length == 4 else { throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED) }
                guard let cicp = try? handle.read(upToCount: 4), cicp.count == 4 else {
                    throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR)
                }
                let bytes = [UInt8](cicp)
                if bytes == [1, 13, 0, 1] { colorSpaceName = CGColorSpace.sRGB }
                else if bytes == [12, 13, 0, 1] { colorSpaceName = CGColorSpace.displayP3 }
                else if bytes == [1, 1, 0, 1] { colorSpaceName = CGColorSpace.itur_709 }
                else { throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED) }
            } else {
                let offset = (try? handle.offset()) ?? fileSize
                guard UInt64(length) <= fileSize - offset else {
                    throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR)
                }
                try handle.seek(toOffset: offset + UInt64(length))
            }
            guard let crc = try? handle.read(upToCount: 4), crc.count == 4 else {
                throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR)
            }
            if chunkType == "IEND" {
                guard length == 0 else { throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR) }
                return colorSpaceName
            }
        }
    }

    private func hasValidSigmaTIFFMetadata(imageSource: CGImageSource, properties: [CFString: Any], width: Int64, height: Int64) -> Bool {
        guard let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let software = tiff[kCGImagePropertyTIFFSoftware] as? String,
              software.hasPrefix("SIGMA Photo Pro "),
              let preview = CGImageSourceCopyPropertiesAtIndex(imageSource, 1, nil) as? [CFString: Any],
              let pw = (preview[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let ph = (preview[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              let pDepth = (preview[kCGImagePropertyDepth] as? NSNumber)?.int64Value else {
            return false
        }
        return pDepth == 8 && pw > 0 && ph > 0 && pw < width && ph < height &&
            max(pw, ph) == 160 && abs(width * ph - height * pw) <= max(width, height)
    }

    func isHDRColorSpaceName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("extended") || lower.contains("hdr") || lower.contains("pq") || lower.contains("hlg")
    }

    func isHDRColorSpace(_ space: CGColorSpace) -> Bool {
        if CGColorSpaceUsesITUR_2100TF(space) || CGColorSpaceUsesExtendedRange(space) { return true }
        if let name = space.name as String? {
            return isHDRColorSpaceName(name)
        }
        return false
    }

    func isOpaqueAlphaInfo(_ alpha: CGImageAlphaInfo) -> Bool {
        alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
    }

    func makeDisplayCGImage(from native: sony2fuji_buffer) -> CGImage? {
        guard let dataPtr = native.data, native.size_bytes > 0, native.width > 0, native.height > 0 else { return nil }
        guard let provider = CGDataProvider(dataInfo: nil, data: dataPtr, size: Int(native.size_bytes), releaseData: { _, _, _ in }) else {
            return nil
        }
        let is16 = native.pixel_format == SONY2FUJI_PIXEL_RGBA16
        let bitsPerComponent = is16 ? 16 : 8
        let bitsPerPixel = is16 ? 64 : 32
        let bitmap = is16
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder16Little)
            : bitmapInfo(for: 4)
        return CGImage(
            width: Int(native.width),
            height: Int(native.height),
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: Int(native.stride_bytes),
            space: outputColorSpace(),
            bitmapInfo: bitmap,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    func renderDisplayRGBA8Buffer(
        from image: CGImage,
        targetWidth: Int,
        targetHeight: Int,
        checkOpaqueAlpha: Bool,
        nativeSize: CGSize,
        isProxy: Bool,
        sourceURL: URL
    ) throws -> Buffer {
        guard targetWidth > 0, targetHeight > 0 else {
            throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED)
        }
        let stride = targetWidth * 4
        let total = stride * targetHeight
        var pixels = Data(count: total)
        let drawn = pixels.withUnsafeMutableBytes { rawBytes -> Bool in
            guard let baseAddress = rawBytes.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: targetWidth,
                      height: targetHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: stride,
                      space: outputColorSpace(),
                      bitmapInfo: bitmapInfo(for: 4).rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            return true
        }
        guard drawn else { throw displayImageFailure(SONY2FUJI_STATUS_PROCESSING_ERROR) }
        if checkOpaqueAlpha {
            let opaque = pixels.withUnsafeBytes { rawBytes -> Bool in
                guard let ptr = rawBytes.bindMemory(to: UInt8.self).baseAddress else { return false }
                var offset = 3
                while offset < total {
                    if ptr[offset] != 255 { return false }
                    offset += 4
                }
                return true
            }
            guard opaque else { throw displayImageFailure(SONY2FUJI_STATUS_UNSUPPORTED) }
        }
        var buffer = Buffer(
            data: pixels,
            width: targetWidth,
            height: targetHeight,
            stride: stride,
            pixelFormat: SONY2FUJI_PIXEL_RGBA8,
            semantic: .display,
            nativeSize: nativeSize,
            isProxy: isProxy
        )
        buffer.sourceLensMetadata = DisplayLensMetadata.read(sourceURL)
        return buffer
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
