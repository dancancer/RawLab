import Foundation
import ImageIO
import UIKit

@main
struct DisplayLensTests {
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "DisplayLensTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS: \(message)")
    }
    static func main() throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let source = output.appendingPathComponent("lens-oriented.jpg")
        let blank = output.appendingPathComponent("lens-blank.jpg")
        let bytes = Data((0..<(96 * 64 * 4)).map { offset -> UInt8 in
            let pixel = offset / 4, channel = offset % 4
            switch channel {
            case 0: return UInt8(pixel % 96 * 255 / 95)
            case 1: return UInt8(pixel / 96 * 255 / 63)
            case 2: return pixel % 12 < 6 ? 50 : 200
            default: return 255
            }
        })
        let provider = CGDataProvider(data: bytes as CFData)!
        let image = CGImage(width: 96, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 384,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        func write(_ url: URL, metadata: Bool) throws {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
            var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1]
            if metadata {
                properties[kCGImagePropertyOrientation] = 6
                properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "RawLab", kCGImagePropertyTIFFModel: "Test Camera"]
                properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifLensModel: "Test 24mm f/2.8", kCGImagePropertyExifFocalLength: 24, kCGImagePropertyExifFNumber: 2.8]
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            try require(CGImageDestinationFinalize(destination), "JPEG fixture is written")
        }
        try write(source, metadata: true); try write(blank, metadata: false)
        let processor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF,
            lensDatabaseURL: root.appendingPathComponent("lutools/tests/fixtures"))
        let input = try processor.loadRasterBuffer(url: source).buffer
        try require(input.width == 64 && input.height == 96 && input.sourceLensMetadata?.orientation == 6,
                    "EXIF orientation is applied once and retained as lens coordinates")
        try require(input.sourceLensMetadata?.focalLength == 24, "Structured EXIF focal length is read")
        let off = try processor.processBuffer(buffer: input, settings: .default, previewLongEdge: 96, lutURL: nil)
        func rgb(_ buffer: Sony2FujiProcessor.Buffer) -> Data {
            let channels = buffer.pixelFormat == SONY2FUJI_PIXEL_RGBA8 ? 4 : 3
            var pixels = Data()
            for y in 0..<buffer.height { for x in 0..<buffer.width {
                let offset = y * buffer.stride + x * channels
                pixels.append(buffer.data[offset..<(offset + 3)])
            } }
            return pixels
        }
        try require(off.width == input.width && off.height == input.height && rgb(off) == rgb(input),
                    "Disabled correction preserves every RGB pixel")
        var vignette = RawSettings.default
        vignette.lensCorrection = LensCorrectionSettings(vignetting: true)
        let correctedVignette = try processor.processBuffer(buffer: input, settings: vignette, previewLongEdge: nil, lutURL: nil)
        try require(correctedVignette.lensInfo?.appliedVignetting == true && correctedVignette.data != off.data,
                    "Vignetting reaches the native display pixels and report")
        let restoredVignette = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(vignette))
        try require(restoredVignette.lensSettings.vignetting,
                    "Vignetting survives photo settings persistence")
        var settings = RawSettings.default
        settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true)
        let preview = try processor.processBuffer(buffer: input, settings: settings, previewLongEdge: 96, lutURL: nil)
        let final = try processor.processBuffer(buffer: input, settings: settings, previewLongEdge: nil, lutURL: nil)
        try require(preview.lensInfo?.appliedDistortion == true && preview.data != off.data, "JPEG calibration changes actual pixels")
        try require(preview.data == final.data, "Preview and final rendering agree")
        try require(final.sourceLensMetadata == nil && input.withSemantic(.legacy).sourceLensMetadata == nil,
                    "Rendered and legacy buffers cannot inherit source correction metadata")
        let dngOn = output.appendingPathComponent("lens-on.dng"), dngOff = output.appendingPathComponent("lens-off.dng")
        try processor.exportDNG(buffer: input, settings: settings, lutURL: nil, outputURL: dngOn)
        try processor.exportDNG(buffer: input, settings: .default, lutURL: nil, outputURL: dngOff)
        try require(try Data(contentsOf: dngOn) != Data(contentsOf: dngOff), "Raster DNG export includes lens correction")
        let other = try processor.loadRasterBuffer(url: blank).buffer
        let missing = try processor.processBuffer(buffer: other, settings: settings, previewLongEdge: 96, lutURL: nil)
        try require(missing.lensInfo?.appliedDistortion == false && other.sourceLensMetadata?.focalLength == 0,
                    "A new source cannot inherit the previous photo metadata")
        let candidate = off.lensInfo!.candidates.first { $0.model == "Test 24mm f/2.8" }!
        settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, mode: .manual,
            profileID: candidate.id, focalLength: 24, cropFactor: 1)
        let manual = try processor.processBuffer(buffer: other, settings: settings, previewLongEdge: nil, lutURL: nil)
        try require(manual.lensInfo?.appliedDistortion == true, "Manual focal and crop overrides enable valid calibration")
        let decoded = try JSONDecoder().decode(LensCorrectionSettings.self, from: JSONEncoder().encode(settings.lensSettings))
        try require(decoded == settings.lensSettings, "Manual metadata survives photo-setting serialization")
        let noDatabase = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: output.appendingPathComponent("missing"))
        _ = try noDatabase.processBuffer(buffer: input, settings: .default, previewLongEdge: 64, lutURL: nil)
        print("PASS: missing database does not block neutral display rendering")
    }
}
