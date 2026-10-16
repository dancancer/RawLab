import AppKit
import Foundation

@main
@MainActor struct FolderDropTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
        checks += 1
        print("PASS: \(message)")
    }

    static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    static func run() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rawlab-folder-drop-\(UUID().uuidString)", isDirectory: true)
        let domain = "com.rawtools.tests.folder-drop.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary); defaults.removePersistentDomain(forName: domain) }
        let first = temporary.appendingPathComponent("first photos", isDirectory: true)
        let second = temporary.appendingPathComponent("second", isDirectory: true)
        let empty = temporary.appendingPathComponent("empty", isDirectory: true)
        let package = temporary.appendingPathComponent("not-a-photo-folder.app", isDirectory: true)
        for url in [first, second, empty, package] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let photo = first.appendingPathComponent("private.DNG")
        try Data([1, 2, 3]).write(to: photo)
        let alias = temporary.appendingPathComponent("first-link")
        try fm.createSymbolicLink(at: alias, withDestinationURL: first)
        let library = PhotoLibrary(defaults: defaults)
        try check(library.roots.isEmpty, "The isolated library starts empty")
        try check(library.addDirectories([first]), "A dropped directory is accepted")
        try check(library.roots.map(\.url) == [first] && library.roots[0].expanded,
                  "A dropped directory appears as an expanded root (actual=\(library.roots.map { $0.url.absoluteString }), expected=\(first.absoluteString), expanded=\(library.roots.first?.expanded ?? false))")
        let originalRoot = library.roots[0]
        for _ in 0..<100 where originalRoot.loading { try await Task.sleep(for: .milliseconds(20)) }
        let loadedPhotos = originalRoot.photos.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        try check(!originalRoot.loading && originalRoot.error == nil && loadedPhotos == [photo.resolvingSymlinksInPath()],
                  "The dropped directory loads its RAW children through the existing folder path (loading=\(originalRoot.loading), error=\(originalRoot.error ?? "none"), photos=\(originalRoot.photos), expected=\(photo))")
        originalRoot.expanded = false
        try check(library.addDirectories([alias, first.appendingPathComponent(".")]),
                  "A duplicate or symlink directory remains an accepted drop")
        try check(library.roots.count == 1 && library.roots[0] === originalRoot && originalRoot.expanded,
                  "Canonical duplicate roots are expanded without duplication or replacement")
        try check(library.addDirectories([second, empty, first]), "Multiple directory URLs are accepted together")
        try check(library.roots.map(\.url) == [first, second, empty],
                  "New roots retain drop order and an empty directory is supported")
        let before = library.roots.map(\.url)
        let invalid = [photo, package, temporary.appendingPathComponent("missing"), URL(string: "https://example.com/photos")!]
        try check(!library.addDirectories(invalid), "Files, packages, missing paths and remote URLs are rejected")
        try check(!library.addDirectories([]) && library.roots.map(\.url) == before,
                  "Rejected and empty drops leave existing roots unchanged")
        let third = temporary.appendingPathComponent("third", isDirectory: true)
        try fm.createDirectory(at: third, withIntermediateDirectories: true)
        try check(library.addDirectories(invalid + [third]) && library.roots.map(\.url) == before + [third],
                  "A mixed drop adds only valid directories")
        let restored = PhotoLibrary(defaults: defaults)
        try check(restored.roots.map(\.url) == before + [third], "Dropped directory roots persist for reopening")
        try check(try Data(contentsOf: photo) == Data([1, 2, 3]), "Adding directories never modifies the source file")
        print("PASS: \(checks) folder-drop ingestion checks; no desktop drag was simulated")
    }
}
