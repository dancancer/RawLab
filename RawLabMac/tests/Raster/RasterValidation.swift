import AppKit
import Foundation
import ImageIO

func expectRasterFailure(_ context: RasterContext, engine: RenderEngine, input: URL,
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

func runRejectedRasterCases(_ context: RasterContext, engine: RenderEngine) throws {
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

func thumbnail(_ url: URL) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 32,
        kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func dictionary(_ value: Any?, _ path: String) throws -> [String: Any] {
    guard let value = value as? [String: Any] else { throw fail("\(path) is not an object") }
    return value
}

func rewriteOutput(_ recipe: [String: Any], output: URL) throws -> [String: Any] {
    var result = recipe
    var outputObject = try dictionary(result["output"], "output")
    outputObject["path"] = output.path
    result["output"] = outputObject
    return result
}

func writeJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
}

func invokeCLI(_ cli: URL, arguments: [String]) throws -> [String: Any] {
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

func runCLI(_ cli: URL, recipe: URL, preview: URL? = nil, edge: Int? = nil) throws -> [String: Any] {
    var arguments = ["--recipe", recipe.path]
    if let preview {
        arguments += ["--preview", preview.path, "--long-edge", String(edge ?? 48)]
    }
    return try invokeCLI(cli, arguments: arguments + ["--json"])
}

func expectCLIFailure(_ cli: URL, recipe: URL, _ label: String) throws {
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

func inspectRasterRecipe(_ data: Data, input: URL, label: String) throws -> [String: Any] {
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


func assertMetadataAndThumbnail(_ input: URL, output: URL, label: String) throws {
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

func assertNeutralNoDoubleGamma(_ input: URL, _ label: String, engine: RenderEngine,
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

func expectProtectedAliases(_ context: RasterContext, input: URL, settings: Adjustments,
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

