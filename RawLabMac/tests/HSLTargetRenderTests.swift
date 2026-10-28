import AppKit
import ImageIO

@main enum HSLTargetRenderTests {
    static func require(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-hsl-target-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("raster.png")
        var pixels = [UInt8]()
        for y in 0..<12 { for x in 0..<16 {
            pixels.append(contentsOf: [200, UInt8(40 + x * 4), UInt8(10 + y * 2), 255])
        } }
        let bytes = Data(pixels)
        let provider = CGDataProvider(data: bytes as CFData)!
        let image = CGImage(width: 16, height: 12, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); require(CGImageDestinationFinalize(destination), "test fixture saved")
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let revision = HSLTargetRevision(source: 5, request: 19)
        let point = CGPoint(x: 0, y: 0)
        var settings = Adjustments()
        let baseline = try engine.sampleHSL(url, settings: settings, lut: nil, edge: nil, interactive: false, revision: revision, point: point)
        require(baseline.isUsable && baseline.revision == revision && !baseline.preview, "native sample is owned and revision-bound")
        require(abs(baseline.rgb[0] - 200.0/255) < 0.00001 && abs(baseline.rgb[1] - 40.0/255) < 0.00001, "Mac display input mapping")
        settings.setHSL(.hue, channel: 0, value: 90)
        settings.gradingSettings.shadows = ColorGradingWheel(hue: 220, saturation: 80)
        settings.setEffect(.grainAmount, to: 60)
        let edited = try engine.sampleHSL(url, settings: settings, lut: nil, edge: nil, interactive: false, revision: revision, point: point)
        require(edited.rgb == baseline.rgb && edited.weights == baseline.weights, "HSL, grading and effects do not feed back")
        settings = Adjustments(); settings.vibrance = 45; settings.blackPoint = -20
        var geometry = settings.geometrySettings
        geometry.quarterTurns = 1; geometry.flipHorizontal = true
        geometry.perspectiveHorizontal = 0.4; geometry.straightenDegrees = 12
        geometry.cropX = 0.1; geometry.cropWidth = 0.7
        settings.geometry = geometry
        let rendered = try engine.render(url, settings: settings, lut: nil, edge: 10, viewportPreview: true)!
        let sample = try engine.sampleHSL(url, settings: settings, lut: nil, edge: 10, interactive: false, revision: revision, point: point)
        let renderedBytes = rendered.image.dataProvider!.data! as Data
        require(sample.preview, "viewport quality explicit")
        for channel in 0..<3 { require(abs(Int(renderedBytes[channel]) - Int((min(1,max(0,sample.rgb[channel]))*255).rounded())) <= 1, "Mac probe and rendering share geometry and tone configuration") }
        require(try engine.sampleHSL(url, settings: settings, lut: nil, edge: 10, interactive: false, revision: revision,
            point: CGPoint(x: -0.000000001, y: 0)).availability == .outside, "double coordinate validation precedes Float conversion")
        print("PASS Mac native HSL target raster, upstream configuration, geometry and immutable revisions")
    }
}
