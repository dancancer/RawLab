import Accelerate
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
        case .invalidWhiteBalance:
            return L10n.text("无效的白平衡参数")
        }
    }

    func encodeSessionState(
        _ settings: RawSettings,
        inputType: sony2fuji_input_type,
        lutPath: String?,
        outputSharpening: OutputSharpening = .off
    ) throws -> String {
        let prepared: RawSettings
        let isRaster: Bool
        switch inputType {
        case SONY2FUJI_INPUT_DISPLAY_BUFFER:
            isRaster = true
            var raster = settings
            raster.exposureMode = .sensor
            if settings.masterRecipeID != nil || raster.whiteBalanceMode != .camera {
                raster.whiteBalanceMode = .camera
                raster.temperature = 6500
                raster.tint = 0
            }
            prepared = raster
        case SONY2FUJI_INPUT_BUFFER:
            isRaster = false
            var legacy = settings.renderedRecipe(cameraTemperature: 6500, cameraTint: 0)
            legacy.whiteBalanceMode = .camera
            legacy.temperature = 6500
            legacy.tint = 0
            prepared = legacy
        default:
            isRaster = false
            prepared = settings
        }
        do {
            return try prepared.sdrSessionStateJSON(
                isRaster: isRaster,
                lutPath: lutPath,
                includeDenoise: true,
                outputSharpening: outputSharpening
            )
        } catch let error as CanonicalEditRecipeError {
            throw ProcessorError.processFailed(validationMessage(for: error))
        } catch is EncodingError {
            throw processingFailure(SONY2FUJI_STATUS_INVALID_ARGUMENT)
        }
    }

    func configureGPU(_ session: OpaquePointer) throws {
        var config = sony2fuji_gpu_config()
        config.version = SONY2FUJI_GPU_CONFIG_VERSION
        config.struct_size = UInt32(MemoryLayout<sony2fuji_gpu_config>.size)
        config.mode = gpuMode
        let gpuStatus = sony2fuji_session_set_gpu_config(session, &config)
        guard gpuStatus == SONY2FUJI_STATUS_OK else {
            throw ProcessorError.processFailed(L10n.format("Invalid GPU configuration: %@", statusMessage(gpuStatus)))
        }
    }

    func makeRenderOptions(
        inputType: sony2fuji_input_type,
        width: UInt32 = 0,
        height: UInt32 = 0,
        previewLongEdge: CGFloat? = nil,
        exportLongEdge: Int? = nil,
        interactive: Bool = false,
        viewportPreview: Bool = false,
        outputTarget: sony2fuji_output_target = SONY2FUJI_TARGET_BUFFER,
        outputFormat: sony2fuji_output_format = SONY2FUJI_OUTPUT_RGBA8
    ) -> sony2fuji_render_options_v1 {
        var options = sony2fuji_render_options_v1()
        options.version = UInt32(SONY2FUJI_RENDER_OPTIONS_V1_VERSION)
        options.struct_size = UInt32(MemoryLayout<sony2fuji_render_options_v1>.size)
        options.input_type = inputType
        options.interactive_preview = interactive ? 1 : 0
        options.viewport_preview = viewportPreview ? 1 : 0
        options.output_target = outputTarget
        options.output_format = outputFormat
        options.jpeg_quality = 95
        if let edge = exportLongEdge {
            options.intent = SONY2FUJI_INTENT_FINAL
            options.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE
            options.long_edge = UInt32(edge)
            options.preview_long_edge = 0
        } else if let edge = previewLongEdge, edge > 0 {
            let edgeValue = UInt32(edge.rounded())
            options.intent = SONY2FUJI_INTENT_PREVIEW
            options.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE
            options.long_edge = edgeValue
            options.preview_long_edge = edgeValue
        } else {
            options.intent = SONY2FUJI_INTENT_FINAL
            options.size_mode = SONY2FUJI_SIZE_NATIVE
            options.target_width = width
            options.target_height = height
        }
        return options
    }

    func makeNativeViewportROI(_ roi: Sony2FujiProcessor.ViewportROI) -> sony2fuji_viewport_roi {
        var nativeRoi = sony2fuji_viewport_roi()
        nativeRoi.struct_size = UInt32(MemoryLayout<sony2fuji_viewport_roi>.size)
        nativeRoi.enabled = 1
        nativeRoi.norm_x0 = Double(roi.normalizedRect.minX)
        nativeRoi.norm_y0 = Double(roi.normalizedRect.minY)
        nativeRoi.norm_x1 = Double(roi.normalizedRect.maxX)
        nativeRoi.norm_y1 = Double(roi.normalizedRect.maxY)
        nativeRoi.max_output_long_edge = UInt32(max(0, roi.maxOutputLongEdge))
        return nativeRoi
    }

    func makeViewportROIResult(_ result: sony2fuji_viewport_roi_result) -> Sony2FujiProcessor.ViewportROIResult? {
        guard result.active != 0,
              result.native_x1 > result.native_x0,
              result.native_y1 > result.native_y0,
              result.full_native_width > 0,
              result.full_native_height > 0 else {
            return nil
        }
        return Sony2FujiProcessor.ViewportROIResult(
            nativeX0: Int(result.native_x0),
            nativeY0: Int(result.native_y0),
            nativeX1: Int(result.native_x1),
            nativeY1: Int(result.native_y1),
            fullNativeWidth: Int(result.full_native_width),
            fullNativeHeight: Int(result.full_native_height)
        )
    }

    func renderSessionRaw(
        session: OpaquePointer,
        options: inout sony2fuji_render_options_v1,
        editStateJSON: String,
        inputPath: String,
        outputPath: String? = nil,
        outBuffer: UnsafeMutablePointer<sony2fuji_buffer>? = nil,
        outROI: UnsafeMutablePointer<sony2fuji_viewport_roi_result>? = nil
    ) -> sony2fuji_status {
        inputPath.withCString { inputPtr in
            options.input_path = inputPtr
            return editStateJSON.withCString { jsonPtr in
                if let outputPath {
                    return outputPath.withCString { outputPtr in
                        options.output_path = outputPtr
                        return sony2fuji_session_render(session, &options, jsonPtr, outBuffer, outROI)
                    }
                }
                options.output_path = nil
                return sony2fuji_session_render(session, &options, jsonPtr, outBuffer, outROI)
            }
        }
    }

    func renderSessionBuffer(
        session: OpaquePointer,
        options: inout sony2fuji_render_options_v1,
        editStateJSON: String,
        buffer: Buffer,
        outputPath: String? = nil,
        outBuffer: UnsafeMutablePointer<sony2fuji_buffer>? = nil,
        outROI: UnsafeMutablePointer<sony2fuji_viewport_roi_result>? = nil
    ) -> sony2fuji_status {
        buffer.data.withUnsafeBytes { bytes in
            options.input_pixels = bytes.baseAddress
            options.input_width = UInt32(buffer.width)
            options.input_height = UInt32(buffer.height)
            options.input_pixel_format = buffer.pixelFormat
            options.input_color_space = SONY2FUJI_COLOR_SRGB
            options.input_is_linear = 0
            return editStateJSON.withCString { jsonPtr in
                if let outputPath {
                    return outputPath.withCString { outputPtr in
                        options.output_path = outputPtr
                        return sony2fuji_session_render(session, &options, jsonPtr, outBuffer, outROI)
                    }
                }
                options.output_path = nil
                return sony2fuji_session_render(session, &options, jsonPtr, outBuffer, outROI)
            }
        }
    }

    func masterRecipeFailureIfNeeded(
        _ status: sony2fuji_status,
        settings: RawSettings,
        inputType: sony2fuji_input_type,
        session: OpaquePointer
    ) -> Error? {
        guard status == SONY2FUJI_STATUS_UNSUPPORTED,
              inputType == SONY2FUJI_INPUT_RAW,
              settings.masterRecipeID != nil,
              sony2fuji_session_get_unsupported_reason(session) == SONY2FUJI_UNSUPPORTED_NONE else {
            return nil
        }
        return ProcessorError.processFailed(L10n.text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"))
    }

    func applySessionParams(_ session: OpaquePointer, settings: RawSettings,
                            isRaster: Bool = false, outputSharpening: OutputSharpening = .off) throws {
        let recipeJSON: String
        do {
            recipeJSON = try settings.canonicalParamsJSON(isRaster: isRaster, outputSharpening: outputSharpening)
        } catch let error as CanonicalEditRecipeError {
            throw ProcessorError.processFailed(validationMessage(for: error))
        } catch is EncodingError {
            throw processingFailure(SONY2FUJI_STATUS_INVALID_ARGUMENT)
        }
        let status = recipeJSON.withCString { sony2fuji_apply_params(session, $0) }
        guard status == SONY2FUJI_STATUS_OK else { throw processingFailure(status, session: session) }
    }

    func configureSession(_ session: OpaquePointer, settings: RawSettings, interactive: Bool,
                          viewportPreview: Bool = false, isRaster: Bool = false,
                          outputSharpening: OutputSharpening = .off) throws {
        try applySessionParams(session, settings: settings, isRaster: isRaster, outputSharpening: outputSharpening)
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
        if settings.masterRecipeID != nil || result.whiteBalanceMode != .camera {
            result.whiteBalanceMode = .camera
            result.temperature = 6500
            result.tint = 0
        }
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
        // Camera WB keeps baseline 6500/0 on the base request for both RAW
        // (camera gains) and SDR display input (relative WB comes from
        // applySessionParams / rasterRelativeWbActive_).
        let neutralCameraWB = request.wb_mode == SONY2FUJI_WB_CAMERA &&
            (inputType == SONY2FUJI_INPUT_RAW || displayInput)
        request.temperature = neutralCameraWB
            ? 6500
            : Float(settings.temperature)
        request.tint = neutralCameraWB
            ? 0
            : Float(settings.tint)
        request.highlights = Float(settings.highlights)
        request.shadows = Float(settings.shadows)
        request.tone_curve = settings.curveSettings.mode == .custom ? 0 : Float(settings.toneCurve)
        request.noise_reduction = 0
        request.sharpening = Float(settings.sharpening)
        return request
    }

    func configureDNGFile(_ request: inout sony2fuji_request) {
        request.output_target = SONY2FUJI_TARGET_FILE
        request.output_format = SONY2FUJI_OUTPUT_DNG
    }

    func configurePNGFile(_ request: inout sony2fuji_request) {
        request.output_target = SONY2FUJI_TARGET_FILE
        request.output_format = SONY2FUJI_OUTPUT_PNG
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

    func applyViewportROI(session: OpaquePointer, roi: ViewportROI?) -> sony2fuji_status {
        var nativeRoi = sony2fuji_viewport_roi()
        nativeRoi.struct_size = UInt32(MemoryLayout<sony2fuji_viewport_roi>.size)
        if let roi {
            nativeRoi.enabled = 1
            nativeRoi.norm_x0 = Double(roi.normalizedRect.minX)
            nativeRoi.norm_y0 = Double(roi.normalizedRect.minY)
            nativeRoi.norm_x1 = Double(roi.normalizedRect.maxX)
            nativeRoi.norm_y1 = Double(roi.normalizedRect.maxY)
            nativeRoi.max_output_long_edge = UInt32(max(0, roi.maxOutputLongEdge))
        } else {
            nativeRoi.enabled = 0
        }
        return sony2fuji_session_set_viewport_roi(session, &nativeRoi)
    }

    func readViewportROIResult(session: OpaquePointer) -> ViewportROIResult? {
        var result = sony2fuji_viewport_roi_result()
        result.struct_size = UInt32(MemoryLayout<sony2fuji_viewport_roi_result>.size)
        guard sony2fuji_session_get_viewport_roi_result(session, &result) == SONY2FUJI_STATUS_OK,
              result.active != 0,
              result.native_x1 > result.native_x0,
              result.native_y1 > result.native_y0,
              result.full_native_width > 0,
              result.full_native_height > 0 else {
            return nil
        }
        return ViewportROIResult(
            nativeX0: Int(result.native_x0),
            nativeY0: Int(result.native_y0),
            nativeX1: Int(result.native_x1),
            nativeY1: Int(result.native_y1),
            fullNativeWidth: Int(result.full_native_width),
            fullNativeHeight: Int(result.full_native_height)
        )
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

    func makeNativeBGRADisplayCGImage(
        consuming buffer: inout sony2fuji_buffer,
        semantic: Buffer.Semantic = .legacy
    ) -> CGImage? {
        if buffer.pixel_format == SONY2FUJI_PIXEL_RGBA8,
           let baseAddress = buffer.data,
           buffer.width > 0, buffer.height > 0,
           buffer.stride_bytes == buffer.width * 4 {
            let width = Int(buffer.width)
            let height = Int(buffer.height)
            let rowBytes = Int(buffer.stride_bytes)
            var src = vImage_Buffer(
                data: baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: rowBytes
            )
            let permuteMap: [UInt8] = [2, 1, 0, 3]
            if vImagePermuteChannels_ARGB8888(&src, &src, permuteMap, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
               let taken = try? takeBuffer(&buffer, semantic: semantic),
               let provider = CGDataProvider(data: taken.data as CFData) {
                let bgraInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                    .union(.byteOrder32Little)
                return CGImage(
                    width: taken.width,
                    height: taken.height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: taken.stride,
                    space: outputColorSpace(),
                    bitmapInfo: bgraInfo,
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                )
            }
        }
        guard let taken = try? takeBuffer(&buffer, semantic: semantic) else { return nil }
        return makeCGImage(from: taken)
    }

    func downscaleDisplayCGImage(_ cgImage: CGImage, maxLongEdge: Int) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, maxLongEdge > 0 else { return nil }
        let longest = max(width, height)
        if longest <= maxLongEdge {
            return cgImage
        }
        let scale = Double(maxLongEdge) / Double(longest)
        let dstW = max(1, Int((Double(width) * scale).rounded()))
        let dstH = max(1, Int((Double(height) * scale).rounded()))
        if cgImage.bitsPerPixel == 32,
           cgImage.bitsPerComponent == 8,
           let srcData = cgImage.dataProvider?.data,
           CFDataGetLength(srcData) >= cgImage.bytesPerRow * height,
           let srcPtr = CFDataGetBytePtr(srcData) {
            let dstStride = dstW * 4
            let byteCount = dstStride * dstH
            if let dstRaw = malloc(byteCount) {
                let dstData = Data(bytesNoCopy: dstRaw, count: byteCount, deallocator: .free)
                var srcBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcPtr),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: cgImage.bytesPerRow
                )
                var dstBuf = vImage_Buffer(
                    data: dstRaw,
                    height: vImagePixelCount(dstH),
                    width: vImagePixelCount(dstW),
                    rowBytes: dstStride
                )
                if vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError,
                   let provider = CGDataProvider(data: dstData as CFData) {
                    return CGImage(
                        width: dstW,
                        height: dstH,
                        bitsPerComponent: 8,
                        bitsPerPixel: 32,
                        bytesPerRow: dstStride,
                        space: cgImage.colorSpace ?? outputColorSpace(),
                        bitmapInfo: cgImage.bitmapInfo,
                        provider: provider,
                        decode: nil,
                        shouldInterpolate: true,
                        intent: .defaultIntent
                    )
                }
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: dstW, height: dstH), format: format).image { _ in
            UIImage(cgImage: cgImage, scale: 1, orientation: .up)
                .draw(in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        }.cgImage
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

    func validateDisplayImage(url: URL) throws {
        var native = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&native) }
        let status = url.path.withCString { path in
            sony2fuji_load_display_preview(path, 1, &native, nil, nil)
        }
        guard status == SONY2FUJI_STATUS_OK else {
            throw displayImageFailure(status)
        }
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
