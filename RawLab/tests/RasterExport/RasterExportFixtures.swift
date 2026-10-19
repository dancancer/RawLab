import Foundation
import ImageIO
import UIKit

enum RasterExportFailure: Error { case message(String) }

final class RasterExportFixture {
    let model: RawEditorViewModel
    let directory: URL
    private var cacheURLs: Set<URL> = []

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = RawEditorViewModel(editPersistence: try EditPersistence(
            directory: directory.appendingPathComponent("edits")))
    }

    func cleanup() {
        cacheURLs.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func importRaster(_ url: URL) throws {
        try importPhoto(.raster(url))
    }

    func importPhoto(_ source: PhotoImportSource) throws {
        let identity = PhotoIdentity(resourceIdentifier: "raster-export-\(UUID().uuidString)")
        let request = model.importImage(from: source, identity: identity)
        try Self.waitUntil { self.model.activeImportRevision != request }
        guard model.hasImage, model.sourceIdentity == identity, let url = model.sourceFile?.withReadAccess({ $0 }) else {
            throw RasterExportFailure.message("Import failed: \(model.statusMessage ?? "no published image")")
        }
        cacheURLs.insert(url)
        try Self.waitUntil { !self.model.previewRendering && !self.model.previewResizePending }
    }

    static func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(120)
        while !condition() {
            guard Date() < deadline else { throw RasterExportFailure.message("Operation timed out") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
    }

    func jpeg(settings: RawSettings = .default, longEdge: Int? = nil) throws -> Data {
        var result: Result<Data, Error>?
        model.exportJPEG(settings: settings, longEdge: longEdge) { result = $0 }
        try Self.waitUntil { result != nil }
        return try result!.get()
    }

    func dng(settings: RawSettings = .default, longEdge: Int? = nil) throws -> Data {
        var result: Result<URL, Error>?
        model.exportDNG(settings: settings, longEdge: longEdge) { result = $0 }
        try Self.waitUntil { result != nil }
        let url = try result!.get()
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    func referenceJPEG(buffer: Sony2FujiProcessor.Buffer, source: URL,
                       settings: RawSettings = .default, longEdge: Int? = nil) throws -> Data {
        let output = try model.processor.processBuffer(buffer: buffer, settings: settings,
            previewLongEdge: nil, lutURL: nil, exportLongEdge: longEdge)
        return try model.processor.makeJPEGData(from: output, sourceURL: source, orientation: .up, quality: 0.92)
    }

    func referenceDNG(buffer: Sony2FujiProcessor.Buffer, settings: RawSettings = .default,
                      longEdge: Int? = nil) throws -> Data {
        let url = directory.appendingPathComponent("reference-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try model.processor.exportDNG(buffer: buffer, settings: settings, lutURL: nil,
                                      outputURL: url, exportLongEdge: longEdge)
        return try Data(contentsOf: url)
    }

    static func writeRaster(_ url: URL, orientation: Int = 1, variant: Int = 0) throws {
        let width = 96, height = 64
        var pixels = Data(repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 2 + variant * 87) % 256)
                pixels[offset + 1] = UInt8((y * 3 + variant * 59) % 256)
                pixels[offset + 2] = UInt8(((x + y) + variant * 137) % 256)
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                  bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                  (url.pathExtension == "png" ? "public.png" : "public.jpeg") as CFString, 1, nil) else {
            throw RasterExportFailure.message("Cannot create raster fixture")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "fixture-\(variant)"]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RasterExportFailure.message("Cannot write raster fixture")
        }
    }

    static func jpegPixels(_ data: Data, directory: URL) throws -> Data {
        let url = directory.appendingPathComponent("pixels-\(UUID().uuidString).jpg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Sony2FujiProcessor().loadRasterBuffer(url: url).buffer.data
    }
}
