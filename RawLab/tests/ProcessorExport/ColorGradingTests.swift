import Foundation

extension ProcessorExportTests {
    static func checkColorGrading() throws {
        let width = 96, height = 64
        var data = Data(count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let index = (y * width + x) * 4
            data[index] = UInt8(24 + x * 2); data[index + 1] = UInt8(16 + y * 3)
            data[index + 2] = UInt8(31 + x + y); data[index + 3] = 255
        } }
        let buffer = Sony2FujiProcessor.Buffer(data: data, width: width, height: height, stride: width * 4,
            pixelFormat: SONY2FUJI_PIXEL_RGBA8, semantic: .display)
        let processor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF)
        let baseline = try processor.processBuffer(buffer: buffer, settings: .default, previewLongEdge: nil, lutURL: nil)
        func grade(shadows: ColorGradingWheel = .init(), midtones: ColorGradingWheel = .init(), highlights: ColorGradingWheel = .init()) -> ColorGradingSettings {
            var value = ColorGradingSettings(); value.shadows = shadows; value.midtones = midtones; value.highlights = highlights
            return value
        }
        let grades = [grade(shadows: ColorGradingWheel(hue: 240, saturation: 80)),
                      grade(midtones: ColorGradingWheel(hue: 120, saturation: 80)),
                      grade(highlights: ColorGradingWheel(hue: 0, saturation: 80)),
                      grade(shadows: ColorGradingWheel(hue: 220, saturation: 35),
                                           midtones: ColorGradingWheel(hue: 110, saturation: 25),
                                           highlights: ColorGradingWheel(hue: 35, saturation: 45))]
        for controls in grades {
            var settings = RawSettings.default; settings.gradingSettings = controls
            let changed = try processor.processBuffer(buffer: buffer, settings: settings, previewLongEdge: nil, lutURL: nil)
            check(changed.data != baseline.data, "Each iOS grading zone reaches native display pixels")
            _ = try processor.processBuffer(buffer: buffer, settings: settings, previewLongEdge: 48, lutURL: nil, interactive: true)
            let final = try processor.processBuffer(buffer: buffer, settings: settings, previewLongEdge: nil, lutURL: nil)
            check(final.data == changed.data, "iOS FINAL grading values survive an interactive preview")
            let reset = try processor.processBuffer(buffer: buffer, settings: .default, previewLongEdge: nil, lutURL: nil)
            check(reset.data == baseline.data, "iOS zero grading clears the reused native session")
        }
        var pending = RawSettings.default
        pending.gradingSettings = grade(shadows: ColorGradingWheel(hue: 231.25, saturation: 0))
        let identity = try processor.processBuffer(buffer: buffer, settings: pending, previewLongEdge: nil, lutURL: nil)
        check(identity.data == baseline.data, "Pending iOS hue remains a pixel identity")
    }
}
