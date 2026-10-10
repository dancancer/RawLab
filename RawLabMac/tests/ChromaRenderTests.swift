import AppKit
import ImageIO

@main struct ChromaRenderTests {
    static func pixels(_ value: RenderedImage) -> Data { value.image.dataProvider!.data! as Data }
    static func check(_ condition: Bool, _ name: String) {
        guard condition else { fatalError(name) }
        print("PASS: \(name)")
    }
    static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let lut = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chroma-render-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try RenderEngine()
        let off = try engine.render(input, settings: Adjustments(), lut: lut, edge: 600)!
        var previous = pixels(off)
        for mode in [1.0, 2.0] {
            var settings = Adjustments()
            settings.denoiseMode = mode
            let preview = try engine.render(input, settings: settings, lut: lut, edge: 600)!
            check(pixels(preview) != previous, "\(input.lastPathComponent): mode \(mode) changes pixels")
            previous = pixels(preview)
            let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF).render(input, settings: settings, lut: lut, edge: 600)!
            let reference = pixels(cpu), actual = pixels(preview)
            let maximum = zip(reference, actual).map { abs(Int($0) - Int($1)) }.max() ?? 0
            check(maximum <= 2, "CPU/Metal denoising differs by at most two code values")
            check(engine.lastBackend == SONY2FUJI_BACKEND_METAL, "Auto chroma denoising uses Metal")
            let proxyEngine = try RenderEngine()
            _ = try proxyEngine.render(input, settings: Adjustments(), lut: lut, edge: 600, interactive: true)
            let interactive = try proxyEngine.render(input, settings: settings, lut: lut, edge: 600, interactive: true)!
            check(pixels(interactive) == pixels(preview), "Enabling denoise replaces a half-size proxy with exact decoding")
            settings.rawNoiseReduction = 2
            let unstacked = try engine.render(input, settings: settings, lut: lut, edge: 600)!
            check(pixels(unstacked) == pixels(preview), "New mode never implicitly stacks legacy FBDD")
            let full = try engine.render(input, settings: settings, lut: lut, edge: nil)!
            let target = directory.appendingPathComponent("mode-\(Int(mode)).png")
            _ = try engine.render(input, settings: settings, lut: lut, edge: nil, output: target)
            let source = CGImageSourceCreateWithURL(target as CFURL, nil)!
            let exported = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            check(exported.bitsPerComponent == 16 && exported.width == full.image.width && exported.height == full.image.height,
                  "Denoised PNG retains native dimensions and 16-bit output")
            let bytes = exported.dataProvider!.data! as Data, expected = pixels(full)
            let little = exported.bitmapInfo.contains(.byteOrder16Little)
            let channels = exported.bitsPerPixel/16
            var error = 0
            for y in stride(from: 0, to: exported.height, by: 67) {
                for x in stride(from: 0, to: exported.width, by: 71) { for c in 0..<3 {
                    let i = y*exported.bytesPerRow+(x*channels+c)*2
                    let a = Int(bytes[i]), b = Int(bytes[i+1])
                    let value = little ? a+(b<<8) : (a<<8)+b
                    let eight = Int((Double(value)*255/65535).rounded())
                    error = max(error, abs(eight-Int(expected[y*full.image.bytesPerRow+x*4+c])))
                }}
            }
            check(error <= 1, "Preview and file export agree within one 8-bit code value")
        }
        let restored = try engine.render(input, settings: Adjustments(), lut: lut, edge: 600)!
        check(pixels(restored) == pixels(off), "Switching off restores the original output")
        print("PASS: chroma real RAW / \(input.lastPathComponent) / LUT \(lut != nil)")
    }
}
