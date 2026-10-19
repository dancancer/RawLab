import Foundation
import ImageIO
import UIKit

enum ImportCacheLifetimeTests {
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure.message(message) }
        print("PASS: \(message)")
    }

    private static func publish(_ f: Fixture, url: URL, identity: PhotoIdentity) throws {
        f.model.importImage(from: .raster(url), identity: identity)
        try f.collector.take().forEach { $0() }
        try check(f.model.hasImage && f.model.sourceIdentity == identity, "Cache fixture publishes a real decoded photo")
    }

    private static func files(near url: URL) throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                       includingPropertiesForKeys: nil))
    }

    private static func rejectedReimport(_ f: Fixture, fails: Bool, cancelled: Bool) throws {
        try publish(f, url: f.aURL, identity: f.aIdentity)
        let oldURL = f.model.sourceURL!
        let original = try Data(contentsOf: oldURL)
        let baseline = try files(near: oldURL)
        let replacement = f.bURL.deletingLastPathComponent().appendingPathComponent("invalid.png")
        if fails { try Data("not an image".utf8).write(to: replacement) }
        let request = f.model.importImage(from: .raster(fails ? replacement : f.bURL), identity: f.aIdentity)
        var held = try f.collector.take()
        try check(try Data(contentsOf: oldURL) == original && CGImageSourceCreateWithURL(oldURL as CFURL, nil) != nil,
                  "Same-identity reimport cannot mutate the published file before \(fails ? "failure" : "success") delivery")
        if cancelled { f.model.cancelImageImport(request) }
        else {
            f.model.importImage(from: .raster(f.bURL), identity: f.bIdentity)
        }
        held.forEach { $0() }
        held.removeAll()
        try check(try Data(contentsOf: oldURL) == original, "Rejected reimport leaves the old photo readable and unchanged")
        if cancelled {
            try check(try files(near: oldURL) == baseline, "Cancelled \(fails ? "failed" : "successful") import leaves no extra cache file")
        } else {
            try f.collector.take().forEach { $0() }
            try check(try files(near: f.model.sourceURL!) == baseline.subtracting([oldURL]).union([f.model.sourceURL!]),
                      "Superseded \(fails ? "failed" : "successful") import leaves only the new published file")
        }
    }

    private static func currentFailure(_ f: Fixture, afterCopy: Bool) throws {
        try publish(f, url: f.aURL, identity: f.aIdentity)
        var reader = f.model.currentBatchSource(settings: .default)
        let oldURL = reader!.sourceURL
        let original = try Data(contentsOf: oldURL)
        let baseline = try files(near: oldURL)
        let invalid = f.aURL.deletingLastPathComponent().appendingPathComponent("broken.png")
        if afterCopy { try Data("not an image".utf8).write(to: invalid) }
        f.model.importImage(from: .raster(invalid), identity: f.aIdentity)
        try f.collector.take().forEach { $0() }
        try check(try Data(contentsOf: oldURL) == original && CGImageSourceCreateWithURL(oldURL as CFURL, nil) != nil,
                  "Current import failure \(afterCopy ? "after decode" : "during copy") cannot destroy a captured source")
        try check(f.model.statusMessage != nil && !f.model.isBusy && f.model.sourceURL == nil,
                  "Current failure still reports the error and clears the editor as before")
        try check(try files(near: oldURL) == baseline, "Failed import leaves no extra copy while the old reader is alive")
        withExtendedLifetime(reader) {}
        reader = nil
        try check(try files(near: oldURL) == baseline.subtracting([oldURL]),
                  "Last reader release removes the old photo after a failed import")
    }

    private static func batchSnapshot(_ f: Fixture) throws {
        try publish(f, url: f.aURL, identity: f.aIdentity)
        var source = f.model.currentBatchSource(settings: f.aSettings)
        let oldURL = source!.sourceURL
        let original = try Data(contentsOf: oldURL)
        let baseline = try files(near: oldURL)
        try publish(f, url: f.bURL, identity: f.bIdentity)
        var job = BatchExportJob(source: source!, targets: [])
        source = nil
        let root = f.aURL.deletingLastPathComponent().appendingPathComponent("batch")
        try BatchInputStore.prepare(&job, look: nil, root: root)
        try check(try Data(contentsOf: job.source.sourceURL) == original && job.source.sourceURL != oldURL,
                  "A captured batch source freezes the old bytes after a new photo publishes")
        try check(try files(near: f.model.sourceURL!) == baseline.subtracting([oldURL]).union([f.model.sourceURL!]),
                  "Batch preparation releases the editor copy after freezing its own input")
        let decoded = try JSONDecoder().decode(BatchExportJob.self, from: JSONEncoder().encode(job))
        try check(decoded == job, "Runtime cache ownership does not change the batch journal format or equality")
    }

    private static func successfulReimport(_ f: Fixture) throws {
        try publish(f, url: f.aURL, identity: f.aIdentity)
        let firstURL = f.model.sourceURL!
        try publish(f, url: f.bURL, identity: f.aIdentity)
        try check(try Data(contentsOf: f.model.sourceURL!) == Data(contentsOf: f.bURL),
                  "Successful same-identity reimport publishes the new source bytes")
        try check(f.model.sourceURL != firstURL && f.model.restoredSettings == f.aSettings,
                  "Cache paths change independently of PhotoIdentity and restored edits")
    }

    private static func repeatedImports(_ f: Fixture) throws {
        try publish(f, url: f.aURL, identity: f.aIdentity)
        let initial = try files(near: f.model.sourceURL!)
        let unrelated = initial.subtracting([f.model.sourceURL!])
        for index in 0..<12 {
            try publish(f, url: index.isMultiple(of: 2) ? f.bURL : f.aURL,
                        identity: PhotoIdentity(resourceIdentifier: "cache-repeat-\(UUID().uuidString)"))
            try check(try files(near: f.model.sourceURL!) == unrelated.union([f.model.sourceURL!]),
                      "Repeated imports retain only the current photo after readers finish (\(index + 1))")
        }
    }

    private static func cachedInput(_ f: Fixture) throws {
        try publish(f, url: f.aURL, identity: f.aIdentity)
        let previousURL = f.model.sourceURL!
        let bytes = try Data(contentsOf: previousURL)
        try publish(f, url: previousURL, identity: f.aIdentity)
        try check(f.model.sourceURL != previousURL && (try Data(contentsOf: f.model.sourceURL!)) == bytes,
                  "Importing an already cached source still creates a separately owned immutable copy")
    }

    static func run(root: URL) throws {
        let manager = FileManager.default
        let cache = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab", isDirectory: true)
        let stale = cache.appendingPathComponent("ImportedPhotos/stale-copy.png")
        let legacy = cache.appendingPathComponent("photo:cache-lifetime-legacy.png")
        try manager.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abandoned copy".utf8).write(to: stale)
        try Data("legacy photo".utf8).write(to: legacy)
        defer { try? manager.removeItem(at: legacy) }
        let input = root.appendingPathComponent("retry-source.png")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("retry source".utf8).write(to: input)
        let managed = stale.deletingLastPathComponent()
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: managed.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: managed.path) }
        var rejected = false
        do { _ = try CachedPhotoFile.copy(input) }
        catch { rejected = true }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: managed.path)
        try check(rejected, "An inaccessible stale cache surfaces the first initialization error")
        do {
            let retried = try CachedPhotoFile.copy(input)
            try check(try Data(contentsOf: retried.url) == Data("retry source".utf8),
                      "Cache initialization retries after a transient directory failure")
        }
        for fails in [false, true] {
            for cancelled in [false, true] {
                try rejectedReimport(Fixture(directory: root.appendingPathComponent("rejected-\(fails)-\(cancelled)")),
                                     fails: fails, cancelled: cancelled)
            }
        }
        try successfulReimport(Fixture(directory: root.appendingPathComponent("successful-reimport")))
        try cachedInput(Fixture(directory: root.appendingPathComponent("cached-input")))
        for afterCopy in [false, true] {
            try currentFailure(Fixture(directory: root.appendingPathComponent("current-failure-\(afterCopy)")),
                               afterCopy: afterCopy)
        }
        try batchSnapshot(Fixture(directory: root.appendingPathComponent("batch-snapshot")))
        try repeatedImports(Fixture(directory: root.appendingPathComponent("repeated-imports")))
        try check(!manager.fileExists(atPath: stale.path) && (try Data(contentsOf: legacy)) == Data("legacy photo".utf8),
                  "First import reclaims abandoned managed copies without touching legacy identity files")
        print("PASS: import cache lifetime regression suite")
    }
}
