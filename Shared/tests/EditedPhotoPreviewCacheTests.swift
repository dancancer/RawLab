import Foundation

@main
struct EditedPhotoPreviewCacheTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func key(_ identity: String = "photo-a", _ settings: String = "exposure=1", _ resources: String = "look-v1", _ edge: Int = 256) -> PhotoPreviewCacheKey {
            PhotoPreviewCacheKey(identity: Data(identity.utf8), adjustments: Data(settings.utf8), resources: Data(resources.utf8), edge: edge)
        }
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { fatalError("FAIL: \(message)") }
            print("PASS: \(message)")
        }
        expect(key() == key(), "The same photo, adjustments, resources and size reuse the same preview")
        expect(key() != key("photo-b"), "Distinct photo identities cannot share a preview")
        expect(key() != key("photo-a", "exposure=0"), "Reset adjustments invalidate the previous effect")
        expect(key() != key("photo-a", "exposure=1", "look-v2"), "Replacing an external look invalidates its preview")
        expect(key() != key("photo-a", "exposure=1", "look-v1", 512), "Thumbnail resolution participates in the cache identity")
        expect(key("ab", "c") != key("a", "bc"), "Identity components cannot collide at a concatenation boundary")
        expect(PhotoPreviewCacheKey(identity: Data(), adjustments: Data(), edge: 256, rendererVersion: "v1") !=
               PhotoPreviewCacheKey(identity: Data(), adjustments: Data(), edge: 256, rendererVersion: "v2"),
               "Renderer changes invalidate previously rendered pixels")

        let cache = EditedPhotoPreviewCache(directory: directory, maximumEntries: 2, maximumBytes: 16)
        expect(try cache.read(key()) == nil, "A cold cache is a miss")
        try cache.write(Data([1, 2, 3]), for: key())
        let reopened = EditedPhotoPreviewCache(directory: directory, maximumEntries: 2, maximumBytes: 16)
        expect(try reopened.read(key()) == Data([1, 2, 3]), "A new cache instance restores the persisted preview")
        expect(try reopened.read(key("photo-a", "exposure=0")) == nil, "A reset never returns old adjusted pixels")
        try cache.write(Data([4, 5]), for: key("photo-b"))
        try cache.write(Data([6]), for: key("photo-c"))
        expect(try cache.read(key("photo-c")) == Data([6]), "The newest completed preview remains available")
        expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".preview") }.count == 2,
               "Persistent previews are bounded by entry count")
        try cache.write(Data(repeating: 7, count: 12), for: key("photo-d"))
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try urls.reduce(0) { total, url in total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        expect(bytes <= 16, "Persistent preview bytes remain bounded")
        try cache.write(Data(repeating: 8, count: 17), for: key("photo-e"))
        expect(try cache.read(key("photo-e")) == nil, "A single oversized image cannot exceed the cache budget")

        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocked)
        do {
            try EditedPhotoPreviewCache(directory: blocked).write(Data([2]), for: key())
            fatalError("FAIL: Cache IO failures must be reportable")
        } catch { print("PASS: Cache IO failures are reportable without modifying photo edits") }
    }
}
