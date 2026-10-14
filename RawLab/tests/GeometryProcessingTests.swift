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
    }
}
