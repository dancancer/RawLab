import AppKit
import Foundation
import ImageIO

private struct RasterFixture {
    let url: URL
    let label: String
    let oriented: Bool
}

private struct RasterContext {
    let root: URL
    let cli: URL
    let raw: URL
}

private func fail(_ message: String) -> RenderError {
    .failed("Raster render test: \(message)")
}

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw fail(message) }
    print("PASS: \(message)")
}

private func image(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let result = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw fail("cannot decode \(url.lastPathComponent)")
    }
    return result
}

private func properties(_ url: URL) throws -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        throw fail("cannot read ImageIO metadata for \(url.lastPathComponent)")
    }
    return values
}

private func pixelData(_ image: CGImage) -> Data {
    image.dataProvider!.data! as Data
}

private func renderedRGB8(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: &bytes, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue |
                                      CGBitmapInfo.byteOrder32Big.rawValue) else {
        return []
    }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (0..<(image.width * image.height)).flatMap { Array(bytes[($0 * 4)..<($0 * 4 + 3)]) }
}

private func comparePNG(_ expected: URL, _ actual: URL, _ label: String) throws {
    let a = try image(expected)
    let b = try image(actual)
    try check(a.bitsPerComponent == 16 && b.bitsPerComponent == 16,
              "\(label): both outputs are 16-bit PNG")
    try check(a.width == b.width && a.height == b.height,
              "\(label): output dimensions match (\(a.width)x\(a.height))")
    try check(pixelData(a) == pixelData(b), "\(label): decoded PNG pixels match exactly")
}

private func writeImage(_ image: CGImage, to url: URL, type: CFString,
                        properties: [CFString: Any]) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination)
}

private func fixtureImage() -> CGImage {
    let width = 96
    let height = 64
    var bytes = [UInt8](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 3
            bytes[offset] = UInt8((x * 5 + y * 3 + (x * y) / 17) & 255)
            bytes[offset + 1] = UInt8((y * 7 + x * 2 + 31) & 255)
            bytes[offset + 2] = UInt8((x * 3 + y * 11 + (x + y) * 2) & 255)
        }
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                   bytesPerRow: width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

private func fixtureAlphaImage() -> CGImage {
    let bytes: [UInt8] = [255, 40, 20, 127, 20, 180, 255, 127]
    return CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

private func fixture16BitImage() -> CGImage {
    let values: [UInt16] = [0x0123, 0x4567, 0x89ab, 0xcdef, 0x1357, 0x9bdf]
    var bytes = [UInt8]()
    for value in values { bytes += [UInt8(value >> 8), UInt8(value & 255)] }
    return CGImage(width: 2, height: 1, bitsPerComponent: 16, bitsPerPixel: 48,
                   bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

private func fixtureProperties(oriented: Bool) -> [CFString: Any] {
    let orientation: UInt32 = oriented ? 6 : 1
    let tiff: [CFString: Any] = [
        kCGImagePropertyTIFFMake: "RawLab Fixture Camera",
        kCGImagePropertyTIFFModel: "RawLab Raster 1",
        kCGImagePropertyTIFFImageDescription: "rawlab-raster-metadata",
        kCGImagePropertyTIFFDateTime: "2026:10:15 12:34:56"
    ]
    let exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: "2026:10:15 12:34:56",
        kCGImagePropertyExifLensModel: "RawLab Fixture 35mm",
        kCGImagePropertyExifISOSpeedRatings: [400],
        kCGImagePropertyExifFNumber: 2.8
    ]
    return [kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyExifDictionary: exif]
}

private func makeFixtures(in root: URL) throws -> [RasterFixture] {
    let source = fixtureImage()
    let metadata = fixtureProperties(oriented: true)
    var result: [RasterFixture] = []
    let definitions: [(String, CFString)] = [
        ("png", "public.png" as CFString),
        ("jpg", "public.jpeg" as CFString),
        ("tiff", "public.tiff" as CFString)
    ]
    for (suffix, type) in definitions {
        let url = root.appendingPathComponent("raster-\(suffix).\(suffix)")
        guard writeImage(source, to: url, type: type, properties: metadata) else {
            throw fail("system encoder could not create \(suffix) fixture")
        }
        result.append(RasterFixture(url: url, label: suffix, oriented: true))
    }
    let heif = root.appendingPathComponent("raster-heic.heic")
    if writeImage(source, to: heif, type: "public.heic" as CFString, properties: metadata) {
        result.append(RasterFixture(url: heif, label: "heif", oriented: true))
    } else {
        print("SKIP: HEIF system encoder unavailable")
    }
    return result
}

private func expectRasterFailure(_ context: RasterContext, engine: RenderEngine, input: URL,
                                 label: String) throws {
    var rejected = false
    do {
        _ = try engine.render(input, settings: Adjustments(), lut: nil, edge: nil,
                              output: context.root.appendingPathComponent("rejected-\(label).png"),
                              exportLongEdge: 48)
    } catch { rejected = true }
    try check(rejected, "\(label): GUI rejects unsupported raster input")

    var settings = Adjustments()
    settings.exposureMode = .sensor
    let recipeData = try engine.agentRecipe(input, settings: settings, lut: nil,
                                             output: context.root.appendingPathComponent("rejected-api.png"),
                                             exportLongEdge: 48)
    let recipe = try inspectRasterRecipe(recipeData, input: input, label: "rejected-\(label)")
    let recipeURL = context.root.appendingPathComponent("rejected-\(label).json")
    try writeJSON(try rewriteOutput(recipe,
                                    output: context.root.appendingPathComponent("rejected-\(label)-cli.png")),
                  to: recipeURL)
    try expectCLIFailure(context.cli, recipe: recipeURL, "\(label)")
}

private func runRejectedRasterCases(_ context: RasterContext, engine: RenderEngine) throws {
    let alpha = context.root.appendingPathComponent("rejected-alpha.png")
    guard writeImage(fixtureAlphaImage(), to: alpha, type: "public.png" as CFString, properties: [:]) else {
        throw fail("could not create alpha fixture")
    }
    try expectRasterFailure(context, engine: engine, input: alpha, label: "alpha")

    let highBit = context.root.appendingPathComponent("rejected-16bit.png")
    guard writeImage(fixture16BitImage(), to: highBit, type: "public.png" as CFString, properties: [:]) else {
        throw fail("could not create 16-bit fixture")
    }
    try expectRasterFailure(context, engine: engine, input: highBit, label: "16-bit")

    let corrupt = context.root.appendingPathComponent("rejected-corrupt.png")
    try Data("not an image".utf8).write(to: corrupt, options: .atomic)
    try expectRasterFailure(context, engine: engine, input: corrupt, label: "corrupt")
}

private func thumbnail(_ url: URL) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 32,
        kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

private func dictionary(_ value: Any?, _ path: String) throws -> [String: Any] {
    guard let value = value as? [String: Any] else { throw fail("\(path) is not an object") }
    return value
}

private func rewriteOutput(_ recipe: [String: Any], output: URL) throws -> [String: Any] {
    var result = recipe
    var outputObject = try dictionary(result["output"], "output")
    outputObject["path"] = output.path
    result["output"] = outputObject
    return result
}

private func writeJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
}

private func invokeCLI(_ cli: URL, arguments: [String]) throws -> [String: Any] {
    let process = Process()
    process.executableURL = cli
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

private func runCLI(_ cli: URL, recipe: URL, preview: URL? = nil, edge: Int? = nil) throws -> [String: Any] {
    var arguments = ["--recipe", recipe.path]
    if let preview {
        arguments += ["--preview", preview.path, "--long-edge", String(edge ?? 48)]
    }
    return try invokeCLI(cli, arguments: arguments + ["--json"])
}

private func expectCLIFailure(_ cli: URL, recipe: URL, _ label: String) throws {
    let process = Process()
    process.executableURL = cli
    process.arguments = ["--recipe", recipe.path, "--json"]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    try check(process.terminationStatus != 0, "\(label): CLI rejects the protected alias")
}

private func inspectRasterRecipe(_ data: Data, input: URL, label: String) throws -> [String: Any] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw fail("\(label): agent recipe is not an object")
    }
    try check((root["schema_version"] as? NSNumber)?.intValue == 4,
              "\(label): agent emits schema_version 4")
    let inputObject = try dictionary(root["input"], "input")
    try check(inputObject["type"] as? String == "raster" &&
              inputObject["path"] as? String == input.standardizedFileURL.path,
              "\(label): v4 declares the raster input type and absolute path")
    let edits = try dictionary(root["edits"], "edits")
    let exposure = try dictionary(edits["exposure"], "edits.exposure")
    let wb = try dictionary(edits["white_balance"], "edits.white_balance")
    try check(exposure["mode"] as? String == "sensor" && wb["mode"] as? String == "none",
              "\(label): raster recipe uses sensor exposure identity and no WB")
    _ = try dictionary(edits["tone"], "edits.tone")
    _ = try dictionary(edits["detail"], "edits.detail")
    _ = try dictionary(edits["hsl"], "edits.hsl")
    _ = try dictionary(edits["effects"], "edits.effects")
    _ = try dictionary(edits["denoise"], "edits.denoise")
    _ = try dictionary(edits["geometry"], "edits.geometry")
    return root
}

private func mixedSettings() -> Adjustments {
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

private func chromaSettings(from source: Adjustments) -> Adjustments {
    var result = source
    result.waveletNoiseReduction = nil
    result.chromaNoiseReduction = 2
    result.rawNoiseReduction = 0
    return result
}

private func renderReference(_ engine: RenderEngine, input: URL, settings: Adjustments,
                            output: URL, edge: Int) throws {
    _ = try engine.render(input, settings: settings, lut: nil, edge: nil,
                          output: output, exportLongEdge: edge)
    try check(FileManager.default.fileExists(atPath: output.path),
              "GUI FINAL writes raster reference")
}

private func assertMetadataAndThumbnail(_ input: URL, output: URL, label: String) throws {
    let sourceValues = try properties(input)
    let sourceTIFF = sourceValues[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    try check(sourceTIFF?[kCGImagePropertyTIFFImageDescription] as? String == "rawlab-raster-metadata",
              "\(label): source metadata is readable")
    guard let thumb = thumbnail(input) else { throw fail("\(label): ImageIO thumbnail is unavailable") }
    try check(thumb.width > 0 && thumb.height > 0 && max(thumb.width, thumb.height) == 32,
              "\(label): oriented thumbnail path is available")
    let values = try properties(output)
    let tiff = values[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    try check(tiff?[kCGImagePropertyTIFFImageDescription] as? String == "rawlab-raster-metadata",
              "\(label): GUI FINAL preserves capture metadata")
}

private func assertNeutralNoDoubleGamma(_ input: URL, _ label: String, engine: RenderEngine,
                                        root: URL) throws {
    let neutral = root.appendingPathComponent("\(label)-neutral.png")
    var settings = Adjustments()
    settings.exposureMode = .sensor
    try renderReference(engine, input: input, settings: settings, output: neutral, edge: 10000)
    let source = try image(input)
    let sourcePixels = renderedRGB8(source)
    let orientation = (try properties(input)[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    try check(orientation == 6 || orientation == 1, "neutral fixture has a known test orientation")
    let width = orientation == 6 ? source.height : source.width
    let height = orientation == 6 ? source.width : source.height
    var expectedPixels = [UInt8]()
    for y in 0..<height {
        for x in 0..<width {
            let sx = orientation == 6 ? y : x
            let sy = orientation == 6 ? source.height - 1 - x : y
            let offset = (sy * source.width + sx) * 3
            expectedPixels += sourcePixels[offset..<(offset + 3)]
        }
    }
    let actual = try image(neutral)
    let actualPixels = renderedRGB8(actual)
    let maximum = zip(expectedPixels, actualPixels).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
    try check(actual.width == width && actual.height == height &&
              expectedPixels.count == actualPixels.count && maximum <= 1,
              "\(label): neutral raster preserves oriented sRGB without RAW baseline or double gamma (max \(maximum))")
}

private func expectProtectedAliases(_ context: RasterContext, input: URL, settings: Adjustments,
                                    engine: RenderEngine, label: String) throws {
    let original = try Data(contentsOf: input)
    let alias = context.root.appendingPathComponent("\(label)-hardlink.\(input.pathExtension)")
    try FileManager.default.linkItem(at: input, to: alias)
    defer { try? FileManager.default.removeItem(at: alias) }
    var rejected = false
    do {
        _ = try engine.render(input, settings: settings, lut: nil, edge: nil, output: alias, exportLongEdge: 48)
    } catch { rejected = true }
    try check(rejected, "\(label): GUI rejects a hard-link output alias")
    try check(try Data(contentsOf: input) == original, "\(label): source is unchanged after GUI alias rejection")

    var recipeSettings = settings
    recipeSettings.geometry = nil
    let recipeData = try engine.agentRecipe(input, settings: recipeSettings, lut: nil,
                                             output: context.root.appendingPathComponent("alias-api.png"),
                                             exportLongEdge: 48)
    let recipe = try inspectRasterRecipe(recipeData, input: input, label: "\(label)-alias")
    let recipeURL = context.root.appendingPathComponent("\(label)-alias.json")
    try writeJSON(try rewriteOutput(recipe, output: alias), to: recipeURL)
    try expectCLIFailure(context.cli, recipe: recipeURL, "\(label)")
    try check(try Data(contentsOf: input) == original, "\(label): source is unchanged after CLI alias rejection")
}

private func runRasterCase(_ context: RasterContext, fixture: RasterFixture,
                           engine: RenderEngine, settings: Adjustments) throws -> URL {
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
    let agentData = try engine.agentRecipe(fixture.url, settings: settings, lut: nil,
                                           output: guiOutput, exportLongEdge: edge)
    let recipe = try inspectRasterRecipe(agentData, input: fixture.url, label: label)
    try check(!FileManager.default.fileExists(atPath: guiOutput.path),
              "\(label): agent recipe Data API has no output side effect")
    try renderReference(engine, input: fixture.url, settings: settings, output: guiOutput, edge: edge)
    let cliRecipe = try rewriteOutput(recipe, output: cliOutput)
    try writeJSON(cliRecipe, to: recipeURL)
    let _ = try runCLI(context.cli, recipe: recipeURL)
    try comparePNG(guiOutput, cliOutput, "\(label) GUI/Agent CLI")

    let directOutput = context.root.appendingPathComponent("\(label)-direct.png")
    let direct = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
    try renderReference(direct, input: fixture.url, settings: settings, output: directOutput, edge: edge)
    try comparePNG(guiOutput, directOutput, "\(label) GUI/CPU")

    let autoOutput = context.root.appendingPathComponent("\(label)-auto.png")
    let auto = try RenderEngine(gpuMode: SONY2FUJI_GPU_AUTO)
    try renderReference(auto, input: fixture.url, settings: settings, output: autoOutput, edge: edge)
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
        _ = try force.render(fixture.url, settings: settings, lut: nil, edge: nil,
                             output: context.root.appendingPathComponent("\(label)-force.png"),
                             exportLongEdge: edge)
    } catch { forceRejected = true }
    try check(forceRejected, "\(label): forced GPU rejects unsupported display raster")

    try assertMetadataAndThumbnail(fixture.url, output: guiOutput, label: label)
    return guiOutput
}

private func runPersistence(_ context: RasterContext, input: URL, settings: Adjustments,
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

private func runMixedBatch(_ context: RasterContext, raster: URL, expectedRaster: URL,
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
        try assertNeutralNoDoubleGamma(primary.url, primary.label, engine: cpu, root: contextRoot)
        try runRejectedRasterCases(context, engine: cpu)
        let settings = mixedSettings()
        var outputs: [String: URL] = [:]
        for fixture in fixtures {
            outputs[fixture.label] = try runRasterCase(context, fixture: fixture, engine: cpu, settings: settings)
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
