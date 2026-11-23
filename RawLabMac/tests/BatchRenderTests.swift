import RawLabKit
import AppKit
import ImageIO

@main struct BatchRenderTests {
    static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-batch-render-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try OriginalFileIdentity(input)
        let journal = MacBatchJournal(directory: root.appendingPathComponent("journal"))
        var settings = Adjustments()
        settings.exposure = 0.5; settings.highlights = -0.25; settings.contrast = 1.20
        settings.setEffect(.vignetteAmount, to: -40)
        settings.setEffect(.vignetteMidpoint, to: 65)
        settings.setEffect(.grainAmount, to: 50)
        settings.setEffect(.grainSize, to: 60)
        if CommandLine.arguments.contains("--legacy") { settings.denoiseMode = 2 }
        else { settings.applyDenoisePreset(.clean); settings.setDenoiseParameter(.luma, to: 53) }
        let engine = try RenderEngine()
        var unsharpenedPixels: Data?
        for sharpening in [OutputSharpening.off, .standard] {
        for png in [false, true] {
            for longEdge: Int? in [nil, 2048] {
            let single = root.appendingPathComponent(png ? "single-\(sharpening.rawValue).png" : "single-\(sharpening.rawValue).jpg")
            _ = try engine.render(input, settings: settings, lut: nil, edge: nil, output: single, exportLongEdge: longEdge, outputSharpening: sharpening)
            var job = MacBatchExportJob(source: input, settings: settings, look: nil, lookName: "Neutral")
            job.outputDirectory = root; job.png = png; job.longEdge = longEdge; job.outputSharpening = sharpening == .off ? nil : sharpening
            var item = try MacBatchExportItem(url: input); item.selected = true
            job.items = [item]
            let model = BatchExportModel(job: job, journal: journal)
            model.start()
            let deadline = Date().addingTimeInterval(120)
            while model.running && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard !model.running, model.job.succeededCount == 1, let output = model.job.items[0].output else {
                throw RenderError.failed(model.error ?? model.job.items[0].error ?? "Batch render timed out")
            }
            let a = CGImageSourceCreateWithURL(single as CFURL, nil)!
            let b = CGImageSourceCreateWithURL(output as CFURL, nil)!
            let first = CGImageSourceCreateImageAtIndex(a, 0, nil)!
            let second = CGImageSourceCreateImageAtIndex(b, 0, nil)!
            guard first.width == second.width, first.height == second.height,
                  first.dataProvider!.data! as Data == second.dataProvider!.data! as Data else {
                throw RenderError.failed("Single and batch pixels differ")
            }
            if png && longEdge == 2048 {
                if sharpening == .off {
                    unsharpenedPixels = first.dataProvider!.data! as Data
                } else if let baseline = unsharpenedPixels {
                    guard (first.dataProvider!.data! as Data) != baseline else {
                        throw RenderError.failed("Output sharpening did not alter exported pixels")
                    }
                }
            }
            if let longEdge, max(first.width, first.height) != longEdge {
                throw RenderError.failed("Batch output ignored its frozen long-edge size")
            }
            if png && first.bitsPerComponent != 16 { throw RenderError.failed("Sized PNG lost sixteen-bit channels") }
            guard try OriginalFileIdentity(input) == original else { throw RenderError.failed("Original RAW changed") }
            print("PASS: \(input.lastPathComponent) \(png ? "16-bit PNG" : "JPEG") (\(sharpening.rawValue)) single/batch pixels, \(first.width)x\(first.height), original unchanged")
            }
        }
        }
    }
}
