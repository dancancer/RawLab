import Foundation
import ImageIO

enum ExportCacheLifetimeTests {
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure.message(message) }
        print("PASS: \(message)")
    }

    private static func exportAfterReplacement(directory: URL, dng: Bool, rawURL: URL?) throws {
        let queue = DispatchQueue(label: "com.rawlab.tests.export-cache")
        let f = try Fixture(directory: directory, exportQueue: queue)
        let source = rawURL.map(PhotoImportSource.raw) ?? .raster(f.aURL)
        f.model.importImage(from: source, identity: f.aIdentity)
        try f.collector.take().forEach { $0() }
        try check(f.model.hasImage, "Export lifetime fixture imports \(rawURL == nil ? "raster" : "RAW")")
        let oldURL = f.model.sourceURL!
        let oldBytes = try Data(contentsOf: oldURL)
        let oldMetadata = try ExportMetadata.properties(from: oldURL, width: 40, height: 30, orientation: .up)
        let oldTIFF = oldMetadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        var jpegResult: Result<Data, Error>?
        var dngResult: Result<URL, Error>?
        var outputURL: URL?
        defer { if let outputURL { try? FileManager.default.removeItem(at: outputURL) } }

        /* 只暂停导出队列，让真实导入先发布 B，再允许旧导出首次读取 A。 */
        queue.suspend()
        var suspended = true
        defer { if suspended { queue.resume() } }
        if dng {
            f.model.exportDNG(settings: .default, longEdge: 40) { dngResult = $0 }
        } else {
            f.model.exportJPEG(settings: .default, longEdge: 40) { jpegResult = $0 }
        }
        try check(f.model.isBusy && jpegResult == nil && dngResult == nil, "Single export is in flight before it can read the source")
        f.model.importImage(from: .raster(f.bURL), identity: f.bIdentity)
        try f.collector.take().forEach { $0() }
        try check(f.model.sourceIdentity == f.bIdentity && f.model.sourceURL != oldURL,
                  "New photo publishes before the queued export reads its old photo")
        try check(try Data(contentsOf: oldURL) == oldBytes, "In-flight export keeps the old cached bytes readable")
        queue.resume()
        suspended = false
        queue.sync {}
        if dng { try f.collector.take().forEach { $0() } }
        else {
            let deadline = Date().addingTimeInterval(15)
            while jpegResult == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }

        if dng {
            guard let result = dngResult else { throw TestFailure.message("DNG export did not finish") }
            let url = try result.get()
            outputURL = url
            try check(try Data(contentsOf: url).count > 200 && CGImageSourceCreateWithURL(url as CFURL, nil) != nil,
                      "Queued \(rawURL == nil ? "raster" : "RAW") DNG export succeeds after the source changes")
        } else {
            guard let result = jpegResult else { throw TestFailure.message("JPEG export did not finish") }
            let bytes = try result.get()
            guard let image = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                throw TestFailure.message("Queued export did not produce a readable JPEG")
            }
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            try check(max(width, height) == 40 && (rawURL != nil || height == 30) &&
                      tiff?[kCGImagePropertyTIFFMake] as? String == oldTIFF?[kCGImagePropertyTIFFMake] as? String,
                      "Queued \(rawURL == nil ? "raster" : "RAW") JPEG exports old pixels and source metadata after replacement")
        }
        try check(!FileManager.default.fileExists(atPath: oldURL.path), "Export releases the old cache file after its final read")
        try check(f.model.sourceIdentity == f.bIdentity && f.model.hasImage, "Old export completion leaves the new photo published")
    }

    static func run(root: URL, rawURL: URL?) throws {
        for dng in [false, true] {
            try exportAfterReplacement(directory: root.appendingPathComponent("raster-\(dng)"), dng: dng, rawURL: nil)
            if let rawURL {
                try exportAfterReplacement(directory: root.appendingPathComponent("raw-\(dng)"), dng: dng, rawURL: rawURL)
            }
        }
        if rawURL == nil { print("SKIP: RAW export lifetime (pass a private RAW fixture as the third script argument)") }
        print("PASS: export cache lifetime regression suite")
    }
}
