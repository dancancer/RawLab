import Foundation
import ImageIO
import UIKit

@main
struct GeometryProcessingTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }

    static func tiffDimensions(_ data: Data) throws -> CGSize {
        func number(_ offset: Int, bytes: Int) -> Int {
            (0..<bytes).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        check(data.prefix(4) == Data([0x49, 0x49, 0x2a, 0]), "rendered DNG uses classic little-endian TIFF")
        let directory = number(4, bytes: 4)
        var dimensions: [Int: Int] = [:]
        for index in 0..<number(directory, bytes: 2) {
            let entry = directory + 2 + index * 12
            let tag = number(entry, bytes: 2)
            if tag == 256 || tag == 257 {
                let type = number(entry + 2, bytes: 2)
                check((type == 3 || type == 4) && number(entry + 4, bytes: 4) == 1,
                      "DNG dimension tag is a scalar SHORT or LONG")
                dimensions[tag] = number(entry + 8, bytes: type == 3 ? 2 : 4)
            }
        }
        return CGSize(width: dimensions[256] ?? 0, height: dimensions[257] ?? 0)
    }

    static func writeOrientedRaster(to url: URL) throws {
        let width = 2
        let height = 3
        var pixels = Data(repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = UInt8(index * 20)
            pixels[index * 4 + 1] = UInt8(240 - index * 20)
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { fatalError("failed to create orientation fixture") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            fatalError("failed to create orientation destination")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { fatalError("failed to write orientation fixture") }
        try (data as Data).write(to: url)
    }

    static func same(_ first: Sony2FujiProcessor.Buffer, _ second: Sony2FujiProcessor.Buffer) -> Bool {
        first.width == second.width && first.height == second.height &&
            first.nativeSize == second.nativeSize && first.data == second.data
    }

    // =========================================================================
    // Independent C setter reference catches omitted, swapped or signed axes.
    // =========================================================================
    static func perspectiveReference(_ source: Sony2FujiProcessor.Buffer, settings: RawSettings,
                                     mode: sony2fuji_gpu_mode) throws -> Sony2FujiProcessor.Buffer {
        let processor = Sony2FujiProcessor(gpuMode: mode)
        let session = try processor.createSession()
        defer { processor.destroySession(session) }
        var neutralPerspective = settings
        neutralPerspective.geometry.perspectiveHorizontal = 0
        neutralPerspective.geometry.perspectiveVertical = 0
        try processor.configureSession(session, settings: neutralPerspective, interactive: false)
        var perspective = sony2fuji_perspective_config()
        perspective.version = UInt32(SONY2FUJI_PERSPECTIVE_CONFIG_VERSION)
        perspective.struct_size = UInt32(MemoryLayout<sony2fuji_perspective_config>.size)
        perspective.horizontal = Float(settings.geometry.perspectiveHorizontal)
        perspective.vertical = Float(settings.geometry.perspectiveVertical)
        check(sony2fuji_session_set_perspective(session, &perspective) == SONY2FUJI_STATUS_OK,
              "direct C perspective reference accepts both axes")
        var request = processor.makeBaseRequest(settings: settings, inputType: SONY2FUJI_INPUT_BUFFER)
        request.input_type = SONY2FUJI_INPUT_BUFFER
        request.input_width = UInt32(source.width)
        request.input_height = UInt32(source.height)
        request.input_pixel_format = source.pixelFormat
        request.input_color_space = SONY2FUJI_COLOR_SRGB
        processor.applySize(&request, width: request.input_width, height: request.input_height,
                            previewLongEdge: nil, exportLongEdge: nil)
        var output = sony2fuji_buffer()
        defer { sony2fuji_release_buffer(&output) }
        check(processor.processBuffer(session: session, request: &request, buffer: source,
                                      lutPath: nil, outBuffer: &output) == SONY2FUJI_STATUS_OK,
              "direct C perspective reference renders")
        if mode == SONY2FUJI_GPU_AUTO {
            check(sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_CPU,
                  "active perspective reports CPU for the mixed Auto geometry result")
        } else if mode == SONY2FUJI_GPU_FORCE {
            check(sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_METAL,
                  "identity Force confirms Metal hardware is available")
        }
        var result = try processor.copyBuffer(output)
        result.nativeSize = processor.geometrySize(session)
        return result
    }

    static func perspectiveBuffers(_ source: Sony2FujiProcessor.Buffer, processor: Sony2FujiProcessor,
                                   geometry: RawSettings, output: URL) throws {
        _ = try perspectiveReference(source, settings: .default, mode: SONY2FUJI_GPU_FORCE)
        for (horizontal, vertical) in [(0.5, 0.0), (0.0, -0.25), (0.5, -0.25)] {
            var settings = RawSettings.default
            settings.geometry.perspectiveHorizontal = horizontal
            settings.geometry.perspectiveVertical = vertical
            let final = try processor.processBuffer(buffer: source, settings: settings,
                                                    previewLongEdge: nil, lutURL: nil)
            let reference = try perspectiveReference(source, settings: settings, mode: SONY2FUJI_GPU_OFF)
            check(same(final, reference), "iOS H=\(horizontal) V=\(vertical) matches direct C pixels and dimensions")
            let edge = Int(floor(256 / (1 + 0.25 * (abs(horizontal) + abs(vertical)))))
            check(final.width == edge && final.height == edge, "nonzero perspective uses the inscribed canvas")
            let preview = try processor.processBuffer(buffer: source, settings: settings,
                                                      previewLongEdge: CGFloat(edge), lutURL: nil,
                                                      interactive: true, viewportPreview: true)
            check(same(preview, final), "active perspective bypasses proxies and matches FINAL")
            let auto = try perspectiveReference(source, settings: settings, mode: SONY2FUJI_GPU_AUTO)
            check(auto.width == final.width && auto.height == final.height &&
                  zip(auto.data, final.data).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
                  "Auto and CPU perspective agree within two RGB8 values")
        }
        var combined = geometry
        combined.geometry.perspectiveHorizontal = 0.5
        combined.geometry.perspectiveVertical = -0.25
        let final = try processor.processBuffer(buffer: source, settings: combined,
                                                previewLongEdge: nil, lutURL: nil)
        let reference = try perspectiveReference(source, settings: combined, mode: SONY2FUJI_GPU_OFF)
        check(same(final, reference), "perspective preserves rotation, flip, straighten and crop")
        let limited = try processor.processBuffer(buffer: source, settings: combined,
                                                  previewLongEdge: nil, lutURL: nil, exportLongEdge: 48)
        let dng = output.appendingPathComponent("perspective.dng")
        try processor.exportDNG(buffer: source, settings: combined, lutURL: nil,
                                outputURL: dng, exportLongEdge: 48)
        check(try tiffDimensions(Data(contentsOf: dng)) == CGSize(width: limited.width, height: limited.height),
              "DNG FINAL receives perspective with the same capped dimensions")
        try frozenBatch(source, processor: processor, settings: combined, output: output, reference: limited)
        try legacySettings(source, processor: processor, settings: geometry)
    }

    static func frozenBatch(_ buffer: Sony2FujiProcessor.Buffer, processor: Sony2FujiProcessor,
                            settings: RawSettings, output: URL, reference: Sony2FujiProcessor.Buffer) throws {
        var editable = settings
        let url = output.appendingPathComponent("oriented.jpg")
        let source = BatchSourceSnapshot(identity: PhotoIdentity(resourceIdentifier: "source"),
                                         sourceURL: url, displayName: "source.jpg", sourceKind: .raster,
                                         settings: editable)
        let target = BatchTarget(identity: PhotoIdentity(resourceIdentifier: "target"),
                                 sourceURL: url, displayName: "target.jpg", sourceKind: .raster)
        let job = BatchExportJob(source: source, targets: [target], longEdge: 48)
        let restored = try JSONDecoder().decode(BatchExportJob.self, from: JSONEncoder().encode(job))
        editable.geometry = GeometrySettings()
        check(restored.source.settings.geometry == settings.geometry &&
              restored.source.settings.geometry != editable.geometry, "batch journal freezes both perspective axes")
        var writes = 0
        let completed = try BatchExportRunner.run(job: restored, journalStore: nil, render: { _, frozen in
            let result = try processor.processBuffer(buffer: buffer, settings: frozen,
                                                       previewLongEdge: nil, lutURL: nil, exportLongEdge: restored.longEdge)
            check(same(result, reference), "batch FINAL renders the frozen perspective pixels")
            return result.data
        }, write: { _, _, _, _ in writes += 1 })
        check(completed.status == .completed && writes == 1, "frozen perspective batch completes once")
    }

    static func legacySettings(_ source: Sony2FujiProcessor.Buffer, processor: Sony2FujiProcessor,
                               settings: RawSettings) throws {
        var document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        var geometry = document["geometry"] as! [String: Any]
        geometry.removeValue(forKey: "perspectiveHorizontal")
        geometry.removeValue(forKey: "perspectiveVertical")
        document["geometry"] = geometry
        let old = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: document))
        check(old.geometry == settings.geometry, "old records retain geometry and default both perspective axes to zero")
        let legacy = try processor.processBuffer(buffer: source, settings: old, previewLongEdge: nil, lutURL: nil)
        let explicit = try processor.processBuffer(buffer: source, settings: settings, previewLongEdge: nil, lutURL: nil)
        check(same(legacy, explicit), "old geometry records retain their rendered pixels")
    }

    static func perspectiveRaw(_ url: URL, lensDatabase: URL) throws {
        let processor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: lensDatabase)
        var settings = RawSettings.default
        settings.applyMasterRecipe(MasterRecipe.allRecipes[0])
        settings.tint = 20
        settings.lutStrength = 0.65
        settings.geometry.perspectiveHorizontal = 0.5
        settings.geometry.perspectiveVertical = -0.25
        let preview = try processor.processRaw(url: url, settings: settings, previewLongEdge: 128,
                                               lutURL: nil, interactive: true, viewportPreview: true).buffer
        let final = try processor.processRaw(url: url, settings: settings, previewLongEdge: nil,
                                             lutURL: nil, exportLongEdge: 128).buffer
        check(same(preview, final), "real RAW tinted recipe perspective preview equals FINAL after cold WB lookup")
        settings.geometry = GeometrySettings()
        let reset = try processor.processRaw(url: url, settings: settings, previewLongEdge: 128, lutURL: nil).buffer
        let fresh = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: lensDatabase)
        let identity = try fresh.processRaw(url: url, settings: settings, previewLongEdge: 128, lutURL: nil).buffer
        check(same(reset, identity), "reused RAW preview session resets both perspective axes to identity pixels")
        check(preview.nativeSize != identity.nativeSize && preview.data != identity.data,
              "nonzero RAW perspective changes canvas and pixels")
        let auto = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_AUTO, lensDatabaseURL: lensDatabase)
        settings.geometry.perspectiveHorizontal = 0.5
        settings.geometry.perspectiveVertical = -0.25
        let gpu = try auto.processRaw(url: url, settings: settings, previewLongEdge: 128,
                                      lutURL: nil, interactive: true, viewportPreview: true).buffer
        check(gpu.width == preview.width && gpu.height == preview.height && gpu.nativeSize == preview.nativeSize &&
              zip(gpu.data, preview.data).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
              "real RAW perspective Auto and CPU agree within two RGB8 values")
    }

    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let lensDatabase = root.appendingPathComponent("lutools/third_party/lensfun/version_1")
        let processor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: lensDatabase)
        let cpuProcessor = processor
        var data = Data(count: 256 * 256 * 4)
        for pixel in 0..<(256 * 256) {
            data[pixel * 4] = UInt8(pixel % 256)
            data[pixel * 4 + 1] = UInt8(pixel / 256)
            data[pixel * 4 + 2] = 96
            data[pixel * 4 + 3] = 255
        }
        let source = Sony2FujiProcessor.Buffer(data: data, width: 256, height: 256,
                                                stride: 1024, pixelFormat: SONY2FUJI_PIXEL_RGBA8)
        let rasterURL = output.appendingPathComponent("oriented.jpg")
        try writeOrientedRaster(to: rasterURL)
        let raster = try processor.loadRasterBuffer(url: rasterURL)
        let oriented = try processor.loadRasterBuffer(url: rasterURL, applyingOrientation: true)
        check(oriented.orientation == .up && oriented.buffer.width == raster.buffer.height &&
              oriented.buffer.height == raster.buffer.width,
              "iOS geometry input bakes EXIF orientation before processing")
        var geometry = RawSettings.default
        geometry.geometry.quarterTurns = 1
        geometry.geometry.flipHorizontal = true
        let rotatedRaster = try cpuProcessor.processBuffer(buffer: oriented.buffer, settings: geometry,
                                                           previewLongEdge: nil, lutURL: nil)
        check(rotatedRaster.width == raster.buffer.width && rotatedRaster.height == raster.buffer.height,
              "iOS geometry rotates the already-oriented raster canvas once")
        let uprightJPEG = try processor.makeJPEGData(from: rotatedRaster, sourceURL: rasterURL,
                                                      orientation: .up, quality: 0.92)
        check((properties(uprightJPEG)[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1,
              "iOS geometry JPEG is physically upright with neutral orientation metadata")
        geometry.geometry.cropX = 0.125
        geometry.geometry.cropY = 0.25
        geometry.geometry.cropWidth = 0.75
        geometry.geometry.cropHeight = 0.5
        let geometryFinal = try cpuProcessor.processBuffer(buffer: source, settings: geometry,
                                                            previewLongEdge: nil, lutURL: nil)
        let geometryPreview = try cpuProcessor.processBuffer(buffer: source, settings: geometry,
                                                              previewLongEdge: 192, lutURL: nil,
                                                              interactive: true, viewportPreview: true)
        check(geometryFinal.width == 192 && geometryFinal.height == 128,
              "iOS crop uses normalized post-rotation canvas coordinates")
        check(geometryPreview.width == geometryFinal.width && geometryPreview.height == geometryFinal.height &&
              geometryPreview.data == geometryFinal.data,
              "iOS geometry preview and FINAL export share exact geometry")
        let geometryLimited = try cpuProcessor.processBuffer(buffer: source, settings: geometry,
                                                              previewLongEdge: nil, lutURL: nil, exportLongEdge: 48)
        check(geometryLimited.nativeSize == CGSize(width: 192, height: 128),
              "iOS preview and final resize retain native geometry canvas dimensions")
        check(geometryLimited.width == 48 && geometryLimited.height == 32,
              "iOS final resize preserves the cropped aspect ratio")
        let identityAgain = try cpuProcessor.processBuffer(buffer: source, settings: .default,
                                                            previewLongEdge: nil, lutURL: nil)
        check(identityAgain.width == 256 && identityAgain.height == 256,
              "iOS default settings restore identity geometry after an active crop")
        geometry.geometry.straightenDegrees = 7
        let straightened = try cpuProcessor.processBuffer(buffer: source, settings: geometry,
                                                           previewLongEdge: nil, lutURL: nil)
        check(straightened.width < geometryFinal.width && straightened.height < geometryFinal.height,
              "iOS straightening uses the inscribed canvas before crop")
        let dng = output.appendingPathComponent("geometry.dng")
        try processor.exportDNG(buffer: source, settings: geometry, lutURL: nil,
                                outputURL: dng, exportLongEdge: 48)
        // ImageIO on this simulator does not expose dimensions for float32 linear DNG.
        let dngSize = try tiffDimensions(Data(contentsOf: dng))
        check(dngSize == CGSize(width: 48, height: 32),
              "iOS DNG stores the cropped geometry and final size cap")
        check(processor.makeUIImage(from: geometryFinal, orientation: .up)?.imageOrientation == .up,
              "iOS geometry preview does not apply EXIF orientation again")
        try perspectiveBuffers(source, processor: processor, geometry: geometry, output: output)
        if CommandLine.arguments.count > 3 && !CommandLine.arguments[3].isEmpty {
            try perspectiveRaw(URL(fileURLWithPath: CommandLine.arguments[3]), lensDatabase: lensDatabase)
        } else {
            print("UNVERIFIED: real RAW perspective/session reset; pass RAWLAB_TEST_RAW or the third script argument")
        }
    }
}
