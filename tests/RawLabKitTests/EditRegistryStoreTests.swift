import Foundation
import XCTest
@testable import RawLabKit

private struct TestStateA: Codable, Equatable {
    var value: Int
}

private struct TestRecordA: Equatable {
    var key: String
    var state: TestStateA?
}

private struct TestSchemaA: EditRegistrySchema {
    typealias IdentityKey = String
    typealias State = TestStateA
    typealias Record = TestRecordA

    static var requiresExistingDirectoryOnRead: Bool { true }
    static var createDirectoryOnLock: Bool { false }
    static var requiresVersionOnDecode: Bool { false }
    static var supportsDeletedTombstones: Bool { true }
    static var allowUTF8BOM: Bool { true }

    static var quarantinedCount = 0
    static func futureVersionError() -> Error { CocoaError(.coderReadCorrupt) }
    static func rootCorruptError(underlying: Error) -> Error { CocoaError(.fileReadCorruptFile) }
    static func didQuarantine(at url: URL, error: Error) { quarantinedCount += 1 }
}

private struct TestSchemaB: EditRegistrySchema {
    typealias IdentityKey = String
    typealias State = TestStateA
    typealias Record = TestRecordA

    static var requiresExistingDirectoryOnRead: Bool { false }
    static var createDirectoryOnLock: Bool { true }
    static var requiresVersionOnDecode: Bool { true }
    static var supportsDeletedTombstones: Bool { false }
    static var allowUTF8BOM: Bool { true }

    static func futureVersionError() -> Error { CocoaError(.coderReadCorrupt) }
    static func rootCorruptError(underlying: Error) -> Error { CocoaError(.fileReadCorruptFile) }
    static func didQuarantine(at url: URL, error: Error) {}
}

final class EditRegistryStoreTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditRegistryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testPerSchemaMetricsAndCacheIsolationAndQuarantine() throws {
        let dirA = temporaryRoot.appendingPathComponent("storeA", isDirectory: true)
        let dirB = temporaryRoot.appendingPathComponent("storeB", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)

        let storeA = EditRegistryStore<TestSchemaA>(directory: dirA)
        let storeB = EditRegistryStore<TestSchemaB>(directory: dirB)

        // Schema B allows non-existent directory on read; Schema A rejects missing dir.
        XCTAssertTrue(try storeB.readEnvelope().records.isEmpty)
        let missingDir = temporaryRoot.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try EditRegistryStore<TestSchemaA>(directory: missingDir).readEnvelope())

        var envA = EditRegistryEnvelope(version: 1, records: ["k1": Data("{\"value\":1}".utf8)], deleted: ["k2"])
        try storeA.withWriteLock {
            try storeA.writeEnvelope(&envA)
        }
        XCTAssertNotNil(storeA.lastWriteFingerprint)

        let readsABefore = EditRegistryStore<TestSchemaA>.registryDiskReadCount(forDirectory: dirA)
        let readsBBefore = EditRegistryStore<TestSchemaB>.registryDiskReadCount(forDirectory: dirB)
        let cachedA = try storeA.readEnvelope()
        XCTAssertEqual(cachedA.records["k1"], Data("{\"value\":1}".utf8))
        XCTAssertEqual(cachedA.deleted, ["k2"])
        XCTAssertEqual(EditRegistryStore<TestSchemaA>.registryDiskReadCount(forDirectory: dirA), readsABefore)
        XCTAssertEqual(EditRegistryStore<TestSchemaB>.registryDiskReadCount(forDirectory: dirB), readsBBefore)

        // Corrupt store A triggers quarantine and preserves corrupt bytes.
        TestSchemaA.quarantinedCount = 0
        try Data("{corrupt".utf8).write(to: storeA.fileURL)
        let recovered = try storeA.readEnvelope()
        XCTAssertTrue(recovered.records.isEmpty)
        XCTAssertEqual(TestSchemaA.quarantinedCount, 1)
        XCTAssertNotNil(storeA.lastQuarantinedURL)
        XCTAssertNotNil(storeA.consumeQuarantinedError())
        XCTAssertNil(storeA.consumeQuarantinedError())

        // Future version rejects without quarantine.
        let futureBytes = Data("{\"version\":2,\"records\":{}}".utf8)
        try futureBytes.write(to: storeA.fileURL)
        XCTAssertThrowsError(try storeA.readEnvelope())
        XCTAssertEqual(TestSchemaA.quarantinedCount, 1)
        XCTAssertEqual(try Data(contentsOf: storeA.fileURL), futureBytes)
    }

    func testStaleTempCleanupAndAsyncQueueOrderingAndFailureChaining() throws {
        let dir = temporaryRoot.appendingPathComponent("queue", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Create stale temp artifacts + one symlink + one regular edits.json
        try Data("{\"version\":1,\"records\":{}}".utf8).write(to: dir.appendingPathComponent("edits.json"))
        try Data("tmp1".utf8).write(to: dir.appendingPathComponent("edits.json.sb-123"))
        try Data("tmp2".utf8).write(to: dir.appendingPathComponent(".dat.nosync999"))
        try Data("tmp3".utf8).write(to: dir.appendingPathComponent("edits.json.abc.tmp"))
        try Data("tmp4".utf8).write(to: dir.appendingPathComponent(".edits.tmp"))
        let stagingDir = dir.appendingPathComponent("(A Document Being Saved By RawLab)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let symlinkTemp = dir.appendingPathComponent("edits.json.symlink.tmp")
        try FileManager.default.createSymbolicLink(at: symlinkTemp, withDestinationURL: dir.appendingPathComponent("edits.json"))

        let removed = EditRegistryStore<TestSchemaB>.removeStaleAtomicTempFiles(in: dir)
        XCTAssertEqual(removed, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("edits.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinkTemp.path))

        let store = EditRegistryStore<TestSchemaB>(directory: dir)
        let lock = NSLock()
        var outcomes: [String] = []
        var failFirst = true

        store.enqueueCommit(
            key: "itemA",
            chainIfUndeliveredFailure: true,
            operation: {
                if failFirst {
                    throw CocoaError(.fileWriteUnknown)
                }
                return (TestRecordA(key: "itemA", state: TestStateA(value: 1)), nil)
            },
            completion: { result in
                lock.lock(); outcomes.append("1:\((try? result.get().state?.value) ?? -1)"); lock.unlock()
            }
        )
        store.enqueueCommit(
            key: "itemA",
            chainIfUndeliveredFailure: true,
            operation: {
                return (TestRecordA(key: "itemA", state: TestStateA(value: 2)), nil)
            },
            completion: { result in
                lock.lock(); outcomes.append("2:\((try? result.get().state?.value) ?? -1)"); lock.unlock()
            }
        )
        store.enqueueCommit(
            key: "itemB",
            chainIfUndeliveredFailure: true,
            operation: {
                return (TestRecordA(key: "itemB", state: TestStateA(value: 3)), nil)
            },
            completion: { result in
                lock.lock(); outcomes.append("3:\((try? result.get().state?.value) ?? -1)"); lock.unlock()
            }
        )

        XCTAssertFalse(store.flushPendingCommits())
        XCTAssertFalse(store.hasPendingCommits)
        XCTAssertEqual(outcomes, ["1:-1", "2:-1", "3:3"])

        failFirst = false
        _ = try store.performSync(clearingFailedKeys: { _ in ["itemA"] }) { true }
        let exp = expectation(description: "retry succeeds")
        store.enqueueCommit(
            key: "itemA",
            chainIfUndeliveredFailure: true,
            operation: {
                (TestRecordA(key: "itemA", state: TestStateA(value: 4)), nil)
            },
            completion: { result in
                XCTAssertEqual((try? result.get().state?.value), 4)
                exp.fulfill()
            }
        )
        XCTAssertTrue(store.flushPendingCommits())
        wait(for: [exp], timeout: 5)
    }

    func testFileDigestCacheDigestAndFingerprint() throws {
        let file = temporaryRoot.appendingPathComponent("lut.cube")
        let bytes = Data("LUT_3D_SIZE 2\n0 0 0\n".utf8)
        try bytes.write(to: file)

        let cache = FileDigestCache(maximumEntries: 4)
        var hashCalls = 0
        let res1 = try cache.digestAndFingerprint(for: file, maximumBytes: 1024, onHash: { hashCalls += 1 })
        let res2 = try cache.digestAndFingerprint(for: file, maximumBytes: 1024, onHash: { hashCalls += 1 })
        XCTAssertEqual(hashCalls, 1)
        XCTAssertEqual(res1.digest, res2.digest)
        XCTAssertEqual(res1.hex, res2.hex)
        XCTAssertEqual(res1.identity, res2.identity)
        XCTAssertThrowsError(try cache.digestAndFingerprint(for: file, maximumBytes: 4))
    }
}
