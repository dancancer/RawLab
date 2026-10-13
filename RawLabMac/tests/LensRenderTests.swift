import AppKit
import ImageIO

@main struct LensRenderTests {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw RenderError.failed(message) }
        print("PASS: \(message)")
    }
    static func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
    static func compare(_ a: CGImage, _ b: CGImage) throws {
        try check(a.width == b.width && a.height == b.height, "CPU/Metal dimensions")
        let first = bytes(a), second = bytes(b)
        var maximum = 0
        for (a, b) in zip(first, second) { maximum = max(maximum, abs(Int(a) - Int(b))) }
        try check(maximum <= 2, "CPU/Metal parity, maximum difference \(maximum)/255")
    }
    static func main() throws {
        let raw = URL(fileURLWithPath: CommandLine.arguments[1])
        let database = URL(fileURLWithPath: CommandLine.arguments[2])
        let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: database)
        let gpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_FORCE, lensDatabaseURL: database)
        let baseline = try cpu.render(raw, settings: Adjustments(), lut: nil, edge: 700)!
        let info = baseline.lensInfo!
        print("Detected lens: \(info.detectedLens), focal \(info.focalLength) mm; catalog \(info.candidates.count), matches \(info.candidates.filter(\.isMatch).count)")
        guard let candidate = info.candidates.first(where: { $0.isMatch && $0.hasDistortion }) else {
            throw RenderError.failed("Real RAW fixture requires a matching distortion profile")
        }
        print("Profile: \(candidate.title), TCA calibration: \(candidate.hasTCA)")
        var settings = Adjustments()
        settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, mode: .manual, profileID: candidate.id)
        let corrected = try cpu.render(raw, settings: settings, lut: nil, edge: 700)!
        try check(corrected.lensInfo!.appliedDistortion, "Manual profile applied before camera matrix")
        try check(corrected.lensInfo!.appliedTCA == candidate.hasTCA, "TCA application agrees with profile calibration")
        try check(corrected.lensInfo!.cropScale >= 1 && corrected.image.width == baseline.image.width && corrected.image.height == baseline.image.height,
                  "Automatic crop preserves dimensions and aspect ratio")
        try check(bytes(corrected.image) != bytes(baseline.image), "Distortion changes rendered geometry")
        let accelerated = try gpu.render(raw, settings: settings, lut: nil, edge: 700)!
        try check(gpu.lastBackend == SONY2FUJI_BACKEND_METAL, "Corrected RAW continues through Metal photo pipeline")
        try compare(corrected.image, accelerated.image)
        let interactive = try gpu.render(raw, settings: settings, lut: nil, edge: 700, interactive: true)!
        try check(bytes(interactive.image) == bytes(accelerated.image), "Interactive preview reuses exact corrected cache")
        settings.lensCorrection!.mode = .automatic
        let automatic = try cpu.render(raw, settings: settings, lut: nil, edge: 700)!
        if info.candidates.filter(\.isMatch).count == 1 {
            try check(bytes(automatic.image) == bytes(corrected.image), "Automatic and manual matching agree")
        } else {
            try check(automatic.lensInfo!.state == SONY2FUJI_LENS_AMBIGUOUS && !automatic.lensInfo!.appliedDistortion,
                      "Ambiguous matching is explicit and never guesses a profile")
        }
        let reset = try cpu.render(raw, settings: Adjustments(), lut: nil, edge: 700)!
        try check(bytes(reset.image) == bytes(baseline.image) && reset.lensInfo!.state == SONY2FUJI_LENS_OFF,
                  "Disabling corrections restores exact baseline, with no session leakage")
        let history = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: database)
        var preview = Adjustments()
        preview.exposureMode = .preview
        let cameraPreview = try history.render(raw, settings: preview, lut: nil, edge: 200)!
        preview.resolveWhiteBalance(cameraPreview.asShotWhiteBalance)
        preview.set(.temperature, to: 7000)
        _ = try history.render(raw, settings: preview, lut: nil, edge: 200)
        for crop in [false, true] {
            preview.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: crop,
                mode: .manual, profileID: candidate.id)
            let changed = try history.render(raw, settings: preview, lut: nil, edge: 200)!
            let fresh = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: database)
            let direct = try fresh.render(raw, settings: preview, lut: nil, edge: 200)!
            print("Preview anchor crop=\(crop): history \(changed.baselineEV), fresh \(direct.baselineEV)")
            try check(abs(changed.baselineEV - direct.baselineEV) < 1e-6 && bytes(changed.image) == bytes(direct.image),
                      "Preview exposure and pixels are independent of lens-setting history, crop=\(crop)")
        }
        settings.lensCorrection!.mode = .manual
        let native = try gpu.render(raw, settings: settings, lut: nil, edge: nil)!
        let nativeCPU = try cpu.render(raw, settings: settings, lut: nil, edge: nil)!
        try compare(nativeCPU.image, native.image)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-lens-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for suffix in ["png", "jpg"] {
            let output = directory.appendingPathComponent("corrected.\(suffix)")
            _ = try gpu.render(raw, settings: settings, lut: nil, edge: nil, output: output)
            let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            try check(image.width == native.image.width && image.height == native.image.height, "\(suffix) export uses corrected native geometry")
            if suffix == "png" { try check(image.bitsPerComponent == 16, "PNG export remains sixteen-bit") }
        }
        print("Lens RAW integration complete")
    }
}
