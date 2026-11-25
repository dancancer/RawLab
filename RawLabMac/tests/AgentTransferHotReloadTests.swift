import RawLabKit
import AppKit

private func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw NSError(domain: label, code: 1) }
    print("PASS: \(label)")
}

private func waitUntil(_ timeout: TimeInterval = 3.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

private func rendered(_ model: EditorModel) throws {
    let ok = waitUntil(30.0) { !model.busy }
    try check(ok && model.result != nil && model.error == nil, "native preview completes")
}

@main struct AgentTransferHotReloadTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-mac-hotreload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let photo = root.appendingPathComponent("photo.png")
        let pixels = [UInt8](repeating: 128, count: 12 * 12 * 3)
        let image = CGImage(
            width: 12,
            height: 12,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: 36,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let destination = CGImageDestinationCreateWithURL(photo as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("fixture write failed") }

        let editDir = root.appendingPathComponent("Edits")
        let presetDir = root.appendingPathComponent("Presets")
        let model = EditorModel(
            lookDirectory: root.appendingPathComponent("Looks"),
            editDirectory: editDir,
            batchDirectory: root.appendingPathComponent("Batch"),
            presetDirectory: presetDir
        )
        model.open(photo)
        try rendered(model)

        // 1. Export & Import Transfer JSON (including 1-step Undo and AI denoise field scoping)
        model.prepareAIOperation = { _, _, _ in }
        model.settings.exposure = 0.55
        model.settings.contrast = 1.12
        model.settings.aiDenoiseEnabled = true
        try check(waitUntil(3.0) { !model.aiState.isRunning }, "AI denoise stub settles")
        try check(model.saveEdits(), "initial adjustment save succeeds")

        let exportedData = try model.exportAdjustmentTransferData()
        let exportedPayload = try AdjustmentTransferPayload.decodeTransferJSON(exportedData)
        try check(abs((exportedPayload[.exposure]?.number ?? 0) - 0.55) < 1e-6, "exported transfer JSON preserves exposure even with AI denoise enabled")

        model.settings.exposure = -0.25
        model.settings.contrast = 0.9
        model.settings.aiDenoiseEnabled = false
        try check(model.saveEdits(), "reset state before JSON import saves")

        try model.importAdjustmentTransfer(data: exportedData)
        try check(abs(model.settings.exposure - 0.55) < 1e-6 && abs(model.settings.contrast - 1.12) < 1e-6,
                  "importing transfer JSON updates EditorModel sliders")
        model.undoAdjustment()
        try check(abs(model.settings.exposure - (-0.25)) < 1e-6, "importing transfer JSON is 1-step undoable")

        // 2. Self-write suppression: saving through EditorModel must NOT trigger external reload banner or extra undo step
        let txCountBeforeSelfSave = model.adjustmentSession?.transactions.count ?? 0
        model.settings.exposure = 0.3
        model.edited()
        _ = waitUntil(2.0) { !model.dirty && !model.hasPendingEditCommits }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        try check(!model.hasActiveExternalReloadBanner, "self-write suppresses external reload banner")
        try check((model.adjustmentSession?.transactions.count ?? 0) == txCountBeforeSelfSave + 1,
                  "self-write creates only normal edit transaction without spurious reload transaction")

        // 3. Clean auto-reload via DispatchSource file watcher + 1-step Cmd+Z Undo
        let externalStore = try MacEditPersistence(directory: editDir)
        let identity = try OriginalFileIdentity(photo)
        var extAdj1 = Adjustments()
        extAdj1.exposureMode = .sensor
        extAdj1.exposure = 0.95
        extAdj1.saturation = 1.14
        _ = try externalStore.saveState(identity: identity, state: MacPhotoEditState(settings: extAdj1, filmID: ""))

        let autoReloaded = waitUntil(3.0) {
            abs(model.settings.exposure - 0.95) < 1e-6 && abs(model.settings.saturation - 1.14) < 1e-6
        }
        try check(autoReloaded && !model.hasActiveExternalReloadBanner && !model.dirty,
                  "clean state auto-reloads external edits.json changes without showing banner")
        model.undoAdjustment()
        try check(abs(model.settings.exposure - 0.3) < 1e-6,
                  "external auto-reload is 1-step undoable")

        // Redo back to 0.95 or save clean baseline for draft protection test
        model.redoAdjustment()
        try check(abs(model.settings.exposure - 0.95) < 1e-6, "external reload redo restores 0.95")

        // 4. Unsaved manual draft protection: external update MUST NOT overwrite unsaved sliders
        model.setInteracting(true)
        model.settings.exposure = -0.85
        model.edited()
        try check(model.hasUnsavedManualDraft, "EditorModel reports active unsaved manual draft")

        var extAdj2 = Adjustments()
        extAdj2.exposureMode = .sensor
        extAdj2.exposure = 1.4
        extAdj2.contrast = 1.33
        _ = try externalStore.saveState(identity: identity, state: MacPhotoEditState(settings: extAdj2, filmID: ""))

        let bannerShown = waitUntil(3.0) { model.hasActiveExternalReloadBanner }
        try check(bannerShown, "unsaved manual draft triggers non-blocking external reload banner")
        try check(abs(model.settings.exposure - (-0.85)) < 1e-6,
                  "unsaved manual draft sliders are preserved when external update arrives")

        // Dismiss with "Keep Current Manual Draft"
        model.keepCurrentManualDraftOnExternalUpdate()
        try check(!model.hasActiveExternalReloadBanner && abs(model.settings.exposure - (-0.85)) < 1e-6,
                  "keeping manual draft dismisses banner while keeping -0.85")

        // Another external update re-surfaces banner, then "Reload Sliders" adopts and is 1-step undoable
        Thread.sleep(forTimeInterval: 0.05)
        var extAdj3 = Adjustments()
        extAdj3.exposureMode = .sensor
        extAdj3.exposure = 1.65
        extAdj3.contrast = 1.42
        _ = try externalStore.saveState(identity: identity, state: MacPhotoEditState(settings: extAdj3, filmID: ""))

        let bannerResurfaced = waitUntil(3.0) { model.hasActiveExternalReloadBanner }
        try check(bannerResurfaced, "subsequent external update re-surfaces reload banner")

        model.reloadFromExternalUpdate()
        try check(!model.hasActiveExternalReloadBanner && !model.dirty &&
                  abs(model.settings.exposure - 1.65) < 1e-6 && abs(model.settings.contrast - 1.42) < 1e-6,
                  "clicking Reload Sliders applies external edit and clears draft")
        model.undoAdjustment()
        try check(abs(model.settings.exposure - 0.95) < 1e-6,
                  "Reload Sliders action is 1-step undoable")

        // 5. External presets.json watch updates presetLibraryRevision
        let initialPresetRev = model.presetLibraryRevision
        let externalPresetStore = AdjustmentPresetStore(directory: presetDir)
        let context = model.adjustmentTransferContext(for: photo)
        let presetPayload = try MacAdjustmentTransfer.capture(
            scope: .custom([.exposure]),
            snapshot: model.editState(settings: model.settings),
            context: context
        )
        _ = try externalPresetStore.create(name: "Agent Preset", payload: presetPayload)
        let presetNotified = waitUntil(3.0) { model.presetLibraryRevision > initialPresetRev }
        try check(presetNotified, "external presets.json write bumps presetLibraryRevision")

        // 6. Un-dirtied crop draft -> Keep Manual Draft -> Esc/cancelGeometryDraft re-triggers external check
        model.beginGeometryDraft()
        try check(model.hasUnsavedManualDraft, "un-dirtied geometry draft marks hasUnsavedManualDraft")
        var extAdj4 = Adjustments()
        extAdj4.exposureMode = .sensor
        extAdj4.exposure = 1.85
        _ = try externalStore.saveState(identity: identity, state: MacPhotoEditState(settings: extAdj4, filmID: ""))
        let bannerOnDraft = waitUntil(3.0) { model.hasActiveExternalReloadBanner }
        try check(bannerOnDraft, "external edit during un-dirtied geometry draft shows banner")
        model.keepCurrentManualDraftOnExternalUpdate()
        try check(!model.hasActiveExternalReloadBanner, "Keep Manual Draft dismisses banner")
        model.cancelGeometryDraft()
        let reloadedAfterCancel = waitUntil(3.0) { abs(model.settings.exposure - 1.85) < 1e-6 }
        try check(reloadedAfterCancel, "cancelling un-dirtied geometry draft re-triggers external check and auto-reloads")

        try rendered(model)

        // 7. Live sony2fuji CLI --save-preset & --sync-photo-edit round-trip + hot reload in EditorModel
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildDir = ProcessInfo.processInfo.environment["RAWLAB_BUILD_DIR"]
            ?? repoRoot.appendingPathComponent("lutools/build-macos").path
        let cliPath = URL(fileURLWithPath: buildDir).appendingPathComponent("sony2fuji").path
        try check(FileManager.default.isExecutableFile(atPath: cliPath), "sony2fuji CLI binary exists at \(cliPath)")

        func runCliSubcommand(_ flag: String, requestObject: [String: Any]) throws -> [String: Any] {
            let reqFile = root.appendingPathComponent("cli-req-\(UUID().uuidString).json")
            let reqData = try JSONSerialization.data(withJSONObject: requestObject, options: [.sortedKeys])
            try reqData.write(to: reqFile)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cliPath)
            proc.arguments = [flag, "--request", reqFile.path, "--json"]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()
            let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try check(proc.terminationStatus == 0, "\(flag) exited 0 (stderr: \(stderrText))")
            let envelope = try JSONSerialization.jsonObject(with: stdoutData) as? [String: Any]
            try check((envelope?["ok"] as? Bool) == true, "\(flag) envelope ok=true")
            return envelope?["result"] as? [String: Any] ?? [:]
        }

        let cliPresetRevBefore = model.presetLibraryRevision
        let cliPresetRes = try runCliSubcommand("--save-preset", requestObject: [
            "data_dir": root.path,
            "name": "Live CLI Look",
            "is_raw": true,
            "processing_version": 3,
            "values": [
                "light.exposure": -0.75,
                "light.curve.apply_to_luminosity": true,
                "color.grading.balance": -10.0,
            ],
        ])
        try check((cliPresetRes["action"] as? String) == "created", "live CLI save_preset created preset")
        let cliPresetWatched = waitUntil(3.0) { model.presetLibraryRevision > cliPresetRevBefore }
        try check(cliPresetWatched, "live CLI save_preset bumps EditorModel.presetLibraryRevision")
        let cliPresetsList = try externalPresetStore.list()
        try check(cliPresetsList.contains(where: { $0.name == "Live CLI Look" }),
                  "AdjustmentPresetStore decodes live CLI presets.json entry")

        let cliSyncRes = try runCliSubcommand("--sync-photo-edit", requestObject: [
            "data_dir": root.path,
            "photo_path": photo.path,
            "is_raster": true,
            "adjustments": [
                "exposure": -1.25,
                "contrast": 18.0,
                "white_balance_mode": "relative",
                "temperature": 6100.0,
                "tint": 6.0,
            ],
        ])
        try check((cliSyncRes["action"] as? String) == "updated", "live CLI sync_photo_edit updated record")
        let cliEditReloaded = waitUntil(3.0) {
            abs(model.settings.exposure - (-1.25)) < 1e-6 && abs(model.settings.contrast - 1.18) < 1e-6
        }
        try check(cliEditReloaded && !model.hasActiveExternalReloadBanner,
                  "EditorModel hot-reloads live CLI --sync-photo-edit update")
        try rendered(model)

        // 8. CanonicalV2 + lutID record upgraded by live sony2fuji --sync-photo-edit remains decodable by MacEditPersistence
        let canonicalPhoto = root.appendingPathComponent("canonical-v2-photo.png")
        let canonicalDest = CGImageDestinationCreateWithURL(canonicalPhoto as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(canonicalDest, image, nil)
        guard CGImageDestinationFinalize(canonicalDest) else { fatalError("canonical fixture write failed") }
        let canonicalIdentity = try OriginalFileIdentity(canonicalPhoto)
        let editsFile = editDir.appendingPathComponent("edits.json")
        var rawEditsObj = try JSONSerialization.jsonObject(with: Data(contentsOf: editsFile)) as! [String: Any]
        var rawRecords = rawEditsObj["records"] as! [String: Any]
        rawRecords[canonicalPhoto.path] = [
            "identity": [
                "fileNumber": canonicalIdentity.fileNumber,
                "modified": canonicalIdentity.modified.timeIntervalSinceReferenceDate,
                "path": canonicalIdentity.path,
                "size": canonicalIdentity.size,
            ],
            "state": [
                "filmID": "builtin:astia",
                "settings": [
                    "settingsVersion": 2,
                    "processing": ["family": "rawlab", "quality": "standard", "version": 3],
                    "exposureMode": "scene",
                    "whiteBalanceMode": "camera",
                    "contrast": 1.25,
                    "lutID": "builtin:astia",
                ],
            ],
        ]
        rawEditsObj["records"] = rawRecords
        let seededData = try JSONSerialization.data(withJSONObject: rawEditsObj, options: [.sortedKeys])
        try seededData.write(to: editsFile, options: .atomic)

        let canonicalSyncRes = try runCliSubcommand("--sync-photo-edit", requestObject: [
            "data_dir": root.path,
            "photo_path": canonicalPhoto.path,
            "is_raster": true,
            "adjustments": ["exposure": 0.4],
        ])
        try check((canonicalSyncRes["action"] as? String) == "updated", "CLI sync_photo_edit updates CanonicalV2+lutID record")
        let decodedCanonical = try externalStore.readState(for: canonicalPhoto)
        try check(abs((decodedCanonical.state?.settings.exposure ?? 0) - 0.4) < 1e-6 &&
                  abs((decodedCanonical.state?.settings.contrast ?? 0) - 1.25) < 1e-6 &&
                  decodedCanonical.state?.filmID == "builtin:astia",
                  "MacEditPersistence decodes CanonicalV2+lutID record after CLI --sync-photo-edit")
        print("ALL AgentTransferHotReloadTests PASSED")
    }
}
