import RawLabKit
import RawLabNativeTypes
import AppKit
import ImageIO

private func check(_ value: Bool, _ message: String) throws {
    guard value else { throw RenderError.failed(message) }
    print("PASS: \(message)")
}

// RenderError.processing 对 Force GPU UNSUPPORTED 的固定文案（RenderError.swift）。
private let forceGpuUnsupportedMessage = "当前照片、外观或处理方式不支持强制 GPU，可切换为自动（Auto）回退。"

private func pixels(_ frame: RenderedImage) -> Data {
    frame.image.dataProvider!.data! as Data
}

private func decodedPixels(_ file: URL) throws -> Data {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw RenderError.failed("Cannot decode exported image")
    }
    return image.dataProvider!.data! as Data
}

private func manualSettings(_ recipe: MasterRecipe, camera: WhiteBalance, strength: Double) -> Adjustments {
    var settings = Adjustments()
    settings.strength = strength
    settings.exposure = recipe.exposureDelta * strength
    settings.shadows = recipe.shadowsDelta * strength / 100
    settings.highlights = -recipe.highlightsDelta * strength / 100
    settings.contrast = 1 + recipe.contrastDelta * strength / 100
    settings.saturation = 1 + recipe.saturationDelta * strength / 100
    settings.hsl = recipe.hsl.scaled(by: strength)
    if recipe.version == 4 {
        settings.toneControls = recipe.tone?.scaled(by: strength)
        settings.curveSettings = (recipe.curve ?? ToneCurveSettings()).scaled(by: strength)
        settings.gradingSettings = (recipe.grading ?? ColorGradingSettings()).scaled(by: strength)
        settings.atmosphere = recipe.atmosphere?.scaled(by: strength)
    }
    if strength != 0 {
        settings.whiteBalanceMode = .custom
        settings.temperature = camera.temperature
        settings.tint = min(150, max(-150, camera.tint + recipe.tintDelta * strength))
    }
    return settings
}

@main struct MasterRecipeRenderTests {
    static func checkDirectRecipeWhiteBalance(root: URL) throws {
        let x3fURL = root.appendingPathComponent("normal-recipe.X3F")
        try Data([0x46, 0x4F, 0x56, 0x62, 0, 0, 0, 0]).write(to: x3fURL)
        let x3fEngine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        var x3fSettings = Adjustments()
        x3fSettings.applyMasterRecipe(.hamadaDaylightV2)
        x3fSettings.x3fMode = .normal
        x3fSettings.set(.tint, to: 20)
        x3fSettings.strength = 0.5
        let decodesBefore = x3fEngine.rawDecodeCount
        let resolvedX3f = try x3fEngine.resolvedRenderSettings(x3fURL, settings: x3fSettings)
        var x3fRequest = sony2fuji_request()
        resolvedX3f.apply(to: &x3fRequest)
        try check(x3fEngine.rawDecodeCount == decodesBefore &&
                  resolvedX3f.settings.asShotWhiteBalance == WhiteBalance(temperature: 6500, tint: 0) &&
                  resolvedX3f.whiteBalance == ResolvedNativeWhiteBalance(wbMode: SONY2FUJI_WB_TEMPERATURE, temperature: 6500, tint: 10) &&
                  x3fRequest.wb_mode == SONY2FUJI_WB_TEMPERATURE && x3fRequest.temperature == 6500 && x3fRequest.tint == 10,
                  "normal X3F recipe resolves to core WB (temperature, 6500, 10) with zero RAW decode probes")

        var mismatched = Adjustments()
        mismatched.applyMasterRecipe(.hamadaDaylightV2)
        mismatched.resolveWhiteBalance(WhiteBalance(temperature: 3200, tint: -40))
        mismatched.set(.tint, to: 20)
        mismatched.strength = 0.5
        var directRequest = sony2fuji_request()
        ResolvedRenderSettings(
            settings: mismatched,
            whiteBalance: ResolvedNativeWhiteBalance(wbMode: SONY2FUJI_WB_TEMPERATURE, temperature: 5600, tint: 17.5)
        ).apply(to: &directRequest)
        try check(directRequest.wb_mode == SONY2FUJI_WB_TEMPERATURE &&
                  directRequest.temperature == 5600 && directRequest.tint == 17.5,
                  "ResolvedRenderSettings applies core-resolved WB directly without Swift recipe-tint recomputation")

        var customMismatched = mismatched
        customMismatched.set(.temperature, to: 8000)
        var cameraRequest = sony2fuji_request()
        ResolvedRenderSettings(
            settings: customMismatched,
            whiteBalance: ResolvedNativeWhiteBalance(wbMode: SONY2FUJI_WB_CAMERA, temperature: 8000, tint: 25)
        ).apply(to: &cameraRequest)
        try check(cameraRequest.wb_mode == SONY2FUJI_WB_CAMERA &&
                  cameraRequest.temperature == 6500 && cameraRequest.tint == 0,
                  "ResolvedRenderSettings normalizes core camera WB directly without Swift temperature/tint leakage")
    }

    static func removal(_ engine: RenderEngine, input: URL) throws {
        guard let camera = try engine.render(input, settings: Adjustments(), lut: nil, edge: 128)?.asShotWhiteBalance else {
            throw RenderError.failed("Removal fixture needs calibrated white balance")
        }
        for recipe in MasterRecipe.allRecipes {
            for strength in [0.0, 0.5, 2.0] {
                var state = Adjustments(); state.applyMasterRecipe(recipe)
                state.resolveWhiteBalance(camera); state.strength = strength
                if recipe.id == MasterRecipe.allRecipes[0].id { state.clarity = 12; state.dehaze = -6 }
                // 单独检查调整贡献；去掉 LUT 本身当然会改变外观。
                let expected = try engine.render(input, settings: state, lut: nil, edge: 128)!
                if recipe.id == MasterRecipe.allRecipes[0].id && strength == 0.5 {
                    let automatic = try RenderEngine(gpuMode: SONY2FUJI_GPU_AUTO)
                    let fallback = try automatic.render(input, settings: state, lut: nil, edge: 128)!
                    try check(automatic.lastBackend == SONY2FUJI_BACKEND_CPU && pixels(fallback) == pixels(expected),
                              "Manual v4 atmosphere uses the honest Auto CPU fallback")
                    let forced = try RenderEngine(gpuMode: SONY2FUJI_GPU_FORCE)
                    let forcedMessage: String?
                    do {
                        _ = try forced.render(input, settings: state, lut: nil, edge: 128)
                        forcedMessage = nil
                    } catch RenderError.failed(let message) {
                        forcedMessage = message
                    }
                    try check(forcedMessage == forceGpuUnsupportedMessage,
                              "Manual v4 atmosphere reports Force GPU UNSUPPORTED prompt")
                }
                try check(state.clearMasterRecipe(), "\(recipe.id) \(strength): direct removal is representable")
                let actual = try engine.render(input, settings: state, lut: nil, edge: 128)!
                try check(pixels(actual) == pixels(expected), "\(recipe.id) \(strength): direct removal preserves adjustment pixels")
            }
        }
    }

    static func main() throws {
        let removalOnly = CommandLine.arguments.contains("--removal-only")
        let inputs = CommandLine.arguments.dropFirst().filter { $0 != "--removal-only" }.map { URL(fileURLWithPath: $0) }
        guard !inputs.isEmpty else {
            throw RenderError.failed("Pass a real RAW fixture and run from the repository root")
        }
        let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        if removalOnly {
            for input in inputs { try removal(cpu, input: input) }
            return
        }
        let metal = try RenderEngine(gpuMode: SONY2FUJI_GPU_FORCE)
        // basic-controls-v3.md「后端、预览与兼容」：基本影调（shadows/highlights/contrast/black/white/vibrance）
        // 在 Metal 上走 GPU；仅 atmosphere（清晰度、去朦胧）与不支持的曲线回退 CPU。
        let automatic = try RenderEngine(gpuMode: SONY2FUJI_GPU_AUTO)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-recipe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try cpu.render(root.appendingPathComponent("missing.ARW"), settings: Adjustments(), lut: nil, edge: 128)
            throw RenderError.failed("Missing input unexpectedly rendered")
        } catch RenderError.failed(let message) {
            try check(message == "无法读取或写入文件，请检查路径和访问权限。",
                      "missing input preserves the native RenderError contract")
        }
        let cacheFile = root.appendingPathComponent("cache-identity.ARW")
        let fixedModified = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("same-size".utf8).write(to: cacheFile)
        try FileManager.default.setAttributes([.modificationDate: fixedModified], ofItemAtPath: cacheFile.path)
        let oldKey = try RawWhiteBalanceCacheKey(cacheFile)
        try FileManager.default.moveItem(at: cacheFile, to: root.appendingPathComponent("previous.ARW"))
        try Data("same-size".utf8).write(to: cacheFile)
        if let modified = oldKey.modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: cacheFile.path)
        }
        let replacedKey = try RawWhiteBalanceCacheKey(cacheFile)
        try check(oldKey.file == replacedKey.file && oldKey.size == replacedKey.size &&
                  oldKey.modified == replacedKey.modified && oldKey != replacedKey,
                  "WB cache invalidates same-path replacement with unchanged size and mtime")
        try checkDirectRecipeWhiteBalance(root: root)
        if inputs.count >= 2 {
            var firstBytes = try Data(contentsOf: inputs[0])
            var secondBytes = try Data(contentsOf: inputs[1])
            let size = max(firstBytes.count, secondBytes.count)
            firstBytes.append(Data(count: size - firstBytes.count))
            secondBytes.append(Data(count: size - secondBytes.count))
            let replacedRAW = root.appendingPathComponent("replaced.ARW")
            try firstBytes.write(to: replacedRAW)
            try FileManager.default.setAttributes([.modificationDate: fixedModified], ofItemAtPath: replacedRAW.path)
            let originalKey = try RawWhiteBalanceCacheKey(replacedRAW)
            var preset = Adjustments(); preset.applyMasterRecipe(.hamadaDaylightV2)
            let lut = MasterRecipe.hamadaDaylightV2.lutURL()!
            let reused = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            _ = try reused.render(replacedRAW, settings: preset, lut: lut, edge: 128)
            try FileManager.default.moveItem(at: replacedRAW, to: root.appendingPathComponent("previous-raw.ARW"))
            try secondBytes.write(to: replacedRAW)
            if let modified = originalKey.modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: replacedRAW.path)
            }
            let actual = try reused.render(replacedRAW, settings: preset, lut: lut, edge: 128)!
            let fresh = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            let expected = try fresh.render(replacedRAW, settings: preset, lut: lut, edge: 128)!
            try check(actual.asShotWhiteBalance == expected.asShotWhiteBalance && pixels(actual) == pixels(expected),
                      "same-path RAW replacement reloads native pixels and camera WB, not just the Swift cache key")
        }
        for input in inputs {
            let original = try OriginalFileIdentity(input)
            let reference = try cpu.render(input, settings: Adjustments(), lut: nil, edge: 128)!
            guard let camera = reference.asShotWhiteBalance else {
                throw RenderError.failed("Fixture must expose calibrated as-shot white balance")
            }
            var zeroHSL = Adjustments()
            zeroHSL.applyMasterRecipe(.hamadaDaylightV2)
            zeroHSL.setHSL(.hue, channel: 0, value: 40)
            zeroHSL.setHSL(.saturation, channel: 5, value: -40)
            zeroHSL.strength = 0
            let zeroHSLResult = try cpu.render(input, settings: zeroHSL,
                                              lut: MasterRecipe.hamadaDaylightV2.lutURL()!, edge: 128)!
            try check(pixels(zeroHSLResult) == pixels(reference),
                      "\(input.lastPathComponent): zero recipe strength bypasses manually edited HSL too")
            var oldZeroPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(zeroHSL)) as! [String: Any]
            oldZeroPayload["masterRecipeSettingsVersion"] = 2
            let oldZero = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: oldZeroPayload))
            var oldZeroReference = Adjustments(); oldZeroReference.hsl = zeroHSL.hsl
            oldZeroReference.toneControls = zeroHSL.toneControls
            oldZeroReference.curveSettings = zeroHSL.curveSettings
            oldZeroReference.gradingSettings = zeroHSL.gradingSettings
            oldZeroReference.atmosphere = zeroHSL.atmosphere
            let independentReference = try cpu.render(input, settings: oldZeroReference, lut: nil, edge: 128)!
            let oldZeroResult = try cpu.render(input, settings: oldZero, lut: MasterRecipe.hamadaDaylightV2.lutURL()!, edge: 128)!
            try check(pixels(oldZeroResult) == pixels(independentReference),
                      "\(input.lastPathComponent): old zero-strength recipe records preserve independent HSL pixels")
            var combined = Adjustments()
            combined.applyMasterRecipe(.hamadaDaylightV2)
            combined.setHSL(.hue, channel: 0, value: 45)
            combined.setHSL(.saturation, channel: 5, value: -60)
            combined.setHSL(.lightness, channel: 3, value: 25)
            var combinedManual = manualSettings(.hamadaDaylightV2, camera: camera, strength: 1)
            combinedManual.hsl = combined.hsl
            let combinedLUT = MasterRecipe.hamadaDaylightV2.lutURL()!
            let combinedReference = try cpu.render(input, settings: combinedManual, lut: combinedLUT, edge: 128)!
            let combinedColdEngine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            let combinedActual = try combinedColdEngine.render(input, settings: combined, lut: combinedLUT, edge: 128)!
            try check(pixels(combinedActual) == pixels(combinedReference),
                      "\(input.lastPathComponent): recipe WB primer preserves the current HSL controls")
            // 配方 v4 的基本影调/曲线/分级（目录内 atmosphere 均为 0）在 Metal 上直接执行，验证 Auto 与 Force Metal parity。
            let combinedAuto = try automatic.render(input, settings: combined, lut: combinedLUT, edge: 128)!
            let combinedAutoDiff = zip(pixels(combinedAuto), pixels(combinedReference)).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
            try check(pixels(combinedAuto).count == pixels(combinedReference).count && combinedAutoDiff <= 2 &&
                      automatic.lastBackend == SONY2FUJI_BACKEND_METAL,
                      "\(input.lastPathComponent): display-sRGB recipe plus HSL runs on Metal with parity max \(combinedAutoDiff) DN")
            for strength in [0.5, 2.0] {
                combined.strength = strength
                var explicitHSL = manualSettings(.hamadaDaylightV2, camera: camera, strength: strength)
                explicitHSL.hsl = combined.hslSettings.scaled(by: strength)
                let expectedHSL = try cpu.render(input, settings: explicitHSL, lut: combinedLUT, edge: 128)!
                let actualHSL = try combinedColdEngine.render(input, settings: combined, lut: combinedLUT, edge: 128)!
                let autoHSL = try automatic.render(input, settings: combined, lut: combinedLUT, edge: 128)!
                let autoHSLDiff = zip(pixels(autoHSL), pixels(expectedHSL)).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
                try check(pixels(actualHSL) == pixels(expectedHSL) &&
                          pixels(autoHSL).count == pixels(expectedHSL).count && autoHSLDiff <= 2 &&
                          automatic.lastBackend == SONY2FUJI_BACKEND_METAL,
                          "\(input.lastPathComponent): \(Int(strength * 100))% manually edited HSL scales, clamps and keeps Metal parity max \(autoHSLDiff) DN")
            }
            let clearedHSL = try cpu.render(input, settings: Adjustments(), lut: nil, edge: 128)!
            try check(pixels(clearedHSL) == pixels(reference),
                      "\(input.lastPathComponent): subsequent neutral render clears prior HSL")
            var recipeOutputs = Set<Data>()
            for recipe in MasterRecipe.allRecipes {
                guard let lut = recipe.lutURL() else { throw RenderError.failed("Missing LUT: \(recipe.id)") }
                let label = "\(input.lastPathComponent) / \(recipe.id)"
                var saved = Adjustments()
                saved.applyMasterRecipe(recipe)
                saved.resolveWhiteBalance(WhiteBalance(temperature: 25000, tint: 30))
                for strength in [0.0, 0.5, 1.0, 2.0] {
                    saved.strength = strength
                    let expected = manualSettings(recipe, camera: camera, strength: strength)
                    let correct = try cpu.render(input, settings: expected, lut: lut, edge: 128)!
                    let actual = try cpu.render(input, settings: saved, lut: lut, edge: 128)!
                    try check(pixels(actual) == pixels(correct),
                              "\(label) \(Int(strength * 100))%: parameters and LUT match explicit manual settings")
                    if strength == 0 {
                        try check(pixels(actual) == pixels(reference), "\(label): zero is exactly neutral")
                    } else if strength == 1 {
                        recipeOutputs.insert(pixels(actual))
                        try check(pixels(actual) != pixels(reference), "\(label): recipe has a visible non-neutral result")
                    }
                    // 14 配方均为 v4 且 atmosphere 目录内为 0、曲线端点钉住，因此 Auto 与 Force 都走 Metal GPU 路径。
                    let fallback = try automatic.render(input, settings: saved, lut: lut, edge: 128)!
                    let fallbackPixels = pixels(fallback), expectedPixels = pixels(actual)
                    let fallbackDifference = zip(fallbackPixels, expectedPixels).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
                    try check(fallbackPixels.count == expectedPixels.count && fallbackDifference <= 2 &&
                              automatic.lastBackend == SONY2FUJI_BACKEND_METAL,
                              "\(label) \(Int(strength * 100))%: Auto runs on Metal max \(fallbackDifference) DN")
                    let gpu = try metal.render(input, settings: saved, lut: lut, edge: 128)!
                    let a = pixels(gpu), b = pixels(actual)
                    let maxDifference = zip(a, b).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
                    try check(a.count == b.count && maxDifference <= 2 && metal.lastBackend == SONY2FUJI_BACKEND_METAL,
                              "\(label) \(Int(strength * 100))%: forced Metal parity max \(maxDifference) DN")
                    if strength == 0 {
                        // 0% 行 lut_strength=0，核心跳过 .cube（use_lut=false），上面只是纯 neutral；
                        // neutral+LUT 才是配方 3D-LUT 真正进入 Metal 管线的面，逐配方钉 forced-Metal parity。
                        let neutralSettings = Adjustments()
                        let neutralReference = try cpu.render(input, settings: neutralSettings, lut: lut, edge: 128)!
                        let neutralForced = try metal.render(input, settings: neutralSettings, lut: lut, edge: 128)!
                        let neutralA = pixels(neutralForced), neutralB = pixels(neutralReference)
                        let neutralDifference = zip(neutralA, neutralB).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
                        try check(neutralA.count == neutralB.count && neutralDifference <= 2 &&
                                  metal.lastBackend == SONY2FUJI_BACKEND_METAL,
                                  "\(label): neutral plus LUT keeps forced Metal parity max \(neutralDifference) DN")
                    }
                }
                saved.strength = 1
                let expected = manualSettings(recipe, camera: camera, strength: 1)
                let correct = try cpu.render(input, settings: expected, lut: lut, edge: 128)!
                let coldEngine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
                let cold = try coldEngine.render(input, settings: saved, lut: lut, edge: 128)!
                try check(pixels(cold) == pixels(correct), "\(label): cold preview resolves target as-shot WB")
                var custom = saved
                custom.set(.temperature, to: 8000)
                var customExpected = expected
                customExpected.temperature = 8000
                let customReference = try cpu.render(input, settings: customExpected, lut: lut, edge: 128)!
                let customRecipe = try cpu.render(input, settings: custom, lut: lut, edge: 128)!
                try check(pixels(customRecipe) == pixels(customReference), "\(label): custom temperature is retained")
                custom.strength = 0
                var customNeutral = Adjustments()
                customNeutral.whiteBalanceMode = .custom
                customNeutral.temperature = 8000
                customNeutral.tint = camera.tint
                let zeroReference = try cpu.render(input, settings: customNeutral, lut: nil, edge: 128)!
                let customZero = try cpu.render(input, settings: custom, lut: lut, edge: 128)!
                try check(pixels(customZero) == pixels(zeroReference), "\(label): zero retains custom temperature")
                for png in [true, false] {
                    let extensionName = png ? "png" : "jpg"
                    let expectedFile = root.appendingPathComponent("\(UUID()).\(extensionName)")
                    _ = try cpu.render(input, settings: expected, lut: lut, edge: nil,
                                       output: expectedFile, exportLongEdge: 128)
                    let journal = MacBatchJournal(directory: root.appendingPathComponent(UUID().uuidString))
                    var job = MacBatchExportJob(source: input, settings: saved, look: lut, lookName: recipe.name)
                    job.outputDirectory = root; job.png = png
                    var item = try MacBatchExportItem(url: input); item.selected = true
                    job.items = [item]
                    let batchEngine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
                    try MacBatchExportRunner.run(job: &job, journal: journal, scope: .unfinished, shouldCancel: { false }) {
                        target, settings, look, output in
                        _ = try batchEngine.render(target, settings: settings, lut: look, edge: nil,
                                                   output: output, exportLongEdge: 128)
                    }
                    guard job.succeededCount == 1, let output = job.items[0].output else {
                        throw RenderError.failed("Recipe batch export failed")
                    }
                    try check(try decodedPixels(expectedFile) == decodedPixels(output),
                              "\(label): frozen batch \(extensionName.uppercased()) matches single export")
                }
                saved.set(.tint, to: 150)
                saved.strength = 2
                _ = try cpu.render(input, settings: saved, lut: lut, edge: 128)
                print("PASS: \(label): maximum user tint at 200% renders")
            }
            try check(recipeOutputs.count == MasterRecipe.allRecipes.count, "\(input.lastPathComponent): all 14 recipe outputs differ")
            try check(try OriginalFileIdentity(input) == original, "\(input.lastPathComponent): original RAW unchanged")
        }
        print("PASS: All \(MasterRecipe.allRecipes.count) recipes verified on \(inputs.count) RAW fixtures")
    }
}
