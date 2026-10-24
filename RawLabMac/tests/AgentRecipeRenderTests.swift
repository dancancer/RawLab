import AppKit
import Foundation
import ImageIO

private struct AgentRecipeContext {
    let root: URL
    let cli: URL
    let lensDatabase: URL
    let lensRaw: URL
}

private func fail(_ message: String) -> RenderError {
    .failed("Agent recipe test: \(message)")
}

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw fail(message) }
    print("PASS: \(message)")
}

private func dictionary(_ value: Any?, _ path: String) throws -> [String: Any] {
    guard let value = value as? [String: Any] else { throw fail("\(path) is not an object") }
    return value
}

private func number(_ value: Any?, _ path: String) throws -> Double {
    guard let value = value as? NSNumber else { throw fail("\(path) is not a number") }
    return value.doubleValue
}

private func image(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let result = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw fail("cannot decode \(url.lastPathComponent)")
    }
    return result
}

private func pixels(_ image: CGImage) -> Data {
    image.dataProvider!.data! as Data
}

private func rgb8(_ image: CGImage) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let channels = max(1, image.bitsPerPixel / image.bitsPerComponent)
    let bytesPerChannel = max(1, image.bitsPerComponent / 8)
    let littleEndian = image.bitmapInfo.contains(.byteOrder16Little)
    var result = [UInt8]()
    result.reserveCapacity(image.width * image.height * 3)
    for y in 0..<image.height {
        for x in 0..<image.width {
            let pixel = y * image.bytesPerRow + x * channels * bytesPerChannel
            for channel in 0..<3 {
                let offset = pixel + channel * bytesPerChannel
                if image.bitsPerComponent == 16 {
                    let first = UInt16(data[offset]), second = UInt16(data[offset + 1])
                    let value = littleEndian ? first | (second << 8) : (first << 8) | second
                    result.append(UInt8((Double(value) * 255.0 / 65535.0).rounded()))
                } else {
                    result.append(data[offset])
                }
            }
        }
    }
    return result
}

private func comparePNG(_ expected: URL, _ actual: URL, _ label: String) throws {
    let a = try image(expected)
    let b = try image(actual)
    try check(a.bitsPerComponent == 16 && b.bitsPerComponent == 16,
              "\(label): both outputs are 16-bit PNG")
    try check(a.width == b.width && a.height == b.height,
              "\(label): output dimensions match (\(a.width)x\(a.height))")
    try check(pixels(a) == pixels(b), "\(label): decoded PNG pixels match exactly")
}

private func writeJSON(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

private func inspectRecipe(_ data: Data, label: String, processing: ProcessingIdentity = .current) throws -> [String: Any] {
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    try check((root["schema_version"] as? NSNumber)?.intValue == 5,
              "\(label): agent emits schema_version 5")
    let identity = try dictionary(root["processing"], "processing")
    try check(identity["family"] as? String == processing.family &&
              (identity["version"] as? NSNumber)?.intValue == processing.version &&
              identity["quality"] as? String == processing.quality, "\(label): processing identity is preserved")
    let edits = try dictionary(root["edits"], "edits")
    _ = try dictionary(edits["exposure"], "edits.exposure")
    _ = try dictionary(edits["white_balance"], "edits.white_balance")
    let look = try dictionary(edits["look"], "edits.look")
    let tone = try dictionary(edits["tone"], "edits.tone")
    let detail = try dictionary(edits["detail"], "edits.detail")
    let hsl = try dictionary(edits["hsl"], "edits.hsl")
    let effects = try dictionary(edits["effects"], "edits.effects")
    let denoise = try dictionary(edits["denoise"], "edits.denoise")
    let wavelet = try dictionary(denoise["wavelet"], "edits.denoise.wavelet")
    if wavelet["enabled"] as? Bool == false {
        try check((wavelet["chroma"] as? NSNumber)?.intValue == 46 &&
                  (wavelet["coarse"] as? NSNumber)?.intValue == 50,
                  "\(label): omitted wavelet uses canonical disabled defaults")
    }
    _ = try dictionary(edits["lens_correction"], "edits.lens_correction")
    _ = try dictionary(edits["geometry"], "edits.geometry")
    let lookStrength = try number(look["strength"], "edits.look.strength")
    let sharpening = try number(detail["sharpening"], "edits.detail.sharpening")
    try check(lookStrength >= 0 && lookStrength <= 2,
              "\(label): look strength is bounded to 0...2")
    try check(sharpening >= 0 && sharpening <= 2,
              "\(label): sharpening is bounded to 0...2")
    for key in ["contrast", "saturation", "highlights", "shadows", "s_curve"] {
        _ = try number(tone[key], "edits.tone.\(key)")
    }
    for key in ["hue", "saturation", "lightness"] {
        let values = hsl[key] as? [NSNumber]
        try check(values?.count == 8, "\(label): HSL \(key) has eight channels")
    }
    for key in ["vignette_amount", "vignette_midpoint", "vignette_roundness", "vignette_feather",
                "vignette_highlights", "grain_amount", "grain_size", "grain_roughness"] {
        _ = try number(effects[key], "edits.effects.\(key)")
    }
    return root
}

private func rewriteOutput(_ recipe: [String: Any], output: URL) throws -> [String: Any] {
    var copy = recipe
    var outputObject = try dictionary(copy["output"], "output")
    outputObject["path"] = output.path
    copy["output"] = outputObject
    return copy
}

private func runCLI(_ cli: URL, recipe: URL, preview: URL? = nil, longEdge: Int? = nil,
                    lensDatabase: URL?) throws -> [String: Any] {
    let process = Process()
    process.executableURL = cli
    var arguments = ["--recipe", recipe.path]
    if let preview {
        arguments += ["--preview", preview.path, "--long-edge", String(longEdge ?? 257)]
    }
    arguments.append("--json")
    if let lensDatabase { arguments += ["--lens-database", lensDatabase.path] }
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let diagnostics = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw fail("CLI failed (\(process.terminationStatus)): \(diagnostics)")
    }
    let envelope = try JSONSerialization.jsonObject(with: output) as? [String: Any] ?? [:]
    try check((envelope["ok"] as? Bool) == true, "CLI returns a successful JSON envelope")
    return envelope
}

private func makeMixedSettings() -> Adjustments {
    var settings = Adjustments()
    settings.exposureMode = .preview
    settings.exposure = 0.37
    settings.whiteBalanceMode = .custom
    settings.temperature = 5200
    settings.tint = 12
    settings.strength = 0.85
    settings.blackPoint = -32.75; settings.whitePoint = 46.5; settings.vibrance = 21.25
    settings.contrast = 24.5
    settings.highlights = 31.5
    settings.shadows = -27.5
    settings.toneCurve = 36.5
    settings.saturation = -18.5
    settings.sharpening = 82.5
    settings.setHSL(.hue, channel: 0, value: 18)
    settings.setHSL(.saturation, channel: 5, value: -43)
    settings.setHSL(.lightness, channel: 3, value: 21)
    settings.setEffect(.vignetteAmount, to: -38)
    settings.setEffect(.vignetteMidpoint, to: 63)
    settings.setEffect(.vignetteRoundness, to: 22)
    settings.setEffect(.vignetteFeather, to: 71)
    settings.setEffect(.vignetteHighlights, to: 54)
    settings.setEffect(.grainAmount, to: 42)
    settings.setEffect(.grainSize, to: 57)
    settings.setEffect(.grainRoughness, to: 34)
    settings.applyDenoisePreset(.clean)
    settings.setDenoiseParameter(.luma, to: 23)
    settings.setDenoiseParameter(.chroma, to: 68)
    settings.setDenoiseParameter(.coarse, to: 81)
    var geometry = GeometrySettings()
    geometry.cropX = 0.08
    geometry.cropY = 0.06
    geometry.cropWidth = 0.84
    geometry.cropHeight = 0.87
    geometry.quarterTurns = 1
    geometry.flipHorizontal = true
    geometry.straightenDegrees = 3.5
    geometry.perspectiveHorizontal = 0.30
    geometry.perspectiveVertical = -0.20
    settings.geometry = geometry
    return settings
}

private func runAgentParity(_ context: AgentRecipeContext, engine: RenderEngine, input: URL,
                            settings: Adjustments, lut: URL?, label: String, edge: Int = 257,
                            previewCheck: Bool = false) throws -> URL {
    let apiOutput = context.root.appendingPathComponent("\(label)-api.png")
    let cliOutput = context.root.appendingPathComponent("\(label)-cli.png")
    let recipeURL = context.root.appendingPathComponent("\(label).json")
    let data = try engine.agentRecipe(input, settings: settings, lut: lut, output: apiOutput,
                                      exportLongEdge: edge)
    let recipe = try inspectRecipe(data, label: label, processing: settings.processing)
    do {
        _ = try engine.render(input, settings: settings, lut: lut, edge: nil, output: apiOutput,
                              exportLongEdge: edge)
    } catch {
        throw fail("\(label): GUI FINAL reference failed: \(error)")
    }
    try check(FileManager.default.fileExists(atPath: apiOutput.path), "\(label): GUI FINAL reference is written")
    let cliRecipe = try rewriteOutput(recipe, output: cliOutput)
    try writeJSON(cliRecipe, to: recipeURL)
    _ = try runCLI(context.cli, recipe: recipeURL, lensDatabase: context.lensDatabase)
    try comparePNG(apiOutput, cliOutput, "\(label) GUI/CLI")

    let directOutput = context.root.appendingPathComponent("\(label)-direct.png")
    let direct = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: context.lensDatabase)
    _ = try direct.render(input, settings: settings, lut: lut, edge: nil, output: directOutput,
                          exportLongEdge: edge)
    try comparePNG(apiOutput, directOutput, "\(label) agent/direct FINAL")

    if previewCheck {
        let preview = context.root.appendingPathComponent("\(label)-preview.png")
        let envelope = try runCLI(context.cli, recipe: recipeURL, preview: preview, longEdge: edge,
                                  lensDatabase: context.lensDatabase)
        let result = try dictionary(envelope["result"], "CLI result")
        try check((result["quality"] as? String) == "exact" &&
                  (result["long_edge"] as? NSNumber)?.intValue == edge,
                  "\(label): CLI exact preview reports requested long edge")
        try comparePNG(apiOutput, preview, "\(label) exact preview")
    }
    return apiOutput
}

private func runBatchFrozen(_ context: AgentRecipeContext, input: URL, settings: Adjustments,
                            lut: URL?, expected: URL) throws {
    let journal = BatchJournal(directory: context.root.appendingPathComponent("batch-journal"))
    var job = BatchExportJob(source: input, settings: settings, look: lut, lookName: "Agent")
    job.outputDirectory = context.root
    job.format = .png
    job.longEdge = 257
    var item = try BatchExportItem(url: input)
    item.selected = true
    job.items = [item]
    try journal.save(job)
    let restored = try journal.load()
    try check(restored?.settings == settings && restored?.longEdge == 257,
              "batch journal freezes complete settings and output size")
    var calls = 0
    let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: context.lensDatabase)
    try BatchExportRunner.run(job: &job, journal: journal, scope: .unfinished, shouldCancel: { false }) {
        target, frozen, frozenLook, output in
        calls += 1
        try check(frozen == settings && frozenLook == lut, "batch render receives frozen settings and LUT")
        _ = try engine.render(target, settings: frozen, lut: frozenLook, edge: nil, output: output,
                              exportLongEdge: 257)
    }
    try check(calls == 1 && job.succeededCount == 1, "batch FINAL render completes one frozen item")
    guard let output = job.items.first?.output else { throw fail("batch did not publish output") }
    try comparePNG(expected, output, "batch/single FINAL")
}

private func runPersistence(_ context: AgentRecipeContext, input: URL, settings: Adjustments,
                            lut: URL?, engine: RenderEngine) throws {
    let directory = context.root.appendingPathComponent("edits")
    let store = try EditPersistence(directory: directory)
    try store.save(input, state: PhotoEditState(settings: settings, filmID: "", masterRecipeID: settings.masterRecipeID))
    let reopened = try EditPersistence(directory: directory)
    guard let restored = try reopened.state(for: input) else { throw fail("edit persistence returned no state") }
    try check(restored.settings == settings && restored.masterRecipeID == settings.masterRecipeID,
              "persistent recipe state restores without mutation")
    let output = context.root.appendingPathComponent("persisted.png")
    _ = try engine.agentRecipe(input, settings: restored.settings, lut: lut, output: output, exportLongEdge: 257)
    _ = try engine.render(input, settings: restored.settings, lut: lut, edge: nil, output: output,
                          exportLongEdge: 257)
    try check(FileManager.default.fileExists(atPath: output.path), "restored settings produce FINAL output")
}

private func runLensCase(_ context: AgentRecipeContext) throws {
    guard FileManager.default.fileExists(atPath: context.lensRaw.path),
          FileManager.default.fileExists(atPath: context.lensDatabase.path) else { return }
    let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: context.lensDatabase)
    let baseline = try engine.render(context.lensRaw, settings: Adjustments(), lut: nil, edge: 64)
    guard let candidate = baseline?.lensInfo?.candidates.first(where: { $0.isMatch && $0.hasDistortion }) else {
        throw fail("lens fixture did not expose a matching distortion profile")
    }
    var settings = Adjustments()
    settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: candidate.hasTCA,
                                                      autoCrop: true, mode: .manual, profileID: candidate.id)
    let recipeData = try engine.agentRecipe(context.lensRaw, settings: settings, lut: nil,
                                            output: context.root.appendingPathComponent("lens-api.png"))
    let recipe = try inspectRecipe(recipeData, label: "lens-manual")
    let cliOutput = context.root.appendingPathComponent("lens-cli.png")
    let recipeURL = context.root.appendingPathComponent("lens.json")
    try writeJSON(try rewriteOutput(recipe, output: cliOutput), to: recipeURL)
    let envelope = try runCLI(context.cli, recipe: recipeURL, lensDatabase: context.lensDatabase)
    let result = try dictionary(envelope["result"], "result")
    let lens = try dictionary(result["lens_correction"], "result.lens_correction")
    try check(lens["applied_distortion"] as? Bool == true, "Agent reports actual applied lens correction")
    let gui = try engine.render(context.lensRaw, settings: settings, lut: nil, edge: nil)!
    let cli = try image(cliOutput)
    try check(gui.lensInfo?.appliedDistortion == true,
              "lens synthetic fixture applies the selected distortion profile")
    try check(cli.bitsPerComponent == 16, "lens CLI output remains a 16-bit PNG")
    try check(gui.image.width == cli.width && gui.image.height == cli.height,
              "lens GUI FINAL buffer and CLI output dimensions match")
    let guiPixels = rgb8(gui.image)
    let cliPixels = rgb8(cli)
    let maximum = zip(guiPixels, cliPixels).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
    try check(guiPixels.count == cliPixels.count && maximum <= 1,
              "lens GUI RGBA8 FINAL and CLI 16-bit pixels agree after quantization (max \(maximum))")
}

@main
struct AgentRecipeRenderTests {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { throw fail("usage: AgentRecipeRenderTests INPUT_RAW CLI") }
        let input = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let cli = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let environment = ProcessInfo.processInfo.environment
        let repository = URL(fileURLWithPath: environment["RAWLAB_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath)
        let lensDatabase = URL(fileURLWithPath: environment["RAWLAB_LENS_DATABASE"] ??
                               repository.appendingPathComponent("lutools/tests/fixtures/lenses.xml").path)
        let lensRaw = URL(fileURLWithPath: environment["RAWLAB_LENS_RAW"] ??
                          repository.appendingPathComponent("lutools/tests/fixtures/linear-lens.dng").path)
        guard FileManager.default.isReadableFile(atPath: input.path) else { throw fail("input RAW is unreadable") }
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw fail("CLI is not executable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-agent-recipe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AgentRecipeContext(root: root, cli: cli, lensDatabase: lensDatabase, lensRaw: lensRaw)
        if arguments.contains("--lens-only") {
            try runLensCase(context)
            print("PASS: lens-only agent recipe evidence complete")
            return
        }
        let original = try OriginalFileIdentity(input)
        if arguments.contains("--bundled-looks-only") {
            let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: lensDatabase)
            let metal = try RenderEngine(gpuMode: SONY2FUJI_GPU_FORCE, lensDatabaseURL: lensDatabase)
            let reference = try cpu.render(input, settings: Adjustments(), lut: nil, edge: 128)!
            for look in BundledLook.all {
                let file = repository.appendingPathComponent("Shared/BundledLooks/" + look.fileName)
                for strength in [0.0, 1.0, 2.0] {
                    var settings = Adjustments()
                    settings.strength = strength
                    let actual = try cpu.render(input, settings: settings, lut: file, edge: 128)!
                    let gpu = try metal.render(input, settings: settings, lut: file, edge: 128)!
                    let a = rgb8(actual.image), b = rgb8(gpu.image)
                    let difference = zip(a, b).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
                    try check(a.count == b.count && difference <= 2 && metal.lastBackend == SONY2FUJI_BACKEND_METAL,
                              "\(look.name) \(Int(strength * 100))% forced Metal max \(difference) DN")
                    if strength == 0 {
                        try check(rgb8(reference.image) == a, "\(look.name): zero is exactly neutral")
                    }
                }
            }
            for id in ["EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65", "RawLab_camera_contax_nd_std_sRGB_v1", "RawLab_look_2383_sRGB_v1"] {
                guard let look = BundledLook.find(id) else { throw fail("Missing catalog identity: \(id)") }
                let file = repository.appendingPathComponent("Shared/BundledLooks/" + look.fileName)
                let settings = Adjustments()
                let output = try runAgentParity(context, engine: cpu, input: input, settings: settings,
                                                lut: file, label: id, previewCheck: true)
                try runBatchFrozen(context, input: input, settings: settings, lut: file, expected: output)
                let store = try EditPersistence(directory: root.appendingPathComponent("edits-" + id))
                let identity = "builtin:" + look.fileName
                try store.save(input, state: PhotoEditState(settings: settings, filmID: identity, masterRecipeID: nil))
                try check(try store.state(for: input)?.filmID == identity, "\(look.name): stable builtin identity persists")
            }
            try check(try OriginalFileIdentity(input) == original, "Source RAW remains unchanged")
            return
        }
        let lut = repository.appendingPathComponent("lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube")
        guard FileManager.default.fileExists(atPath: lut.path) else { throw fail("PROVIA LUT is missing") }

        let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: lensDatabase)
        let mixed = makeMixedSettings()
        let mixedOutput = try runAgentParity(context, engine: cpu, input: input, settings: mixed,
                                             lut: lut, label: "mixed", previewCheck: true)
        var legacy = mixed
        legacy.processing = .legacy
        _ = try runAgentParity(context, engine: cpu, input: input, settings: legacy,
                               lut: lut, label: "legacy-processing", previewCheck: true)
        let recipeLUT = MasterRecipe.hamadaDaylightV2.lutURL()!

        var clamped = Adjustments()
        clamped.applyMasterRecipe(.hamadaDaylightV2)
        clamped.strength = 2
        clamped.contrast = 150
        clamped.saturation = -100
        clamped.highlights = 100
        clamped.shadows = -100
        clamped.toneCurve = 100
        clamped.sharpening = 200
        let clampData = try cpu.agentRecipe(input, settings: clamped, lut: recipeLUT,
                                            output: root.appendingPathComponent("clamped.png"), exportLongEdge: 257)
        let clampRecipe = try inspectRecipe(clampData, label: "core-clamp")
        let clampTone = try dictionary(try dictionary(clampRecipe["edits"], "edits")["tone"], "edits.tone")
        let clampDetail = try dictionary(try dictionary(clampRecipe["edits"], "edits")["detail"], "edits.detail")
        let contrast = try number(clampTone["contrast"], "contrast")
        let saturation = try number(clampTone["saturation"], "saturation")
        let highlights = try number(clampTone["highlights"], "highlights")
        let shadows = try number(clampTone["shadows"], "shadows")
        let sCurve = try number(clampTone["s_curve"], "s_curve")
        let clampedSharpening = try number(clampDetail["sharpening"], "sharpening")
        try check(contrast == 2 && saturation == 0 && highlights == -1 && shadows == -1 &&
                  sCurve == 1 && clampedSharpening == 2,
                  "agent v4 emits core-clamped tone and detail values")

        var oldChroma = mixed
        oldChroma.waveletNoiseReduction = nil
        oldChroma.chromaNoiseReduction = 2
        oldChroma.rawNoiseReduction = 0
        oldChroma.geometry = nil
        _ = try runAgentParity(context, engine: cpu, input: input, settings: oldChroma,
                               lut: nil, label: "legacy-chroma", edge: 257)

        var recipeSettings = Adjustments()
        recipeSettings.applyMasterRecipe(.hamadaDaylightV2)
        var oneOutput: URL?
        for strength in [0.0, 0.5, 1.0, 2.0] {
            recipeSettings.strength = strength
            let output = try runAgentParity(context, engine: cpu, input: input, settings: recipeSettings,
                                            lut: recipeLUT, label: "recipe-\(Int(strength * 100))", edge: 257)
            if strength == 1 { oneOutput = output }
        }
        guard let oneOutput else { throw fail("recipe 100% output was not captured") }
        recipeSettings.strength = 1
        try runPersistence(context, input: input, settings: recipeSettings, lut: recipeLUT, engine: cpu)
        try runBatchFrozen(context, input: input, settings: recipeSettings, lut: recipeLUT, expected: oneOutput)
        try runLensCase(context)
        let finalIdentity = try OriginalFileIdentity(input)
        try check(finalIdentity == original, "source RAW identity remains unchanged")
        print("PASS: agent recipe FINAL parity, v4 controls, recipes, persistence, batch and lens coverage")
        _ = mixedOutput
    }
}
