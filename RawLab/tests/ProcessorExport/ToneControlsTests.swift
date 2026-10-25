import Foundation

extension ProcessorExportTests {
    static func checkToneControls() throws {
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
        for controls in [ToneControlsSettings(blackPoint: 60), ToneControlsSettings(whitePoint: -60),
                         ToneControlsSettings(vibrance: 60), ToneControlsSettings(blackPoint: -32.75, whitePoint: 46.5, vibrance: 21.25)] {
            var settings = RawSettings.default; settings.toneControls = controls
            let changed = try processor.processBuffer(buffer: buffer, settings: settings, previewLongEdge: nil, lutURL: nil)
            check(changed.data != baseline.data, "Each iOS tone control reaches native display pixels")
            _ = try processor.processBuffer(buffer: buffer, settings: settings, previewLongEdge: 48, lutURL: nil, interactive: true)
            let final = try processor.processBuffer(buffer: buffer, settings: settings, previewLongEdge: nil, lutURL: nil)
            check(final.data == changed.data, "iOS FINAL tone values survive an interactive preview")
            let reset = try processor.processBuffer(buffer: buffer, settings: .default, previewLongEdge: nil, lutURL: nil)
            check(reset.data == baseline.data, "iOS zero tone clears the reused native session")
        }
    }
}
