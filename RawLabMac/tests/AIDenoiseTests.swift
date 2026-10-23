import AppKit

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
    print("PASS: \(message)")
}

@main struct AIDenoiseTests {
    static func wait(_ message: String, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(predicate(), message)
    }

    static func main() throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-ai-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.dng"), second = root.appendingPathComponent("second.dng")
        try Data([1,2,3]).write(to: first); try Data([4,5,6]).write(to: second)
        var identitySettings = Adjustments()
        let originalIdentity = try EditorModel.AIWorkIdentity(first, settings: identitySettings)
        identitySettings.lensCorrection = LensCorrectionSettings(distortion: true)
        let lensIdentity = try EditorModel.AIWorkIdentity(first, settings: identitySettings)
        check(lensIdentity != originalIdentity,
              "Lens correction invalidates prepared scene RGB")
        let editor = EditorModel(lookDirectory: root.appendingPathComponent("looks"),
            editDirectory: root.appendingPathComponent("edits"), batchDirectory: root.appendingPathComponent("batch"))
        // 隔离任务发布逻辑；真实 native preview/export 在下方独立验证。
        editor.debounceTimer?.cancel(); editor.debounceTimer = nil
        editor.file = first
        var started = 0
        let release = DispatchSemaphore(value: 0)
        editor.prepareAIOperation = { _, _, progress in
            DispatchQueue.main.async { started += 1 }
            _ = release.wait(timeout: .now() + 8)
            _ = progress.report(phase: 3, completed: 1, total: 1)
        }
        editor.requestAIDenoise()
        wait("Manual AI starts in the background") { started == 1 }
        check(!editor.settings.aiDenoiseEnabled, "Pending first result is not persisted as enabled")
        editor.settings.exposure = 1
        check(started == 1 && editor.aiState.isRunning, "Exposure changes preserve the pending AI job")
        editor.setAIEnabled(false)
        release.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(!editor.settings.aiDenoiseEnabled && editor.aiState == .idle, "Cancelled completion cannot re-enable AI")

        editor.requestAIDenoise()
        wait("Second manual AI job starts") { started == 2 }
        editor.resetAITask(); editor.file = second
        release.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(!editor.settings.aiDenoiseEnabled && editor.aiState == .idle, "Old photo completion cannot publish onto a new photo")

        editor.requestAIDenoise()
        wait("New photo AI job starts") { started == 3 }
        release.signal()
        wait("Successful complete result enables AI") { editor.settings.aiDenoiseEnabled }
        let savedIdentity = editor.aiIdentity
        editor.settings.exposure = 2; editor.settings.saturation = 10
        check(editor.aiIdentity == savedIdentity && started == 3, "Tone edits retain the completed AI identity")
        editor.settings.whiteBalanceMode = .custom; editor.settings.temperature = 4500
        wait("White balance schedules a new RGB preparation") { started == 4 }
        editor.cancelAIDenoise(); release.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(editor.settings.aiDenoiseEnabled && editor.aiState == .cancelled,
              "Cancelling a rebuild retains the requested AI appearance for explicit retry or disable")
        editor.settings.exposure = 3
        check(editor.aiState == .cancelled && started == 4, "Ordinary edits do not restart a cancelled AI job")
        editor.aiState = .ready
        editor.aiResultUnavailable()
        wait("Missing previously ready cache schedules preparation") { started == 5 }
        editor.cancelAIDenoise(); release.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        editor.setAIEnabled(false)

        let lensEditor = EditorModel(lookDirectory: root.appendingPathComponent("lens-looks"),
            editDirectory: root.appendingPathComponent("lens-edits"), batchDirectory: root.appendingPathComponent("lens-batch"))
        lensEditor.debounceTimer?.cancel(); lensEditor.debounceTimer = nil; lensEditor.file = first
        var lensStarted = 0
        var lensSnapshots: [LensCorrectionSettings] = []
        let lensRelease = DispatchSemaphore(value: 0)
        lensEditor.prepareAIOperation = { _, snapshot, progress in
            DispatchQueue.main.async { lensStarted += 1; lensSnapshots.append(snapshot.lensSettings) }
            _ = lensRelease.wait(timeout: .now() + 8)
            _ = progress.report(phase: 3, completed: 1, total: 1)
        }
        lensEditor.requestAIDenoise()
        wait("Lens regression starts with an active AI task") { lensStarted == 1 }
        var draft = MacGeometryDraft(geometry: GeometrySettings(), lens: LensCorrectionSettings())
        draft.lens.distortion = true
        lensEditor.geometryDraft = draft; lensEditor.geometryDraftPreviewReady = true
        lensEditor.busy = false; lensEditor.previewOutdated = false
        check(lensEditor.applyGeometryDraft(), "Lens draft commits during AI preparation")
        lensEditor.debounceTimer?.cancel(); lensEditor.debounceTimer = nil
        lensRelease.signal()
        wait("Committed lens draft prepares the new AI identity") { lensStarted == 2 }
        lensRelease.signal()
        wait("Only the new lens identity publishes ready") { lensEditor.settings.aiDenoiseEnabled && lensEditor.aiState == .ready }
        check(lensEditor.aiIdentity?.lens.distortion == true, "Prepared AI identity retains committed lens settings")
        var activeDraft = MacGeometryDraft(geometry: GeometrySettings(), lens: lensEditor.settings.lensSettings)
        activeDraft.lens.tca = true
        lensEditor.geometryDraft = activeDraft; lensEditor.schedule(forceExact: true)
        lensEditor.debounceTimer?.cancel(); lensEditor.debounceTimer = nil
        wait("Active lens draft prepares its preview identity") { lensStarted == 3 }
        check(!lensEditor.scheduler.hasPending && lensEditor.previewOutdated,
              "Lens AI preparation waits before rendering a missing cache")
        check(lensSnapshots.last?.tca == true && !lensEditor.settings.lensSettings.tca,
              "AI receives draft lens settings without committing them")
        lensEditor.geometryDraft?.geometry.straightenDegrees = 1
        lensEditor.schedule(forceExact: true)
        check(lensStarted == 3 && lensEditor.aiIdentity?.lens.tca == true, "Geometry-only draft reuses the same AI preparation")
        lensEditor.cancelAIDenoise(); lensRelease.signal()
        lensEditor.cancelGeometryDraft(); lensEditor.debounceTimer?.cancel(); lensEditor.debounceTimer = nil
        wait("Cancelling a cancelled lens draft restores committed AI identity") { lensStarted == 4 }
        check(lensSnapshots.last?.tca == false, "Draft cancellation prepares the committed lens snapshot")
        lensRelease.signal()
        wait("Committed AI becomes ready after draft cancellation") { lensEditor.aiState == .ready }
        lensEditor.debounceTimer?.cancel(); lensEditor.debounceTimer = nil; lensEditor.resetAITask()

        guard CommandLine.arguments.count == 4 || CommandLine.arguments.count == 5 else { return }
        let model = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw = URL(fileURLWithPath: CommandLine.arguments[2])
        let cache = URL(fileURLWithPath: CommandLine.arguments[3])
        let requested = CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : "auto"
        let backend = requested == "cpu" ? SONY2FUJI_AI_CPU : requested == "coreml" ? SONY2FUJI_AI_COREML : SONY2FUJI_AI_AUTO
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, aiModelDirectory: model, aiCacheDirectory: cache, aiBackend: backend)
        var settings = Adjustments(); settings.aiDenoiseEnabled = true
        check(!settings.neutralSettings.aiDenoiseEnabled, "Neutral comparison excludes AI adjustments")
        var phases: [(Int, UInt64, UInt64)] = []
        weak var cancellation: AIPreparation?
        let cachedOnly = AIPreparation { phase, done, total in
            phases.append((phase, done, total))
            if (phase == 2 || phase == 3) && (done != 1 || total != 1) { cancellation?.cancel() }
        }
        cancellation = cachedOnly
        try engine.prepareAI(raw, settings: settings, progress: cachedOnly)
        check(phases.filter { $0.0 == 2 || $0.0 == 3 }.allSatisfy { $0.1 == 1 && $0.2 == 1 },
              "Real RAW preparation reuses complete native caches without inference")
        check(!engine.lastAIBackend.isEmpty, "Prepared cache reports its actual AI producers")
        let sceneRGB = engine.lastAIBackend.hasPrefix("SceneRGB=")
        if backend != SONY2FUJI_AI_CPU {
            check(engine.lastAIBackend == (sceneRGB ? "SceneRGB=CoreML" : "RAW=CoreML; RGB=ISP:CPU/RGB:CoreML"),
                  "Native cache identifies CoreML networks and CPU ISP")
        }
        let preview = try engine.render(raw, settings: settings, lut: nil, edge: 512, viewportPreview: true)!
        check(preview.histogram.count == 3 && preview.histogram.allSatisfy { $0.count == 256 },
              "AI preview publishes all three RGB histogram channels")
        settings.applyDenoisePreset(.clean)
        let ordinaryEnabled = try engine.render(raw, settings: settings, lut: nil, edge: 512, viewportPreview: true)!
        check(pixels(preview.image) == pixels(ordinaryEnabled.image), "Active AI bypasses retained ordinary denoise settings")
        settings.exposure = 1
        let brighter = try engine.render(raw, settings: settings, lut: nil, edge: 512, viewportPreview: true)!
        check(pixels(preview.image) != pixels(brighter.image), "Exposure still edits the prepared AI result")
        let exact = try engine.render(raw, settings: settings, lut: nil, edge: nil)!
        let output = root.appendingPathComponent("ai-output.png")
        _ = try engine.render(raw, settings: settings, lut: nil, edge: nil, output: output)
        let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
        let exported = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let a = pixels(exact.image), b = pixels(exported)
        check(a.count == b.count && zip(a,b).allSatisfy { abs(Int($0)-Int($1)) <= 2 },
              "Exact preview and native export use the same AI result within output quantization")
        if backend != SONY2FUJI_AI_CPU {
            let copiedModel = root.appendingPathComponent("model")
            try FileManager.default.copyItem(at: model, to: copiedModel)
            let validationEngine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, aiModelDirectory: copiedModel, aiCacheDirectory: cache, aiBackend: backend)
            _ = try validationEngine.render(raw, settings: settings, lut: nil, edge: 128)
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: copiedModel.appendingPathComponent("manifest.json"))) as! [String: Any]
            let native = sceneRGB ? (manifest["blind_rgb"] as! [String: Any])["coreml"] as! [String: Any] :
                (manifest["coreml"] as! [String: Any])["raw"] as! [String: Any]
            let file = (native["files"] as! [[String: Any]])[0]["path"] as! String
            let resource = copiedModel.appendingPathComponent(native["directory"] as! String).appendingPathComponent(file)
            let modified = try FileManager.default.attributesOfItem(atPath: resource.path)[.modificationDate]!
            var bytes = try Data(contentsOf: resource); bytes[0] ^= 1
            try bytes.write(to: resource)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: resource.path)
            do {
                _ = try validationEngine.render(raw, settings: settings, lut: nil, edge: 128)
                fatalError("Mutated native model reused a validated package")
            } catch RenderError.failed {
                print("PASS: Native resource change invalidates loaded package despite preserved size and modification time")
            }
        }
        settings.whiteBalanceMode = .custom; settings.temperature = 4500
        do {
            _ = try engine.render(raw, settings: settings, lut: nil, edge: 512)
            fatalError("Missing WB-specific RGB cache rendered silently")
        } catch RenderError.aiNotReady { print("PASS: New white balance requires its own RGB result") }
        let cancelled = AIPreparation { _, _, _ in }; cancelled.cancel()
        do {
            try engine.prepareAI(raw, settings: settings, progress: cancelled)
            fatalError("Cancelled job started inference")
        } catch RenderError.aiCancelled { print("PASS: Cancelled preparation exits without inference") }
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
