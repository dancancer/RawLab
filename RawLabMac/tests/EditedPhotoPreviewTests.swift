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
        let store = try EditPersistence(directory: root.appendingPathComponent("edits"))
        let original = try store.readState(for: photo)
        check(!MacPhotoPreviewPlan.isEdited(original))
        var settings = Adjustments(); settings.exposureMode = .sensor
        let defaults = PhotoEditState(settings: settings, filmID: "")
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
        let geometry = PhotoEditRecord(identity: edited.identity, state: .init(settings: settings, filmID: ""))
        check(try MacPhotoPreviewPlan(record: geometry, films: []).key != first.key)
        let lut = root.appendingPathComponent("look.cube")
        try Data("first".utf8).write(to: lut)
        let lookState = PhotoEditState(settings: settings, filmID: "look")
        let film = Film(name: "Test", url: lut, managedID: "look")
        let lookRecord = PhotoEditRecord(identity: edited.identity, state: lookState)
        let before = try MacPhotoPreviewPlan(record: lookRecord, films: [film])
        try Data("second".utf8).write(to: lut)
        check(try MacPhotoPreviewPlan(record: lookRecord, films: [film]).key != before.key)
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
    }
}
