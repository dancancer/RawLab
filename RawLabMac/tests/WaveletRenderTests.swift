import AppKit
import ImageIO

@main struct WaveletRenderTests {
    static func bytes(_ image: RenderedImage) -> Data { image.image.dataProvider!.data! as Data }
    static func check(_ value: Bool, _ name: String) {
        guard value else { fatalError(name) }
        print("PASS: \(name)")
    }
    static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let lut = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
        let engine = try RenderEngine()
        var settings = Adjustments()
        let off = try engine.render(input, settings: settings, lut: lut, edge: 600)!
        settings.applyDenoisePreset(.detail)
        let detail = try engine.render(input, settings: settings, lut: lut, edge: 600)!
        check(bytes(detail) != bytes(off), "Adjustable denoise changes real RAW pixels")
        let repeated = try engine.render(input, settings: settings, lut: lut, edge: 600)!
        check(bytes(detail) == bytes(repeated), "Repeated exact render is stable")
        for parameter in DenoiseParameter.allCases {
            var changed = settings
            changed.setDenoiseParameter(parameter, to: parameter == .chroma ? 0 : 100)
            let output = try engine.render(input, settings: changed, lut: lut, edge: 600)!
            check(bytes(output) != bytes(detail), "\(parameter) independently changes output")
        }
        let proxy = try RenderEngine()
        _ = try proxy.render(input, settings: settings, lut: lut, edge: 300, interactive: true)
        let exact = try proxy.render(input, settings: settings, lut: lut, edge: 600)!
        check(bytes(exact) == bytes(detail), "Interactive approximation never contaminates exact output")
        settings.setDenoiseEnabled(false)
        check(bytes(try engine.render(input, settings: settings, lut: lut, edge: 600)!) == bytes(off), "Off restores original while retaining parameters")
        settings.setDenoiseEnabled(true)
        check(bytes(try engine.render(input, settings: settings, lut: lut, edge: 600)!) == bytes(detail), "Re-enable restores same output")
        var exposed = settings
        exposed.exposure = 1
        let reusedExposure = try engine.render(input, settings: exposed, lut: lut, edge: 600)!
        let freshExposure = try RenderEngine().render(input, settings: exposed, lut: lut, edge: 600)!
        check(bytes(reusedExposure) == bytes(freshExposure), "Exposure after denoise uses the same cached linear result")
        var balanced = settings
        balanced.whiteBalanceMode = .custom; balanced.temperature = 6500; balanced.tint = 0
        let reusedWB = try engine.render(input, settings: balanced, lut: lut, edge: 600)!
        let freshWB = try RenderEngine().render(input, settings: balanced, lut: lut, edge: 600)!
        check(bytes(reusedWB) == bytes(freshWB), "White balance changes invalidate the filtered RAW cache")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wavelet-render-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("denoised.png")
        _ = try engine.render(input, settings: settings, lut: lut, edge: nil, output: target)
        let full = try engine.render(input, settings: settings, lut: lut, edge: nil)!
        let source = CGImageSourceCreateWithURL(target as CFURL, nil)!
        let saved = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        check(saved.bitsPerComponent == 16 && saved.width == full.image.width && saved.height == full.image.height,
              "Export keeps native dimensions and sixteen-bit samples")
        let exported = saved.dataProvider!.data! as Data, expected = bytes(full)
        let little = saved.bitmapInfo.contains(.byteOrder16Little), channels = saved.bitsPerPixel / 16
        var maximum = 0
        for y in stride(from: 0, to: saved.height, by: 67) {
            for x in stride(from: 0, to: saved.width, by: 71) { for c in 0..<3 {
                let i = y*saved.bytesPerRow+(x*channels+c)*2
                let a = Int(exported[i]), b = Int(exported[i+1])
                let value = little ? a+(b<<8) : (a<<8)+b
                maximum = max(maximum, abs(Int((Double(value)*255/65535).rounded())-Int(expected[y*full.image.bytesPerRow+x*4+c])))
            }}
        }
        check(maximum <= 1, "Exact preview/export agree within one code value")
        print("PASS: \(input.lastPathComponent) / LUT \(lut != nil)")
    }
}
