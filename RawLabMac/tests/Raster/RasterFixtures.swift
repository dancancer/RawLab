import AppKit
import Foundation
import ImageIO

struct RasterFixture {
    let url: URL
    let label: String
    let oriented: Bool
}

struct RasterContext {
    let root: URL
    let cli: URL
    let raw: URL
}

func fail(_ message: String) -> RenderError {
    .failed("Raster render test: \(message)")
}

func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw fail(message) }
    print("PASS: \(message)")
}

func image(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let result = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw fail("cannot decode \(url.lastPathComponent)")
    }
    return result
}
func properties(_ url: URL) throws -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        throw fail("cannot read ImageIO metadata for \(url.lastPathComponent)")
    }
    return values
}

func pixelData(_ image: CGImage) -> Data {
    image.dataProvider!.data! as Data
}

func renderedRGB8(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: &bytes, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue |
                                      CGBitmapInfo.byteOrder32Big.rawValue) else {
        return []
    }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (0..<(image.width * image.height)).flatMap { Array(bytes[($0 * 4)..<($0 * 4 + 3)]) }
}

func comparePNG(_ expected: URL, _ actual: URL, _ label: String) throws {
    let a = try image(expected)
    let b = try image(actual)
    try check(a.bitsPerComponent == 16 && b.bitsPerComponent == 16,
              "\(label): both outputs are 16-bit PNG")
    try check(a.width == b.width && a.height == b.height,
              "\(label): output dimensions match (\(a.width)x\(a.height))")
    try check(pixelData(a) == pixelData(b), "\(label): decoded PNG pixels match exactly")
}

func writeImage(_ image: CGImage, to url: URL, type: CFString,
                        properties: [CFString: Any]) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination)
}

func fixtureImage() -> CGImage {
    let width = 96
    let height = 64
    var bytes = [UInt8](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 3
            bytes[offset] = UInt8((x * 5 + y * 3 + (x * y) / 17) & 255)
            bytes[offset + 1] = UInt8((y * 7 + x * 2 + 31) & 255)
            bytes[offset + 2] = UInt8((x * 3 + y * 11 + (x + y) * 2) & 255)
        }
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                   bytesPerRow: width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

func fixtureAlphaImage() -> CGImage {
    let bytes: [UInt8] = [255, 40, 20, 127, 20, 180, 255, 127]
    return CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

func fixture16BitImage() -> CGImage {
    let values: [UInt16] = [0x0123, 0x4567, 0x89ab, 0xcdef, 0x1357, 0x9bdf]
    var bytes = [UInt8]()
    for value in values { bytes += [UInt8(value >> 8), UInt8(value & 255)] }
    return CGImage(width: 2, height: 1, bitsPerComponent: 16, bitsPerPixel: 48,
                   bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

func fixtureProperties(oriented: Bool) -> [CFString: Any] {
    let orientation: UInt32 = oriented ? 6 : 1
    let tiff: [CFString: Any] = [
        kCGImagePropertyTIFFMake: "RawLab Fixture Camera",
        kCGImagePropertyTIFFModel: "RawLab Raster 1",
        kCGImagePropertyTIFFImageDescription: "rawlab-raster-metadata",
        kCGImagePropertyTIFFDateTime: "2026:10:15 12:34:56"
    ]
    let exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: "2026:10:15 12:34:56",
        kCGImagePropertyExifLensModel: "RawLab Fixture 35mm",
        kCGImagePropertyExifISOSpeedRatings: [400],
        kCGImagePropertyExifFNumber: 2.8
    ]
    return [kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyExifDictionary: exif]
}

func makeFixtures(in root: URL) throws -> [RasterFixture] {
    let source = fixtureImage()
    let metadata = fixtureProperties(oriented: true)
    var result: [RasterFixture] = []
    let definitions: [(String, CFString)] = [
        ("png", "public.png" as CFString),
        ("jpg", "public.jpeg" as CFString),
        ("tiff", "public.tiff" as CFString)
    ]
    for (suffix, type) in definitions {
        let url = root.appendingPathComponent("raster-\(suffix).\(suffix)")
        guard writeImage(source, to: url, type: type, properties: metadata) else {
            throw fail("system encoder could not create \(suffix) fixture")
        }
        result.append(RasterFixture(url: url, label: suffix, oriented: true))
    }
    let heif = root.appendingPathComponent("raster-heic.heic")
    if writeImage(source, to: heif, type: "public.heic" as CFString, properties: metadata) {
        result.append(RasterFixture(url: heif, label: "heif", oriented: true))
    } else {
        print("SKIP: HEIF system encoder unavailable")
    }
    return result
}
