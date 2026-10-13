import Foundation

@main struct LensDNGExportTests {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Sony2FujiProcessor.ProcessorError.processFailed(message) }
        print("PASS: \(message)")
    }

    static func main() throws {
        let raw = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let original = try Data(contentsOf: raw)
        let missing = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF,
                                        lensDatabaseURL: output.appendingPathComponent("missing.xml"))
        let smallBuffer = Sony2FujiProcessor.Buffer(data: Data(repeating: 80, count: 16), width: 2, height: 2,
                                                    stride: 8, pixelFormat: SONY2FUJI_PIXEL_RGBA8)
        var rawRejected = false, bufferRejected = false
        do {
            try missing.exportDNG(url: raw, settings: .default, lutURL: nil,
                                  outputURL: output.appendingPathComponent("invalid-raw-db.dng"), exportLongEdge: 128)
        } catch Sony2FujiProcessor.ProcessorError.processFailed(let message) {
            rawRejected = message == "镜头数据库不可用"
        }
        do {
            try missing.exportDNG(buffer: smallBuffer, settings: .default, lutURL: nil,
                                  outputURL: output.appendingPathComponent("invalid-buffer-db.dng"))
        } catch Sony2FujiProcessor.ProcessorError.processFailed(let message) {
            bufferRejected = message == "镜头数据库不可用"
        }
        try check(rawRejected && bufferRejected,
                  "DNG entries validate the explicit Lens database: RAW=\(rawRejected), buffer=\(bufferRejected)")
        let cpu = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF)
        let neutral = try cpu.processRaw(url: raw, settings: .default, previewLongEdge: nil,
                                         lutURL: nil, exportLongEdge: 128)
        guard let candidate = neutral.lensInfo?.candidates.first(where: { $0.isMatch && $0.hasDistortion }) else {
            throw Sony2FujiProcessor.ProcessorError.processFailed("Fixture needs a matching distortion profile")
        }
        var settings = RawSettings.default
        settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: true,
                                                         mode: .manual, profileID: candidate.id)
        let corrected = try cpu.processRaw(url: raw, settings: settings, previewLongEdge: nil,
                                           lutURL: nil, exportLongEdge: 128)
        try check(corrected.lensInfo?.appliedDistortion == true && corrected.buffer.data != neutral.buffer.data,
                  "bundled Lens database changes actual final RAW geometry")
        let off = output.appendingPathComponent("off.dng")
        try cpu.exportDNG(url: raw, settings: .default, lutURL: nil, outputURL: off, exportLongEdge: 128)

        for (name, mode) in [("cpu", SONY2FUJI_GPU_OFF), ("metal", SONY2FUJI_GPU_FORCE)] {
            let processor = Sony2FujiProcessor(gpuMode: mode)
            let actual = output.appendingPathComponent("\(name).dng")
            try processor.exportDNG(url: raw, settings: settings, lutURL: nil, outputURL: actual, exportLongEdge: 128)
            try check(try Data(contentsOf: actual) != Data(contentsOf: off),
                      "\(name) DNG export includes enabled Lens geometry")

            let expected = output.appendingPathComponent("\(name)-reference.dng")
            let session = try processor.createSession()
            defer { processor.destroySession(session) }
            try processor.loadLensDatabase(session)
            try processor.configureSession(session, settings: settings, interactive: false)
            let metadata = try processor.loadMetadata(from: raw)
            let dimensions = raw.path.withCString { rawlab_get_raw_dimensions($0) }
            var request = processor.makeBaseRequest(settings: settings, inputType: SONY2FUJI_INPUT_RAW)
            processor.applySize(&request, width: dimensions.width > 0 ? dimensions.width : metadata.width,
                                height: dimensions.height > 0 ? dimensions.height : metadata.height,
                                previewLongEdge: nil, exportLongEdge: 128)
            processor.configureDNGFile(&request)
            let status = processor.processRawToFile(session: session, request: &request, inputPath: raw.path,
                                                     lutPath: nil, outputPath: expected.path)
            try check(status == SONY2FUJI_STATUS_OK && (try Data(contentsOf: actual) == Data(contentsOf: expected)),
                      "\(name) wrapper DNG matches explicitly configured native Lens export")
            try check(sony2fuji_session_get_last_backend(session) == (mode == SONY2FUJI_GPU_OFF ? SONY2FUJI_BACKEND_CPU : SONY2FUJI_BACKEND_METAL),
                      "\(name) DNG uses the requested actual backend")
            let frozen = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(settings))
            let frozenOutput = output.appendingPathComponent("\(name)-frozen.dng")
            try processor.exportDNG(url: raw, settings: frozen, lutURL: nil, outputURL: frozenOutput, exportLongEdge: 128)
            try check(try Data(contentsOf: actual) == Data(contentsOf: frozenOutput),
                      "\(name) frozen Lens settings retain identical DNG pixels")
        }

        try check(try Data(contentsOf: raw) == original, "original RAW remains unchanged")
    }
}
