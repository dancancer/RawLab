import AppKit
import ImageIO

@main struct PhotoEffectsRenderTests {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw RenderError.failed(message) }
        print("PASS: \(message)")
    }

    static func compare(_ a: CGImage, _ b: CGImage, label: String) throws {
        try check(a.width == b.width && a.height == b.height, "\(label) dimensions")
        let first = a.dataProvider!.data! as Data, second = b.dataProvider!.data! as Data
        var maximum = 0
        for y in 0..<a.height { for x in 0..<a.width { for c in 0..<3 {
            maximum = max(maximum, abs(Int(first[y * a.bytesPerRow + x * 4 + c]) -
                                       Int(second[y * b.bytesPerRow + x * 4 + c])))
        } } }
        try check(maximum <= 2, "\(label) CPU/Metal parity, maximum difference \(maximum)/255")
    }

    static func main() throws {
        let raw = URL(fileURLWithPath: CommandLine.arguments[1])
        let lut = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-effects-metal-\(UUID())")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let gpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_FORCE)
        var settings = Adjustments()
        let denoise = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "none"
        if denoise == "wavelet" { settings.applyDenoisePreset(.clean); settings.setDenoiseParameter(.luma, to: 50) }
        if denoise == "chroma" { settings.denoiseMode = 2 }
        _ = try cpu.render(raw, settings: Adjustments(), lut: lut, edge: 700)
        _ = try gpu.render(raw, settings: Adjustments(), lut: lut, edge: 700)
        for mode in 0..<3 {
            settings.setEffect(.vignetteAmount, to: mode == 1 ? 0 : -65)
            settings.setEffect(.vignetteRoundness, to: -35)
            settings.setEffect(.vignetteHighlights, to: 75)
            settings.setEffect(.grainAmount, to: mode == 0 ? 0 : 70)
            settings.setEffect(.grainSize, to: 60)
            settings.setEffect(.grainRoughness, to: 80)
            let beginCPU = Date()
            let reference = try cpu.render(raw, settings: settings, lut: lut, edge: 700)!
            let secondsCPU = Date().timeIntervalSince(beginCPU), beginGPU = Date()
            let actual = try gpu.render(raw, settings: settings, lut: lut, edge: 700)!
            if mode == 0 {
                print(String(format: "First %@ denoise after RAW warmup: CPU %.3fs, Metal %.3fs", denoise, secondsCPU, Date().timeIntervalSince(beginGPU)))
            }
            try check(gpu.lastBackend == SONY2FUJI_BACKEND_METAL, "RAW effects \(mode) execute on Metal")
            try compare(reference.image, actual.image, label: "RAW effects \(mode)")
            let interactive = try gpu.render(raw, settings: settings, lut: lut, edge: 700, interactive: true)!
            try check(interactive.image.dataProvider!.data! as Data == actual.image.dataProvider!.data! as Data,
                      "Interactive effects retain exact source-pixel grain")
        }
        let startCPU = Date()
        _ = try cpu.render(raw, settings: settings, lut: lut, edge: 700)
        let cpuSeconds = Date().timeIntervalSince(startCPU)
        let startGPU = Date()
        _ = try gpu.render(raw, settings: settings, lut: lut, edge: 700)
        print(String(format: "Warm 700px preview: CPU %.3fs, Metal %.3fs", cpuSeconds, Date().timeIntervalSince(startGPU)))
        let fullCPU = try cpu.render(raw, settings: settings, lut: lut, edge: nil)!
        let fullGPU = try gpu.render(raw, settings: settings, lut: lut, edge: nil)!
        try compare(fullCPU.image, fullGPU.image, label: "Native RAW effects")
        for suffix in ["png", "jpg"] {
            let file = output.appendingPathComponent("effects.\(suffix)")
            _ = try gpu.render(raw, settings: settings, lut: lut, edge: nil, output: file)
            try check(gpu.lastBackend == SONY2FUJI_BACKEND_METAL, "\(suffix) export runs on Metal")
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw RenderError.failed("Cannot decode exported \(suffix)")
            }
            try check(image.width == fullGPU.image.width && image.height == fullGPU.image.height,
                      "\(suffix) export retains native dimensions")
            if suffix == "png" {
                try check(image.bitsPerComponent == 16, "PNG retains sixteen-bit output")
                let bytes = image.dataProvider!.data! as Data
                let expected = fullGPU.image.dataProvider!.data! as Data
                let little = image.bitmapInfo.contains(.byteOrder16Little)
                let channels = image.bitsPerPixel / 16
                var maximum = 0
                for y in stride(from: 0, to: image.height, by: 17) {
                    for x in stride(from: 0, to: image.width, by: 19) { for c in 0..<3 {
                        let index = y * image.bytesPerRow + (x * channels + c) * 2
                        let a = Int(bytes[index]), b = Int(bytes[index + 1])
                        let value = little ? a + (b << 8) : (a << 8) + b
                        let quantized = Int((Double(value) * 255 / 65535).rounded())
                        maximum = max(maximum, abs(quantized - Int(expected[y * fullGPU.image.bytesPerRow + x * 4 + c])))
                    } }
                }
                try check(maximum <= 1, "Metal native preview/PNG parity, maximum difference \(maximum)/255")
            }
        }
        settings.reset(.effects)
        _ = try gpu.render(raw, settings: settings, lut: lut, edge: 700)
        try check(gpu.lastBackend == SONY2FUJI_BACKEND_METAL, "Disabling effects retains Metal")
        print("PASS: denoise mode \(denoise) with vignette/grain and export")
    }
}
