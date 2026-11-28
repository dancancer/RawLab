import AppKit
import CryptoKit
import RawLabKit

enum AIDenoiseRecoveryChecks {
    private enum Ending: String, CaseIterable { case cancel, disable, failure, reset }

    static func firstPreparation(root: URL) throws {
        let raw = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lutools/tests/fixtures/bayer-demosaic.dng")
        var failures: [String] = []
        for ending in Ending.allCases {
            let folder = root.appendingPathComponent(ending.rawValue)
            let model = EditorModel(lookDirectory: folder.appendingPathComponent("looks"),
                editDirectory: folder.appendingPathComponent("edits"), batchDirectory: folder.appendingPathComponent("batch"))
            model.debounceTimer?.cancel(); model.debounceTimer = nil
            model.file = raw; model.engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            model.schedule(forceExact: true); model.launchNextRender()
            try wait("Ordinary preview becomes exportable") { model.canExport }
            let original = pixels(model.result!.image)
            var started = false, completed = false
            let release = DispatchSemaphore(value: 0)
            model.prepareAIOperation = { _, _, _ in
                DispatchQueue.main.async { started = true }
                _ = release.wait(timeout: .now() + 8)
                defer { DispatchQueue.main.async { completed = true } }
                if ending == .failure { throw RenderError.aiFailed("Fixture model failure") }
            }
            model.requestAIDenoise()
            try wait("First AI preparation starts") { started && model.aiState.isRunning }
            switch ending {
            case .cancel: model.cancelAIDenoise()
            case .disable: model.setAIEnabled(false)
            case .failure: break
            case .reset: model.requestAdjustmentReset(.tool(.denoise))
            }
            release.signal()
            try wait("First AI preparation finishes") { completed && !model.aiState.isRunning }
            model.launchNextRender()
            try wait("Ordinary recovery finishes") { !model.workerActive && !model.scheduler.isBusy }
            let expected: EditorModel.AIDenoiseState = ending == .cancel ? .cancelled :
                ending == .failure ? .failed("Fixture model failure") : .idle
            let valid = !model.settings.aiDenoiseEnabled && model.aiState == expected &&
                !model.previewOutdated && model.canExport && pixels(model.result!.image) == original
            let message = "First AI \(ending.rawValue) restores ordinary preview/export without losing terminal state"
            print("\(valid ? "PASS" : "FAIL"): \(message)")
            if !valid { failures.append(message) }
            model.resetAITask()
        }
        if !failures.isEmpty { throw failure(failures.joined(separator: "\n")) }
    }

    static func modelDownloadHardening(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lutools/tests/fixtures/bayer-demosaic.dng")

        let savedHardwareProvider = RenderEngine.aiHardwareAvailableProvider
        let savedOverride = RenderEngine.aiModelOverrideDirectory
        let savedStore = RenderEngine.aiModelStore
        defer {
            RenderEngine.aiHardwareAvailableProvider = savedHardwareProvider
            RenderEngine.aiModelOverrideDirectory = savedOverride
            RenderEngine.aiModelStore = savedStore
        }

        let manifestBytes = Data("{\"version\":1}\n".utf8)
        let manifestSha = SHA256.hash(data: manifestBytes).map { String(format: "%02x", $0) }.joined()
        let descriptor = AIModelPackageDescriptor(
            platform: AIModelCatalog.macOSArm64Platform,
            url: "https://example.com/model.tar.gz",
            archiveName: "model.tar.gz",
            archiveSha256: manifestSha,
            archiveBytes: 1024,
            manifestSha256: manifestSha,
            unpackedBytes: UInt64(manifestBytes.count),
            entries: [AIModelArchiveEntry(path: "manifest.json", kind: .file, bytes: UInt64(manifestBytes.count), sha256: manifestSha)]
        )
        let storageRoot = root.appendingPathComponent("model-storage", isDirectory: true)
        let isolatedStore = AIModelPackageStore(storageRoot: storageRoot, descriptor: descriptor)
        RenderEngine.aiModelStore = isolatedStore
        RenderEngine.aiModelOverrideDirectory = nil

        func installSyntheticPackage() throws -> URL {
            let dir = storageRoot.appendingPathComponent(manifestSha, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try manifestBytes.write(to: dir.appendingPathComponent("manifest.json"))
            return dir
        }

        func assertTrue(_ cond: Bool, _ msg: String) throws {
            guard cond else { throw failure(msg) }
            print("PASS: \(msg)")
        }

        // 1) Hardware/OS gate: sony2fuji_ai_hardware_available() == false hides download, blocks canStartAI,
        //    and reports hardware reason before missing-model in validateAIInput & configureAI.
        do {
            RenderEngine.aiHardwareAvailableProvider = { false }
            defer { RenderEngine.aiHardwareAvailableProvider = savedHardwareProvider }

            try assertTrue(!RenderEngine.aiModelDownloadSupported,
                           "Hardware-unavailable environment disables aiModelDownloadSupported")
            var aiSettings = Adjustments()
            aiSettings.aiDenoiseEnabled = true
            do {
                try RenderEngine.validateAIInput(raw, settings: aiSettings)
                throw failure("validateAIInput should fail when AI hardware is unavailable")
            } catch RenderError.aiFailed(let message) {
                if RenderEngine.aiAvailable {
                    try assertTrue(message == L10n.text("AI 降噪需要 Apple Silicon GPU 和 macOS 14.4 或更新版本。"),
                                   "validateAIInput reports hardware unavailability before missing-model (\(message))")
                } else {
                    try assertTrue(message == L10n.text("此构建未安装 AI 降噪模型。"),
                                   "validateAIInput reports missing AI runtime on non-AI build (\(message))")
                }
            }
            let engineNoModel = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, aiModelDirectory: nil)
            do {
                try engineNoModel.prepareAI(raw, settings: aiSettings, progress: AIPreparation { _, _, _ in })
                throw failure("configureAI should fail when AI hardware is unavailable")
            } catch RenderError.aiFailed(let message) {
                if RenderEngine.aiAvailable {
                    try assertTrue(message == L10n.text("AI 降噪需要 Apple Silicon GPU 和 macOS 14.4 或更新版本。"),
                                   "configureAI reports hardware unavailability before missing-model (\(message))")
                } else {
                    try assertTrue(message == L10n.text("此构建未安装 AI 降噪模型。"),
                                   "configureAI reports missing AI runtime on non-AI build (\(message))")
                }
            }

            let manager = AIModelPackageManager(
                store: isolatedStore,
                isRuntimeSupported: { RenderEngine.aiAvailable },
                isHardwareAvailable: { RenderEngine.aiHardwareAvailable }
            )
            try assertTrue(manager.state == .unavailable,
                           "Manager state is .unavailable when AI hardware is unavailable and nothing is installed")
            let installedDir = try installSyntheticPackage()
            manager.refresh()
            if RenderEngine.aiAvailable {
                try assertTrue(manager.state.isDownloadedInstalled,
                               "Previously downloaded model remains .installed when AI hardware is unavailable so it can be removed")
            } else {
                try assertTrue(manager.state == .unavailable,
                               "Manager state stays .unavailable on non-AI build even when a downloaded model directory exists")
            }
            let editor = EditorModel(
                lookDirectory: root.appendingPathComponent("hw-looks"),
                editDirectory: root.appendingPathComponent("hw-edits"),
                batchDirectory: root.appendingPathComponent("hw-batch"),
                presetDirectory: root.appendingPathComponent("hw-presets"),
                aiModelManager: manager
            )
            editor.debounceTimer?.cancel(); editor.debounceTimer = nil
            editor.file = raw
            try assertTrue(!editor.canStartAI,
                           "canStartAI is false when AI hardware is unavailable even if a model is installed")
            RenderEngine.aiHardwareAvailableProvider = { true }
            if RenderEngine.aiAvailable {
                try assertTrue(editor.canStartAI, "canStartAI becomes true when AI hardware is available and model is installed")
            }
            try FileManager.default.removeItem(at: installedDir)
        }

        // 2a) Model-layer active reader guards: cancelled editor AI, standalone thumbnail AI render (no EditorView),
        //     and closed batch effect preview all block canRemoveDownloadedAIModel & removeDownloadedAIModel() until exit.
        do {
            RenderEngine.aiHardwareAvailableProvider = { true }
            let installedDir = try installSyntheticPackage()
            let tracker = AIModelAccessTracker()
            let manager = AIModelPackageManager(
                store: isolatedStore,
                isRuntimeSupported: { true },
                isHardwareAvailable: { true }
            )
            let editor = EditorModel(
                lookDirectory: root.appendingPathComponent("guard-looks"),
                editDirectory: root.appendingPathComponent("guard-edits"),
                batchDirectory: root.appendingPathComponent("guard-batch"),
                presetDirectory: root.appendingPathComponent("guard-presets"),
                aiModelManager: manager,
                aiModelAccessTracker: tracker
            )
            editor.debounceTimer?.cancel(); editor.debounceTimer = nil
            editor.file = raw
            try assertTrue(editor.canRemoveDownloadedAIModel, "Idle editor allows removing downloaded AI model")

            // (i) Cancelled editor AI still executing on aiQueue
            // 设置 settings.aiDenoiseEnabled = true，使 cancelAIDenoise 不会触发普通预览 busy，确保真正命中模型层 reader 守卫。
            editor.updatingMetadata = true
            editor.settings.aiDenoiseEnabled = true
            editor.updatingMetadata = false
            var aiEntered = false
            let aiRelease = DispatchSemaphore(value: 0)
            editor.prepareAIOperation = { _, _, _ in
                DispatchQueue.main.async { aiEntered = true }
                _ = aiRelease.wait(timeout: .now() + 8)
            }
            editor.requestAIDenoise()
            try wait("Editor AI preparation entered aiQueue") { aiEntered }
            editor.cancelAIDenoise()
            try assertTrue(editor.aiState == .cancelled && !editor.busy && tracker.hasActiveReaders && !editor.canRemoveDownloadedAIModel,
                           "Cancelled editor AI still blocks model removal while aiQueue is executing")
            editor.removeDownloadedAIModel()
            try assertTrue(FileManager.default.fileExists(atPath: installedDir.path),
                           "removeDownloadedAIModel refuses while cancelled aiQueue operation is still running")
            aiRelease.signal()
            try wait("Removal unblocks once cancelled aiQueue operation exits") { !tracker.hasActiveReaders && editor.canRemoveDownloadedAIModel }
            editor.resetAITask()
            editor.updatingMetadata = true
            editor.settings.aiDenoiseEnabled = false
            editor.updatingMetadata = false

            // (ii) Standalone MacEditedPhotoPreviews AI thumbnail render (no EditorView!)
            let thumbEditsDir = root.appendingPathComponent("thumb-edits", isDirectory: true)
            let thumbStore = try MacEditPersistence(directory: thumbEditsDir)
            var thumbAI = Adjustments(); thumbAI.aiDenoiseEnabled = true
            try thumbStore.save(raw, state: MacPhotoEditState(settings: thumbAI, filmID: ""))
            let thumbRecord = try thumbStore.readState(for: raw)
            let sampleCG = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.blue.setFill(); rect.fill(); return true
            }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            var thumbRenderEntered = false
            let thumbRenderRelease = DispatchSemaphore(value: 0)
            let previews = MainActor.assumeIsolated {
                MacEditedPhotoPreviews(
                    editDirectory: thumbEditsDir,
                    cacheDirectory: root.appendingPathComponent("thumb-cache", isDirectory: true),
                    thumbnails: PhotoThumbnails(),
                    aiModelDirectory: installedDir,
                    aiModelAccessTracker: tracker,
                    prepareAI: { _, _, _ in },
                    renderThumbnail: { _, _, _ in
                        DispatchQueue.main.async { thumbRenderEntered = true }
                        _ = thumbRenderRelease.wait(timeout: .now() + 8)
                        return sampleCG
                    }
                )
            }
            let thumbTask = Task { @MainActor in
                _ = try? await previews.image(for: thumbRecord)
            }
            try wait("Thumbnail worker enters render phase after prepareAI returns") { thumbRenderEntered }
            try assertTrue(!editor.canRemoveDownloadedAIModel,
                           "Active thumbnail AI render blocks model removal in model layer without EditorView")
            editor.removeDownloadedAIModel()
            try assertTrue(FileManager.default.fileExists(atPath: installedDir.path),
                           "removeDownloadedAIModel refuses while thumbnail render is still active")
            thumbRenderRelease.signal()
            try wait("Removal unblocks once thumbnail AI render exits") { editor.canRemoveDownloadedAIModel }
            thumbTask.cancel()

            // (iii) Closed batch effect preview still executing on batch queue
            var batchSettings = Adjustments(); batchSettings.aiDenoiseEnabled = true
            var batchJob = MacBatchExportJob(source: raw, settings: batchSettings, look: nil, lookName: "Neutral")
            let batchItem = try MacBatchExportItem(url: raw)
            batchJob.items = [batchItem]
            var batchEntered = false
            let batchRelease = DispatchSemaphore(value: 0)
            let batch = BatchExportModel(
                job: batchJob,
                journal: MacBatchJournal(directory: root.appendingPathComponent("guard-batch-journal")),
                prepareAI: { _, _, _, _ in
                    DispatchQueue.main.async { batchEntered = true }
                    _ = batchRelease.wait(timeout: .now() + 8)
                },
                aiModelAccessTracker: tracker
            )
            editor.batch = batch
            batch.inspect(batchItem)
            try wait("Batch preview entered queue") { batchEntered }
            batch.closePreview()
            try assertTrue(!batch.previewing && !editor.canRemoveDownloadedAIModel,
                           "Closed batch effect preview still blocks model removal until queue finishes")
            editor.removeDownloadedAIModel()
            try assertTrue(FileManager.default.fileExists(atPath: installedDir.path),
                           "removeDownloadedAIModel refuses while closed batch preview is still running")
            batchRelease.signal()
            try wait("Removal unblocks once closed batch preview queue finishes") { editor.canRemoveDownloadedAIModel }
            editor.batch = nil
            try FileManager.default.removeItem(at: installedDir)
        }

        // 4) Custom injected RenderEngine is preserved across launchNextRender; managed engine updates on directory change.
        do {
            let customModelA = root.appendingPathComponent("custom-a", isDirectory: true)
            let customModelB = root.appendingPathComponent("custom-b", isDirectory: true)
            try FileManager.default.createDirectory(at: customModelA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: customModelB, withIntermediateDirectories: true)
            try manifestBytes.write(to: customModelA.appendingPathComponent("manifest.json"))
            try manifestBytes.write(to: customModelB.appendingPathComponent("manifest.json"))

            RenderEngine.aiModelOverrideDirectory = customModelB
            let customEngine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, aiModelDirectory: customModelA)
            let customEditor = EditorModel(
                lookDirectory: root.appendingPathComponent("eng-custom-looks"),
                editDirectory: root.appendingPathComponent("eng-custom-edits"),
                batchDirectory: root.appendingPathComponent("eng-custom-batch"),
                presetDirectory: root.appendingPathComponent("eng-custom-presets")
            )
            customEditor.debounceTimer?.cancel(); customEditor.debounceTimer = nil
            customEditor.file = raw
            customEditor.engine = customEngine
            customEditor.schedule(forceExact: true)
            customEditor.launchNextRender()
            try wait("Custom engine render completes") { !customEditor.workerActive && customEditor.result != nil }
            try assertTrue(customEditor.engine === customEngine && customEditor.engine?.currentAIModelDirectory == customModelA,
                           "Explicitly injected RenderEngine is preserved instead of overwritten by RenderEngine()")

            let managedEditor = EditorModel(
                lookDirectory: root.appendingPathComponent("eng-managed-looks"),
                editDirectory: root.appendingPathComponent("eng-managed-edits"),
                batchDirectory: root.appendingPathComponent("eng-managed-batch"),
                presetDirectory: root.appendingPathComponent("eng-managed-presets")
            )
            managedEditor.debounceTimer?.cancel(); managedEditor.debounceTimer = nil
            managedEditor.file = raw
            managedEditor.schedule(forceExact: true)
            managedEditor.launchNextRender()
            try wait("Managed engine initial render completes") { !managedEditor.workerActive && managedEditor.result != nil }
            try assertTrue(managedEditor.engine?.currentAIModelDirectory == customModelB,
                           "Managed engine adopts current resolvedAIModelDirectory")
            RenderEngine.aiModelOverrideDirectory = customModelA
            let ensuredDirectory = try managedEditor.queue.sync { try managedEditor.ensureEngine().currentAIModelDirectory }
            try assertTrue(ensuredDirectory == customModelA,
                           "Managed engine recreates via ensureEngine() when resolvedAIModelDirectory changes")
            RenderEngine.aiModelOverrideDirectory = nil
        }

        // 5) Removing model when current photo has aiState == .ready resets .ready, blocks stale export,
        //    and reinstalling triggers re-preparation automatically.
        do {
            RenderEngine.aiHardwareAvailableProvider = { true }
            _ = try installSyntheticPackage()
            let tracker = AIModelAccessTracker()
            let manager = AIModelPackageManager(
                store: isolatedStore,
                isRuntimeSupported: { true },
                isHardwareAvailable: { true }
            )
            let editor = EditorModel(
                lookDirectory: root.appendingPathComponent("ready-looks"),
                editDirectory: root.appendingPathComponent("ready-edits"),
                batchDirectory: root.appendingPathComponent("ready-batch"),
                presetDirectory: root.appendingPathComponent("ready-presets"),
                aiModelManager: manager,
                aiModelAccessTracker: tracker
            )
            editor.debounceTimer?.cancel(); editor.debounceTimer = nil
            editor.file = raw
            editor.engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            editor.schedule(forceExact: true); editor.launchNextRender()
            try wait("Baseline render ready before AI state test") { editor.canExport && !editor.workerActive }

            editor.updatingMetadata = true
            editor.settings.aiDenoiseEnabled = true
            editor.updatingMetadata = false
            editor.aiIdentity = try EditorModel.AIWorkIdentity(raw, settings: editor.settings)
            editor.aiState = .ready
            editor.previewOutdated = false
            try assertTrue(editor.canExport && editor.aiState == .ready, "AI photo starts in ready exportable state")

            editor.removeDownloadedAIModel()
            try assertTrue(editor.aiState == .idle && editor.aiIdentity == nil && editor.settings.aiDenoiseEnabled,
                           "Removing model resets .ready AI state while preserving user AI toggle")
            try assertTrue(editor.previewOutdated && !editor.canExport,
                           "Removing model invalidates stale preview and blocks stale export")

            var reinstallPrepareCalls = 0
            editor.prepareAIOperation = { _, _, _ in
                DispatchQueue.main.async { reinstallPrepareCalls += 1 }
            }
            _ = try installSyntheticPackage()
            manager.refresh()
            try wait("Reinstalling model re-triggers AI preparation after removal reset") {
                reinstallPrepareCalls == 1 && editor.aiState == .ready
            }
            editor.resetAITask()
            try isolatedStore.removeInstalledPackages()
        }

        // 6) Batch draft stale "model not downloaded" validation error clears automatically on model install and on re-add.
        if RenderEngine.aiAvailable {
            RenderEngine.aiHardwareAvailableProvider = { true }
            RenderEngine.aiModelOverrideDirectory = nil
            try? isolatedStore.removeInstalledPackages()
            let tracker = AIModelAccessTracker()
            let manager = AIModelPackageManager(
                store: isolatedStore,
                isRuntimeSupported: { true },
                isHardwareAvailable: { true }
            )
            let editor = EditorModel(
                lookDirectory: root.appendingPathComponent("batch-looks"),
                editDirectory: root.appendingPathComponent("batch-edits"),
                batchDirectory: root.appendingPathComponent("batch-batch"),
                presetDirectory: root.appendingPathComponent("batch-presets"),
                aiModelManager: manager,
                aiModelAccessTracker: tracker
            )
            editor.debounceTimer?.cancel(); editor.debounceTimer = nil
            var aiSettings = Adjustments(); aiSettings.aiDenoiseEnabled = true
            let job = MacBatchExportJob(source: raw, settings: aiSettings, look: nil, lookName: "Neutral")
            let batch = BatchExportModel(
                job: job,
                journal: MacBatchJournal(directory: root.appendingPathComponent("batch-draft-journal")),
                aiModelAccessTracker: tracker
            )
            editor.batch = batch
            batch.add([raw])
            try wait("Batch draft validation completes without model") { !batch.validating }
            try assertTrue(batch.job.items.count == 1 &&
                           batch.job.items[0].validationError == L10n.text("尚未下载 AI 降噪模型。") &&
                           !batch.job.items[0].selected,
                           "Uninstalled model marks batch draft item unselected with missing-model error")

            // Install model -> manager transition triggers batch.revalidateAfterAIModelInstall()
            _ = try installSyntheticPackage()
            manager.refresh()
            try wait("Batch draft item clears stale error and becomes selected after model install") {
                !batch.validating && batch.job.items[0].validationError == nil && batch.job.items[0].selected
            }
            editor.batch = nil

            // Also verify direct re-add clears a stale validationError
            try isolatedStore.removeInstalledPackages()
            let batch2 = BatchExportModel(
                job: MacBatchExportJob(source: raw, settings: aiSettings, look: nil, lookName: "Neutral"),
                journal: MacBatchJournal(directory: root.appendingPathComponent("batch-readd-journal")),
                aiModelAccessTracker: tracker
            )
            batch2.add([raw])
            try wait("Second batch draft records missing-model error") {
                !batch2.validating && batch2.job.items.first?.validationError != nil
            }
            _ = try installSyntheticPackage()
            batch2.add([raw])
            try wait("Re-adding the same file after model install clears stale validationError") {
                !batch2.validating && batch2.job.items[0].validationError == nil && batch2.job.items[0].selected
            }
            try isolatedStore.removeInstalledPackages()
        }

        // Non-blocking 1: BatchSelection collection preflight validates HDR camera AI too (uses activeAIDenoise).
        do {
            RenderEngine.aiHardwareAvailableProvider = { true }
            RenderEngine.aiModelOverrideDirectory = nil
            try? isolatedStore.removeInstalledPackages()
            let colEditor = EditorModel(
                lookDirectory: root.appendingPathComponent("col-hdr-looks"),
                editDirectory: root.appendingPathComponent("col-hdr-edits"),
                batchDirectory: root.appendingPathComponent("col-hdr-batch"),
                presetDirectory: root.appendingPathComponent("col-hdr-presets")
            )
            colEditor.debounceTimer?.cancel(); colEditor.debounceTimer = nil
            var hdrAISettings = Adjustments()
            hdrAISettings.hdr = HDRSettings()
            hdrAISettings.activeAIDenoise = true
            colEditor.addCollectionPhotos([raw])
            try colEditor.editStore!.save(raw, state: MacPhotoEditState(settings: hdrAISettings, filmID: ""))
            let review = try colEditor.prepareCollectionExport(skipping: [], format: .jpeg, longEdge: nil, directory: root)
            try assertTrue(!review.ready && review.rows.count == 1 && review.rows[0].error != nil,
                           "Collection preflight catches missing AI model for HDR camera AI targets")
        }
    }

    private static func wait(_ message: String, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if !predicate() { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AIDenoiseRecoveryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func pixels(_ image: CGImage) -> Data {
        var data = Data(count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
