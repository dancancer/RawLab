import Foundation

@main struct RenderedDNGExportTests {
    static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let lut = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : nil
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let original = try OriginalFileIdentity(input)
        let longEdges: [Int?]
        if let value = ProcessInfo.processInfo.environment["RAWLAB_DNG_TEST_LONG_EDGE"] {
            guard let edge = Int(value), (1...65535).contains(edge) else {
                throw RenderError.failed("Invalid RAWLAB_DNG_TEST_LONG_EDGE")
            }
            longEdges = [edge]
        } else {
            longEdges = [nil, 1536]
        }
        var settings = Adjustments()
        settings.exposure = 0.35
        settings.whiteBalanceMode = .custom
        settings.temperature = 5400; settings.tint = 12
        settings.strength = 0.7
        settings.contrast = 17; settings.highlights = -15; settings.shadows = 20
        settings.toneCurve = 12; settings.saturation = 8; settings.sharpening = 25
        settings.setHSL(.hue, channel: 1, value: 12)
        settings.setHSL(.saturation, channel: 5, value: -20)
        settings.setEffect(.vignetteAmount, to: -35)
        settings.setEffect(.grainAmount, to: 25)
        settings.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 25, chroma: 46, coarse: 50)
        try JSONEncoder().encode(settings).write(to: output.appendingPathComponent("settings.json"))

        for (name, mode) in [("cpu", SONY2FUJI_GPU_OFF), ("metal", SONY2FUJI_GPU_AUTO)] {
            let engine = try RenderEngine(gpuMode: mode)
            for longEdge in longEdges {
                let label = name + (longEdge.map { "-\($0)" } ?? "-native")
                let png = output.appendingPathComponent(label + ".png")
                let dng = output.appendingPathComponent(label + ".dng")
                _ = try engine.render(input, settings: settings, lut: lut, edge: nil,
                                      output: png, exportLongEdge: longEdge)
                _ = try engine.render(input, settings: settings, lut: lut, edge: nil,
                                      output: dng, exportLongEdge: longEdge)
                if mode == SONY2FUJI_GPU_AUTO, engine.lastBackend != SONY2FUJI_BACKEND_METAL {
                    throw RenderError.failed("DNG export did not execute Metal")
                }
                var job = BatchExportJob(source: input, settings: settings, look: lut, lookName: label)
                job.format = .renderedDNG; job.outputDirectory = output; job.longEdge = longEdge
                var item = try BatchExportItem(url: input); item.selected = true; job.items = [item]
                let journal = BatchJournal(directory: output.appendingPathComponent(label + "-journal"))
                try BatchExportRunner.run(job: &job, journal: journal, scope: .unfinished,
                                         shouldCancel: { false }) { source, frozen, look, destination in
                    _ = try engine.render(source, settings: frozen, lut: look, edge: nil,
                                          output: destination, exportLongEdge: longEdge)
                }
                guard job.succeededCount == 1, let batch = job.items[0].output,
                      try Data(contentsOf: dng) == Data(contentsOf: batch) else {
                    throw RenderError.failed("Single and batch DNG differ")
                }
                guard try OriginalFileIdentity(input) == original else {
                    throw RenderError.failed("Original RAW changed")
                }
                print("PASS: \(label), nonzero adjustments, single/batch exact DNG match, original unchanged")
            }
        }
    }
}
