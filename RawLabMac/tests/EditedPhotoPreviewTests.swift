import RawLabKit
import AppKit
import Combine

@main struct EditedPhotoPreviewTests {
    static func check(_ value: Bool, _ message: String = "", line: UInt = #line) {
        if !value {
            fputs("FAIL (line \(line)): \(message)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func waitEditorIdle(_ model: EditorModel) async {
        let deadline = Date().addingTimeInterval(20)
        while (model.busy || model.importing || model.lookLibraryBusy) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!model.busy && !model.importing && !model.lookLibraryBusy, "Editor settled within timeout")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("photo.jpg")
        try Data([1, 2, 3]).write(to: photo)
        let store = try MacEditPersistence(directory: root.appendingPathComponent("edits"))
        let original = try store.readState(for: photo)
        check(!MacPhotoPreviewPlan.isEdited(original))
        var settings = Adjustments(); settings.exposureMode = .sensor
        let defaults = MacPhotoEditState(settings: settings, filmID: "")
        try store.save(photo, state: defaults)
        check(!MacPhotoPreviewPlan.isEdited(try store.readState(for: photo)))
        settings.exposure = 1
        try store.save(photo, state: .init(settings: settings, filmID: ""))
        let edited = try store.readState(for: photo)
        check(MacPhotoPreviewPlan.isEdited(edited))
        let first = try MacPhotoPreviewPlan(record: edited, films: [])
        check(try first.isCurrent(in: store, films: []))
        try store.save(photo, state: defaults)
        check(try !first.isCurrent(in: store, films: []))
        check(!MacPhotoPreviewPlan.isEdited(try store.readState(for: photo)))
        var turn = GeometrySettings(); turn.quarterTurns = 1; settings.geometry = turn
        let geometry = MacPhotoEditRecord(identity: edited.identity, state: .init(settings: settings, filmID: ""))
        check(try MacPhotoPreviewPlan(record: geometry, films: []).key != first.key)
        let lut = root.appendingPathComponent("look.cube")
        try Data("first".utf8).write(to: lut)
        let lookState = MacPhotoEditState(settings: settings, filmID: "look")
        let film = Film(name: "Test", url: lut, managedID: "look")
        let lookRecord = MacPhotoEditRecord(identity: edited.identity, state: lookState)
        let before = try MacPhotoPreviewPlan(record: lookRecord, films: [film])
        try Data("second".utf8).write(to: lut)
        check(try MacPhotoPreviewPlan(record: lookRecord, films: [film]).key != before.key)
        // Legacy normal X3F thumbnail read-only path: flags-only is unedited, AI/lens cleared in memory, edits.json untouched.
        let x3fEditsDir = root.appendingPathComponent("x3f-preview-edits")
        let x3fStore = try MacEditPersistence(directory: x3fEditsDir)
        let x3fFlagsURL = root.appendingPathComponent("flags-only.X3F")
        let x3fEditedURL = root.appendingPathComponent("edited.X3F")
        try Data("FOVb-flags".utf8).write(to: x3fFlagsURL)
        try Data("FOVb-edited".utf8).write(to: x3fEditedURL)
        var x3fFlags = Adjustments()
        x3fFlags.x3fMode = .normal
        x3fFlags.aiDenoiseEnabled = true
        x3fFlags.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, vignetting: true)
        try x3fStore.save(x3fFlagsURL, state: .init(settings: x3fFlags, filmID: ""))
        var x3fEdited = x3fFlags
        x3fEdited.exposure = 0.6
        x3fEdited.lensCorrection?.profileID = "sigma-45"
        try x3fStore.save(x3fEditedURL, state: .init(settings: x3fEdited, filmID: ""))
        let x3fEditsJSON = x3fEditsDir.appendingPathComponent("edits.json")
        let x3fRawBefore = try Data(contentsOf: x3fEditsJSON)
        let readFlags = try x3fStore.readState(for: x3fFlagsURL)
        check(!MacPhotoPreviewPlan.isEdited(readFlags), "Mac thumbnail read-only state does not mark flags-only old normal X3F as edited")
        let readEdited = try x3fStore.readState(for: x3fEditedURL)
        check(MacPhotoPreviewPlan.isEdited(readEdited), "Mac thumbnail read-only state keeps real edits on old normal X3F")
        let x3fPlan = try MacPhotoPreviewPlan(record: readEdited, films: [], aiModelDirectory: nil)
        check(try x3fPlan.isCurrent(in: x3fStore, films: [], aiModelDirectory: nil),
              "Mac thumbnail plan succeeds without AI model manifest and matches store currency")
        check((try Data(contentsOf: x3fEditsJSON)) == x3fRawBefore,
              "Mac thumbnail read-only path leaves edits.json untouched on disk")
        try store.save(photo, state: lookState)
        let previews = MacEditedPhotoPreviews(editDirectory: root.appendingPathComponent("edits"), cacheDirectory: root.appendingPathComponent("cache"))
        previews.films = [film]
        previews.watch(photo)
        _ = try await previews.record(for: photo)
        for replacement in ["third", "fourth"] {
            let revision = previews.revision
            try Data(replacement.utf8).write(to: lut, options: .atomic)
            for _ in 0..<200 where previews.revision == revision { try await Task.sleep(nanoseconds: 10_000_000) }
            check(previews.revision > revision)
            _ = try await previews.record(for: photo)
        }
        try FileManager.default.removeItem(at: lut)
        _ = try await previews.record(for: photo)
        let missingRevision = previews.revision
        try Data("restored".utf8).write(to: lut, options: .atomic)
        for _ in 0..<200 where previews.revision == missingRevision { try await Task.sleep(nanoseconds: 10_000_000) }
        check(previews.revision > missingRevision)
        previews.unwatch(photo)
        print("PASS: repeated atomic resource replacement and missing resource restoration refresh visible previews")
        try Data([4, 5, 6, 7]).write(to: photo)
        check(try !first.isCurrent(in: store, films: []))
        check(!MacPhotoPreviewPlan.isEdited(try store.readState(for: photo)))
        let image = NSImage(size: NSSize(width: 160, height: 80), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let data = try MacPhotoPreviewPlan.thumbnailData(image, edge: 64)
        let decoded = NSImage(data: data)!
        check(decoded.size == NSSize(width: 64, height: 32))
        let renderedPhoto = root.appendingPathComponent("rendered.png")
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: renderedPhoto)
        var renderSettings = Adjustments(); renderSettings.exposureMode = .sensor; renderSettings.exposure = 1.0
        try store.save(renderedPhoto, state: .init(settings: renderSettings, filmID: ""))
        let isolatedThumbnails = PhotoThumbnails()
        let cachedPreviews = MacEditedPhotoPreviews(editDirectory: root.appendingPathComponent("edits"),
            cacheDirectory: root.appendingPathComponent("render-cache"), thumbnails: isolatedThumbnails)
        let record1 = try await cachedPreviews.record(for: renderedPhoto)
        let firstImage = try await cachedPreviews.image(for: record1)
        let firstStats = await cachedPreviews.renderStats()
        check(firstStats.renders == 1 && firstStats.decodes == 1)
        let secondImage = try await cachedPreviews.image(for: record1)
        let secondStats = await cachedPreviews.renderStats()
        check(secondImage === firstImage && secondStats.renders == 1 && secondStats.diskReads == 0 && secondStats.decodes == 1)
        check(cachedPreviews.cachedThumbnail(for: renderedPhoto)?.image === firstImage)
        try store.save(renderedPhoto, state: defaults)
        check(cachedPreviews.cachedThumbnail(for: renderedPhoto) == nil, "store.save automatically invalidates cachedThumbnail without manual invalidateEdited")
        check(await cachedPreviews.cachedImage(for: record1) == nil)
        print("PASS: semantic edit status, reset, source/resource changes, stale plans, proportional preview")

        try await verifyEditorModelIntegration(in: root, sampleImage: image)
        print("PASS: EditorModel automatic invalidation, single-pass reset/undo idempotency, and look-removal tile cleanup")

        try await verifyAIThumbnailPreparationProgress(in: root, sampleImage: image)
        print("PASS: AI thumbnail preparation progress indicator updates, clears on exit/cancel, and enforces single-actor memory cap")

        try await verifyDownloadedAIModelThumbnailAndRefresh(in: root, sampleImage: image)
        print("PASS: unbundled downloaded AI model resolves for thumbnails and model install/remove triggers preview refresh")
    }

    @MainActor static func verifyAIThumbnailPreparationProgress(in root: URL, sampleImage: CGImage) async throws {
        let dir = root.appendingPathComponent("ai-progress-test", isDirectory: true)
        let editsDir = dir.appendingPathComponent("edits", isDirectory: true)
        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        let aiModelDir = dir.appendingPathComponent("DualDn", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: aiModelDir, withIntermediateDirectories: true)
        try Data("{\"version\":1}".utf8).write(to: aiModelDir.appendingPathComponent("manifest.json"))

        let firstPhoto = dir.appendingPathComponent("ai-one.DNG")
        let secondPhoto = dir.appendingPathComponent("ai-two.DNG")
        let cancelPhoto = dir.appendingPathComponent("ai-cancel.DNG")
        for url in [firstPhoto, secondPhoto, cancelPhoto] {
            try Data("raw-fixture-\(url.lastPathComponent)".utf8).write(to: url)
        }

        let store = try MacEditPersistence(directory: editsDir)
        var aiSettings = Adjustments()
        aiSettings.aiDenoiseEnabled = true
        aiSettings.exposure = 0.4
        for url in [firstPhoto, secondPhoto, cancelPhoto] {
            try store.save(url, state: MacPhotoEditState(settings: aiSettings, filmID: ""))
        }

        final class ConcurrencyProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var active = 0
            private var maxActive = 0
            private var calls = 0
            private var enteredFirst = false
            private var enteredCancel = false
            let releaseFirst = DispatchSemaphore(value: 0)
            let releaseCancel = DispatchSemaphore(value: 0)

            func enter(_ url: URL) -> Int {
                lock.lock()
                calls += 1
                let count = calls
                active += 1
                maxActive = max(maxActive, active)
                if url.lastPathComponent == "ai-one.DNG" { enteredFirst = true }
                if url.lastPathComponent == "ai-cancel.DNG" { enteredCancel = true }
                lock.unlock()
                if url.lastPathComponent == "ai-one.DNG" {
                    releaseFirst.wait()
                } else if url.lastPathComponent == "ai-cancel.DNG" {
                    releaseCancel.wait()
                }
                return count
            }

            func leave() {
                lock.lock()
                active -= 1
                lock.unlock()
            }

            var hasEnteredFirst: Bool {
                lock.lock(); defer { lock.unlock() }
                return enteredFirst
            }

            var hasEnteredCancel: Bool {
                lock.lock(); defer { lock.unlock() }
                return enteredCancel
            }

            var maxConcurrent: Int {
                lock.lock(); defer { lock.unlock() }
                return maxActive
            }
        }

        let probe = ConcurrencyProbe()
        let previews = MacEditedPhotoPreviews(
            editDirectory: editsDir,
            cacheDirectory: cacheDir,
            thumbnails: PhotoThumbnails(),
            aiModelDirectory: aiModelDir,
            prepareAI: { url, _, progress in
                _ = probe.enter(url)
                defer { probe.leave() }
                _ = progress.report(phase: 2, completed: 1, total: 4)
                if progress.isCancelled {
                    throw CancellationError()
                }
                _ = progress.report(phase: 3, completed: 3, total: 4)
                _ = progress.report(phase: 4, completed: 4, total: 4)
            },
            renderThumbnail: { _, _, _ in sampleImage }
        )

        var observedProgress: [AIPreparationProgress?] = []
        let sub = previews.$aiPreparationProgress.sink { observedProgress.append($0) }
        defer { sub.cancel() }

        let rec1 = try await previews.record(for: firstPhoto)
        let rec2 = try await previews.record(for: secondPhoto)
        let task1 = Task { try await previews.image(for: rec1) }
        for _ in 0..<200 where !probe.hasEnteredFirst {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        check(probe.hasEnteredFirst, "First AI thumbnail entered prepareAI")
        let task2 = Task { try await previews.image(for: rec2) }

        // Wait briefly for initial MainActor progress emission while task1 is paused in prepareAI and task2 is queued.
        for _ in 0..<50 where previews.aiPreparationProgress?.path != rec1.identity.path {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        check(previews.aiPreparationProgress?.path == rec1.identity.path,
              "Active AI preparation exposes progress for the running tile")
        check(probe.maxConcurrent == 1,
              "Second AI tile stays queued behind single-actor memory cap while first runs")

        probe.releaseFirst.signal()
        _ = try await task1.value
        _ = try await task2.value
        for _ in 0..<50 where previews.aiPreparationProgress != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        check(probe.maxConcurrent == 1, "MacPhotoPreviewWorker preserves maxConcurrent == 1 across sequential AI tasks")
        check(previews.aiPreparationProgress == nil, "aiPreparationProgress clears to nil on completion")
        check(observedProgress.compactMap { $0 }.contains { $0.path == rec1.identity.path && $0.phase == 4 && $0.done == 4 && $0.total == 4 },
              "Multi-phase AI progress updates were observed for first tile")
        check(observedProgress.compactMap { $0 }.contains { $0.path == rec2.identity.path },
              "Second queued AI tile also emitted progress once active")

        // Verify cancellation clears aiPreparationProgress via defer.
        let recCancel = try await previews.record(for: cancelPhoto)
        let cancelTask = Task { try await previews.image(for: recCancel) }
        for _ in 0..<200 where !probe.hasEnteredCancel {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        check(probe.hasEnteredCancel, "Cancel test tile entered prepareAI")
        for _ in 0..<50 where previews.aiPreparationProgress?.path != recCancel.identity.path {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        cancelTask.cancel()
        probe.releaseCancel.signal()
        _ = try? await cancelTask.value
        for _ in 0..<50 where previews.aiPreparationProgress != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        check(previews.aiPreparationProgress == nil, "aiPreparationProgress clears to nil on cancellation")
    }

    @MainActor static func verifyEditorModelIntegration(in root: URL, sampleImage: CGImage) async throws {
        _ = NSApplication.shared
        let workDir = root.appendingPathComponent("editor-integration", isDirectory: true)
        let looksDir = workDir.appendingPathComponent("looks", isDirectory: true)
        let editsDir = workDir.appendingPathComponent("edits", isDirectory: true)
        let batchDir = workDir.appendingPathComponent("batch", isDirectory: true)
        let previewCacheDir = workDir.appendingPathComponent("preview-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let photo = workDir.appendingPathComponent("editor-photo.png")
        let bitmap = NSBitmapImageRep(cgImage: sampleImage)
        try bitmap.representation(using: .png, properties: [:])!.write(to: photo)

        let thumbnails = PhotoThumbnails()
        let previews = MacEditedPhotoPreviews(editDirectory: editsDir, cacheDirectory: previewCacheDir, thumbnails: thumbnails)
        let model = EditorModel(lookDirectory: looksDir, editDirectory: editsDir, batchDirectory: batchDir)

        // Mirror EditorView's bindings between EditorModel and MacEditedPhotoPreviews.
        var cancellables = Set<AnyCancellable>()
        previews.films = model.films
        model.$films.dropFirst().sink { [weak previews] films in
            previews?.films = films
            previews?.refresh()
        }.store(in: &cancellables)
        model.$completedEditPreview.sink { [weak previews] preview in
            guard let preview else { return }
            previews?.accept(record: preview.record, image: preview.image)
        }.store(in: &cancellables)

        // 1. Open photo in EditorModel and prime unedited tile.
        model.open(photo)
        await waitEditorIdle(model)
        check(model.error == nil && model.result != nil, "EditorModel opened photo")

        var tile = WorkspacePhotoTileState()
        await tile.refresh(url: photo, previews: previews)
        let uneditedImg = tile.thumbnail
        check(uneditedImg != nil && !tile.edited && !tile.adjustedThumbnail, "Initial tile shows unedited thumbnail")
        check(thumbnails.decodeCount == 1, "Initial unedited decode count == 1")

        // 2. Edit exposure via EditorModel and saveEdits() (commitAdjustment) -> automatic invalidation.
        model.settings.exposure = 1.2
        model.edited()
        check(model.saveEdits(), "EditorModel saveEdits succeeded")
        check(previews.cachedThumbnail(for: photo) == nil,
              "EditorModel.saveEdits automatically invalidated stale unedited presentation")
        await waitEditorIdle(model)
        // Allow completedEditPreview -> previews.accept detached task to finish storing.
        for _ in 0..<100 where previews.cachedThumbnail(for: photo) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await tile.refresh(url: photo, previews: previews)
        let editedExposureImg = tile.thumbnail
        check(editedExposureImg != nil && editedExposureImg !== uneditedImg && tile.edited && tile.adjustedThumbnail,
              "Tile updated to edited thumbnail after EditorModel save")

        // 3. Finding 1: Reset All in EditorModel -> tile refreshes unedited -> wait for debounced .exact frame.
        let thumbInvBeforeReset = thumbnails.editedInvalidationCount
        let previewInvBeforeReset = previews.editedInvalidationCount
        guard case .prepared(let resetAll) = model.prepareReset(scope: .all) else {
            check(false, "prepareReset(.all) must succeed")
            return
        }
        check(model.commitReset(resetAll) && model.saveEdits(), "EditorModel Reset All saved")
        check(thumbnails.editedInvalidationCount == thumbInvBeforeReset + 1 && previews.editedInvalidationCount == previewInvBeforeReset + 1,
              "Reset All invalidates edited cache exactly once on commit")

        // Tile refreshes immediately (before debounced .exact frame finishes) and registers unedited activeKeys.
        await tile.refresh(url: photo, previews: previews)
        check(!tile.edited && !tile.adjustedThumbnail && tile.thumbnail === uneditedImg,
              "Tile displays cached unedited thumbnail right after Reset All")
        check(previews.cachedThumbnail(for: photo)?.image === uneditedImg && previews.cachedThumbnail(for: photo)?.isEdited == false,
              "Unedited cachedThumbnail active before exact frame completion")

        // Let debounced .exact render finish completely in EditorModel+Rendering.swift.
        await waitEditorIdle(model)
        try await Task.sleep(nanoseconds: 50_000_000)

        check(thumbnails.editedInvalidationCount == thumbInvBeforeReset + 1 && previews.editedInvalidationCount == previewInvBeforeReset + 1,
              "Exact frame completion after Reset All does NOT trigger a second invalidation")
        var rebuiltAfterReset = WorkspacePhotoTileState()
        rebuiltAfterReset.appear(url: photo, previews: previews)
        check(rebuiltAfterReset.thumbnail === uneditedImg && !rebuiltAfterReset.edited && !rebuiltAfterReset.adjustedThumbnail,
              "Rebuilt tile after Reset All exact render synchronously hits unedited thumbnail without miss/flash")

        // 4. Undo (back to +1.2) and Undo again (back to unmodified) via EditorModel.undoAdjustment().
        model.undoAdjustment()
        await waitEditorIdle(model)
        for _ in 0..<100 where previews.cachedThumbnail(for: photo)?.isEdited != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await tile.refresh(url: photo, previews: previews)
        check(tile.edited && tile.adjustedThumbnail, "First undo restored edited state")

        let thumbInvBeforeUndoToDefault = thumbnails.editedInvalidationCount
        let previewInvBeforeUndoToDefault = previews.editedInvalidationCount
        model.undoAdjustment()
        check(thumbnails.editedInvalidationCount == thumbInvBeforeUndoToDefault + 1 && previews.editedInvalidationCount == previewInvBeforeUndoToDefault + 1,
              "Undo back to unmodified invalidates edited cache once")
        await tile.refresh(url: photo, previews: previews)
        await waitEditorIdle(model)
        try await Task.sleep(nanoseconds: 50_000_000)
        check(thumbnails.editedInvalidationCount == thumbInvBeforeUndoToDefault + 1 && previews.editedInvalidationCount == previewInvBeforeUndoToDefault + 1,
              "Exact frame completion after Undo to unmodified does NOT trigger a second invalidation")
        var rebuiltAfterUndo = WorkspacePhotoTileState()
        rebuiltAfterUndo.appear(url: photo, previews: previews)
        check(rebuiltAfterUndo.thumbnail === uneditedImg && !rebuiltAfterUndo.edited,
              "Rebuilt tile after Undo to unmodified synchronously hits unedited thumbnail")

        // 5. Finding 2: Import custom look via EditorModel, apply & save, render tile, then removeLook(id:).
        let lutSource = workDir.appendingPathComponent("TestLook.cube")
        let lutText = "#Gamma:F-Log2 to Model Test\n#Gamut:F-Gamut to ITU-R BT.709\nLUT_3D_SIZE 2\n" +
            Array(repeating: "0.8 0.2 0.1\n", count: 8).joined()
        try lutText.write(to: lutSource, atomically: true, encoding: .utf8)
        model.importLook(lutSource)
        await waitEditorIdle(model)
        guard let importedFilm = model.selectedFilm, let lookID = importedFilm.managedID else {
            check(false, "importLook must select imported managed look")
            return
        }
        model.edited()
        check(model.saveEdits(), "Saved custom look adjustment")
        await waitEditorIdle(model)
        for _ in 0..<100 where previews.cachedThumbnail(for: photo)?.isEdited != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        var mountedLookTile = WorkspacePhotoTileState()
        await mountedLookTile.refresh(url: photo, previews: previews)
        let oldLookImg = mountedLookTile.thumbnail
        check(oldLookImg != nil && oldLookImg !== uneditedImg && mountedLookTile.adjustedThumbnail && mountedLookTile.notice == nil,
              "Mounted tile shows custom look edited thumbnail")

        // Remove the active look through EditorModel.removeLook(id:).
        model.removeLook(id: lookID)
        await waitEditorIdle(model)
        check(model.missingFilm && model.previewOutdated, "EditorModel marks removed look missing and preview outdated")
        check(previews.cachedThumbnail(for: photo) == nil,
              "EditorModel.removeLook invalidates synchronous edited thumbnail cache")

        await mountedLookTile.refresh(url: photo, previews: previews)
        check(mountedLookTile.thumbnail !== oldLookImg && mountedLookTile.thumbnail === uneditedImg && !mountedLookTile.adjustedThumbnail && mountedLookTile.notice == "预览未更新",
              "Mounted tile drops stale look thumbnail and falls back to original after EditorModel.removeLook")

        var rebuiltLookTile = WorkspacePhotoTileState()
        rebuiltLookTile.appear(url: photo, previews: previews)
        check(rebuiltLookTile.thumbnail == nil, "Rebuilt tile onAppear does not load stale look thumbnail")
        await rebuiltLookTile.refresh(url: photo, previews: previews)
        check(rebuiltLookTile.thumbnail !== oldLookImg && rebuiltLookTile.thumbnail === uneditedImg && !rebuiltLookTile.adjustedThumbnail && rebuiltLookTile.notice == "预览未更新",
              "Rebuilt tile after EditorModel.removeLook shows original fallback instead of stale look thumbnail")

        // M-N3: EditPersistence.editedRevision and MacPhotoPreviewPlan.isEditedState share raster classification.
        var sensorNeutral = Adjustments()
        sensorNeutral.exposureMode = .sensor
        let sensorState = MacPhotoEditState(settings: sensorNeutral, filmID: "")
        var modified = Adjustments()
        modified.exposure = 0.5
        let modifiedState = MacPhotoEditState(settings: modified, filmID: "")
        for ext in ["tiff", "tif", "heic"] {
            let path = "/tmp/mn3-sample.\(ext)"
            let url = URL(fileURLWithPath: path)
            check(PhotoInputClassification.isRasterInput(url) && RenderEngine.isRasterInput(url),
                  "\(ext) is classified as raster on both paths")
            check(MacPhotoPreviewPlan.isEditedState(sensorState, atPath: path) ==
                  (MacEditPersistence.editedRevision(for: sensorState, atPath: path) != nil) &&
                  !MacPhotoPreviewPlan.isEditedState(sensorState, atPath: path),
                  "Neutral .sensor state is unedited for \(ext) on both paths")
            check(MacPhotoPreviewPlan.isEditedState(modifiedState, atPath: path) ==
                  (MacEditPersistence.editedRevision(for: modifiedState, atPath: path) != nil) &&
                  MacPhotoPreviewPlan.isEditedState(modifiedState, atPath: path),
                  "Exposure-modified state is edited for \(ext) on both paths")
        }
        let rawPath = "/tmp/mn3-sample.arw"
        let rawURL = URL(fileURLWithPath: rawPath)
        check(!PhotoInputClassification.isRasterInput(rawURL) && !RenderEngine.isRasterInput(rawURL),
              "ARW is classified as non-raster on both paths")
        check(MacPhotoPreviewPlan.isEditedState(sensorState, atPath: rawPath) ==
              (MacEditPersistence.editedRevision(for: sensorState, atPath: rawPath) != nil) &&
              MacPhotoPreviewPlan.isEditedState(sensorState, atPath: rawPath),
              "RAW .sensor state differs from default .preview on both paths")
    }

    @MainActor static func verifyDownloadedAIModelThumbnailAndRefresh(in root: URL, sampleImage: CGImage) async throws {
        _ = NSApplication.shared
        let workDir = root.appendingPathComponent("downloaded-ai-thumb", isDirectory: true)
        let storageRoot = workDir.appendingPathComponent("model-storage", isDirectory: true)
        let looksDir = workDir.appendingPathComponent("looks", isDirectory: true)
        let editsDir = workDir.appendingPathComponent("edits", isDirectory: true)
        let batchDir = workDir.appendingPathComponent("batch", isDirectory: true)
        let cacheDir = workDir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let manifestBytes = Data("{\"version\":1,\"model\":\"downloaded-test\"}".utf8)
        let manifestSha = String(repeating: "a", count: 64)
        let descriptor = AIModelPackageDescriptor(
            platform: "macos-arm64",
            url: "https://example.invalid/model.tar.gz",
            archiveName: "model.tar.gz",
            archiveSha256: String(repeating: "b", count: 64),
            archiveBytes: 128,
            manifestSha256: manifestSha,
            unpackedBytes: UInt64(manifestBytes.count),
            entries: [
                AIModelArchiveEntry(path: "manifest.json", kind: .file, bytes: UInt64(manifestBytes.count), sha256: String(repeating: "c", count: 64)),
            ]
        )
        let isolatedStore = AIModelPackageStore(storageRoot: storageRoot, descriptor: descriptor)
        let manager = AIModelPackageManager(
            store: isolatedStore,
            isRuntimeSupported: { true },
            overrideProvider: { nil },
            bundledProvider: { nil }
        )

        let previousStore = RenderEngine.aiModelStore
        let previousOverride = RenderEngine.aiModelOverrideDirectory
        RenderEngine.aiModelStore = isolatedStore
        RenderEngine.aiModelOverrideDirectory = nil
        defer {
            RenderEngine.aiModelStore = previousStore
            RenderEngine.aiModelOverrideDirectory = previousOverride
        }
        check(RenderEngine.bundledAIModel == nil, "Test binary has no bundled AI model")
        check(RenderEngine.resolvedAIModelDirectory == nil, "Initially no downloaded AI model is installed")

        let photo = workDir.appendingPathComponent("ai-edited.DNG")
        try Data("raw-fixture-bytes".utf8).write(to: photo)
        let editStore = try MacEditPersistence(directory: editsDir)
        var aiSettings = Adjustments()
        aiSettings.aiDenoiseEnabled = true
        aiSettings.exposure = 0.35
        try editStore.save(photo, state: MacPhotoEditState(settings: aiSettings, filmID: ""))

        let model = EditorModel(lookDirectory: looksDir, editDirectory: editsDir, batchDirectory: batchDir, aiModelManager: manager)
        // Production wiring: no injected aiModelDirectory.
        let previews = MacEditedPhotoPreviews(
            editDirectory: editsDir,
            cacheDirectory: cacheDir,
            thumbnails: PhotoThumbnails(),
            prepareAI: { _, _, _ in },
            renderThumbnail: { _, _, _ in sampleImage }
        )

        // 1. Without bundled or downloaded model, plan throws and tile reports "预览未更新".
        var tile = WorkspacePhotoTileState()
        await tile.refresh(url: photo, previews: previews)
        check(!tile.adjustedThumbnail && tile.notice == "预览未更新",
              "Without downloaded model, AI-edited tile falls back with '预览未更新'")

        // 2. Install model into storageRoot and refresh manager -> EditorModel transitions to .installed
        //    and triggers previews.refresh() via production notification.
        let installedDir = isolatedStore.installedDirectoryURL!
        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        try manifestBytes.write(to: installedDir.appendingPathComponent("manifest.json"))

        let revisionBeforeInstall = previews.revision
        manager.refresh()
        for _ in 0..<50 where previews.revision == revisionBeforeInstall {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        check(previews.revision > revisionBeforeInstall,
              "EditorModel AI model install-state change triggers MacEditedPhotoPreviews.refresh()")
        check(RenderEngine.resolvedAIModelDirectory == installedDir,
              "RenderEngine.resolvedAIModelDirectory resolves the downloaded model directory")

        let record = try await previews.record(for: photo)
        let plan = try MacPhotoPreviewPlan(record: record, films: [])
        check(plan.resourceURLs.contains(installedDir.appendingPathComponent("manifest.json")),
              "MacPhotoPreviewPlan tracks downloaded manifest.json with no bundled model")

        await tile.refresh(url: photo, previews: previews)
        check(tile.adjustedThumbnail && tile.notice == nil && tile.thumbnail != nil,
              "AI-edited tile renders edited thumbnail using downloaded model")

        // 3. Removing the downloaded model through EditorModel triggers another refresh and invalidates AI plan.
        let revisionBeforeRemove = previews.revision
        check(model.canRemoveDownloadedAIModel, "Idle EditorModel allows removing downloaded model")
        model.removeDownloadedAIModel()
        for _ in 0..<50 where previews.revision == revisionBeforeRemove {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        check(previews.revision > revisionBeforeRemove,
              "EditorModel AI model removal triggers MacEditedPhotoPreviews.refresh()")
        check(RenderEngine.resolvedAIModelDirectory == nil, "Removed model is no longer resolved")
        await tile.refresh(url: photo, previews: previews)
        check(!tile.adjustedThumbnail && tile.notice == "预览未更新",
              "After model removal, AI-edited tile drops stale thumbnail and reports '预览未更新'")
    }
}
