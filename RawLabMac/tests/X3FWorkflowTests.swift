import AppKit
import Foundation
import ImageIO

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw RenderError.failed("X3F test: " + message) }
}
private func pixels(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
private func image(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RenderError.failed("Missing exported X3F image") }
    return image
}

@main struct X3FWorkflowTests {
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let cli = URL(fileURLWithPath: CommandLine.arguments[2])
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-x3f-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        var settings = Adjustments()
        let normal = try engine.render(source, settings: settings, lut: nil, edge: nil)!
        try require(settings.x3fMode == .normal && normal.baselineEV == 0, "fresh normal rendering uses the saved baseline")
        settings.x3fMode = .legacy
        let legacy = try engine.render(source, settings: settings, lut: nil, edge: nil)!
        try require(pixels(normal.image) != pixels(legacy.image), "mode selection changes the actual photograph")
        settings.x3fMode = .normal
        let roundTrip = try engine.render(source, settings: settings, lut: nil, edge: nil)!
        try require(pixels(normal.image) == pixels(roundTrip.image), "normal/legacy/normal reuses the correct source")

        var lensSwitch = settings
        lensSwitch.x3fMode = .legacy
        lensSwitch.lensCorrection = LensCorrectionSettings(distortion: true, tca: true)
        _ = try engine.render(source, settings: lensSwitch, lut: nil, edge: 384)
        lensSwitch.selectX3fMode(.normal)
        let switched = try engine.render(source, settings: lensSwitch, lut: nil, edge: nil)!
        try require(!lensSwitch.lensSettings.isEnabled && pixels(switched.image) == pixels(normal.image),
                    "legacy lens correction switches to an exact normal preview")
        let lensOutput = work.appendingPathComponent("lens-switch.png")
        _ = try engine.render(source, settings: lensSwitch, lut: nil, edge: nil, output: lensOutput)
        let lensImage = try image(lensOutput)
        try require(lensImage.bitsPerComponent == 16, "normal export succeeds after disabling legacy lens correction")

        var unsupportedAI = settings
        unsupportedAI.aiDenoiseEnabled = true
        do {
            try RenderEngine.validateAIInput(source, settings: unsupportedAI)
            throw RenderError.failed("Normal X3F AI preflight unexpectedly succeeded")
        } catch RenderError.failed(let message) {
            try require(message == L10n.text("此 X3F 显影模式不支持 AI 降噪。"), "AI is rejected before batch work or model lookup")
        }

        settings.exposure = 0.25
        settings.temperature = 7200
        settings.whiteBalanceMode = .custom
        settings.saturation = 7
        let adjusted = try engine.render(source, settings: settings, lut: nil, edge: nil)!
        try require(pixels(adjusted.image) != pixels(normal.image), "ordinary edits affect normal X3F")
        let apiOutput = work.appendingPathComponent("api.png")
        _ = try engine.render(source, settings: settings, lut: nil, edge: nil, output: apiOutput)
        let apiImage = try image(apiOutput)
        try require(apiImage.bitsPerComponent == 16 && apiImage.width == adjusted.image.width && apiImage.height == adjusted.image.height,
                    "export uses native dimensions and RGB16")

        let cliOutput = work.appendingPathComponent("cli.png")
        let recipe = try engine.agentRecipe(source, settings: settings, lut: nil, output: cliOutput)
        let object = try JSONSerialization.jsonObject(with: recipe) as! [String: Any]
        try require(object["schema_version"] as? Int == 7 && object["x3f_mode"] as? String == "normal-v1",
                    "Agent recipe carries explicit X3F identity")
        let recipeURL = work.appendingPathComponent("recipe.json")
        try recipe.write(to: recipeURL)
        let process = Process(); process.executableURL = cli
        process.arguments = ["--recipe", recipeURL.path, "--json"]
        let capture = Pipe(); process.standardOutput = capture; process.standardError = capture
        try process.run()
        let log = capture.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, String(decoding: log, as: UTF8.self))
        let cliImage = try image(cliOutput)
        try require(cliImage.bitsPerComponent == 16 && pixels(apiImage) == pixels(cliImage), "GUI and CLI export identical RGB16 pixels")

        let store = try EditPersistence(directory: work.appendingPathComponent("edits"))
        try store.save(source, state: PhotoEditState(settings: settings, filmID: "builtin:preserved-look.cube"))
        let restored = try EditPersistence(directory: work.appendingPathComponent("edits")).state(for: source)!
        try require(restored.settings.x3fMode == .normal && restored.filmID == "builtin:preserved-look.cube",
                    "save/reopen preserves mode, look identity and edits")
        let reopened = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF).render(source, settings: restored.settings, lut: nil, edge: nil)!
        try require(pixels(reopened.image) == pixels(adjusted.image), "reopened edit reproduces the current preview")
        print("PASS X3F Mac preview, relative WB, mode isolation, RGB16 export, CLI parity and edit restart")
    }
}
