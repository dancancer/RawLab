import Foundation
import ImageIO

extension ProcessorExportTests {
    static func checkNativeDenoiseExport(_ processor: Sony2FujiProcessor, raw: URL, lut: URL, output: URL) throws {
        var viewportSettings = RawSettings.default
        viewportSettings.denoise.apply(.clean)
        let denoiseRaw = ProcessInfo.processInfo.environment["RAWLAB_TEST_DENOISE_RAW"].map { URL(fileURLWithPath: $0) } ?? raw
        let dimensions = denoiseRaw.path.withCString { rawlab_get_raw_dimensions($0) }
        check(dimensions.width > 0 && dimensions.height > 0, "native RAW fixture dimensions are available")
        let metadata = try processor.loadMetadata(from: denoiseRaw)
        let sourceOrientation = metadata.orientation ?? .up
        // =====================================================================
        // 期望值来自输入 RAW；正向像素在 EXIF 方向 5...8 时交换宽高。
        // =====================================================================
        let swapsAxes = [CGImagePropertyOrientation.leftMirrored, .right, .rightMirrored, .left].contains(sourceOrientation)
        let expectedWidth = Int(swapsAxes ? dimensions.height : dimensions.width)
        let expectedHeight = Int(swapsAxes ? dimensions.width : dimensions.height)
        _ = try processor.processRaw(url: denoiseRaw, settings: viewportSettings, previewLongEdge: 512,
                                     lutURL: lut, viewportPreview: true)
        viewportSettings.exposure = 0.35
        _ = try processor.processRaw(url: denoiseRaw, settings: viewportSettings, previewLongEdge: 768,
                                     lutURL: lut, interactive: true, viewportPreview: true)
        let nativeDenoise = try processor.processRaw(url: denoiseRaw, settings: viewportSettings, previewLongEdge: nil,
                                                    lutURL: lut, interactive: true, viewportPreview: true)
        var withoutDenoise = viewportSettings
        withoutDenoise.denoise.enabled = false
        let nativeOff = try processor.processRaw(url: denoiseRaw, settings: withoutDenoise, previewLongEdge: nil, lutURL: lut)
        check(nativeDenoise.buffer.data != nativeOff.buffer.data, "iOS native export fixture actually applies denoise")
        let freshDenoise = try Sony2FujiProcessor().processRaw(url: denoiseRaw, settings: viewportSettings,
                                                             previewLongEdge: nil, lutURL: lut)
        print("Native RAW: sensor=\(dimensions.width)x\(dimensions.height), EXIF=\(sourceOrientation.rawValue), " +
              "expected=\(expectedWidth)x\(expectedHeight), output=\(nativeDenoise.buffer.width)x\(nativeDenoise.buffer.height), " +
              "processorOrientation=\(nativeDenoise.orientation?.rawValue ?? 0)")
        check(nativeDenoise.orientation == .up, "iOS native RAW export reports physically upright pixels")
        check(nativeDenoise.buffer.width == expectedWidth && nativeDenoise.buffer.height == expectedHeight,
              "iOS denoise export after viewport resize remains native size")
        check(nativeDenoise.buffer.data == freshDenoise.buffer.data,
              "iOS native denoise export never reuses viewport pixels")
        let nativeJPEG = try processor.makeJPEGData(from: nativeDenoise.buffer, sourceURL: denoiseRaw,
                                                    orientation: nativeDenoise.orientation, quality: 0.92)
        let freshJPEG = try processor.makeJPEGData(from: freshDenoise.buffer, sourceURL: denoiseRaw,
                                                   orientation: freshDenoise.orientation, quality: 0.92)
        check(nativeJPEG == freshJPEG, "iOS native JPEG matches independent FINAL processing")
        try nativeJPEG.write(to: output.appendingPathComponent("ios-denoised-native.jpg"))
    }
}
