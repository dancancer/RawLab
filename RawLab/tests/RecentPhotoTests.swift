import CryptoKit
import Darwin
import Foundation

@main struct RecentPhotoTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
        print("PASS: \(message)")
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "Expected failure", code: 1)
    }
    static func main() throws {
        try testRecentPhotoRetentionAndRejection()
        try testEditPersistenceReadBudgetAndBatchIsolation()
        try testRegistryCacheInvalidationSymlinkAndLRU()
        try testFileDigestCacheHitInvalidationStabilityAndLRU()
    }

    private static func testRecentPhotoRetentionAndRejection() throws {
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
        let retainedHashBefore = FileDigestCache.shared.digestComputeCount(for: retained)
        _ = try reopened.sourceURL(for: first)
        try check(FileDigestCache.shared.digestComputeCount(for: retained) == retainedHashBefore, "Warm RecentPhotoStore.sourceURL reuses stat-validated digest without re-hashing")
        _ = try reopened.recordOpened(url: retained, identity: identity, displayName: "renamed.dng", isRaw: true, now: Date(timeIntervalSince1970: 2))
        try check((try reopened.records()).count == 1 && (try reopened.records())[0].displayName == "renamed.dng", "Same identity updates without duplicating")
        try Data([4, 5, 6]).write(to: file)
        let other = try PhotoIdentity.fallback(for: file)
        _ = try reopened.recordOpened(url: file, identity: other, displayName: "renamed.dng", isRaw: true, now: Date(timeIntervalSince1970: 3))
        try check((try reopened.records()).count == 2 && (try reopened.records())[0].identity == other, "Equal filenames stay independent and most recent comes first")
        let key = PhotoPreviewCacheKey(identity: Data([1]), adjustments: Data([2]), edge: 256)
        try reopened.savePreview(Data([9, 8]), key: key, for: first.identity)
        try check(try reopened.lastPreview(for: first) == Data([9, 8]), "Last preview persists independently of the original")
        // Same-size overwrite must invalidate cached digest immediately and reject the tampered retained original.
        try Data([9, 9, 9]).write(to: retained)
        try rejects { _ = try reopened.sourceURL(for: first) }
        try check((try reopened.records()).contains { $0.id == first.id }, "Same-size tampered original is rejected without deleting metadata")
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

    private static func testEditPersistenceReadBudgetAndBatchIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let editsDir = root.appendingPathComponent("edits")
        let recentsDir = root.appendingPathComponent("recents")
        let editStore = try EditPersistence(directory: editsDir)
        let recentStore = try RecentPhotoStore(directory: recentsDir, maximumEntries: 100, maximumOriginalBytes: 64 * 1024 * 1024)

        var identities = [PhotoIdentity]()
        for i in 0..<100 {
            let f = root.appendingPathComponent("raw-\(i).dng")
            try Data("img-\(i)".utf8).write(to: f)
            let id = try PhotoIdentity.cachedFallback(for: f, resourceIdentifier: "asset-\(i)")
            identities.append(id)
            _ = try recentStore.recordOpened(url: f, identity: id, displayName: "raw-\(i).dng", isRaw: true, now: Date(timeIntervalSince1970: Double(i)))
            var s = RawSettings.default
            s.exposure = Double(i % 5) * 0.25
            try editStore.save(id, state: PhotoEditState(settings: s))
        }

        // Warm commit + fresh reopen + 100-item batch read must stay <= 2 whole-file reads.
        let readsBeforeCommit = EditPersistence.registryDiskReadCount(forDirectory: editsDir)
        var modified = RawSettings.default; modified.exposure = 1.75
        try editStore.save(identities[0], state: PhotoEditState(settings: modified))
        let reloaded = try EditPersistence(directory: editsDir)
        let batch = try reloaded.readStates(for: identities)
        let readsDelta = EditPersistence.registryDiskReadCount(forDirectory: editsDir) - readsBeforeCommit
        try check(readsDelta <= 2, "P2-04: 100-photo commit+reload reads \(readsDelta) <= 2")
        try check(batch.count == 100, "P2-04: readStates returned all 100 identities")
        if case .success(let firstRecord) = batch[identities[0]] {
            try check(firstRecord.state?.settings.exposure == 1.75, "P2-04: committed adjustment visible in batch reload")
        } else {
            try check(false, "P2-04: expected healthy first record")
        }
        // Repeated readStates across another EditPersistence instance hits RegistryCache with 0 reads.
        let secondReadsBefore = EditPersistence.registryDiskReadCount(forDirectory: editsDir)
        let cachedStore = try EditPersistence(directory: editsDir)
        let secondBatch = try cachedStore.readStates(for: identities)
        let secondReadsDelta = EditPersistence.registryDiskReadCount(forDirectory: editsDir) - secondReadsBefore
        try check(secondReadsDelta == 0 && secondBatch.count == 100, "P2-04: subsequent batch reopen hits RegistryCache with 0 disk reads")

        // Partial corrupt entry isolation + legacy unverified asset edit handling inside readStates.
        let partialDir = root.appendingPathComponent("partial-corrupt")
        let partialStore = try EditPersistence(directory: partialDir)
        let healthyID = PhotoIdentity(resourceIdentifier: "healthy-res", contentIdentifier: String(repeating: "a", count: 64))
        let corruptID = PhotoIdentity(resourceIdentifier: "corrupt-res", contentIdentifier: String(repeating: "b", count: 64))
        let legacyOnlyAsset = PhotoIdentity(resourceIdentifier: "legacy-res")
        let legacyResWithBytes = PhotoIdentity(resourceIdentifier: "legacy-res", contentIdentifier: String(repeating: "c", count: 64))
        var hs = RawSettings.default; hs.contrast = 1.2
        try partialStore.save(healthyID, state: PhotoEditState(settings: hs))
        var ls = RawSettings.default; ls.saturation = 1.2
        try partialStore.save(legacyOnlyAsset, state: PhotoEditState(settings: ls))

        let editsFile = partialDir.appendingPathComponent("edits.json")
        var rawJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: editsFile)) as! [String: Any]
        var recordsDict = rawJSON["records"] as! [String: Any]
        let corruptEditKey = "photo-content:\(corruptID.resourceIdentifier!.utf8.count):\(corruptID.resourceIdentifier!):\(corruptID.contentIdentifier!)"
        recordsDict[corruptEditKey] = ["not": "valid-edit-state"]
        rawJSON["records"] = recordsDict
        try JSONSerialization.data(withJSONObject: rawJSON, options: [.sortedKeys]).write(to: editsFile)

        let reopenedPartial = try EditPersistence(directory: partialDir)
        let rBeforeBatch = EditPersistence.registryDiskReadCount(forDirectory: partialDir)
        let partialResult = try reopenedPartial.readStates(for: [healthyID, corruptID, legacyResWithBytes], requiringLegacyDecision: true)
        let rBatchDelta = EditPersistence.registryDiskReadCount(forDirectory: partialDir) - rBeforeBatch
        try check(rBatchDelta == 0, "P2-04: single-read readStates after reopen performs 0 extra disk reads")
        // Verify a cold batch read on an already-open EditPersistence reads edits.json only once for all 3 entries.
        var times = [timespec(tv_sec: 1_700_000_050, tv_nsec: 0), timespec(tv_sec: 1_700_000_051, tv_nsec: 0)]
        _ = editsFile.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) }
        let rBeforeColdBatch = EditPersistence.registryDiskReadCount(forDirectory: partialDir)
        _ = try reopenedPartial.readStates(for: [healthyID, corruptID, legacyResWithBytes], requiringLegacyDecision: true)
        try check(EditPersistence.registryDiskReadCount(forDirectory: partialDir) - rBeforeColdBatch == 1,
                  "P2-04: cold readStates reads edits.json 1 time for entire batch")
        if case .success(let rec) = partialResult[healthyID] {
            try check(rec.state?.settings.contrast == 1.2, "P2-04: healthy record remains readable alongside corrupt sibling")
        } else {
            try check(false, "P2-04: expected healthy sibling in partial corrupt store")
        }
        if case .failure(let err) = partialResult[corruptID] {
            try check(err is UnusableEditRecordError, "P2-04: corrupt sibling isolates to UnusableEditRecordError")
        } else {
            try check(false, "P2-04: expected UnusableEditRecordError for corrupt entry")
        }
        if case .failure(let err) = partialResult[legacyResWithBytes],
           case .legacyAssetEditNeedsDecision? = err as? EditPersistenceError {
            print("PASS: P2-04: legacy asset edit reports legacyAssetEditNeedsDecision without aborting batch")
        } else {
            try check(false, "P2-04: expected legacyAssetEditNeedsDecision in batch readStates")
        }
    }

    private static func testRegistryCacheInvalidationSymlinkAndLRU() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Symlink directory switching (dirA <-> dirB) must never alias across targets.
        let dirA = root.appendingPathComponent("dirA")
        let dirB = root.appendingPathComponent("dirB")
        let linkDir = root.appendingPathComponent("link-dir")
        let idA = PhotoIdentity(contentIdentifier: String(repeating: "1", count: 64))
        let idB = PhotoIdentity(contentIdentifier: String(repeating: "2", count: 64))
        var sA = RawSettings.default; sA.exposure = 1.0
        var sB = RawSettings.default; sB.exposure = -1.0
        try EditPersistence(directory: dirA).save(idA, state: PhotoEditState(settings: sA))
        try EditPersistence(directory: dirB).save(idB, state: PhotoEditState(settings: sB))
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: dirA)
        let openA = try EditPersistence(directory: linkDir)
        try check(openA.readState(for: idA).state?.settings.exposure == 1.0, "RegistryCache symlink initially resolves dirA")
        try FileManager.default.removeItem(at: linkDir)
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: dirB)
        let openB = try EditPersistence(directory: linkDir)
        try check(openB.readState(for: idB).state?.settings.exposure == -1.0 && openB.readState(for: idA).state == nil,
                  "RegistryCache symlink switch dirA -> dirB never leaks dirA cache")

        // External corruption, deletion, and transient directory unavailability fallback.
        let invDir = root.appendingPathComponent("invalidation")
        let invStore = try EditPersistence(directory: invDir)
        try invStore.save(idA, state: PhotoEditState(settings: sA))
        let invFile = invDir.appendingPathComponent("edits.json")
        _ = try invStore.readState(for: idA)
        try Data("{corrupt".utf8).write(to: invFile)
        try rejects { _ = try invStore.readState(for: idA) }
        try check(invStore.state(for: idA)?.settings.exposure == 1.0, "Transient/corrupt fallback preserves lastReadableStore for legacy state(for:)")
        try rejects { _ = try EditPersistence(directory: invDir) }
        try FileManager.default.removeItem(at: invFile)
        let emptyAfterDelete = try EditPersistence(directory: invDir)
        try check(emptyAfterDelete.readState(for: idA).state == nil, "External edits.json deletion evicts cached snapshot")

        // Bounded LRU capacity (32): creating 33 directories must evict the oldest directory cleanly.
        var lruDirs = [URL]()
        for i in 0..<33 {
            let d = root.appendingPathComponent("lru-\(i)")
            lruDirs.append(d)
            var st = RawSettings.default; st.exposure = Double(i) * 0.1
            try EditPersistence(directory: d).save(idA, state: PhotoEditState(settings: st))
            _ = try EditPersistence(directory: d)
        }
        let newestBefore = EditPersistence.registryDiskReadCount(forDirectory: lruDirs[32])
        _ = try EditPersistence(directory: lruDirs[32])
        try check(EditPersistence.registryDiskReadCount(forDirectory: lruDirs[32]) == newestBefore,
                  "RegistryCache retains most-recently-used directory within 32-entry cap")
        let oldestBefore = EditPersistence.registryDiskReadCount(forDirectory: lruDirs[0])
        _ = try EditPersistence(directory: lruDirs[0])
        try check(EditPersistence.registryDiskReadCount(forDirectory: lruDirs[0]) == oldestBefore + 1,
                  "RegistryCache evicts oldest directory past 32-entry LRU bound")
    }

    private static func testFileDigestCacheHitInvalidationStabilityAndLRU() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = FileDigestCache(maximumEntries: 4)
        let file = root.appendingPathComponent("asset.cube")
        try Data("abcd1234".utf8).write(to: file)

        let expectedSHA = SHA256.hash(data: Data("abcd1234".utf8)).map { String(format: "%02x", $0) }.joined()
        try check(try cache.digest(for: file) == expectedSHA, "FileDigestCache computes exact SHA-256")
        try check(cache.digestComputeCount(for: file) == 1, "Cold hash computes 1 time")
        for _ in 0..<5 {
            _ = try cache.digest(for: file, maximumBytes: 32 * 1024 * 1024)
        }
        try check(cache.digestComputeCount(for: file) == 1, "Repeated warm lookups perform 0 hashes")

        // Mtime touch invalidates even with unchanged bytes.
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 111), timespec(tv_sec: 1_700_000_001, tv_nsec: 222)]
        _ = file.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) }
        _ = try cache.digest(for: file)
        try check(cache.digestComputeCount(for: file) == 2, "mtime update invalidates FileDigestCache")

        // Size change invalidates.
        try Data("abcd12345".utf8).write(to: file)
        _ = try cache.digest(for: file)
        try check(cache.digestComputeCount(for: file) == 3, "Size change invalidates FileDigestCache")

        // Same-size overwrite invalidates.
        try Data("wxyz98765".utf8).write(to: file)
        _ = try cache.digest(for: file)
        try check(cache.digestComputeCount(for: file) == 4, "Same-size rewrite invalidates FileDigestCache")

        // chmod 000 invalidates via mode/ctime check instead of serving stale digest.
        _ = file.path.withCString { chmod($0, 0o000) }
        defer { _ = file.path.withCString { chmod($0, 0o644) } }
        try rejects { _ = try cache.digest(for: file) }
        _ = file.path.withCString { chmod($0, 0o644) }

        // Symlink swap fileA <-> fileB.
        let targetA = root.appendingPathComponent("a.bin")
        let targetB = root.appendingPathComponent("b.bin")
        let sym = root.appendingPathComponent("link.bin")
        try Data("alpha".utf8).write(to: targetA)
        try Data("bravo".utf8).write(to: targetB)
        try FileManager.default.createSymbolicLink(at: sym, withDestinationURL: targetA)
        let dA = try cache.digest(for: sym)
        try FileManager.default.removeItem(at: sym)
        try FileManager.default.createSymbolicLink(at: sym, withDestinationURL: targetB)
        let dB = try cache.digest(for: sym)
        try check(dA != dB, "FileDigestCache symlink swap computes distinct digests for A and B")

        // Deletion fails closed.
        try FileManager.default.removeItem(at: targetB)
        try rejects { _ = try cache.digest(for: sym) }

        // Empty and >maximumBytes files are rejected without polluting cache.
        let emptyFile = root.appendingPathComponent("empty.cube")
        try Data().write(to: emptyFile)
        try rejects { _ = try cache.digest(for: emptyFile, maximumBytes: 1024) }
        let overFile = root.appendingPathComponent("over.cube")
        try Data(repeating: 7, count: 16).write(to: overFile)
        try rejects { _ = try cache.digest(for: overFile, maximumBytes: 8) }

        // Mid-read mutation stability guard without sleep: stabilizes on attempt 1 -> succeeds; mutates all attempts -> fails closed.
        let raceFile = root.appendingPathComponent("race.bin")
        try Data("v0".utf8).write(to: raceFile)
        var recoveredOnce = false
        let recoveringCache = FileDigestCache(maximumEntries: 4) { url, attempt in
            if attempt == 0, !recoveredOnce {
                recoveredOnce = true
                try? Data("v1-stable".utf8).write(to: url)
            }
        }
        let expectedV1 = SHA256.hash(data: Data("v1-stable".utf8)).map { String(format: "%02x", $0) }.joined()
        try check(try recoveringCache.digest(for: raceFile) == expectedV1 && recoveredOnce,
                  "FileDigestCache retries and recovers when file stabilizes after mid-read mutation")

        let alwaysMutatingCache = FileDigestCache(maximumEntries: 4) { url, attempt in
            try? Data("mut-\(attempt)".utf8).write(to: url)
        }
        try rejects { _ = try alwaysMutatingCache.digest(for: raceFile) }
        try check(alwaysMutatingCache.entryCount == 0, "Continuously mutating file fails closed without caching torn bytes")

        // Bounded LRU eviction (maximumEntries = 2).
        let smallCache = FileDigestCache(maximumEntries: 2)
        let f1 = root.appendingPathComponent("f1.bin")
        let f2 = root.appendingPathComponent("f2.bin")
        let f3 = root.appendingPathComponent("f3.bin")
        try Data("1".utf8).write(to: f1); try Data("2".utf8).write(to: f2); try Data("3".utf8).write(to: f3)
        _ = try smallCache.digest(for: f1)
        _ = try smallCache.digest(for: f2)
        _ = try smallCache.digest(for: f3)
        try check(smallCache.entryCount == 2, "FileDigestCache stays bounded at maximumEntries (2)")
        _ = try smallCache.digest(for: f3)
        try check(smallCache.digestComputeCount(for: f3) == 1, "Most recent FileDigestCache entry stays warm")
        _ = try smallCache.digest(for: f1)
        try check(smallCache.digestComputeCount(for: f1) == 2, "Oldest FileDigestCache entry is evicted past LRU capacity")
    }
}
