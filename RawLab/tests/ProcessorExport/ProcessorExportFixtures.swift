import Foundation
import ImageIO
import UIKit

extension ProcessorExportTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as! [CFString: Any]
    }

    static func maximumDifference(_ first: Data, _ second: Data) -> Int {
        guard first.count == second.count else { return Int.max }
        return zip(first, second).map { abs(Int($0) - Int($1)) }.max() ?? 0
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
