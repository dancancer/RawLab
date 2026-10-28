import Foundation

extension ProcessorExportTests {
    static func checkRGBHistogram() {
        let pixels: [[UInt8]] = [[0, 0, 0], [255, 255, 255], [255, 0, 0],
                                 [255, 0, 0], [0, 255, 0], [64, 128, 192]]
        var expected = [UInt32](repeating: 0, count: 768)
        expected[0] = 2; expected[64] = 1; expected[255] = 3
        expected[256] = 3; expected[256 + 128] = 1; expected[256 + 255] = 2
        expected[512] = 4; expected[512 + 192] = 1; expected[512 + 255] = 1
        // 照片即使选择 Force，CPU 上的显示统计也不依赖 Metal。
        let processor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_FORCE)
        for channels in [3, 4] {
            let stride = 3 * channels + 4
            var bytes = Data(repeating: 93, count: stride * 2)
            for index in pixels.indices {
                let start = (index / 3) * stride + (index % 3) * channels
                for channel in 0..<3 { bytes[start + channel] = pixels[index][channel] }
                if channels == 4 { bytes[start + 3] = UInt8(index * 40) }
            }
            let buffer = Sony2FujiProcessor.Buffer(data: bytes, width: 3, height: 2, stride: stride,
                pixelFormat: channels == 4 ? SONY2FUJI_PIXEL_RGBA8 : SONY2FUJI_PIXEL_RGB8, semantic: .display)
            let histogram = processor.computeRGBHistogram(from: buffer)
            check(histogram?.counts == expected, "RGB\(channels * 8) counts match all 768 bins; alpha and row padding are ignored")
            check(histogram?.width == 3 && histogram?.height == 2 && histogram?.peak == 4,
                  "RGB histogram carries actual frame dimensions and one shared channel peak")
            check(histogram?.segments(at: 0) == [.init(lower: 0, upper: 0.5, channels: 7),
                .init(lower: 0.5, upper: 0.75, channels: 6), .init(lower: 0.75, upper: 1, channels: 4)],
                "RGB overlap uses shared heights and additive gray/cyan/blue segments")
            check(histogram?.segments(at: 255) == [.init(lower: 0, upper: 0.25, channels: 7),
                .init(lower: 0.25, upper: 0.5, channels: 3), .init(lower: 0.5, upper: 0.75, channels: 1)],
                "weaker channels keep their relative heights instead of independent normalization")
            for channel in 0..<3 {
                check(histogram?.counts[(channel * 256)..<((channel + 1) * 256)].reduce(UInt64(0), { $0 + UInt64($1) }) == 6,
                      "RGB channel \(channel) counts every pixel exactly once")
            }
        }
        let invalid = Sony2FujiProcessor.Buffer(data: Data([0, 0, 0, 255]), width: 2, height: 1,
            stride: 8, pixelFormat: SONY2FUJI_PIXEL_RGBA8, semantic: .display)
        check(processor.computeRGBHistogram(from: invalid) == nil,
              "truncated frame reports unavailable statistics without throwing or inventing bins")
        let negative = Sony2FujiProcessor.Buffer(data: Data([0]), width: -1, height: 1,
            stride: 4, pixelFormat: SONY2FUJI_PIXEL_RGBA8)
        check(processor.computeRGBHistogram(from: negative) == nil, "invalid dimensions do not trap in the Swift bridge")
        check(Sony2FujiProcessor.RGBHistogram(width: 3, height: 2, counts: Array(expected.dropLast())) == nil,
              "incomplete RGB payload is rejected")
        check(Sony2FujiProcessor.RGBHistogram(width: 3, height: 3, counts: expected) == nil,
              "payload cannot claim dimensions from a different frame")
        var large = [UInt32](repeating: 0, count: 768)
        for channel in 0..<3 { large[channel * 256] = UInt32.max }
        check(Sony2FujiProcessor.RGBHistogram(width: Int(UInt32.max), height: 1, counts: large)?.peak == UInt32.max,
              "RGB payload preserves unsigned counts without signed narrowing")
        check(Sony2FujiProcessor.RGBHistogram(width: Int.max, height: 2, counts: large) == nil,
              "oversized dimensions cannot overflow pixel-count validation")
    }
}
