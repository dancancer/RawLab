import AppKit

@main struct AILiveTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["DEEPSEEK_API_KEY"] ?? environment["DEEPSEEK-API-KEY"], !key.isEmpty,
              CommandLine.arguments.count == 2 else {
            fputs("A test API key and an output directory are required.\n", stderr)
            exit(2)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = try fixture(reference: false, variant: 0)
        let reference = try fixture(reference: true, variant: 0)
        let second = try fixture(reference: true, variant: 1)
        try source.jpeg.write(to: output.appendingPathComponent("source.jpg"))
        try reference.jpeg.write(to: output.appendingPathComponent("reference-1.jpg"))
        try second.jpeg.write(to: output.appendingPathComponent("reference-2.jpg"))
        let service = AIService()
        let configuration = AIConfiguration()
        for referenceCount in [1, 2] {
            let started = Date()
            let recipe = try await service.generate(configuration: configuration, key: key,
                images: [source, reference] + (referenceCount == 2 ? [second] : []),
                instruction: "匹配参考色块的低饱和、略冷阴影风格。保持明暗克制，不增加饱和度，不要大幅移动色相。", previous: nil)
            let look = try AIColorLook.compile(recipe: recipe, model: configuration.model)
            let cube = output.appendingPathComponent("reference-\(referenceCount).cube")
            try AIFileExporter.write(source: look.url, destination: cube, protecting: [], overwrite: false)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recipe).write(to: output.appendingPathComponent("recipe-\(referenceCount).json"))
            let report: [String: Any] = ["references": referenceCount, "configuredModel": configuration.model,
                "elapsedSeconds": Date().timeIntervalSince(started), "gridSize": look.report.gridSize,
                "maxSampledError": look.report.maxError, "p99SampledError": look.report.p99Error,
                "fixture": "synthetic color patches; no private photos", "cube": cube.path]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("report-\(referenceCount).json"))
            print(String(data: data, encoding: .utf8)!)
        }
    }

    private static func fixture(reference: Bool, variant: Int) throws -> AIImage {
        let width = 360, height = 240
        let palette: [[Double]] = [[0.75,0.25,0.16], [0.72,0.52,0.36], [0.25,0.56,0.32],
                                   [0.2,0.43,0.75], [0.74,0.74,0.74], [0.38,0.28,0.48]]
        var pixels = [UInt8](repeating: 255, count: width*height*4)
        for y in 0..<height {
            for x in 0..<width {
                let base = palette[min(5, x/60)]
                let brightness = 0.4 + 0.6*Double(y)/Double(height-1)
                let gray = (base[0]+base[1]+base[2])/3
                for channel in 0..<3 {
                    var value = base[channel]*brightness
                    if reference {
                        value = (gray + (base[channel]-gray)*0.82)*brightness
                        if channel == 2 { value += 0.012*(1-brightness) }
                        if channel == 0 { value -= 0.006*(1-brightness) }
                        value *= variant == 1 ? 0.98 : 1
                    }
                    pixels[(y*width+x)*4+channel] = UInt8((min(1,max(0,value))*255).rounded())
                }
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw AIError.message("Fixture creation failed") }
        return try AIImage.prepare(image, name: reference ? "Reference" : "Source")
    }
}
