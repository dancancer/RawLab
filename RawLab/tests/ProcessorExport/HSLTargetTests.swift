import Foundation

extension ProcessorExportTests {
    static func checkHSLTarget() throws {
        let width = 24, height = 16
        var data = Data(count: width * height * 4)
        for i in 0..<(width * height) {
            data[i * 4] = 204; data[i * 4 + 1] = 102; data[i * 4 + 2] = 51; data[i * 4 + 3] = 255
        }
        let buffer = Sony2FujiProcessor.Buffer(data: data, width: width, height: height, stride: width * 4,
            pixelFormat: SONY2FUJI_PIXEL_RGBA8, semantic: .display)
        let processor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF)
        let revision = HSLTargetRevision(source: 3, request: 17)
        func sample(_ settings: RawSettings, point: CGPoint = CGPoint(x: 0.5, y: 0.5)) throws -> HSLTargetSample {
            try processor.sampleHSL(url: nil, buffer: buffer, settings: settings, previewLongEdge: 24,
                lutURL: nil, interactive: false, revision: revision, point: point)
        }
        let original = try sample(.default)
        check(original.isUsable && original.revision == revision && abs(original.rgb[0] - 0.8) < 0.01,
            "iOS native probe binds revision and returns pre-HSL RGB with normalized weights")
        var downstream = RawSettings.default
        downstream.hsl.setExact(.hue, channel: 0, value: 80)
        downstream.gradingSettings.shadows = ColorGradingWheel(hue: 230, saturation: 70)
        let unchanged = try sample(downstream)
        check(original.rgb == unchanged.rgb && original.weights == unchanged.weights,
            "iOS HSL and grading do not feed back into sampling")
        var upstream = RawSettings.default; upstream.exposure = 0.5; upstream.vibrance = 60
        let changed = try sample(upstream)
        check(changed.rgb != original.rgb, "iOS target includes upstream tone and vibrance")
        let outside = try sample(.default, point: CGPoint(x: -Double.leastNonzeroMagnitude, y: 0.5))
        check(outside.availability == .outside && !outside.isUsable, "iOS rejects outside Double before Float conversion")
        let nonfinite = try sample(.default, point: CGPoint(x: Double.nan, y: 0.5))
        check(nonfinite.availability == .nonfinite && !nonfinite.isUsable, "iOS rejects nonfinite coordinates")
    }
}
