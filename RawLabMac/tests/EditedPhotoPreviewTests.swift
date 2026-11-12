import AppKit

@main struct EditedPhotoPreviewTests {
    static func check(_ value: Bool) { precondition(value) }
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
        cachedPreviews.invalidateEdited(for: renderedPhoto)
        check(cachedPreviews.cachedThumbnail(for: renderedPhoto) == nil)
        check(await cachedPreviews.cachedImage(for: record1) == nil)
        print("PASS: semantic edit status, reset, source/resource changes, stale plans, proportional preview")
    }
}
