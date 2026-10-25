import AppKit
import ImageIO

@main enum AtmosphereRenderTests {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }; print("PASS: \(message)")
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-atmosphere-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        let width = 320, height = 192
        var pixels = [UInt8]()
        for y in 0..<height { for x in 0..<width {
            let wave = Int(25 * sin(Double(x) * .pi / 16))
            pixels.append(contentsOf: [UInt8(80 + x / 4 + wave), UInt8(60 + y / 2 + wave), UInt8(65 + x / 8 + y / 4 + wave), 255])
        } }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        require(CGImageDestinationFinalize(destination), "atmosphere fixture saved")
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        func bytes(_ settings: Adjustments) throws -> Data {
            try engine.render(url, settings: settings, lut: nil, edge: nil)!.image.dataProvider!.data! as Data
        }
        let baseline = try bytes(Adjustments())
        for atmosphere in [AtmosphereSettings(clarity: 75), AtmosphereSettings(clarity: -75),
                           AtmosphereSettings(dehaze: 75), AtmosphereSettings(dehaze: -75),
                           AtmosphereSettings(clarity: 37.251234, dehaze: -42.5)] {
            var settings = Adjustments(); settings.atmosphere = atmosphere
            let config = atmosphere.nativeConfig
            require(config.version == 1 && config.struct_size == 16, "atmosphere native adapter uses the versioned ABI")
            let changed = try bytes(settings)
            require(changed != baseline, "each signed atmosphere control changes native pixels")
            _ = try engine.render(url, settings: settings, lut: nil, edge: 73, interactive: true)
            require(try bytes(settings) == changed, "FINAL atmosphere pixels survive interactive preview")
            let auto = try RenderEngine(gpuMode: SONY2FUJI_GPU_AUTO)
            require(try auto.render(url, settings: settings, lut: nil, edge: nil)!.image.dataProvider!.data! as Data == changed,
                "Auto atmosphere matches the CPU path")
            let output = directory.appendingPathComponent("output.png"), reference = directory.appendingPathComponent("reference.png")
            _ = try engine.render(url, settings: settings, lut: nil, edge: nil, output: output)
            let fresh = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            _ = try fresh.render(url, settings: settings, lut: nil, edge: nil, output: reference)
            require(try Data(contentsOf: output) == Data(contentsOf: reference), "export ignores preview history")
            if let path = ProcessInfo.processInfo.environment["RAWLAB_TEST_CLI"] {
                let agent = directory.appendingPathComponent("agent.png"), recipe = directory.appendingPathComponent("atmosphere.json")
                let data = try engine.agentRecipe(url, settings: settings, lut: nil, output: agent)
                let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let effects = (object["edits"] as! [String: Any])["effects"] as! [String: Any]
                require((effects["clarity"] as! NSNumber).floatValue == config.clarity && (effects["dehaze"] as! NSNumber).floatValue == config.dehaze,
                    "Mac Agent converts atmosphere values once")
                try data.write(to: recipe)
                let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = ["--recipe", recipe.path]
                try process.run(); process.waitUntilExit(); require(process.terminationStatus == 0, "Mac atmosphere Agent recipe succeeds")
                let nativeImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(output as CFURL, nil)!, 0, nil)!
                let agentImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(agent as CFURL, nil)!, 0, nil)!
                require(nativeImage.bitsPerComponent == 16 && agentImage.bitsPerComponent == 16 &&
                    nativeImage.dataProvider!.data! as Data == agentImage.dataProvider!.data! as Data, "Mac native and Agent FINAL 16-bit pixels agree exactly")
            } else { print("SKIP: RAWLAB_TEST_CLI unavailable; Agent comparison not run") }
            require(try bytes(Adjustments()) == baseline, "zero atmosphere clears reused session state")
        }
    }
}
