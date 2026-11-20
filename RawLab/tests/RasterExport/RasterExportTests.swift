import RawLabKit
import Combine
import CoreGraphics
import Foundation
import ImageIO
import UIKit

@_silgen_name("rawlab_raster_counter_reset")
func rawlabRasterCounterReset()
@_silgen_name("rawlab_raster_counter_load_display_image")
func rawlabRasterCounterLoadDisplayImage() -> Int32
@_silgen_name("rawlab_raster_counter_cg_full_image")
func rawlabRasterCounterCGFullImage() -> Int32
@_silgen_name("rawlab_raster_counter_cg_thumbnail")
func rawlabRasterCounterCGThumbnail() -> Int32

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
            try boundedLargeRasterPreviewAndExport(fixture)
        case "rewritten-cache": try rewrittenCache(fixture)
        case "missing-buffer": try missingBuffer(fixture)
        default: throw RasterExportFailure.message("Unknown mode: \(mode)")
        }
        print("PASS: single raster export regression suite (\(assertions) assertions)")
    }

    private static func writeLargeImage(_ url: URL, width: Int, height: Int, orientation: Int = 1,
                                        colorSpaceName: CFString = CGColorSpace.sRGB,
                                        bitsPerComponent: Int = 8, alpha: UInt8 = 255) throws {
        let bytesPerComponent = bitsPerComponent / 8
        let stride = width * 4 * bytesPerComponent
        var data = Data(count: stride * height)
        data.withUnsafeMutableBytes { raw in
            if bitsPerComponent == 16 {
                let ptr = raw.bindMemory(to: UInt16.self)
                let a16: UInt16 = alpha == 255 ? 65535 : UInt16(alpha) * 257
                for y in 0..<height {
                    for x in 0..<width {
                        let base = (y * width + x) * 4
                        ptr[base] = UInt16((x * 65535) / max(1, width - 1))
                        ptr[base + 1] = UInt16((y * 65535) / max(1, height - 1))
                        ptr[base + 2] = 32768
                        ptr[base + 3] = a16
                    }
                }
            } else {
                let ptr = raw.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let base = (y * width + x) * 4
                        ptr[base] = UInt8((x * 255) / max(1, width - 1))
                        ptr[base + 1] = UInt8((y * 255) / max(1, height - 1))
                        ptr[base + 2] = 128
                        ptr[base + 3] = alpha
                    }
                }
            }
        }
        let uti = url.pathExtension.lowercased() == "png" ? "public.png" : "public.jpeg"
        let bitmapInfo: CGBitmapInfo = bitsPerComponent == 16
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder16Little)
            : CGBitmapInfo(rawValue: (alpha == 255 ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: colorSpaceName),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: bitsPerComponent,
                                    bitsPerPixel: 4 * bitsPerComponent, bytesPerRow: stride,
                                    space: space, bitmapInfo: bitmapInfo,
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            throw RasterExportFailure.message("Failed to build large raster fixture at \(url.path)")
        }
        CGImageDestinationAddImage(dest, cgImage, [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw RasterExportFailure.message("Failed to finalize large raster fixture at \(url.path)")
        }
    }

    private static func imageDimensions(ofData data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return (w, h)
    }

    private static func dngDimensions(ofData bytes: Data) -> (Int, Int)? {
        guard bytes.count >= 8 else { return nil }
        let little = bytes[0] == 0x49 && bytes[1] == 0x49
        guard little || (bytes[0] == 0x4d && bytes[1] == 0x4d) else { return nil }
        func integer(_ offset: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { value, index in
                let shift = little ? index : count - index - 1
                return value | (Int(bytes[offset + index]) << (shift * 8))
            }
        }
        func readIFDDims(_ directory: Int) -> (width: Int, height: Int, hasVersion: Bool, subIFDOffsets: [Int])? {
            guard directory > 0, directory <= bytes.count - 2 else { return nil }
            let count = integer(directory, 2)
            guard count <= (bytes.count - directory - 2) / 12 else { return nil }
            var width = 0, height = 0, hasVersion = false
            var subIFDOffsets: [Int] = []
            for index in 0..<count {
                let entry = directory + 2 + index * 12
                let tag = integer(entry, 2), type = integer(entry + 2, 2), values = integer(entry + 4, 4)
                if (tag == 256 || tag == 257) && values == 1 && (type == 3 || type == 4) {
                    let dimension = integer(entry + 8, type == 3 ? 2 : 4)
                    if tag == 256 { width = dimension } else { height = dimension }
                }
                if tag == 50706 && type == 1 && values == 4 { hasVersion = bytes[entry + 8] == 1 }
                if tag == 330 && (type == 4 || type == 13) && values >= 1 {
                    if values == 1 {
                        subIFDOffsets.append(integer(entry + 8, 4))
                    } else {
                        let tableOffset = integer(entry + 8, 4)
                        if tableOffset > 0 && tableOffset + values * 4 <= bytes.count {
                            for i in 0..<values {
                                subIFDOffsets.append(integer(tableOffset + i * 4, 4))
                            }
                        }
                    }
                }
            }
            return (width, height, hasVersion, subIFDOffsets)
        }
        guard integer(2, 2) == 42, let ifd0 = readIFDDims(integer(4, 4)), ifd0.hasVersion else { return nil }
        var best = (ifd0.width, ifd0.height)
        for subOffset in ifd0.subIFDOffsets {
            if let sub = readIFDDims(subOffset), sub.width * sub.height > best.0 * best.1 {
                best = (sub.width, sub.height)
            }
        }
        return (best.0 > 0 && best.1 > 0) ? best : nil
    }

    private static func boundedLargeRasterPreviewAndExport(_ fixture: RasterExportFixture) throws {
        // 1. Small raster export reuses draftBuffer with 0 loadDisplayImage calls.
        let small = fixture.directory.appendingPathComponent("small-reuse.jpg")
        try RasterExportFixture.writeRaster(small, orientation: 1)
        try fixture.importRaster(small)
        try check(fixture.model.draftBuffer?.isProxy == false, "small 96x64 raster draftBuffer is non-proxy")
        rawlabRasterCounterReset()
        _ = try fixture.jpeg()
        _ = try fixture.dng()
        try check(rawlabRasterCounterLoadDisplayImage() == 0,
                  "small raster JPEG+DNG export reuses draftBuffer with 0 loadDisplayImage calls (got \(rawlabRasterCounterLoadDisplayImage()))")

        // 2. Large 2000x1500 JPEG uses bounded ImageIO thumbnail (0 full-res decodes) and exports full 2000x1500 once.
        let largeJPEG = fixture.directory.appendingPathComponent("large-2000x1500.jpg")
        try writeLargeImage(largeJPEG, width: 2000, height: 1500)
        rawlabRasterCounterReset()
        try fixture.importRaster(largeJPEG)
        let draft = fixture.model.draftBuffer
        try check(draft?.isProxy == true && max(draft?.width ?? 0, draft?.height ?? 0) == 1280 &&
                  draft?.nativeSize == CGSize(width: 2000, height: 1500),
                  "large 2000x1500 JPEG import produces 1280px proxy with nativeSize 2000x1500")
        try check(rawlabRasterCounterLoadDisplayImage() == 0 && rawlabRasterCounterCGFullImage() == 0 &&
                  rawlabRasterCounterCGThumbnail() >= 1,
                  "large 8-bit JPEG import performs 0 full-res decodes (load=\(rawlabRasterCounterLoadDisplayImage()) cgFull=\(rawlabRasterCounterCGFullImage()) thumb=\(rawlabRasterCounterCGThumbnail()))")

        rawlabRasterCounterReset()
        let fullJPEG = try fixture.jpeg()
        let fullDims = imageDimensions(ofData: fullJPEG)
        try check(fullDims?.0 == 2000 && fullDims?.1 == 1500 && rawlabRasterCounterLoadDisplayImage() == 1,
                  "large JPEG export produces full 2000x1500 output with 1 loadDisplayImage call")

        rawlabRasterCounterReset()
        let fullDNG = try fixture.dng()
        let dngDims = dngDimensions(ofData: fullDNG)
        let dngLoads = rawlabRasterCounterLoadDisplayImage()
        try check(dngDims?.0 == 2000 && dngDims?.1 == 1500 && dngLoads == 1,
                  "large DNG export produces full 2000x1500 output with 1 loadDisplayImage call (dims=\(String(describing: dngDims)) loads=\(dngLoads))")

        // 3. Rotated Display-P3 JPEG (1500x2000 with orientation 6 -> oriented 2000x1500).
        let p3Rotated = fixture.directory.appendingPathComponent("p3-rotated.jpg")
        try writeLargeImage(p3Rotated, width: 1500, height: 2000, orientation: 6, colorSpaceName: CGColorSpace.displayP3)
        rawlabRasterCounterReset()
        try fixture.importRaster(p3Rotated)
        let p3Draft = fixture.model.draftBuffer
        try check(p3Draft?.isProxy == true && p3Draft?.width == 1280 && p3Draft?.height == 960 &&
                  p3Draft?.nativeSize == CGSize(width: 2000, height: 1500) && rawlabRasterCounterCGFullImage() == 0,
                  "rotated Display-P3 JPEG import bounds to 1280x960 proxy with nativeSize 2000x1500 and 0 full-res decodes")
        let p3ExportDims = imageDimensions(ofData: try fixture.jpeg())
        try check(p3ExportDims?.0 == 2000 && p3ExportDims?.1 == 1500,
                  "rotated Display-P3 JPEG exports full upright 2000x1500")

        // 4. Large 16-bit opaque PNG (1600x1200) bounds resident draftBuffer to 1280px proxy and exports full 1600x1200.
        let large16PNG = fixture.directory.appendingPathComponent("large-16bit.png")
        try writeLargeImage(large16PNG, width: 1600, height: 1200, bitsPerComponent: 16)
        try fixture.importRaster(large16PNG)
        let png16Draft = fixture.model.draftBuffer
        try check(png16Draft?.isProxy == true && max(png16Draft?.width ?? 0, png16Draft?.height ?? 0) == 1280 &&
                  png16Draft?.nativeSize == CGSize(width: 1600, height: 1200),
                  "16-bit 1600x1200 PNG import bounds resident draftBuffer to 1280px proxy")
        let png16DNGDims = dngDimensions(ofData: try fixture.dng())
        try check(png16DNGDims?.0 == 1600 && png16DNGDims?.1 == 1200,
                  "16-bit PNG DNG export produces full 1600x1200 (dims=\(String(describing: png16DNGDims)))")

        // 5. Transparent PNG (alpha=128) is rejected by bounded preview decode too.
        let alphaPNG = fixture.directory.appendingPathComponent("transparent.png")
        try writeLargeImage(alphaPNG, width: 1600, height: 1200, alpha: 128)
        var alphaRejected = false
        do { _ = try fixture.model.processor.loadRasterBuffer(url: alphaPNG, previewLongEdge: 1280) }
        catch { alphaRejected = true }
        try check(alphaRejected, "transparent large PNG is rejected by bounded preview decode")
    }
}
