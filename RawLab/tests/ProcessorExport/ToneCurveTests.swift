import RawLabKit
import Foundation

extension ProcessorExportTests {
    static func checkToneCurve() throws {
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
        func render(_ settings: RawSettings) throws -> Data {
            try processor.processBuffer(buffer: buffer, settings: settings, previewLongEdge: nil, lutURL: nil).data
        }
        let baseline = try render(.default)
        var settings = RawSettings.default; settings.toneCurve = 0.65
        let legacy = try render(settings)
        check(legacy != baseline, "iOS legacy S curve remains effective")
        settings.curveSettings = .identity
        check(try render(settings) == baseline, "iOS identity bypasses inactive legacy scalar exactly")
        settings.curveSettings = .identity.inserting(x: 0.25, y: 0.4).inserting(x: 0.75, y: 0.9)
        let changed = try render(settings)
        check(changed != baseline && changed != legacy, "iOS custom curve reaches native pixels")
        let sample = try processor.sampleHSL(url: nil, buffer: buffer, settings: settings, previewLongEdge: CGFloat(width),
            lutURL: nil, interactive: false, revision: .init(source: 1, request: 1), point: .zero)
        let curve = settings.curveSettings.sampledPoints(count: 256)
        check(curve.count == 256 && sample.isUsable, "iOS native sampler and pre-HSL probe succeed")
        for (channel, input) in [24, 16, 31].enumerated() {
            check(abs(sample.rgb[channel] - curve[input].y) < 0.00001, "iOS canvas evaluator agrees with native pixels")
        }
        _ = try processor.processBuffer(buffer: buffer, settings: settings, previewLongEdge: 48, lutURL: nil, interactive: true)
        check(try render(settings) == changed, "iOS FINAL curve survives interactive preview")
        settings.curveSettings = ToneCurveSettings()
        check(try render(settings) == legacy, "iOS legacy clears reused custom session")
        check(try render(.default) == baseline, "iOS reset clears curve state")

        var v2 = RawSettings.default
        v2.curveSettings = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0, y: 0.1), .init(x: 0.5, y: 0.55), .init(x: 1, y: 0.9)],
            channels: ToneCurveChannels(red: ToneCurveShape(mode: .custom, points: [.init(x: 0, y: 0.05), .init(x: 1, y: 0.95)])),
            applyToLuminosity: false,
            parametric: ToneCurveParametric(highlights: -10, lights: 15, darks: -5, shadows: 20, splitShadow: 0.2, splitMidtone: 0.5, splitHighlight: 0.8)
        )
        let rgbSamples = v2.curveSettings.sampledPoints(channel: .rgb, count: 256)
        let redSamples = v2.curveSettings.sampledPoints(channel: .red, count: 256)
        check(abs(rgbSamples[0].y - 0.1) < 1e-5 && abs(rgbSamples[255].y - 0.9) < 1e-5,
            "iOS v2 RGB sampling reflects unpinned matte-fade endpoints")
        check(abs(redSamples[0].y - 0.05) < 1e-5 && abs(redSamples[255].y - 0.95) < 1e-5,
            "iOS v2 Red channel sampling reflects red unpinned endpoints without parametric")
        let v2Rgb = try render(v2)
        v2.curveSettings.applyToLuminosity = true
        let v2Lum = try render(v2)
        check(v2Rgb != v2Lum, "iOS applyToLuminosity produces distinct chrominance-preserving render")
    }
}
