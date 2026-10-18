import AppKit
import Foundation
import ImageIO

func mixedSettings() -> Adjustments {
    var settings = Adjustments()
    settings.exposureMode = .sensor
    settings.exposure = 0.27
    settings.contrast = 23.5
    settings.highlights = 31.0
    settings.shadows = -24.0
    settings.toneCurve = 35.0
    settings.saturation = -17.0
    settings.sharpening = 78.0
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

func chromaSettings(from source: Adjustments) -> Adjustments {
    var result = source
    result.waveletNoiseReduction = nil
    result.chromaNoiseReduction = 2
    result.rawNoiseReduction = 0
    return result
}

func renderReference(_ engine: RenderEngine, input: URL, settings: Adjustments,
                            output: URL, edge: Int, lut: URL? = nil) throws {
    _ = try engine.render(input, settings: settings, lut: lut, edge: nil,
                          output: output, exportLongEdge: edge)
    try check(FileManager.default.fileExists(atPath: output.path),
              "GUI FINAL writes raster reference")
}


func runRasterCase(_ context: RasterContext, fixture: RasterFixture,
                           engine: RenderEngine, settings: Adjustments, lut: URL? = nil) throws -> URL {
    let label = fixture.label
    let edge = 48
    let info = try invokeCLI(context.cli, arguments: ["--info", fixture.url.path, "--json"])
    let metadata = info["result"] as? [String: Any] ?? [:]
    try check(metadata["input_type"] as? String == "raster" &&
              metadata["color_space"] as? String == "srgb" &&
              metadata["bits_per_component"] as? Int == 8,
              "\(label): Agent info reports display raster semantics")
    for key in ["camera", "lens", "capture", "as_shot_white_balance"] {
        try check(metadata[key] is NSNull, "\(label): Agent info does not invent RAW \(key)")
    }
    let guiOutput = context.root.appendingPathComponent("\(label)-gui.png")
    let cliOutput = context.root.appendingPathComponent("\(label)-cli.png")
    let recipeURL = context.root.appendingPathComponent("\(label).json")
    let agentData = try engine.agentRecipe(fixture.url, settings: settings, lut: lut,
                                           output: guiOutput, exportLongEdge: edge)
    let recipe = try inspectRasterRecipe(agentData, input: fixture.url, label: label)
    try check(!FileManager.default.fileExists(atPath: guiOutput.path),
              "\(label): agent recipe Data API has no output side effect")
    try renderReference(engine, input: fixture.url, settings: settings, output: guiOutput, edge: edge, lut: lut)
    let cliRecipe = try rewriteOutput(recipe, output: cliOutput)
    try writeJSON(cliRecipe, to: recipeURL)
    let _ = try runCLI(context.cli, recipe: recipeURL)
    try comparePNG(guiOutput, cliOutput, "\(label) GUI/Agent CLI")

    let directOutput = context.root.appendingPathComponent("\(label)-direct.png")
    let direct = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
    try renderReference(direct, input: fixture.url, settings: settings, output: directOutput, edge: edge, lut: lut)
    try comparePNG(guiOutput, directOutput, "\(label) GUI/CPU")

    let autoOutput = context.root.appendingPathComponent("\(label)-auto.png")
    let auto = try RenderEngine(gpuMode: SONY2FUJI_GPU_AUTO)
    try renderReference(auto, input: fixture.url, settings: settings, output: autoOutput, edge: edge, lut: lut)
    try comparePNG(guiOutput, autoOutput, "\(label) GUI/Auto")
    try check(auto.lastBackend == SONY2FUJI_BACKEND_CPU,
              "\(label): Auto explicitly falls back to CPU for display raster")

    let preview = context.root.appendingPathComponent("\(label)-preview.png")
    let envelope = try runCLI(context.cli, recipe: recipeURL, preview: preview, edge: edge)
    let result = try dictionary(envelope["result"], "CLI result")
    try check((result["quality"] as? String) == "exact" &&
              (result["long_edge"] as? NSNumber)?.intValue == edge,
              "\(label): exact preview reports the requested size")
    try comparePNG(guiOutput, preview, "\(label) exact preview")

    var forceRejected = false
    do {
        let force = try RenderEngine(gpuMode: SONY2FUJI_GPU_FORCE)
        _ = try force.render(fixture.url, settings: settings, lut: lut, edge: nil,
                             output: context.root.appendingPathComponent("\(label)-force.png"),
                             exportLongEdge: edge)
    } catch { forceRejected = true }
    try check(forceRejected, "\(label): forced GPU rejects unsupported display raster")

    try assertMetadataAndThumbnail(fixture.url, output: guiOutput, label: label)
    return guiOutput
}

func runPersistence(_ context: RasterContext, input: URL, settings: Adjustments,
                            expected: URL, engine: RenderEngine) throws {
    let directory = context.root.appendingPathComponent("raster-edits")
    let store = try EditPersistence(directory: directory)
    try store.save(input, state: PhotoEditState(settings: settings, filmID: "raster", masterRecipeID: nil))
    let reopened = try EditPersistence(directory: directory)
    guard let restored = try reopened.state(for: input) else { throw fail("raster edit persistence returned no state") }
    try check(restored.settings == settings, "raster persistence restores all settings")
    let output = context.root.appendingPathComponent("raster-persisted.png")
    try renderReference(engine, input: input, settings: restored.settings, output: output, edge: 48)
    try comparePNG(expected, output, "raster persistence FINAL")
}

func runMixedBatch(_ context: RasterContext, raster: URL, expectedRaster: URL,
                           settings: Adjustments, engine: RenderEngine) throws {
    let directory = context.root.appendingPathComponent("raster-batch")
    let journal = BatchJournal(directory: context.root.appendingPathComponent("raster-batch-journal"))
    var job = BatchExportJob(source: context.raw, settings: settings, look: nil, lookName: "Raster")
    job.outputDirectory = directory
    job.format = .png
    job.longEdge = 48
    var rawItem = try BatchExportItem(url: context.raw)
    rawItem.selected = true
    var rasterItem = try BatchExportItem(url: raster)
    rasterItem.selected = true
    job.items = [rawItem, rasterItem]
    try journal.save(job)
    guard let frozen = try journal.load() else { throw fail("mixed batch journal did not reload") }
    try check(frozen.items.map(\.input) == [context.raw.standardizedFileURL, raster.standardizedFileURL] &&
              frozen.settings == settings && frozen.longEdge == 48,
              "mixed RAW+raster batch freezes both inputs and settings")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var calls = 0
    try BatchExportRunner.run(job: &job, journal: journal, scope: .unfinished, shouldCancel: { false }) {
        input, frozenSettings, _, output in
        calls += 1
        _ = try engine.render(input, settings: frozenSettings, lut: nil, edge: nil,
                              output: output, exportLongEdge: 48)
    }
    try check(calls == 2 && job.succeededCount == 2,
              "mixed RAW+raster batch publishes both frozen FINAL outputs")
    guard let rasterOutput = job.items.first(where: { $0.input == raster.standardizedFileURL })?.output else {
        throw fail("mixed batch did not publish a raster output")
    }
    try comparePNG(expectedRaster, rasterOutput, "mixed batch raster FINAL")
    try check(try OriginalFileIdentity(raster) == rasterItem.identity,
              "mixed batch leaves raster source identity unchanged")
}

@main
struct RasterRenderTests {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            throw fail("usage: RasterRenderTests INPUT_RAW CLI")
        }
        let contextRoot = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("rawlab-raster-\(UUID())")
        try FileManager.default.createDirectory(at: contextRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: contextRoot) }
        let context = RasterContext(root: contextRoot,
                                    cli: URL(fileURLWithPath: arguments[2]).standardizedFileURL,
                                    raw: URL(fileURLWithPath: arguments[1]).standardizedFileURL)
        guard FileManager.default.isReadableFile(atPath: context.raw.path) else {
            throw fail("input RAW is unreadable")
        }
        guard FileManager.default.isExecutableFile(atPath: context.cli.path) else {
            throw fail("CLI is not executable")
        }
        let rawIdentity = try OriginalFileIdentity(context.raw)
        let fixtures = try makeFixtures(in: contextRoot)
        guard let primary = fixtures.first(where: { $0.label == "png" }) else {
            throw fail("PNG fixture was not generated")
        }
        let primaryIdentity = try OriginalFileIdentity(primary.url)
        let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        try assertMacFailureSemantics(context, raster: primary.url, engine: cpu)
        try assertNeutralNoDoubleGamma(primary.url, primary.label, engine: cpu, root: contextRoot)
        try runRejectedRasterCases(context, engine: cpu)
        let settings = mixedSettings()
        var outputs: [String: URL] = [:]
        for fixture in fixtures {
            outputs[fixture.label] = try runRasterCase(context, fixture: fixture, engine: cpu, settings: settings)
        }
        var master = settings
        master.applyMasterRecipe(.hamadaDaylightV2)
        let masterLUT = MasterRecipe.hamadaDaylightV2.lutURL()!
        for strength in [0.0, 0.5, 1.0, 2.0] {
            master.strength = strength
            let fixture = RasterFixture(url: primary.url, label: "png-master-\(Int(strength * 100))", oriented: primary.oriented)
            _ = try runRasterCase(context, fixture: fixture, engine: cpu, settings: master, lut: masterLUT)
        }
        if let primaryOutput = outputs[primary.label] {
            try expectProtectedAliases(context, input: primary.url, settings: settings, engine: cpu, label: primary.label)
            try runPersistence(context, input: primary.url, settings: settings,
                               expected: primaryOutput, engine: cpu)
            var chroma = chromaSettings(from: settings)
            chroma.geometry = nil
            let chromaFixture = RasterFixture(url: primary.url, label: "png-chroma", oriented: primary.oriented)
            let chromaOutput = try runRasterCase(context, fixture: chromaFixture, engine: cpu, settings: chroma)
            try check(pixelData(try image(chromaOutput)) != pixelData(try image(primaryOutput)),
                      "PNG: legacy display-chroma denoise changes the FINAL pixels")
            try runMixedBatch(context, raster: primary.url, expectedRaster: primaryOutput,
                              settings: settings, engine: cpu)
        }
        try check(try OriginalFileIdentity(context.raw) == rawIdentity,
                  "input RAW identity remains unchanged after raster runs")
        try check(try OriginalFileIdentity(primary.url) == primaryIdentity,
                  "primary raster identity remains unchanged after raster runs")
        print("PASS: raster GUI/Agent/Batch/Persist, metadata, thumbnails, geometry and source protection")
    }
}
