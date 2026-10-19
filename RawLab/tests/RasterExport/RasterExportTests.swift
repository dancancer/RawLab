import Combine
import Foundation
import ImageIO

@main
struct RasterExportTests {
    private static var assertions = 0

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw RasterExportFailure.message(message) }
        assertions += 1
        print("PASS: \(message)")
    }

    private static func unchangedCache(_ fixture: RasterExportFixture) throws {
        for (name, orientation) in [("upright.jpg", 1), ("rotated.jpg", 6), ("opaque.png", 1)] {
            let source = fixture.directory.appendingPathComponent(name)
            try RasterExportFixture.writeRaster(source, orientation: orientation)
            try fixture.importRaster(source)
            let model = fixture.model
            let url = model.sourceFile!.withReadAccess({ $0 })
            let decoded = try model.processor.loadRasterBuffer(url: url)
            let expectedWidth = orientation == 6 ? 64 : 96
            let expectedHeight = orientation == 6 ? 96 : 64
            try check(model.draftBuffer?.width == expectedWidth && model.draftBuffer?.height == expectedHeight &&
                      model.draftBuffer?.data == decoded.buffer.data && model.sourceOrientation == .up,
                      "\(name): published source is full size, upright and identical to a fresh decode")
            for longEdge in [nil, 48] as [Int?] {
                var settings = RawSettings.default
                settings.exposure = 0.35
                settings.geometry.quarterTurns = 1
                settings.geometry.cropWidth = 0.75
                let expectedJPEG = try fixture.referenceJPEG(buffer: decoded.buffer, source: url,
                                                             settings: settings, longEdge: longEdge)
                let actualJPEG = try fixture.jpeg(settings: settings, longEdge: longEdge)
                try check(actualJPEG == expectedJPEG,
                          "\(name), edge \(longEdge ?? 0): JPEG bytes equal the re-decode path")
                let expectedDNG = try fixture.referenceDNG(buffer: decoded.buffer, settings: settings, longEdge: longEdge)
                let actualDNG = try fixture.dng(settings: settings, longEdge: longEdge)
                try check(actualDNG == expectedDNG,
                          "\(name), edge \(longEdge ?? 0): DNG bytes equal the re-decode path")
            }
        }
    }

    private static func rewrittenCache(_ fixture: RasterExportFixture) throws {
        let source = fixture.directory.appendingPathComponent("published.jpg")
        try RasterExportFixture.writeRaster(source, orientation: 6)
        try fixture.importRaster(source)
        let model = fixture.model
        let published = model.draftBuffer!
        let preview = model.previewImage?.pngData()
        let url = model.sourceFile!.withReadAccess({ $0 })
        try RasterExportFixture.writeRaster(url, variant: 1)
        let replacement = try model.processor.loadRasterBuffer(url: url).buffer
        try check(replacement.data != published.data && model.previewImage?.pngData() == preview,
                  "Cache was replaced with different pixels while the old photo stays published")
        let expectedJPEG = try fixture.referenceJPEG(buffer: published, source: url)
        let actualJPEG = try fixture.jpeg()
        try check(try RasterExportFixture.jpegPixels(actualJPEG, directory: fixture.directory) ==
                  RasterExportFixture.jpegPixels(expectedJPEG, directory: fixture.directory),
                  "Rewritten cache: JPEG pixels still match the published photo")
        let properties = CGImageSourceCreateWithData(actualJPEG as CFData, nil).flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        try check(tiff?[kCGImagePropertyTIFFArtist] as? String == "fixture-1",
                  "JPEG metadata still comes from the current cache file, not the pixel snapshot")
        let expectedDNG = try fixture.referenceDNG(buffer: published)
        try check(try fixture.dng() == expectedDNG,
                  "Rewritten cache: DNG bytes still match the published photo")
    }

    private static func missingBuffer(_ fixture: RasterExportFixture) throws {
        let source = fixture.directory.appendingPathComponent("missing-buffer.png")
        try RasterExportFixture.writeRaster(source)
        try fixture.importRaster(source)
        fixture.model.draftBuffer = nil
        for format in ["JPEG", "DNG"] {
            var rejected = false
            do {
                if format == "JPEG" { _ = try fixture.jpeg() }
                else { _ = try fixture.dng() }
            } catch EditorError.noImageLoaded { rejected = true }
            try check(rejected && !fixture.model.isBusy,
                      "\(format): raster without a published buffer fails instead of silently decoding")
        }
    }

    private static func photoSwitch(_ fixture: RasterExportFixture) throws {
        let first = fixture.directory.appendingPathComponent("switch-first.jpg")
        let second = fixture.directory.appendingPathComponent("switch-second.png")
        try RasterExportFixture.writeRaster(first, orientation: 6)
        try RasterExportFixture.writeRaster(second, variant: 1)
        for format in ["JPEG", "DNG"] {
            try fixture.importRaster(first)
            let originalURL = fixture.model.sourceFile!.withReadAccess({ $0 })
            let originalBuffer = fixture.model.draftBuffer!
            let expected = try format == "JPEG"
                ? fixture.referenceJPEG(buffer: originalBuffer, source: originalURL)
                : fixture.referenceDNG(buffer: originalBuffer)
            var jpeg: Result<Data, Error>?
            var dng: Result<URL, Error>?
            var switched = false
            var importFailure: Error?
            // ====================================================================
            // 同步的 busy 发布把导出停在后台入队之前，不给线程调度决定切图顺序。
            // ====================================================================
            let observation = fixture.model.$isBusy.dropFirst().sink { busy in
                guard busy, !switched else { return }
                switched = true
                do { try fixture.importRaster(second) }
                catch { importFailure = error }
            }
            defer { observation.cancel() }
            if format == "JPEG" { fixture.model.exportJPEG(settings: .default) { jpeg = $0 } }
            else { fixture.model.exportDNG(settings: .default) { dng = $0 } }
            if let importFailure { throw importFailure }
            try check(switched && jpeg == nil && dng == nil && fixture.model.isBusy &&
                      fixture.model.sourceFile?.withReadAccess({ $0 }) != originalURL && fixture.model.draftBuffer?.data != originalBuffer.data,
                      "\(format): the second import publishes before the export worker is queued")
            try RasterExportFixture.waitUntil { jpeg != nil || dng != nil }
            let actual: Data
            if let jpeg { actual = try jpeg.get() }
            else {
                let url = try dng!.get()
                defer { try? FileManager.default.removeItem(at: url) }
                actual = try Data(contentsOf: url)
            }
            try check(actual == expected && fixture.model.sourceFile?.withReadAccess({ $0 }) != originalURL &&
                      fixture.model.draftBuffer?.data != originalBuffer.data,
                      "\(format): importing another photo cannot mix the new source with the in-flight export")
        }
    }

    private static func rawIgnoresDraft(_ fixture: RasterExportFixture, raw: URL) throws {
        try fixture.importPhoto(.raw(raw))
        let model = fixture.model
        let source = model.sourceFile!.withReadAccess({ $0 })
        let result = try model.processor.processRaw(url: source, settings: .default,
            previewLongEdge: nil, lutURL: nil, exportLongEdge: 64)
        let expectedJPEG = try model.processor.makeJPEGData(from: result.buffer, sourceURL: source,
                                                            orientation: result.orientation, quality: 0.92)
        let reference = fixture.directory.appendingPathComponent("raw-reference.dng")
        defer { try? FileManager.default.removeItem(at: reference) }
        try model.processor.exportDNG(url: source, settings: .default, lutURL: nil,
                                      outputURL: reference, exportLongEdge: 64)
        let expectedDNG = try Data(contentsOf: reference)
        let poison = fixture.directory.appendingPathComponent("poison.png")
        try RasterExportFixture.writeRaster(poison, variant: 1)
        model.draftBuffer = try model.processor.loadRasterBuffer(url: poison).buffer
        try check(try fixture.jpeg(longEdge: 64) == expectedJPEG,
                  "RAW JPEG ignores an unrelated raster draft buffer")
        try check(try fixture.dng(longEdge: 64) == expectedDNG,
                  "RAW DNG ignores an unrelated raster draft buffer")
        model.draftBuffer = nil
        try check(try fixture.jpeg(longEdge: 64) == expectedJPEG,
                  "RAW JPEG does not require a draft buffer")
        try check(try fixture.dng(longEdge: 64) == expectedDNG,
                  "RAW DNG does not require a draft buffer")
    }

    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 4 else {
            throw RasterExportFailure.message("Pass mode (tests/benchmark), real RAW and output directory")
        }
        let mode = CommandLine.arguments[1]
        let raw = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try check(Thread.isMainThread, "Export snapshots and import publications run on the main thread")
        if mode == "benchmark" {
            try RasterExportBenchmark.run(raw: raw, directory: output)
            return
        }
        let fixture = try RasterExportFixture(directory: output)
        defer { fixture.cleanup() }
        switch mode {
        case "tests":
            try unchangedCache(fixture)
            try photoSwitch(fixture)
            try rawIgnoresDraft(fixture, raw: raw)
            try rewrittenCache(fixture)
            try missingBuffer(fixture)
        case "rewritten-cache": try rewrittenCache(fixture)
        case "missing-buffer": try missingBuffer(fixture)
        default: throw RasterExportFailure.message("Unknown mode: \(mode)")
        }
        print("PASS: single raster export regression suite (\(assertions) assertions)")
    }
}
