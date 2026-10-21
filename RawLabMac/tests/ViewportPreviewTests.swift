import AppKit
import ImageIO
import Combine

@main
struct ViewportPreviewTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func pixels(_ image: CGImage) -> Data {
        image.dataProvider!.data! as Data
    }

    static func main() throws {
        let raw = URL(fileURLWithPath: CommandLine.arguments[1])
        let lut = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        if CommandLine.arguments.contains("--model-only") {
            try modelChecks(raw: raw, lut: lut, output: output)
            return
        }
        let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let metal = try RenderEngine(gpuMode: SONY2FUJI_GPU_AUTO)
        var detail = Adjustments()
        detail.exposure = 0.35; detail.sharpening = 100
        detail.setEffect(.vignetteAmount, to: -35)
        detail.setEffect(.grainAmount, to: 45)
        var wavelet = detail
        wavelet.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 65, chroma: 72, coarse: 100)
        var chroma = detail
        chroma.chromaNoiseReduction = 2

        for (name, settings) in [("detail-effects", detail), ("wavelet-effects", wavelet), ("chroma-effects", chroma)] {
            let exact = try cpu.render(raw, settings: settings, lut: lut, edge: 1200)!
            let proxy = try cpu.render(raw, settings: settings, lut: lut, edge: 1200, viewportPreview: true)!
            check(max(proxy.image.width, proxy.image.height) == 1200 && !proxy.isFullResolution,
                  "\(name): viewport dimensions are bounded")
            check(proxy.baselineEV == exact.baselineEV && proxy.asShotWhiteBalance == exact.asShotWhiteBalance,
                  "\(name): exposure and camera WB metadata survive reduction")
            let accelerated = try metal.render(raw, settings: settings, lut: lut, edge: 1200, viewportPreview: true)!
            check(metal.lastBackend == SONY2FUJI_BACKEND_METAL, "\(name): Auto completes display processing on Metal")
            let a = pixels(proxy.image), b = pixels(accelerated.image)
            let difference = zip(a, b).map { abs(Int($0) - Int($1)) }
            check(difference.max()! <= 4 && Double(difference.reduce(0, +)) / Double(difference.count) < 0.5,
                  "\(name): viewport CPU/Metal pixels agree")
            _ = try cpu.render(raw, settings: settings, lut: lut, edge: 768, viewportPreview: true)
            let restored = try cpu.render(raw, settings: settings, lut: lut, edge: 1200)!
            check(pixels(restored.image) == pixels(exact.image),
                  "\(name): smaller proxies cannot contaminate exact rendering")
            var times: [String: Double] = [:]
            for viewport in [false, true] {
                _ = try metal.render(raw, settings: settings, lut: lut, edge: 1200, viewportPreview: viewport)
                var samples: [Double] = []
                for ev in [0.1, 0.2, 0.3] {
                    var adjusted = settings; adjusted.exposure = ev
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = try metal.render(raw, settings: adjusted, lut: lut, edge: 1200, viewportPreview: viewport)
                    samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                times[viewport ? "viewport" : "exact"] = samples.sorted()[1]
            }
            print(String(format: "BENCH %@: exact %.1f ms, viewport %.1f ms, %.2fx", name,
                         times["exact"]!, times["viewport"]!, times["exact"]! / times["viewport"]!))
        }

        for ext in ["jpg", "png"] {
            let exact = output.appendingPathComponent("exact.\(ext)")
            let afterProxy = output.appendingPathComponent("after-proxy.\(ext)")
            _ = try metal.render(raw, settings: detail, lut: lut, edge: nil, output: exact, exportLongEdge: 1200)
            _ = try metal.render(raw, settings: detail, lut: lut, edge: 768, viewportPreview: true)
            _ = try metal.render(raw, settings: detail, lut: lut, edge: nil, output: afterProxy,
                                 exportLongEdge: 1200, viewportPreview: true)
            let before = CGImageSourceCreateWithURL(exact as CFURL, nil)!
            let after = CGImageSourceCreateWithURL(afterProxy as CFURL, nil)!
            let a = CGImageSourceCreateImageAtIndex(before, 0, nil)!
            let b = CGImageSourceCreateImageAtIndex(after, 0, nil)!
            check(pixels(a) == pixels(b), "\(ext): export pixels are unchanged after viewport previews")
            if ext == "png" { check(a.bitsPerComponent == 16, "PNG export remains sixteen-bit") }
        }
        try denoiseExportChecks(raw: raw, lut: lut, output: output, engine: metal)
        try interactiveWhiteBalanceChecks(raw: raw, lut: lut)
        try modelChecks(raw: raw, lut: lut, output: output)
    }

    static func denoiseExportChecks(raw: URL, lut: URL, output: URL, engine: RenderEngine) throws {
        var settings = Adjustments()
        settings.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 40, chroma: 46, coarse: 50)
        _ = try engine.render(raw, settings: settings, lut: lut, edge: 768, viewportPreview: true)
        _ = try engine.render(raw, settings: settings, lut: lut, edge: 1280, viewportPreview: true)
        settings.setDenoiseParameter(.chroma, to: 72)
        settings.setDenoiseParameter(.coarse, to: 100)
        settings.set(.temperature, to: 8000)
        settings.exposure = -0.25
        _ = try engine.render(raw, settings: settings, lut: lut, edge: 832,
                              interactive: true, viewportPreview: true)
        let reference = try RenderEngine(gpuMode: SONY2FUJI_GPU_AUTO)
        let native = try reference.render(raw, settings: settings, lut: lut, edge: nil)!
        check(native.isFullResolution, "denoise reference uses native processing")
        let denoised = try reference.render(raw, settings: settings, lut: lut, edge: 512)!
        var off = settings; off.setDenoiseEnabled(false)
        let unfiltered = try reference.render(raw, settings: off, lut: lut, edge: 512)!
        check(pixels(denoised.image) != pixels(unfiltered.image), "export fixture exercises an applied denoise filter")
        for ext in ["jpg", "png"] {
            let expected = output.appendingPathComponent("denoise-native-reference.\(ext)")
            let actual = output.appendingPathComponent("denoise-native-after-proxy.\(ext)")
            _ = try reference.render(raw, settings: settings, lut: lut, edge: nil, output: expected)
            _ = try engine.render(raw, settings: settings, lut: lut, edge: nil, output: actual,
                                  interactive: true, viewportPreview: true)
            let before = CGImageSourceCreateWithURL(expected as CFURL, nil)!
            let after = CGImageSourceCreateWithURL(actual as CFURL, nil)!
            let a = CGImageSourceCreateImageAtIndex(before, 0, nil)!
            let b = CGImageSourceCreateImageAtIndex(after, 0, nil)!
            check(a.width == native.image.width && a.height == native.image.height &&
                  b.width == a.width && b.height == a.height,
                  "\(ext): denoise export retains native dimensions after viewport and WB changes")
            check(pixels(a) == pixels(b), "\(ext): denoise native export matches an independent exact session")
            if ext == "png" { check(b.bitsPerComponent == 16, "denoise native PNG remains sixteen-bit") }
            _ = try engine.render(raw, settings: settings, lut: lut, edge: 640, viewportPreview: true)
        }
    }

    static func interactiveWhiteBalanceChecks(raw: URL, lut: URL) throws {
        for exposureMode in [ExposureMode.scene, .preview] {
            let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            let metal = try RenderEngine(gpuMode: SONY2FUJI_GPU_AUTO)
            let reference = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            var settings = Adjustments()
            settings.exposureMode = exposureMode
            settings.set(.temperature, to: 8000)
            settings.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 65, chroma: 72, coarse: 100)
            let proxy = try cpu.render(raw, settings: settings, lut: lut, edge: 1200,
                                       interactive: true, viewportPreview: true)!
            let accelerated = try metal.render(raw, settings: settings, lut: lut, edge: 1200,
                                             interactive: true, viewportPreview: true)!
            let differences = zip(pixels(proxy.image), pixels(accelerated.image)).map { abs(Int($0) - Int($1)) }
            check(differences.max()! <= 4, "\(exposureMode): half-size RAW + viewport CPU/Metal pixels agree")
            let released = try cpu.render(raw, settings: settings, lut: lut, edge: 1200)!
            let exact = try reference.render(raw, settings: settings, lut: lut, edge: 1200)!
            check(pixels(released.image) == pixels(exact.image), "\(exposureMode): half-size viewport cache cannot serve exact release")
        }
    }

    static func modelChecks(raw: URL, lut: URL, output: URL) throws {
        let model = EditorModel(lookDirectory: output.appendingPathComponent("looks"),
                                editDirectory: output.appendingPathComponent("edits"),
                                batchDirectory: output.appendingPathComponent("batch"))
        model.films = [Film(name: "PROVIA", url: lut)]; model.selectedFilmID = lut.path
        model.updatePreviewLongEdge(832)
        model.open(raw)
        wait("initial viewport-sized model preview") { !model.busy && model.result?.image.width == 832 }
        let original = model.neutral!.image
        model.settings.sharpening = 100
        model.settings.setEffect(.grainAmount, to: 45)
        wait("numeric and effects changes use the viewport") { !model.busy && model.result?.image.width == 832 }
        let engine = try RenderEngine()
        let expected = try engine.render(raw, settings: model.settings, lut: lut, edge: 832, viewportPreview: true)!
        check(pixels(model.result!.image) == pixels(expected.image), "model requests the reduced-source pipeline")
        model.updatePreviewLongEdge(1600)
        wait("viewport resizing refreshes the preview") { !model.busy && model.result?.image.width == 1600 }
        model.updatePreviewLongEdge(768)
        model.updatePreviewLongEdge(1280)
        model.updatePreviewLongEdge(960)
        wait("rapid window resizing settles at the latest dimensions") { !model.busy && model.result?.image.width == 960 }
        let resized = try engine.render(raw, settings: model.settings, lut: lut, edge: 960, viewportPreview: true)!
        check(pixels(model.result!.image) == pixels(resized.image), "resizing retains current settings and publishes the latest size")
        model.updatePreviewLongEdge(1600)
        wait("expanding the window rebuilds a larger preview") { !model.busy && model.result?.image.width == 1600 }
        var resizeFrames: [Int] = []
        let subscription = model.$result.dropFirst().sink { frame in
            if let frame { resizeFrames.append(max(frame.image.width, frame.image.height)) }
        }
        model.setInteracting(true)
        model.updatePreviewLongEdge(1280)
        model.updatePreviewLongEdge(960)
        model.updatePreviewLongEdge(832)
        wait("window resizing during a drag publishes the latest viewport") {
            model.status.hasPrefix("交互预览") && model.result?.image.width == 832
        }
        subscription.cancel()
        check(!resizeFrames.isEmpty && resizeFrames.allSatisfy { $0 == 832 },
              "in-flight interactive results at obsolete window sizes are discarded")
        model.setInteracting(false)
        wait("resized drag settles without extra full-image work") { !model.busy && model.result?.image.width == 832 }
        model.updatePreviewLongEdge(1600)
        wait("viewport size can grow again after a drag") { !model.busy && model.result?.image.width == 1600 }
        model.fullResolution = true
        wait("100 percent returns to native rendering") { !model.busy && model.result?.isFullResolution == true }
        model.setInteracting(true)
        model.settings.exposure = 0.75
        wait("pixel-mode adjustments publish a bounded proxy") {
            model.status.hasPrefix("交互预览") && model.result?.image.width == 1600
        }
        model.setInteracting(false)
        wait("pixel-mode release restores native quality") { !model.busy && model.result?.isFullResolution == true }
        let native = try engine.render(raw, settings: model.settings, lut: lut, edge: nil)!
        check(pixels(model.result!.image) == pixels(native.image), "100 percent release matches exact source-resolution pixels")
        check(model.neutral!.image === original, "original baseline stays immutable across viewport and settings changes")
        model.fullResolution = false
        wait("fit returns to the bounded preview") { !model.busy && model.result?.image.width == 1600 }
        model.settings.setDenoiseEnabled(true)
        wait("denoise prepares a stable viewport proxy") { !model.busy && model.result?.image.width == 1600 }
        model.updatePreviewLongEdge(832)
        model.updatePreviewLongEdge(1280)
        model.updatePreviewLongEdge(960)
        check(model.renderPreviewLongEdge == 1600 && model.previewLongEdge == 960 && model.busy,
              "a resize burst holds the denoised proxy edge and blocks export until settled")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(model.renderPreviewLongEdge == 1600, "denoise does not rebuild for intermediate resize dimensions")
        model.updatePreviewLongEdge(1280)
        model.updatePreviewLongEdge(960)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        check(model.renderPreviewLongEdge == 1600 && model.busy && !model.canApplySettings,
              "cancelled resize timers cannot commit the latest edge before its quiet period")
        model.setInteracting(true)
        model.settings.exposure = -0.25
        wait("resize settles at the latest edge even while editing") { model.result?.image.width == 960 }
        model.setInteracting(false)
        wait("resized denoise preview becomes export-ready") { !model.busy && model.result?.image.width == 960 }
        let denoised = try engine.render(raw, settings: model.settings, lut: lut, edge: 960, viewportPreview: true)!
        check(pixels(model.result!.image) == pixels(denoised.image), "resize stabilization retains exact current settings at the committed proxy size")
        model.updatePreviewLongEdge(832)
        model.fullResolution = true
        wait("100 percent cancels pending proxy resize work") { !model.busy && model.result?.isFullResolution == true }
        check(model.error == nil, "editor finishes without rendering errors")
    }

    static func wait(_ name: String, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if condition() { print("PASS: \(name)"); return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        fatalError("FAIL: timed out waiting for \(name)")
    }
}
