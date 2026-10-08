import AppKit
import Foundation
import ImageIO

@main
struct ExportMetadataTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as! [CFString: Any]
    }

    static func decoded(_ url: URL) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    }

    static func pixels(_ url: URL) -> Data { decoded(url).dataProvider!.data! as Data }

    static func hasPNGEXIF(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        var offset = 8
        while offset + 12 <= data.count {
            let length = data[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= data.count - offset - 12 else { return false }
            if String(data: data[offset+4..<offset+8], encoding: .ascii) == "eXIf" { return true }
            offset += length + 12
        }
        return false
    }

    static func image(bits: Int = 8) -> CGImage {
        var bytes = Data()
        for i in 0..<18 {
            let value = UInt16((i * 3547 + 123) % 65536)
            if bits == 16 { bytes.append(UInt8(value & 255)); bytes.append(UInt8(value >> 8)) }
            else { bytes.append(UInt8(value >> 8)) }
        }
        return CGImage(width: 3, height: 2, bitsPerComponent: bits, bitsPerPixel: 3 * bits,
                       bytesPerRow: 9 * bits / 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: bits == 16 ? .byteOrder16Little : CGBitmapInfo(rawValue: 0),
                       provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func encode(_ image: CGImage, to url: URL, type: CFString,
                       properties: [CFString: Any] = [:]) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        check(CGImageDestinationFinalize(destination), "Create image fixture")
    }

    static func verifyCapture(_ values: [CFString: Any], orientation: UInt32, width: Int, height: Int) {
        let exif = values[kCGImagePropertyExifDictionary] as! [CFString: Any]
        let tiff = values[kCGImagePropertyTIFFDictionary] as! [CFString: Any]
        let gps = values[kCGImagePropertyGPSDictionary] as! [CFString: Any]
        check(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2021:03:04 05:06:07", "Original capture date is retained")
        check(abs((exif[kCGImagePropertyExifExposureTime] as! Double) - 0.008) < 1e-8,
              "Shutter speed is retained")
        check(exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] == [400] &&
              abs((exif[kCGImagePropertyExifFNumber] as! Double) - 2.8) < 1e-6, "ISO and aperture are retained")
        check(exif[kCGImagePropertyExifLensModel] as? String == "Fixture 50mm" &&
              tiff[kCGImagePropertyTIFFMake] as? String == "Fixture Camera", "Camera and lens are retained")
        check(abs((gps[kCGImagePropertyGPSLatitude] as! Double) - 12.3) < 1e-6 &&
              gps[kCGImagePropertyGPSLatitudeRef] as? String == "N", "GPS metadata is retained")
        check(values[kCGImagePropertyOrientation] as? UInt32 == orientation,
              "Orientation matches the exported pixel orientation")
        check(exif[kCGImagePropertyExifPixelXDimension] as? Int == width &&
              exif[kCGImagePropertyExifPixelYDimension] as? Int == height &&
              exif[kCGImagePropertyExifColorSpace] as? Int == 1, "EXIF dimensions and color space describe the output")
        check(exif[kCGImagePropertyExifMakerNote] == nil && exif[kCGImagePropertyExifCFAPattern] == nil,
              "Sensor-only data and opaque MakerNotes are not copied")
    }

    static func syntheticChecks(in output: URL) throws {
        let original = output.appendingPathComponent("original.jpg")
        let fixture: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fixture Camera", kCGImagePropertyTIFFModel: "Fixture Model"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2021:03:04 05:06:07",
                kCGImagePropertyExifExposureTime: 0.008, kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifLensModel: "Fixture 50mm"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 45.6, kCGImagePropertyGPSLongitudeRef: "E"]
        ]
        encode(image(), to: original, type: "public.jpeg" as CFString, properties: fixture)
        let originalBytes = try Data(contentsOf: original)
        for (suffix, type, bits) in [("jpg", "public.jpeg", 8), ("png", "public.png", 16)] {
            let destination = output.appendingPathComponent("metadata-copy.\(suffix)")
            encode(image(bits: bits), to: destination, type: type as CFString)
            let before = pixels(destination)
            try ExportMetadata.preserve(from: original, in: destination)
            verifyCapture(properties(destination), orientation: 1, width: 3, height: 2)
            check(pixels(destination) == before && decoded(destination).bitsPerComponent == bits,
                  "\(suffix) metadata attachment preserves decoded pixels and bit depth")
        }
        let jpeg = try ExportMetadata.jpegData(image: image(), sourceURL: original, orientation: .right, quality: 0.92)
        let jpegURL = output.appendingPathComponent("ios-encoder.jpg")
        try jpeg.write(to: jpegURL)
        verifyCapture(properties(jpegURL), orientation: 6, width: 3, height: 2)
        check(try Data(contentsOf: original) == originalBytes, "Source file is unchanged")
        do {
            try ExportMetadata.preserve(from: original, in: original)
            check(false, "Overwriting the metadata source must fail")
        } catch ExportMetadata.Failure.sameFile { print("PASS: Metadata source cannot be overwritten") }
        let plain = output.appendingPathComponent("no-exif.png")
        encode(image(), to: plain, type: "public.png" as CFString)
        let plainJPEG = try ExportMetadata.jpegData(image: image(), sourceURL: plain, orientation: .up, quality: 0.92)
        check(!plainJPEG.isEmpty, "Images without shooting EXIF can still be exported")
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try syntheticChecks(in: output)
        let raw = root.appendingPathComponent("lutools/examples/DSC06251.ARW")
        let original = properties(raw)
        let originalEXIF = original[kCGImagePropertyExifDictionary] as! [CFString: Any]
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let jpeg = output.appendingPathComponent("capture.jpg")
        _ = try engine.render(raw, settings: Adjustments(), lut: nil, edge: 400, output: jpeg)
        let exported = properties(jpeg)
        let exif = exported[kCGImagePropertyExifDictionary] as? [CFString: Any]
        check(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == originalEXIF[kCGImagePropertyExifDateTimeOriginal] as? String,
              "Mac JPEG export retains the actual RAW capture timestamp")
        check(exported[kCGImagePropertyOrientation] as? Int == 1, "RAW pixels are upright without double rotation")
        check(exif?[kCGImagePropertyExifPixelXDimension] as? Int == decoded(jpeg).width &&
              exif?[kCGImagePropertyExifPixelYDimension] as? Int == decoded(jpeg).height,
              "RAW export dimensions reflect crop, rotation and resize")
        let png = output.appendingPathComponent("capture.png")
        _ = try engine.render(raw, settings: Adjustments(), lut: nil, edge: 400, output: png)
        let pngEXIF = properties(png)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        check(decoded(png).bitsPerComponent == 16 &&
              pngEXIF?[kCGImagePropertyExifDateTimeOriginal] as? String == originalEXIF[kCGImagePropertyExifDateTimeOriginal] as? String,
              "Mac PNG exports preserve sixteen-bit pixels and RAW capture EXIF")
        check(try hasPNGEXIF(png), "Core-generated PNG contains actual eXIf, not only XMP projection")
    }
}
