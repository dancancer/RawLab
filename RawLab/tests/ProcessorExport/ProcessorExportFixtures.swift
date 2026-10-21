import Foundation
import ImageIO
import UIKit

extension ProcessorExportTests {
    static func checkProcessorErrorMapping(_ processor: Sony2FujiProcessor) {
        let cases: [(sony2fuji_status, String)] = [
            (SONY2FUJI_STATUS_UNSUPPORTED, "不支持此照片、外观或处理方式。请检查文件兼容性和处理设置。"),
            (SONY2FUJI_STATUS_IO_ERROR, "无法读取或写入文件，请检查路径和访问权限。"),
            (SONY2FUJI_STATUS_INVALID_ARGUMENT, "参数或输出路径无效。"),
            (SONY2FUJI_STATUS_OUTPUT_IO_ERROR, "无法写入成片，请检查输出位置和剩余空间。"),
            (SONY2FUJI_STATUS_PROCESSING_ERROR, "处理失败：processing error")
        ]
        for (status, expected) in cases {
            check(processor.processingFailure(status).localizedDescription == expected,
                  "process status \(status) has one accurate localized message and preserves its detail")
        }
        if case .processFailed(let message) = processor.processingFailure(SONY2FUJI_STATUS_PROCESSING_ERROR) {
            check(message == "processing error", "generic process failure keeps the native associated value")
        } else { check(false, "generic process failure keeps its existing enum contract") }
        for (status, expected) in [
            (SONY2FUJI_STATUS_UNSUPPORTED, "普通图像仅支持不透明的 8-bit SDR JPEG、PNG、TIFF 或 HEIF。"),
            (SONY2FUJI_STATUS_IO_ERROR, "无法读取照片，请检查文件和访问权限。"),
            (SONY2FUJI_STATUS_OUT_OF_MEMORY, "内存不足，无法解码普通图片。"),
            (SONY2FUJI_STATUS_PROCESSING_ERROR, "无法解码普通图片：processing error")
        ] {
            check(processor.displayImageFailure(status).localizedDescription == expected,
                  "decoder status \(status) distinguishes format, access, memory and processing failures")
        }
    }

    static func checkOriginalProtection(_ processor: Sony2FujiProcessor, raw: URL, output: URL) throws {
        let owned = output.appendingPathComponent("protection-source.\(raw.pathExtension)")
        try FileManager.default.copyItem(at: raw, to: owned)
        let alias = output.appendingPathComponent("protection-alias.\(raw.pathExtension)")
        try FileManager.default.linkItem(at: owned, to: alias)
        let original = try Data(contentsOf: owned)
        for destination in [owned, alias] {
            do {
                try processor.exportDNG(url: owned, settings: .default, lutURL: nil, outputURL: destination, exportLongEdge: 64)
                check(false, "same-path and hard-link output cannot overwrite an original")
            } catch let error as Sony2FujiProcessor.ProcessorError {
                check(error.localizedDescription == "不能覆盖原始文件。", "source aliases have the dedicated protection message")
            }
            check(try Data(contentsOf: owned) == original, "rejected source aliases leave original bytes unchanged")
        }
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
        fflush(stdout)
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as! [CFString: Any]
    }

    static func maximumDifference(_ first: Data, _ second: Data) -> Int {
        guard first.count == second.count else { return Int.max }
        return zip(first, second).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    static func visibleRGBA(_ image: CGImage) -> Data {
        var pixels = Data(count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue)!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
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
}
