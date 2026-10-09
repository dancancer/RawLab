import Foundation
import ImageIO
import UIKit

@main
struct ProcessorExportTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as! [CFString: Any]
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let processor = Sony2FujiProcessor()
        var random: UInt32 = 8171
        var noisy = Data(count: 256 * 256 * 4)
        for i in 0..<(256 * 256) {
            for c in 0..<3 {
                random = random &* 1664525 &+ 1013904223
                noisy[i * 4 + c] = UInt8(108 + Int(random >> 24) % 40)
            }
            noisy[i * 4 + 3] = 255
        }
        let noiseBuffer = Sony2FujiProcessor.Buffer(data: noisy, width: 256, height: 256, stride: 1024,
                                                   pixelFormat: SONY2FUJI_PIXEL_RGBA8)
        let noiseOff = try processor.processBuffer(buffer: noiseBuffer, settings: .default, previewLongEdge: 128, lutURL: nil)
        var denoised = RawSettings.default
        denoised.denoise.apply(.clean)
        let noiseOn = try processor.processBuffer(buffer: noiseBuffer, settings: denoised, previewLongEdge: 128, lutURL: nil)
        check(noiseOff.data != noiseOn.data, "iOS settings reach native wavelet processing")
        let noiseProxy = try processor.processBuffer(buffer: noiseBuffer, settings: denoised, previewLongEdge: 96, lutURL: nil, interactive: true)
        let noiseExact = try processor.processBuffer(buffer: noiseBuffer, settings: denoised, previewLongEdge: 128, lutURL: nil)
        check(noiseExact.data == noiseOn.data, "iOS interactive approximation never changes exact output")
        denoised.denoise.enabled = false
        check(try processor.processBuffer(buffer: noiseBuffer, settings: denoised, previewLongEdge: 128, lutURL: nil).data == noiseOff.data,
              "iOS disabling denoise restores the original output")
        let scroll = PhotoScrollView()
        scroll.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        scroll.pixels = CGSize(width: 2400, height: 1600)
        scroll.displayScale = 2
        scroll.imageView.image = UIImage(cgImage: processor.makeCGImage(from: noiseOff)!)
        scroll.layoutIfNeeded()
        scroll.setZoomScale(1, animated: false)
        scroll.setContentOffset(CGPoint(x: 100, y: 80), animated: false)
        let originalOffset = scroll.contentOffset
        for frame in [noiseProxy, noiseExact] {
            scroll.imageView.image = UIImage(cgImage: processor.makeCGImage(from: frame)!)
            scroll.setNeedsLayout()
            scroll.layoutIfNeeded()
            check(scroll.zoomScale == 1 && scroll.contentOffset == originalOffset,
                  "iOS denoise frame replacement preserves native zoom and pan")
        }
        let bytes = Data([45, 110, 180, 255, 170, 110, 60, 255, 85, 145, 75, 255,
                          80, 70, 65, 255, 180, 185, 190, 255, 210, 65, 115, 255])
        let buffer = Sony2FujiProcessor.Buffer(data: bytes, width: 3, height: 2, stride: 12,
                                              pixelFormat: SONY2FUJI_PIXEL_RGBA8)
        let original = output.appendingPathComponent("source.jpg")
        let destination = CGImageDestinationCreateWithURL(original as CFURL, "public.jpeg" as CFString, 1, nil)!
        let originalProperties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fixture Camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2021:03:04 05:06:07",
                kCGImagePropertyExifExposureTime: 0.008, kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifLensModel: "Fixture 50mm"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 45.6, kCGImagePropertyGPSLongitudeRef: "E"]
        ]
        CGImageDestinationAddImage(destination, processor.makeCGImage(from: buffer)!, originalProperties as CFDictionary)
        check(CGImageDestinationFinalize(destination), "Create simulator metadata fixture")
        let lut = root.appendingPathComponent("lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube")
        let normal = try processor.processBuffer(buffer: buffer, settings: .default, previewLongEdge: nil, lutURL: lut)
        var stronger = RawSettings.default
        stronger.lutStrength = 2
        let doubled = try processor.processBuffer(buffer: buffer, settings: stronger, previewLongEdge: nil, lutURL: lut)
        check(normal.data != doubled.data, "iOS buffer processing actually renders 200 percent differently from 100")
        let jpeg = try processor.makeJPEGData(from: doubled, sourceURL: original, orientation: .right, quality: 0.92)
        let fields = properties(jpeg)
        let exif = fields[kCGImagePropertyExifDictionary] as! [CFString: Any]
        let gps = fields[kCGImagePropertyGPSDictionary] as! [CFString: Any]
        check(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2021:03:04 05:06:07" &&
              abs((exif[kCGImagePropertyExifExposureTime] as! Double) - 0.008) < 1e-8 &&
              exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] == [400], "iOS JPEG retains date, shutter and ISO")
        check(exif[kCGImagePropertyExifLensModel] as? String == "Fixture 50mm" &&
              abs((gps[kCGImagePropertyGPSLatitude] as! Double) - 12.3) < 1e-6, "iOS JPEG retains lens and GPS")
        check(fields[kCGImagePropertyOrientation] as? Int == 6 &&
              exif[kCGImagePropertyExifPixelXDimension] as? Int == 3 &&
              exif[kCGImagePropertyExifPixelYDimension] as? Int == 2,
              "Raster export keeps the orientation of unrotated buffer pixels")
        try jpeg.write(to: output.appendingPathComponent("ios-raster-exif.jpg"))
        let raw = root.appendingPathComponent("lutools/examples/DSC06251.ARW")
        let standardRaw = try processor.processRaw(url: raw, settings: .default, previewLongEdge: 128, lutURL: lut)
        let strongRaw = try processor.processRaw(url: raw, settings: stronger, previewLongEdge: 128, lutURL: lut)
        check(standardRaw.buffer.data != strongRaw.buffer.data, "iOS RAW processing also passes through 200 percent")
        let rawJPEG = try processor.makeJPEGData(from: strongRaw.buffer, sourceURL: raw,
                                                orientation: strongRaw.orientation, quality: 0.92)
        let rawFields = properties(rawJPEG)
        let rawEXIF = rawFields[kCGImagePropertyExifDictionary] as! [CFString: Any]
        let originalRaw = CGImageSourceCreateWithURL(raw as CFURL, nil)!
        let rawSourceFields = CGImageSourceCopyPropertiesAtIndex(originalRaw, 0, nil)! as! [CFString: Any]
        let sourceEXIF = rawSourceFields[kCGImagePropertyExifDictionary] as! [CFString: Any]
        check(rawEXIF[kCGImagePropertyExifDateTimeOriginal] as? String == sourceEXIF[kCGImagePropertyExifDateTimeOriginal] as? String,
              "Actual iOS RAW export retains its source capture date")
        check(rawFields[kCGImagePropertyOrientation] as? Int == 1 &&
              rawEXIF[kCGImagePropertyExifPixelXDimension] as? Int == strongRaw.buffer.width &&
              rawEXIF[kCGImagePropertyExifPixelYDimension] as? Int == strongRaw.buffer.height,
              "iOS RAW export is upright and reports rendered dimensions")
        try rawJPEG.write(to: output.appendingPathComponent("ios-raw-exif.jpg"))
    }
}
