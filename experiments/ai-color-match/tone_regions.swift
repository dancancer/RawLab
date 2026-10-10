import AppKit
import ImageIO
import UniformTypeIdentifiers

private struct Sample: Codable {
    let name: String
    let raw: String
    let regions: AIToneRegions
}
private struct Record: Codable {
    let sample: Sample
    let recipe: AIColorRecipe
    let fixed: AIColorLook.Report
    let manual: AIColorLook.Report
    let settings: Adjustments
}

@main struct ToneRegionExperiment {
    static func main() throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: tone_regions CONFIG.json NEW_OUTPUT_DIRECTORY") }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw RenderError.failed("Output directory already exists") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var style = AIColorRecipe.identity(name: "Tone region study", summary: "Fixed synthetic style; manual boundaries, not learned labels")
        style.chroma = 0.85
        style.toning = [.init(a: -0.006, b: -0.009), .init(a: 0.002, b: 0.003), .init(a: 0.001, b: 0.007)]
        let fixed = try AIColorLook.compile(recipe: style, model: "local-experiment-no-ai")
        try FileManager.default.copyItem(at: fixed.url, to: output.appendingPathComponent("fixed.cube"))
        let engine = try RenderEngine()
        let settings = Adjustments().aiBaseline
        var comparisons: [CGImage] = []
        for sample in samples {
            try autoreleasepool {
                let raw = URL(fileURLWithPath: sample.raw)
                let original = try OriginalFileIdentity(raw)
                let manual = try AIColorLook.compile(recipe: style, model: "local-experiment-no-ai", regions: sample.regions)
                let directory = output.appendingPathComponent(sample.name, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try FileManager.default.copyItem(at: manual.url, to: directory.appendingPathComponent("manual.cube"))
                var images: [CGImage] = []
                for (name, look) in [("neutral", nil), ("fixed", Optional(fixed.url)), ("manual", Optional(manual.url))] {
                    guard let frame = try engine.render(raw, settings: settings, lut: look, edge: 1200, interactive: false) else {
                        throw RenderError.failed("Missing render")
                    }
                    images.append(frame.image)
                    try write(frame.image, to: directory.appendingPathComponent(name+".jpg"))
                }
                let board = try comparison(images, title: sample.name)
                try write(board, to: directory.appendingPathComponent("comparison.jpg"))
                comparisons.append(board)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(Record(sample: sample, recipe: style, fixed: fixed.report, manual: manual.report, settings: settings))
                    .write(to: directory.appendingPathComponent("record.json"))
                guard try OriginalFileIdentity(raw) == original else { throw RenderError.failed("Source RAW changed") }
                print("PASS \(sample.name): fixed=\(fixed.report.maxError), manual=\(manual.report.maxError), grid=\(manual.report.gridSize)")
            }
        }
        let context = CGContext(data: nil, width: 1500, height: comparisons.count*410, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for (index, image) in comparisons.enumerated() {
            context.draw(image, in: CGRect(x: 0, y: (comparisons.count-1-index)*410, width: 1500, height: 410))
        }
        try write(context.makeImage()!, to: output.appendingPathComponent("overview.jpg"))
    }

    private static func comparison(_ images: [CGImage], title: String) throws -> CGImage {
        let context = CGContext(data: nil, width: 1500, height: 410, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1500, height: 410))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        for (index, image) in images.enumerated() {
            let scale = min(484.0/Double(image.width), 365.0/Double(image.height))
            let width = Double(image.width)*scale, height = Double(image.height)*scale
            context.draw(image, in: CGRect(x: Double(index*500)+(500-width)/2, y: (365-height)/2+6, width: width, height: height))
            let name = ["Neutral", "Fixed regions", "Manual regions"][index]
            (title+" | "+name).draw(at: NSPoint(x: index*500+12, y: 382),
                withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white])
        }
        return context.makeImage()!
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RenderError.failed("Cannot create JPEG")
        }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw RenderError.failed("Cannot write JPEG") }
    }
}
