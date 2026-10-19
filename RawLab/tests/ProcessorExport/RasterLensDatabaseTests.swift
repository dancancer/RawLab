import Foundation

extension ProcessorExportTests {
    static func checkRasterLensDatabase(root: URL, output: URL) throws {
        let jpeg = output.appendingPathComponent("raster-lens.jpg")
        try writeOrientedRaster(to: jpeg)
        let database = root.appendingPathComponent("lutools/third_party/lensfun/version_1")
        let missing = output.appendingPathComponent("missing-lens-database")
        var settings = RawSettings.default
        settings.exposure = 0.7
        settings.contrast = 1.1
        settings.geometry.quarterTurns = 1
        settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: true,
                                                         mode: .manual, profileID: "unused-display-profile")

        for (name, mode) in [("cpu", SONY2FUJI_GPU_OFF), ("auto", SONY2FUJI_GPU_AUTO)] {
            let loaded = Sony2FujiProcessor(gpuMode: mode, lensDatabaseURL: database)
            let skipped = Sony2FujiProcessor(gpuMode: mode, lensDatabaseURL: missing)
            let raster = try loaded.loadRasterBuffer(url: jpeg)
            check(raster.buffer.semantic == .display, "raster decoder marks display input")
            for edge: CGFloat? in [2, nil] {
                let expected = try loadedRasterReference(loaded, buffer: raster.buffer, settings: settings,
                                                         previewLongEdge: edge)
                let actual: Sony2FujiProcessor.Buffer
                do {
                    actual = try skipped.processBuffer(buffer: raster.buffer, settings: settings,
                                                       previewLongEdge: edge, lutURL: nil)
                } catch {
                    check(false, "display raster must not load Lensfun: \(error.localizedDescription)")
                    return
                }
                check(actual.data == expected.data && actual.width == expected.width &&
                      actual.height == expected.height && actual.stride == expected.stride &&
                      actual.pixelFormat == expected.pixelFormat && actual.semantic == expected.semantic &&
                      actual.nativeSize == expected.nativeSize,
                      "\(name) raster preview/FINAL is byte-identical to explicitly loaded Lensfun")
                let expectedJPEG = try loaded.makeJPEGData(from: expected, sourceURL: jpeg,
                                                           orientation: .up, quality: 0.92)
                let actualJPEG = try skipped.makeJPEGData(from: actual, sourceURL: jpeg,
                                                          orientation: .up, quality: 0.92)
                check(actualJPEG == expectedJPEG, "\(name) raster JPEG is byte-identical with/without Lensfun")
            }
            let expectedDNG = output.appendingPathComponent("\(name)-raster-lens-reference.dng")
            let actualDNG = output.appendingPathComponent("\(name)-raster-lens-skipped.dng")
            _ = try loadedRasterReference(loaded, buffer: raster.buffer, settings: settings,
                                          previewLongEdge: nil, dng: expectedDNG)
            try skipped.exportDNG(buffer: raster.buffer, settings: settings, lutURL: nil, outputURL: actualDNG)
            check(try Data(contentsOf: actualDNG) == Data(contentsOf: expectedDNG),
                  "\(name) raster DNG is byte-identical with/without Lensfun")
            let expectedEV = try loaded.autoExposure(url: nil, buffer: raster.buffer, settings: settings)
            let actualEV = try skipped.autoExposure(url: nil, buffer: raster.buffer, settings: settings)
            check(expectedEV == actualEV, "\(name) raster auto exposure does not require Lensfun")
        }

        let processor = Sony2FujiProcessor(lensDatabaseURL: missing)
        let raster = try processor.loadRasterBuffer(url: jpeg)
        try rejectsMissingLensDatabase("legacy buffer still loads Lensfun") {
            _ = try processor.processBuffer(buffer: raster.buffer.withSemantic(.legacy), settings: .default,
                                             previewLongEdge: 2, lutURL: nil)
        }
        let raw = ProcessInfo.processInfo.environment["RAWLAB_TEST_RAW"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("lutools/examples/DSC06251.ARW")
        if FileManager.default.fileExists(atPath: raw.path) {
            try rejectsMissingLensDatabase("RAW preview still loads Lensfun") {
                _ = try processor.processRaw(url: raw, settings: .default, previewLongEdge: 32, lutURL: nil)
            }
            try rejectsMissingLensDatabase("RAW DNG export still loads Lensfun") {
                try processor.exportDNG(url: raw, settings: .default, lutURL: nil,
                                        outputURL: output.appendingPathComponent("missing-db-raw.dng"))
            }
            try rejectsMissingLensDatabase("RAW auto exposure still loads Lensfun") {
                _ = try processor.autoExposure(url: raw, buffer: nil, settings: .default)
            }
        } else {
            print("SKIP: RAW sample unavailable; raster/legacy Lens database checks passed")
        }
    }

    private static func rejectsMissingLensDatabase(_ message: String, body: () throws -> Void) throws {
        do {
            try body()
            check(false, message)
        } catch Sony2FujiProcessor.ProcessorError.processFailed(let detail) {
            check(detail == L10n.text("镜头数据库不可用"), message)
        }
    }

    /* ======================================================================
       显式加载数据库作为旧路径基准，不能调用待测的 display 快捷路径。
       ====================================================================== */
    private static func loadedRasterReference(_ processor: Sony2FujiProcessor,
                                              buffer: Sony2FujiProcessor.Buffer, settings: RawSettings,
                                              previewLongEdge: CGFloat?, dng: URL? = nil) throws -> Sony2FujiProcessor.Buffer {
        let session = try processor.createSession()
        defer { processor.destroySession(session) }
        try processor.loadLensDatabase(session)
        let inputType = processor.semanticInputType(for: buffer)
        let effective = try processor.effectiveSettings(settings, session: session, url: nil, inputType: inputType)
        try processor.configureSession(session, settings: effective, interactive: false)
        var request = processor.makeBaseRequest(settings: effective, inputType: inputType)
        request.input_type = inputType
        request.input_width = UInt32(buffer.width)
        request.input_height = UInt32(buffer.height)
        request.input_pixel_format = buffer.pixelFormat
        request.input_color_space = SONY2FUJI_COLOR_SRGB
        processor.applySize(&request, width: UInt32(buffer.width), height: UInt32(buffer.height),
                            previewLongEdge: previewLongEdge, exportLongEdge: nil)
        request.lut_strength = 0
        if let dng {
            processor.configureDNGFile(&request)
            let status = processor.processBufferToFile(session: session, request: &request, buffer: buffer,
                                                       lutPath: nil, outputPath: dng.path)
            check(status == SONY2FUJI_STATUS_OK, "explicitly loaded raster DNG reference succeeds")
            return buffer
        }
        var native = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&native) }
        let status = processor.processBuffer(session: session, request: &request, buffer: buffer,
                                             lutPath: nil, outBuffer: &native)
        check(status == SONY2FUJI_STATUS_OK, "explicitly loaded raster reference succeeds")
        var result = try processor.copyBuffer(native, semantic: .display)
        result.nativeSize = processor.geometrySize(session)
        return result
    }
}
