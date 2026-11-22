import RawLabKit
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

        var v2 = RawSettings.default
        v2.gradingSettings = ColorGradingSettings(
            shadows: ColorGradingWheel(hue: 220, saturation: 35, luminance: -35),
            midtones: ColorGradingWheel(hue: 110, saturation: 25, luminance: 20),
            highlights: ColorGradingWheel(hue: 35, saturation: 45, luminance: 45),
            global: ColorGradingWheel(hue: 310, saturation: 30, luminance: -15),
            blending: 75,
            balance: -30
        )
        let v2Rendered = try processor.processBuffer(buffer: buffer, settings: v2, previewLongEdge: nil, lutURL: nil)
        check(v2Rendered.data != baseline.data, "iOS Color Grading v2 reaches native display pixels")
    }

    static func checkRasterRelativeWB() throws {
        let width = 32, height = 32
        var data = Data(count: width * height * 4)
        for i in 0..<(width * height) {
            data[i * 4] = 175
            data[i * 4 + 1] = 145
            data[i * 4 + 2] = 115
            data[i * 4 + 3] = 255
        }
        let buffer = Sony2FujiProcessor.Buffer(data: data, width: width, height: height, stride: width * 4,
                                               pixelFormat: SONY2FUJI_PIXEL_RGBA8, semantic: .display)
        let processor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF)
        let neutral = try processor.processBuffer(buffer: buffer, settings: .default, previewLongEdge: nil, lutURL: nil)
        var edited = RawSettings.default
        edited.whiteBalanceMode = .camera
        edited.masterRecipeID = nil
        edited.temperature = 5400
        edited.tint = 12
        let baseReq = processor.makeBaseRequest(settings: edited, inputType: SONY2FUJI_INPUT_DISPLAY_BUFFER)
        check(baseReq.wb_mode == SONY2FUJI_WB_CAMERA && baseReq.temperature == 6500 && baseReq.tint == 0,
              "iOS makeBaseRequest keeps CAMERA 6500/0 on SDR raster relative WB")
        let shifted = try processor.processBuffer(buffer: buffer, settings: edited, previewLongEdge: nil, lutURL: nil)
        check(shifted.data != neutral.data, "iOS SDR raster relative WB renders shifted pixels")
        let ev = try processor.autoExposure(url: nil, buffer: buffer, settings: edited)
        check(ev.isFinite, "iOS SDR raster relative WB supports auto exposure")
        let probe = try processor.sampleWBProbe(url: nil, buffer: buffer, settings: edited, previewLongEdge: 32,
                                                lutURL: nil, interactive: false, point: CGPoint(x: 0.5, y: 0.5))
        check(probe.availability == SONY2FUJI_WB_PROBE_AVAILABLE, "iOS SDR raster relative WB supports WB probe")
    }
}
