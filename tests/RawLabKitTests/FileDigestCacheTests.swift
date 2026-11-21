import Foundation
import XCTest
@testable import RawLabKit

final class FileDigestCacheTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLabKitDigestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testFileDigestCacheHitsAndInvalidation() throws {
        let fileA = temporaryRoot.appendingPathComponent("a.bin")
        let fileB = temporaryRoot.appendingPathComponent("b.bin")
        let symlinkA = temporaryRoot.appendingPathComponent("a-link.bin")
        try Data("alpha-content".utf8).write(to: fileA)
        try Data("beta-content".utf8).write(to: fileB)
        try FileManager.default.createSymbolicLink(at: symlinkA, withDestinationURL: fileA)

        let cache = FileDigestCache(maximumEntries: 2)
        let d1 = try cache.digest(for: fileA)
        let d2 = try cache.digest(for: symlinkA)
        XCTAssertEqual(d1, d2)
        XCTAssertEqual(cache.digestComputeCount, 1)

        // Overwrite with modified content -> stat changes -> recomputes
        try Data("alpha-updated-longer-bytes".utf8).write(to: fileA)
        let d3 = try cache.digest(for: fileA)
        XCTAssertNotEqual(d1, d3)
        XCTAssertEqual(cache.digestComputeCount, 2)

        // Bounded eviction
        let fileC = temporaryRoot.appendingPathComponent("c.bin")
        try Data("gamma-content".utf8).write(to: fileC)
        _ = try cache.digest(for: fileB)
        _ = try cache.digest(for: fileC)
        XCTAssertEqual(cache.entryCount, 2)
    }

    func testMacResourceDigestCacheHitsAndMaximumBytes() throws {
        let file = temporaryRoot.appendingPathComponent("preset.json")
        try Data("{\"ok\":true}".utf8).write(to: file)
        let cache = MacResourceDigestCache(maximumEntries: 4)
        let first = try cache.fingerprintDigest(for: file, maxBytes: 1024)
        let second = try cache.fingerprintDigest(for: file, maxBytes: 1024)
        XCTAssertEqual(first.digest, second.digest)
        XCTAssertEqual(cache.sha256Count, 1)
        XCTAssertThrowsError(try cache.fingerprintDigest(for: file, maxBytes: 4))
    }

    func testRecentPhotoStoreRecordsSourcesAndBoundedEviction() throws {
        let src1 = temporaryRoot.appendingPathComponent("one.ARW")
        let src2 = temporaryRoot.appendingPathComponent("two.ARW")
        try Data(repeating: 1, count: 64).write(to: src1)
        try Data(repeating: 2, count: 64).write(to: src2)

        let storeDir = temporaryRoot.appendingPathComponent("recent", isDirectory: true)
        let store = try RecentPhotoStore(directory: storeDir, maximumEntries: 1, maximumOriginalBytes: 128)
        let id1 = try PhotoIdentity.fallback(for: src1)
        let id2 = try PhotoIdentity.fallback(for: src2)

        let p1 = try store.recordOpened(url: src1, identity: id1, displayName: "one.ARW", isRaw: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.sourceURL(for: p1).path))

        let p2 = try store.recordOpened(url: src2, identity: id2, displayName: "two.ARW", isRaw: true)
        XCTAssertEqual(try store.records().map(\.id), [p2.id])
        XCTAssertThrowsError(try store.sourceURL(for: p1))
    }
}
