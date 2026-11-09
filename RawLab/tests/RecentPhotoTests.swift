import Foundation

@main struct RecentPhotoTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }; print("PASS: \(message)")
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "Expected failure", code: 1)
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("same-name.dng")
        try Data([1, 2, 3]).write(to: file)
        let identity = try PhotoIdentity.fallback(for: file, resourceIdentifier: "photo-a")
        let store = try RecentPhotoStore(directory: root.appendingPathComponent("recents"), maximumEntries: 2, maximumOriginalBytes: 10)
        let first = try store.recordOpened(url: file, identity: identity, displayName: "same-name.dng", isRaw: true, now: Date(timeIntervalSince1970: 1))
        try FileManager.default.removeItem(at: file)
        let reopened = try RecentPhotoStore(directory: root.appendingPathComponent("recents"), maximumEntries: 2, maximumOriginalBytes: 10)
        try check(try Data(contentsOf: reopened.sourceURL(for: first)) == Data([1, 2, 3]), "Retained original reopens after process and temporary source disappear")
        try check((try reopened.records()).count == 1, "Recent metadata survives reopening")
        let retained = try reopened.sourceURL(for: first)
        _ = try reopened.recordOpened(url: retained, identity: identity, displayName: "renamed.dng", isRaw: true, now: Date(timeIntervalSince1970: 2))
        try check((try reopened.records()).count == 1 && (try reopened.records())[0].displayName == "renamed.dng", "Same identity updates without duplicating")
        try Data([4, 5, 6]).write(to: file)
        let other = try PhotoIdentity.fallback(for: file)
        _ = try reopened.recordOpened(url: file, identity: other, displayName: "renamed.dng", isRaw: true, now: Date(timeIntervalSince1970: 3))
        try check((try reopened.records()).count == 2 && (try reopened.records())[0].identity == other, "Equal filenames stay independent and most recent comes first")
        let key = PhotoPreviewCacheKey(identity: Data([1]), adjustments: Data([2]), edge: 256)
        try reopened.savePreview(Data([9, 8]), key: key, for: first.identity)
        try check(try reopened.lastPreview(for: first) == Data([9, 8]), "Last preview persists independently of the original")
        try Data([0]).write(to: retained)
        try rejects { _ = try reopened.sourceURL(for: first) }
        try check((try reopened.records()).contains { $0.id == first.id }, "Changed original is rejected without deleting metadata")
        try FileManager.default.removeItem(at: retained)
        try rejects { _ = try reopened.sourceURL(for: first) }
        try check(try reopened.lastPreview(for: first) != nil, "Missing original keeps last preview")
        try reopened.remove(first.id)
        try check(FileManager.default.fileExists(atPath: file.path), "Removing a recent never deletes the external original")
        try Data([7, 8, 9]).write(to: file)
        let third = try PhotoIdentity.fallback(for: file)
        _ = try reopened.recordOpened(url: file, identity: third, displayName: "3", isRaw: true)
        try Data([10, 11, 12, 13, 14, 15, 16, 17]).write(to: file)
        let fourth = try PhotoIdentity.fallback(for: file)
        _ = try reopened.recordOpened(url: file, identity: fourth, displayName: "4", isRaw: true)
        try check((try reopened.records()).count == 1 && (try reopened.records())[0].identity == fourth, "Old recent copies obey count and byte limits")
        let editStore = try EditPersistence(directory: root.appendingPathComponent("edits"))
        var settings = RawSettings.default; settings.exposure = 1
        try editStore.save(fourth, state: .init(settings: settings))
        try reopened.remove(fourth.key)
        try check(editStore.state(for: fourth)?.settings.exposure == 1, "Removing recent leaves adjustments intact")
        try rejects { _ = try reopened.recordOpened(url: file, identity: identity, displayName: "changed", isRaw: true) }
        try check((try reopened.records()).isEmpty, "Identity mismatch does not create a recent")
    }
}
