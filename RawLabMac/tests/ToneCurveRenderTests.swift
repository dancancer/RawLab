import RawLabKit
import RawLabNative
import AppKit
import ImageIO

@main enum ToneCurveRenderTests {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }; print("PASS: \(message)")
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-curve-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        var pixels = [UInt8]()
        for y in 0..<12 { for x in 0..<16 {
            pixels.append(contentsOf: [200, UInt8(40 + x * 4), UInt8(10 + y * 2), 255])
        } }
        let image = CGImage(width: 16, height: 12, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        require(CGImageDestinationFinalize(destination), "curve fixture saved")
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        func bytes(_ settings: Adjustments) throws -> Data {
            try engine.render(url, settings: settings, lut: nil, edge: nil)!.image.dataProvider!.data! as Data
        }
        let baseline = try bytes(Adjustments())
        var settings = Adjustments(); settings.toneCurve = 0.65
        let legacy = try bytes(settings)
        require(legacy != baseline, "legacy S curve remains effective")
        settings.curveSettings = .identity
        require(try bytes(settings) == baseline, "custom identity bypasses inactive legacy scalar exactly")
        settings.curveSettings = .identity.inserting(x: 0.25, y: 0.4).inserting(x: 0.75, y: 0.9)
        let changed = try bytes(settings)
        require(changed != baseline && changed != legacy, "custom curve reaches native render and cache key")
        let sample = try engine.sampleHSL(url, settings: settings, lut: nil, edge: nil, interactive: false,
            revision: .init(source: 1, request: 1), point: .zero)
        let curve = settings.curveSettings.sampledPoints(count: 256)
        require(curve.count == 256 && sample.isUsable, "native curve sampling and pre-HSL probe succeed")
        for (channel, input) in [200, 40, 10].enumerated() {
            require(abs(sample.rgb[channel] - curve[input].y) < 0.00001, "canvas evaluator agrees with rendered curve channel \(channel)")
        }
        _ = try engine.render(url, settings: settings, lut: nil, edge: 8, interactive: true)
        require(try bytes(settings) == changed, "FINAL curve pixels survive interactive preview")
        let output = directory.appendingPathComponent("output.png"), reference = directory.appendingPathComponent("reference.png")
        _ = try engine.render(url, settings: settings, lut: nil, edge: nil, output: output)
        let fresh = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        _ = try fresh.render(url, settings: settings, lut: nil, edge: nil, output: reference)
        require(try Data(contentsOf: output) == Data(contentsOf: reference), "FINAL export is independent of preview history")
        if let path = ProcessInfo.processInfo.environment["RAWLAB_TEST_CLI"] {
            let agent = directory.appendingPathComponent("agent.png"), recipe = directory.appendingPathComponent("curve.json")
            let data = try engine.agentRecipe(url, settings: settings, lut: nil, output: agent)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let tone = (object["edits"] as! [String: Any])["tone"] as! [String: Any]
            require((tone["s_curve"] as! NSNumber).doubleValue == 0 && (tone["curve"] as! [String: Any])["mode"] as? String == "custom",
                "Mac Agent emits custom curve with scalar zero")
            try data.write(to: recipe)
            let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = ["--recipe", recipe.path]
            try process.run(); process.waitUntilExit(); require(process.terminationStatus == 0, "Mac curve Agent recipe succeeds")
            let nativeImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(output as CFURL, nil)!, 0, nil)!
            let agentImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(agent as CFURL, nil)!, 0, nil)!
            require(nativeImage.bitsPerComponent == 16 && agentImage.bitsPerComponent == 16 &&
                nativeImage.dataProvider!.data! as Data == agentImage.dataProvider!.data! as Data,
                "Mac native and Agent FINAL 16-bit pixels agree exactly")
        } else { print("SKIP: RAWLAB_TEST_CLI unavailable; Agent comparison not run") }
        settings.curveSettings = ToneCurveSettings()
        require(try bytes(settings) == legacy, "returning to legacy clears custom session state")
        require(try bytes(Adjustments()) == baseline, "reset clears the complete curve state")

        // Track A Tone Curve v2: unpinned endpoints, parametric, applyToLuminosity, channel sampling & v17 Agent parity.
        var v2 = Adjustments()
        v2.curveSettings = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0, y: 0.1), .init(x: 0.5, y: 0.55), .init(x: 1, y: 0.9)],
            channels: ToneCurveChannels(red: ToneCurveShape(mode: .custom, points: [.init(x: 0, y: 0.05), .init(x: 1, y: 0.95)])),
            applyToLuminosity: false,
            parametric: ToneCurveParametric(highlights: -10, lights: 15, darks: -5, shadows: 20, splitShadow: 0.2, splitMidtone: 0.5, splitHighlight: 0.8)
        )
        let rgbSamples = v2.curveSettings.sampledPoints(channel: .rgb, count: 256)
        let pointOnlySamples = v2.curveSettings.sampledPoints(channel: .rgb, includeParametric: false, count: 257)
        let parametricOnlySamples = ToneCurveSettings(
            mode: .custom,
            points: ToneCurveShape.identity.points,
            parametric: v2.curveSettings.parametric
        ).sampledPoints(channel: .rgb, includeParametric: true, count: 257)
        let redSamples = v2.curveSettings.sampledPoints(channel: .red, count: 256)
        require(abs(rgbSamples[0].y - 0.1) < 1e-5 && abs(rgbSamples[255].y - 0.9) < 1e-5,
            "v2 RGB sampling reflects unpinned matte-fade endpoints")
        require(abs(pointOnlySamples[128].y - 0.55) < 1e-9 && abs(rgbSamples[128].y - 0.55) > 1e-3,
            "Point-curve canvas sampling isolates control points from active parametric curve")
        require(abs(parametricOnlySamples[0].y - 0.0) < 1e-9 && abs(parametricOnlySamples[256].y - 1.0) < 1e-9 &&
            abs(parametricOnlySamples[64].y - 0.25) > 1e-3,
            "Parametric-curve canvas sampling isolates parametric bands from point-curve endpoints")
        require(abs(redSamples[0].y - 0.05) < 1e-5 && abs(redSamples[255].y - 0.95) < 1e-5,
            "v2 Red channel sampling reflects red unpinned endpoints without parametric")
        let v2RgbBytes = try bytes(v2)
        v2.curveSettings.applyToLuminosity = true
        let v2LumBytes = try bytes(v2)
        require(v2RgbBytes != v2LumBytes, "applyToLuminosity produces distinct chrominance-preserving render")
        if let path = ProcessInfo.processInfo.environment["RAWLAB_TEST_CLI"] {
            let v2Out = directory.appendingPathComponent("v2-native.png")
            let v2Agent = directory.appendingPathComponent("v2-agent.png")
            let v2Recipe = directory.appendingPathComponent("v2-curve.json")
            _ = try engine.render(url, settings: v2, lut: nil, edge: nil, output: v2Out)
            let data = try engine.agentRecipe(url, settings: v2, lut: nil, output: v2Agent)
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            require((obj["schema_version"] as? Int) == 17, "v2 Agent emits schema_version 17")
            try data.write(to: v2Recipe)
            let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = ["--recipe", v2Recipe.path]
            try process.run(); process.waitUntilExit(); require(process.terminationStatus == 0, "Mac v2 curve Agent recipe succeeds")
            let nativeImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(v2Out as CFURL, nil)!, 0, nil)!
            let agentImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(v2Agent as CFURL, nil)!, 0, nil)!
            require(nativeImage.dataProvider!.data! as Data == agentImage.dataProvider!.data! as Data,
                "Mac v2 native and Agent FINAL 16-bit pixels agree exactly")
        }

        var freeX = Adjustments()
        freeX.curveSettings = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0.2, y: 0.0), .init(x: 0.8, y: 1.0)],
            channels: ToneCurveChannels(red: ToneCurveShape(mode: .custom, points: [.init(x: 0.15, y: 0.05), .init(x: 0.85, y: 0.95)]))
        )
        let freeXSamples = freeX.curveSettings.sampledPoints(channel: .rgb, count: 256)
        require(freeXSamples[0].y == 0.0 && freeXSamples[255].y == 1.0,
            "free-X RGB sampling clamps flat outside [x0, x1]")
        let freeXRedSamples = freeX.curveSettings.sampledPoints(channel: .red, count: 256)
        require(abs(freeXRedSamples[0].y - 0.05) < 1e-5 && abs(freeXRedSamples[255].y - 0.95) < 1e-5,
            "free-X Red channel sampling clamps flat outside [x0, x1]")
        let freeXBytes = try bytes(freeX)
        require(freeXBytes != baseline && freeXBytes != v2RgbBytes, "free-X curve reaches Mac native render")
        if let path = ProcessInfo.processInfo.environment["RAWLAB_TEST_CLI"] {
            let fxOut = directory.appendingPathComponent("freex-native.png")
            let fxAgent = directory.appendingPathComponent("freex-agent.png")
            let fxRecipe = directory.appendingPathComponent("freex-curve.json")
            _ = try engine.render(url, settings: freeX, lut: nil, edge: nil, output: fxOut)
            let data = try engine.agentRecipe(url, settings: freeX, lut: nil, output: fxAgent)
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            require((obj["schema_version"] as? Int) == 18, "free-X Agent emits schema_version 18")
            try data.write(to: fxRecipe)
            let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = ["--recipe", fxRecipe.path]
            try process.run(); process.waitUntilExit(); require(process.terminationStatus == 0, "Mac free-X Agent recipe succeeds")
            let nativeImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(fxOut as CFURL, nil)!, 0, nil)!
            let agentImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(fxAgent as CFURL, nil)!, 0, nil)!
            require(nativeImage.dataProvider!.data! as Data == agentImage.dataProvider!.data! as Data,
                "Mac free-X native and Agent FINAL 16-bit pixels agree exactly")
        }
    }
}
