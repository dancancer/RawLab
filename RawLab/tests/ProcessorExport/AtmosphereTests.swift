import Foundation

extension ProcessorExportTests {
    static func checkAtmosphere() throws {
        let width = 320, height = 192
        var data = Data(count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let index = (y * width + x) * 4, wave = Int(25 * sin(Double(x) * .pi / 16))
            data[index] = UInt8(80 + x / 4 + wave); data[index + 1] = UInt8(60 + y / 2 + wave)
            data[index + 2] = UInt8(65 + x / 8 + y / 4 + wave); data[index + 3] = 255
        } }
        let buffer = Sony2FujiProcessor.Buffer(data: data, width: width, height: height, stride: width * 4,
            pixelFormat: SONY2FUJI_PIXEL_RGBA8, semantic: .display)
        let processor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF)
        let baseline = try processor.processBuffer(buffer: buffer, settings: .default, previewLongEdge: nil, lutURL: nil)
        for atmosphere in [AtmosphereSettings(clarity: 75), AtmosphereSettings(clarity: -75),
                           AtmosphereSettings(dehaze: 75), AtmosphereSettings(dehaze: -75),
                           AtmosphereSettings(clarity: 37.251234, dehaze: -42.5)] {
            var settings = RawSettings.default; settings.atmosphere = atmosphere
            let config = atmosphere.nativeConfig
            check(config.version == 1 && config.struct_size == 16, "iOS atmosphere adapter uses the versioned 16-byte ABI")
            let changed = try processor.processBuffer(buffer: buffer, settings: settings, previewLongEdge: nil, lutURL: nil)
            check(changed.data != baseline.data, "Each signed iOS atmosphere control reaches native pixels")
            _ = try processor.processBuffer(buffer: buffer, settings: settings, previewLongEdge: 73, lutURL: nil, interactive: true)
            let final = try processor.processBuffer(buffer: buffer, settings: settings, previewLongEdge: nil, lutURL: nil)
            check(final.data == changed.data, "iOS FINAL atmosphere survives interactive previews")
            let auto = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_AUTO)
            let autoResult = try auto.processBuffer(buffer: buffer, settings: settings, previewLongEdge: nil, lutURL: nil)
            check(autoResult.data == changed.data, "iOS Auto atmosphere matches CPU")
            let reset = try processor.processBuffer(buffer: buffer, settings: .default, previewLongEdge: nil, lutURL: nil)
            check(reset.data == baseline.data, "iOS zero atmosphere clears reused session state")
        }
    }
}
