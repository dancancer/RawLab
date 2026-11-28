import Foundation
import XCTest
@testable import RawLabKit

final class IOSAdjustmentPersistenceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawlab-ios-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func assertRejects(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), label, file: file, line: line)
    }

    func testCoreSaveReadResetAndAtomicFailure() throws {
        let dir = root.appendingPathComponent("core")
        let first = try EditPersistence(directory: dir), second = try EditPersistence(directory: dir)
        let a = PhotoIdentity(resourceIdentifier: "a"), b = PhotoIdentity(resourceIdentifier: "b")
        var settings = RawSettings.default; settings.exposure = 1
        try first.save(a, state: .init(settings: settings))
        settings.exposure = 2; try second.save(b, state: .init(settings: settings))
        let reopened = try EditPersistence(directory: dir)
        XCTAssertTrue(
            try reopened.state(for: a)?.settings.exposure == 1 && reopened.state(for: b)?.settings.exposure == 2,
            "Independent store instances preserve both photos"
        )
        XCTAssertEqual(try first.state(for: b)?.settings.exposure, 2, "Existing readers observe another instance's save")
        let saved = try first.readState(for: a, isX3f: false)
        XCTAssertEqual(saved.state?.settings.exposure, 1, "A successful edit creates a readable photo record")
        let metadataOnly = PhotoEditState(settings: saved.state!.settings, updatedAt: Date(timeIntervalSince1970: 999))
        let unchanged = try first.saveState(identity: saved.identity, state: metadataOnly)
        XCTAssertTrue(unchanged.hasSameAdjustments(as: saved), "Timestamp-only changes do not rewrite the stored adjustments")
        settings.exposure = 3
        let changed = try first.saveState(identity: saved.identity, state: .init(settings: settings))
        XCTAssertEqual(changed.state?.settings.exposure, 3, "SaveState writes the requested adjustment atomically")
        let later = try second.saveState(identity: saved.identity, state: metadataOnly)
        XCTAssertEqual(later.state?.settings.exposure, 1, "Independent writers use the current session intent instead of a disk revision")
        let missing = PhotoIdentity(resourceIdentifier: "missing")
        let absent = try first.readState(for: missing, isX3f: false)
        _ = try first.saveState(identity: absent.identity, state: metadataOnly)
        try first.reset(missing)
        let deleted = try first.readState(for: missing, isX3f: false)
        XCTAssertNil(deleted.state, "Deletion removes the current record without a revision tombstone")
        _ = try first.saveState(identity: absent.identity, state: metadataOnly)
        XCTAssertEqual(try first.state(for: missing)?.settings, metadataOnly.settings, "A later ordinary save can recreate a deleted record")
        let file = dir.appendingPathComponent("edits.json"), bytes = try Data(contentsOf: file)
        let failing = try EditPersistence(directory: dir, writeData: { _, _ in throw NSError(domain: "injected write", code: 1) })
        settings.exposure = -1
        assertRejects("Injected atomic write failure is reported") {
            _ = try failing.saveState(identity: changed.identity, state: .init(settings: settings))
        }
        XCTAssertTrue(
            try Data(contentsOf: file) == bytes && first.readState(for: a, isX3f: false).state?.settings.exposure == 1,
            "Write failure preserves the registry"
        )
        var invalid = settings; invalid.exposure = .nan
        assertRejects("Invalid JSON cannot replace the old registry") {
            try first.save(a, state: .init(settings: invalid))
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes, "Encoding failure preserves the registry")
        assertRejects("Invalid identity cannot be saved") {
            try first.save(.init(resourceIdentifier: ""), state: metadataOnly)
        }
    }

    func testProcessingMigration() throws {
        let dir = root.appendingPathComponent("processing-migration")
        let store = try EditPersistence(directory: dir)
        let content = PhotoIdentity(contentIdentifier: "migration-content")
        let photo = PhotoIdentity(resourceIdentifier: "migration-asset", contentIdentifier: "migration-content")
        var old = RawSettings.default; old.processing = .c5; old.exposure = 0.5; old.highlights = 0.2
        old.lutID = "saved-look"; old.clarity = 14
        let before = PhotoEditState(settings: old, filmID: "exact-film-id", updatedAt: Date(timeIntervalSince1970: 42))
        try store.save(content, state: before)
        let expected = try store.readState(for: content, isX3f: false)
        var newer = old; newer.processing = .current; newer.highlights = 0.12
        let candidate = before.replacing(settings: newer, preservingFilmID: before.filmID)
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.002, worstTileRMSE: 0.003,
                                                 detailRMSE: 0.001, evaluations: 20)
        let file = dir.appendingPathComponent("edits.json"), bytes = try Data(contentsOf: file)
        let failing = try EditPersistence(directory: dir, writeData: { _, _ in throw NSError(domain: "injected write", code: 1) })
        assertRejects("Migration write failure is atomic") {
            _ = try failing.commitProcessingMigration(expected: expected, candidate: candidate, quality: quality)
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes, "Failed migration preserves old record bytes")
        _ = try store.commitProcessingMigration(expected: expected, candidate: candidate, quality: quality)
        let reopened = try EditPersistence(directory: dir)
        XCTAssertEqual(try reopened.processingMigration(for: photo)?.original, before, "PhotoKit content fallback retains migration rollback")
        var later = newer; later.exposure = 1.5
        try reopened.save(photo, state: before.replacing(settings: later, preservingFilmID: before.filmID))
        XCTAssertEqual(try reopened.processingMigration(for: photo)?.original, before, "Creating a preferred resource record preserves the alias backup")
        let restored = try reopened.rollbackProcessingMigration(expected: reopened.readState(for: photo, isX3f: false), isX3f: false)
        XCTAssertEqual(restored.state, before, "Restart-safe rollback restores full old state and exact film ID")
        let receipt = try XCTUnwrap(reopened.processingMigration(for: photo))
        XCTAssertTrue(
            receipt.status == .rolledBack && !receipt.shouldAttempt(current: before, sourceVersion: 2),
            "Rolled-back resource no longer automatically migrates"
        )
        XCTAssertEqual(try reopened.state(for: content), candidate, "Resource rollback does not rewrite independent content record")

        let rejected = PhotoIdentity(resourceIdentifier: "rejected")
        try store.save(rejected, state: before)
        let rejectedExpected = try store.readState(for: rejected, isX3f: false)
        _ = try store.commitProcessingMigration(expected: rejectedExpected, candidate: nil, quality: quality)
        XCTAssertEqual(try store.readState(for: rejected, isX3f: false), rejectedExpected, "Rejected migration retains old version and parameters")
        assertRejects("Unchanged rejected record is not repeatedly migrated") {
            _ = try store.commitProcessingMigration(expected: rejectedExpected, candidate: nil, quality: quality)
        }
        let changed = before.replacing(settings: later, preservingFilmID: before.filmID)
        try reopened.save(rejected, state: changed)
        assertRejects("Stale migration cannot overwrite another instance's edit") {
            _ = try store.commitProcessingMigration(expected: rejectedExpected, candidate: candidate, quality: quality)
        }
        XCTAssertEqual(try store.state(for: rejected), changed, "Concurrent saved state wins")

        for legacy in [false, true] {
            let alias = PhotoIdentity(contentIdentifier: "rejected-alias-\(legacy)")
            let asset = PhotoIdentity(
                resourceIdentifier: "rejected-asset-\(legacy)",
                contentIdentifier: legacy ? "unrecorded-content" : alias.contentIdentifier,
                legacyContentIdentifier: legacy ? alias.contentIdentifier : nil
            )
            try store.save(alias, state: before)
            let expected = try store.readState(for: asset, isX3f: false)
            _ = try store.commitProcessingMigration(expected: expected, candidate: nil, quality: quality)
            let restarted = try EditPersistence(directory: dir)
            XCTAssertEqual(try restarted.readState(for: asset, isX3f: false), expected, "Rejected alias migration preserves the resolved old edit")
            let kept = try restarted.processingMigration(for: asset)
            XCTAssertTrue(
                kept?.status == .kept && kept?.original == before &&
                    kept?.shouldAttempt(current: before, sourceVersion: 2) == false,
                "Rejected resource receipt survives reopening a content or legacy-content fallback"
            )
            assertRejects("Rejected alias edit does not repeat fitting after restart") {
                _ = try restarted.commitProcessingMigration(expected: expected, candidate: nil, quality: quality)
            }
            XCTAssertNil(try restarted.processingMigration(for: alias), "Resource rejection does not modify an independent content receipt")
            var editedOld = old; editedOld.exposure = 0.75
            let edited = before.replacing(settings: editedOld, preservingFilmID: before.filmID)
            try restarted.save(alias, state: edited)
            XCTAssertEqual(
                try restarted.processingMigration(for: asset)?.shouldAttempt(current: edited, sourceVersion: 2),
                true,
                "Changing the fallback edit permits a new attempt"
            )
            try restarted.save(asset, state: before)
            XCTAssertEqual(try restarted.processingMigration(for: asset)?.original, before, "Creating the resource record keeps its rejection receipt")
        }
    }

    func testProcessingMigrationResetAndIsolation() async throws {
        let dir = root.appendingPathComponent("migration-reset-isolation")
        let store = try EditPersistence(directory: dir)
        var old = RawSettings.default; old.processing = .c5; old.exposure = 0.6; old.highlights = 0.25
        let original = PhotoEditState(settings: old, filmID: "legacy-film", updatedAt: Date(timeIntervalSince1970: 50))
        var newer = old; newer.processing = .current; newer.highlights = 0.15
        let migrated = original.replacing(settings: newer, preservingFilmID: original.filmID)
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.002, worstTileRMSE: 0.003,
                                                 detailRMSE: 0.001, evaluations: 20)
        var neutralV3 = RawSettings.default; neutralV3.processing = .current
        let neutralCandidate = PhotoEditState(settings: neutralV3, updatedAt: Date(timeIntervalSince1970: 60))

        // 1. Migrated -> explicit reset commit -> receipt nil -> rollback expired -> reopen still nil.
        let primary = PhotoIdentity(resourceIdentifier: "reset-asset", contentIdentifier: "reset-bytes")
        try store.save(primary, state: original)
        _ = try store.commitProcessingMigration(expected: store.readState(for: primary, isX3f: false), candidate: migrated, quality: quality)
        XCTAssertEqual(try store.processingMigration(for: primary)?.status, .migrated, "Migration receipt exists before reset")
        _ = try store.saveState(identity: primary, state: neutralCandidate, clearsProcessingMigration: true)
        XCTAssertNil(try store.processingMigration(for: primary), "Explicit reset commit clears migrated receipt")
        do {
            _ = try store.rollbackProcessingMigration(expected: store.readState(for: primary, isX3f: false), isX3f: false)
            XCTFail("Rollback after reset must throw expired")
        } catch AdjustmentCommitError.expired {}
        let reopenedPrimary = try EditPersistence(directory: dir)
        XCTAssertNil(try reopenedPrimary.processingMigration(for: primary), "Cleared receipt remains nil after reopening store")
        do {
            _ = try reopenedPrimary.rollbackProcessingMigration(expected: reopenedPrimary.readState(for: primary, isX3f: false), isX3f: false)
            XCTFail("Reopened rollback after reset must throw expired")
        } catch AdjustmentCommitError.expired {}

        // Also verify .rolledBack and .kept-only (no primary record) receipts are cleared.
        let rolled = PhotoIdentity(resourceIdentifier: "rolled-asset", contentIdentifier: "rolled-bytes")
        try store.save(rolled, state: original)
        let rolledMigrated = try store.commitProcessingMigration(expected: store.readState(for: rolled, isX3f: false), candidate: migrated, quality: quality)
        _ = try store.rollbackProcessingMigration(expected: rolledMigrated, isX3f: false)
        XCTAssertEqual(try store.processingMigration(for: rolled)?.status, .rolledBack, "Rolled-back receipt exists before reset")
        try store.reset(rolled)
        XCTAssertNil(try EditPersistence(directory: dir).processingMigration(for: rolled), "Reset clears rolled-back receipt")

        let keptAlias = PhotoIdentity(contentIdentifier: "kept-only-alias")
        let keptAsset = PhotoIdentity(resourceIdentifier: "kept-only-asset", contentIdentifier: keptAlias.contentIdentifier)
        try store.save(keptAlias, state: original)
        _ = try store.commitProcessingMigration(expected: store.readState(for: keptAsset, isX3f: false), candidate: nil, quality: quality)
        try store.reset(keptAlias)
        XCTAssertTrue(
            try store.state(for: keptAsset) == nil && store.processingMigration(for: keptAsset)?.status == .kept,
            "Kept-only asset has a receipt without a primary record"
        )
        try store.reset(keptAsset)
        XCTAssertNil(
            try EditPersistence(directory: dir).processingMigration(for: keptAsset),
            "write(nil) clears a kept-only receipt even when current.state is already nil"
        )

        // 2(a). Same PHAsset (resourceIdentifier) with different bytes (contentIdentifier) keeps its receipt intact.
        let assetV1 = PhotoIdentity(resourceIdentifier: "shared-phasset", contentIdentifier: "bytes-v1")
        let assetV2 = PhotoIdentity(resourceIdentifier: "shared-phasset", contentIdentifier: "bytes-v2")
        let unboundAsset = PhotoIdentity(resourceIdentifier: "shared-phasset")
        for id in [assetV1, assetV2, unboundAsset] {
            try store.save(id, state: original)
            _ = try store.commitProcessingMigration(expected: store.readState(for: id, isX3f: false), candidate: migrated, quality: quality)
        }
        _ = try store.saveState(identity: assetV1, state: neutralCandidate, clearsProcessingMigration: true)
        try store.reset(assetV1)
        let reopenedShared = try EditPersistence(directory: dir)
        XCTAssertNil(try reopenedShared.processingMigration(for: assetV1), "Reset clears target PHAsset+bytes receipt")
        XCTAssertTrue(
            try reopenedShared.processingMigration(for: assetV2)?.status == .migrated &&
                reopenedShared.processingMigration(for: assetV2)?.original == original,
            "Another identity on the same PHAsset with different bytes keeps its receipt intact"
        )
        XCTAssertEqual(
            try reopenedShared.processingMigration(for: unboundAsset)?.status,
            .migrated,
            "Legacy photo:<res> receipt with non-matching contentIdentifier is not deleted"
        )
        let restoredV2 = try reopenedShared.rollbackProcessingMigration(expected: reopenedShared.readState(for: assetV2, isX3f: false), isX3f: false)
        XCTAssertEqual(restoredV2.state, original, "Sibling PHAsset identity with different bytes can still roll back")

        // 2(b). Independent content:<id> import record keeps its receipt intact under both commitEdit-style and write(nil) resets.
        let contentImport = PhotoIdentity(contentIdentifier: "independent-file-sha")
        let photoSharingContent = PhotoIdentity(resourceIdentifier: "photo-sharing-sha", contentIdentifier: contentImport.contentIdentifier)
        let photoResetNil = PhotoIdentity(resourceIdentifier: "photo-reset-nil", contentIdentifier: contentImport.contentIdentifier)
        try store.save(contentImport, state: original)
        _ = try store.commitProcessingMigration(expected: store.readState(for: contentImport, isX3f: false), candidate: migrated, quality: quality)
        XCTAssertTrue(
            try store.processingMigration(for: photoSharingContent)?.status == .migrated &&
                store.processingMigration(for: photoResetNil)?.status == .migrated,
            "PhotoKit identities initially observe fallback receipt before reset"
        )
        _ = try store.saveState(identity: photoSharingContent, state: neutralCandidate, clearsProcessingMigration: true)
        try store.reset(photoResetNil)
        let rawStore = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("edits.json"))) as! [String: Any]
        let rawMigrations = rawStore["processingMigrations"] as? [String: Any] ?? [:]
        XCTAssertFalse(
            rawMigrations.keys.contains { $0.contains("photo-reset-nil") || $0.contains("photo-sharing-sha") },
            "write(nil) and reset saveState never copy an alias receipt into receipts[editKey]"
        )
        let reopenedAlias = try EditPersistence(directory: dir)
        let resolvedAfterReset = await reopenedAlias.resolvingLegacyContent(for: photoResetNil) { contentImport.contentIdentifier }
        XCTAssertTrue(
            try reopenedAlias.processingMigration(for: photoSharingContent) == nil &&
                reopenedAlias.processingMigration(for: resolvedAfterReset) == nil &&
                reopenedAlias.state(for: photoResetNil) == nil,
            "Both neutral-commit reset and tombstone reset block alias receipt fallback across reopen"
        )
        XCTAssertTrue(
            try reopenedAlias.processingMigration(for: contentImport)?.status == .migrated &&
                reopenedAlias.processingMigration(for: contentImport)?.original == original &&
                reopenedAlias.state(for: contentImport) == migrated,
            "Independent content:<id> import record and its migration receipt remain completely unaffected"
        )
        let restoredContent = try reopenedAlias.rollbackProcessingMigration(expected: reopenedAlias.readState(for: contentImport, isX3f: false), isX3f: false)
        XCTAssertEqual(restoredContent.state, original, "Independent content:<id> import record can still roll back after PhotoKit reset")
    }

    func testReopenedLegacyMigration() async throws {
        let dir = root.appendingPathComponent("reopened-legacy-migration")
        let store = try EditPersistence(directory: dir)
        let legacy = PhotoIdentity(contentIdentifier: "migration-transferable")
        let stable = PhotoIdentity(resourceIdentifier: "migration-resource", contentIdentifier: "original-bytes")
        var settings = RawSettings.default; settings.processing = .c5; settings.exposure = 0.5
        let original = PhotoEditState(settings: settings, filmID: "original-look", updatedAt: Date(timeIntervalSince1970: 42))
        try store.save(legacy, state: original)
        let resolved = await store.resolvingLegacyContent(for: stable) { legacy.contentIdentifier }
        XCTAssertEqual(resolved.legacyContentIdentifier, legacy.contentIdentifier, "First open resolves the transferable alias before migration")
        let expected = try store.readState(for: resolved, isX3f: false)
        settings.processing = .current
        let candidate = original.replacing(settings: settings, preservingFilmID: original.filmID)
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.002, worstTileRMSE: 0.003,
                                                 detailRMSE: 0.001, evaluations: 20)
        _ = try store.commitProcessingMigration(expected: expected, candidate: candidate, quality: quality)
        let reopened = try EditPersistence(directory: dir)
        var loads = 0
        let current = await reopened.resolvingLegacyContent(for: stable) { loads += 1; return legacy.contentIdentifier }
        XCTAssertTrue(current.legacyContentIdentifier == nil && loads == 0, "Reopening the migrated resource does not reload the legacy alias")
        XCTAssertTrue(
            try reopened.processingMigration(for: current)?.status == .migrated &&
                reopened.processingMigration(for: current)?.original == original,
            "Accepted migration retains rollback after the legacy lookup hint disappears"
        )
        let changedHint = PhotoIdentity(
            resourceIdentifier: stable.resourceIdentifier,
            contentIdentifier: stable.contentIdentifier,
            legacyContentIdentifier: "another-transferable-hint"
        )
        XCTAssertEqual(try reopened.processingMigration(for: changedHint)?.original, original, "A changed legacy lookup hint does not change the original identity")

        let changedContent = PhotoIdentity(resourceIdentifier: stable.resourceIdentifier, contentIdentifier: "changed-bytes")
        XCTAssertNil(try reopened.processingMigration(for: changedContent), "A changed original content identifier cannot reuse the old backup")
        XCTAssertNil(try reopened.processingMigration(for: PhotoIdentity(resourceIdentifier: "migration-resource")), "A missing content identifier cannot match a content-verified backup")
        assertRejects("Changed content cannot roll back the previous original") {
            _ = try reopened.rollbackProcessingMigration(expected: reopened.readState(for: changedContent, isX3f: false), isX3f: false)
        }
        _ = try reopened.rollbackProcessingMigration(expected: reopened.readState(for: current, isX3f: false), isX3f: false)
        let restarted = try EditPersistence(directory: dir)
        let again = await restarted.resolvingLegacyContent(for: stable) { loads += 1; return legacy.contentIdentifier }
        let rolledBack = try restarted.processingMigration(for: again)
        XCTAssertTrue(
            try again.legacyContentIdentifier == nil && loads == 0 && rolledBack?.status == .rolledBack &&
                rolledBack?.shouldAttempt(current: original, sourceVersion: 2) == false &&
                restarted.readState(for: again, isX3f: false).state == original,
            "Rollback marker survives reopening without the legacy lookup hint"
        )
        assertRejects("Reopened rollback cannot migrate automatically again") {
            _ = try restarted.commitProcessingMigration(expected: restarted.readState(for: again, isX3f: false), candidate: candidate, quality: quality)
        }
        XCTAssertEqual(try restarted.state(for: legacy), original, "Resource migration and rollback preserve the independent legacy record")

        let direct = PhotoIdentity(resourceIdentifier: "rollback-before-reopen", contentIdentifier: "direct-original-bytes")
        let directResolved = await restarted.resolvingLegacyContent(for: direct) { legacy.contentIdentifier }
        let migrated = try restarted.commitProcessingMigration(
            expected: restarted.readState(for: directResolved, isX3f: false),
            candidate: candidate,
            quality: quality
        )
        _ = try restarted.rollbackProcessingMigration(expected: migrated, isX3f: false)
        let directReopened = try EditPersistence(directory: dir)
        let directIdentity = await directReopened.resolvingLegacyContent(for: direct) { loads += 1; return legacy.contentIdentifier }
        let directReceipt = try directReopened.processingMigration(for: directIdentity)
        XCTAssertTrue(
            directIdentity.legacyContentIdentifier == nil && loads == 0 && directReceipt?.status == .rolledBack &&
                directReceipt?.shouldAttempt(current: original, sourceVersion: 2) == false,
            "Rollback performed before closing survives the first reopen without a legacy hint"
        )
    }

    func testLazyTransferableFallback() async throws {
        let directory = root.appendingPathComponent("lazy-transferable-fallback")
        let store = try EditPersistence(directory: directory)
        let photo = PhotoIdentity(resourceIdentifier: "asset", contentIdentifier: "original")
        let legacy = PhotoIdentity(contentIdentifier: "transferable")
        var loads = 0
        func resolve(_ identity: PhotoIdentity) async -> PhotoIdentity {
            await store.resolvingLegacyContent(for: identity) {
                loads += 1
                return "transferable"
            }
        }
        let resolvedEmpty = await resolve(photo)
        XCTAssertTrue(resolvedEmpty == photo && loads == 0, "An empty registry does not load extra transferable bytes")
        try store.save(.init(resourceIdentifier: "other-photo"), state: .init(settings: .default))
        let resolvedOther = await resolve(photo)
        XCTAssertTrue(resolvedOther == photo && loads == 0, "A registry with only photo records does not load transferable bytes")
        var settings = RawSettings.default; settings.exposure = 0.75
        try store.save(legacy, state: .init(settings: settings))
        let resolved = await resolve(photo)
        XCTAssertTrue(
            try loads == 1 && resolved.contentIdentifier == "original" &&
                store.state(for: resolved)?.settings.exposure == 0.75,
            "Missing photo and original records load the old transferable hash once"
        )
        let resolvedAgain = await resolve(resolved)
        XCTAssertTrue(resolvedAgain == resolved && loads == 1, "An already resolved identity does not reload its transferable")
        let resolvedLegacy = await resolve(legacy)
        XCTAssertTrue(resolvedLegacy == legacy && loads == 1, "A file identity never requests photo picker bytes")
        try store.save(photo, state: .init(settings: .default))
        let resolvedSaved = await resolve(photo)
        XCTAssertTrue(resolvedSaved == photo && loads == 1, "An existing photo edit skips transferable loading")
        try store.reset(photo)
        let resolvedReset = await resolve(photo)
        XCTAssertTrue(resolvedReset == photo && loads == 1, "A photo deletion marker skips transferable loading")
        let other = PhotoIdentity(resourceIdentifier: "other-asset", contentIdentifier: "original")
        let original = PhotoIdentity(contentIdentifier: "original")
        try store.save(original, state: .init(settings: .default))
        let resolvedOriginal = await resolve(other)
        XCTAssertTrue(resolvedOriginal == other && loads == 1, "An existing original content edit skips transferable loading")
        try store.reset(original)
        let resolvedResetOriginal = await resolve(other)
        XCTAssertTrue(resolvedResetOriginal == other && loads == 1, "An original deletion marker skips transferable loading")
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("edits.json"))
        let absent = PhotoIdentity(resourceIdentifier: "absent", contentIdentifier: "absent-original")
        let resolvedAbsent = await resolve(absent)
        XCTAssertTrue(resolvedAbsent == absent && loads == 1, "Unreadable storage does not trigger a speculative transferable load")
    }

    func testTransferableFallback() throws {
        let directory = root.appendingPathComponent("transferable-fallback")
        let store = try EditPersistence(directory: directory)
        let original = directory.appendingPathComponent("original.jpg")
        let transferable = directory.appendingPathComponent("current.jpg")
        try Data("original photo container".utf8).write(to: original)
        try Data("edited or transcoded picker bytes".utf8).write(to: transferable)
        let originalID = try PhotoIdentity.fallback(for: original)
        let legacyID = try PhotoIdentity.fallback(for: transferable)
        // JSON 同时验证旧身份兼容性；旧日志没有 legacyContentIdentifier。
        let photo = try JSONDecoder().decode(PhotoIdentity.self, from: JSONSerialization.data(withJSONObject: [
            "resourceIdentifier": "edited-asset", "contentIdentifier": originalID.contentIdentifier!,
            "legacyContentIdentifier": legacyID.contentIdentifier!
        ]))
        var settings = RawSettings.default; settings.exposure = 1.5
        let legacy = PhotoEditState(settings: settings)
        try store.save(legacyID, state: legacy)
        let file = directory.appendingPathComponent("edits.json")
        let before = try Data(contentsOf: file)
        let receipt = try store.readState(for: photo, isX3f: false)
        XCTAssertTrue(
            receipt.state == legacy && receipt.identity.key == "photo:edited-asset",
            "Different transferable bytes restore the old content edit under the library identity"
        )
        XCTAssertEqual(try Data(contentsOf: file), before, "Transferable fallback does not migrate or rewrite the old record")
        let roundTrip = try JSONDecoder().decode(PhotoIdentity.self, from: JSONEncoder().encode(photo))
        XCTAssertEqual(try store.state(for: roundTrip), legacy, "A journal round-trip retains the transferable fallback")
        settings.exposure = 2
        try store.save(legacyID, state: .init(settings: settings))
        settings.exposure = -0.5
        try store.save(originalID, state: .init(settings: settings))
        XCTAssertEqual(try store.state(for: photo)?.settings.exposure, -0.5, "Original content adjustments take priority over transferable adjustments")
        try store.reset(originalID)
        XCTAssertNil(try store.state(for: photo), "An original content tombstone prevents transferable edits from reappearing")
        try store.save(photo, state: legacy)
        XCTAssertTrue(
            try store.state(for: photo) == legacy && store.state(for: legacyID)?.settings.exposure == 2,
            "Saving a resolved photo writes its library key and preserves transferable edits"
        )
        try store.reset(photo)
        XCTAssertTrue(
            try store.state(for: photo) == nil && store.state(for: legacyID) != nil,
            "A library tombstone also blocks the transferable fallback"
        )
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertNil(try store.state(for: photo), "Cached reads preserve the library tombstone with a transferable fallback")
    }

    func testPhotoLibraryFallback() throws {
        let directory = root.appendingPathComponent("photo-library-fallback")
        let store = try EditPersistence(directory: directory)
        let source = directory.appendingPathComponent("source.raw")
        try Data("same original photo".utf8).write(to: source)
        let content = try PhotoIdentity.fallback(for: source)
        let photo = PhotoIdentity(resourceIdentifier: "asset-id", contentIdentifier: content.contentIdentifier)
        XCTAssertEqual(
            try PhotoIdentity.fallback(for: source, resourceIdentifier: "asset-id"),
            photo,
            "Photo import keeps both the library identifier and the original content hash"
        )
        var settings = RawSettings.default; settings.exposure = 1.25
        let legacy = PhotoEditState(settings: settings)
        try store.save(content, state: legacy)
        let file = directory.appendingPathComponent("edits.json")
        let before = try Data(contentsOf: file)
        let restored = try store.readState(for: photo, isX3f: false)
        XCTAssertTrue(
            photo.key == "photo:asset-id" && restored.identity == photo && restored.state == legacy,
            "Photo library identity reads an existing content edit without changing its key"
        )
        XCTAssertTrue(
            try store.state(for: photo) == legacy && Data(contentsOf: file) == before,
            "Content fallback reads never migrate or rewrite the registry"
        )
        let resetFallback = PhotoIdentity(resourceIdentifier: "reset-fallback", contentIdentifier: content.contentIdentifier)
        try store.reset(resetFallback)
        XCTAssertTrue(
            try store.state(for: resetFallback) == nil && store.state(for: content) == legacy,
            "Resetting a fallback-only photo preserves the old record without restoring it"
        )
        let afterReset = try Data(contentsOf: file)
        let unchanged = try store.saveState(identity: restored.identity, state: legacy)
        XCTAssertTrue(
            try unchanged.hasSameAdjustments(as: restored) && Data(contentsOf: file) == afterReset,
            "Unchanged fallback adjustments do not create a photo record"
        )
        settings.exposure = 2
        try store.save(content, state: .init(settings: settings))
        _ = try store.saveState(identity: restored.identity, state: legacy)
        let refreshed = try store.readState(for: photo, isX3f: false)
        let legacyState = try store.state(for: content)
        settings.exposure = -0.5
        let saved = try store.saveState(identity: refreshed.identity, state: .init(settings: settings))
        XCTAssertTrue(
            try saved.state?.settings.exposure == -0.5 && store.state(for: photo)?.settings.exposure == -0.5,
            "Explicit edits write a preferred photo record"
        )
        XCTAssertEqual(try store.state(for: content), legacyState, "Saving photo edits preserves the old content record")
        try store.reset(photo)
        let deleted = try store.readState(for: photo, isX3f: false)
        XCTAssertTrue(
            try deleted.state == nil && store.state(for: content) != nil,
            "Photo deletion tombstone prevents old content edits from reappearing"
        )
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertNil(try store.state(for: photo), "Cached reads also respect the photo deletion tombstone")

        let oldDirectory = directory.appendingPathComponent("unversioned")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldFile = oldDirectory.appendingPathComponent("edits.json")
        let oldBytes = try JSONEncoder().encode(["records": [content.key: legacy]])
        try oldBytes.write(to: oldFile)
        let oldStore = try EditPersistence(directory: oldDirectory)
        let oldRecord = try oldStore.readState(for: photo, isX3f: false)
        XCTAssertTrue(
            try oldRecord.state == legacy && Data(contentsOf: oldFile) == oldBytes,
            "Unversioned content edits remain readable without adding a revision map"
        )
        try FileManager.default.removeItem(at: oldFile)
        try FileManager.default.createDirectory(at: oldFile, withIntermediateDirectories: false)
        XCTAssertEqual(try oldStore.state(for: photo), legacy, "Storage failure retains the last readable fallback edit")
        assertRejects("Strict fallback reads still report corrupt storage") { _ = try oldStore.readState(for: photo, isX3f: false) }
    }

    func testPhotoLibraryContentChange() throws {
        let directory = root.appendingPathComponent("photo-content-change")
        let store = try EditPersistence(directory: directory)
        let original = PhotoIdentity(resourceIdentifier: "reused-asset", contentIdentifier: "original-sha")
        let replacement = PhotoIdentity(resourceIdentifier: "reused-asset", contentIdentifier: "replacement-sha")
        var settings = RawSettings.default; settings.exposure = 1.25
        let edit = PhotoEditState(settings: settings)
        try store.save(original, state: edit)
        let reopened = try EditPersistence(directory: directory)
        XCTAssertTrue(
            try reopened.state(for: original) == edit && reopened.state(for: replacement) == nil,
            "A new source with the same Photos asset ID starts without the old edits"
        )
        settings.exposure = -0.5
        try reopened.save(replacement, state: .init(settings: settings))
        try reopened.reset(replacement)
        XCTAssertTrue(
            try reopened.state(for: original) == edit && reopened.state(for: replacement) == nil,
            "Saving or resetting the replacement leaves the original revision's edits intact"
        )
        let legacy = PhotoIdentity(resourceIdentifier: "unbound-asset")
        try reopened.save(legacy, state: edit)
        let unknown = PhotoIdentity(resourceIdentifier: legacy.resourceIdentifier, contentIdentifier: "unverified-sha")
        XCTAssertTrue(
            try reopened.state(for: unknown) == nil && reopened.state(for: legacy) == edit,
            "Unbound historical edits remain stored without being applied to unverified bytes"
        )
        XCTAssertEqual(try reopened.unverifiedAssetEdit(for: unknown), edit, "An older asset-only adjustment is available for explicit recovery")
        try reopened.resolveUnverifiedAssetEdit(for: unknown, expected: edit, restore: true)
        XCTAssertTrue(
            try reopened.state(for: unknown) == edit && reopened.unverifiedAssetEdit(for: unknown) == nil,
            "Confirming recovery binds the historical adjustments to the selected original"
        )
        let differentBytes = PhotoIdentity(resourceIdentifier: legacy.resourceIdentifier, contentIdentifier: "different-sha")
        XCTAssertTrue(
            try reopened.unverifiedAssetEdit(for: differentBytes) == edit && reopened.state(for: differentBytes) == nil,
            "The previous confirmation does not apply edits to a different original"
        )
        try reopened.resolveUnverifiedAssetEdit(for: differentBytes, expected: edit, restore: false)
        let decided = try EditPersistence(directory: directory)
        XCTAssertTrue(
            try decided.unverifiedAssetEdit(for: differentBytes) == nil && decided.state(for: differentBytes) == nil &&
                decided.state(for: unknown) == edit && decided.state(for: legacy) == edit,
            "Opening the original records that choice without overwriting the historical adjustment"
        )
    }

    func testRefinedRecipe() throws {
        let fixtureURL = RawLabKitTestSupport.repoRoot.appendingPathComponent("Shared/fixtures/master-recipe-v4.json")
        let recipe = try JSONDecoder().decode(MasterRecipe.self, from: Data(contentsOf: fixtureURL))
        var state = RawSettings.default
        state.blackPoint = -20; state.clarity = -40; state.toneCurve = 0.35
        state.temperature = 8000; state.sharpening = 0.75
        state.applyMasterRecipe(recipe)
        XCTAssertTrue(
            state.blackPoint == 50 && state.whitePoint == -60 && state.vibrance == 15 &&
                state.clarity == 12 && state.dehaze == -6 && state.curveSettings.mode == .custom &&
                state.gradingSettings.shadows.saturation == 8 && state.toneCurve == 0,
            "Explicit refined recipe replaces all visible new controls"
        )
        let restored = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state, "Refined recipe survives photo settings round-trip")
        for strength in [0.0, 0.5, 1.0, 2.0] {
            state.lutStrength = strength
            let rendered = state.renderedRecipe(cameraTemperature: 6000, cameraTint: 0)
            XCTAssertTrue(
                rendered.blackPoint == min(100, 50 * strength) && rendered.whitePoint == max(-100, -60 * strength) &&
                    rendered.vibrance == 15 * strength && rendered.clarity == 12 * strength && rendered.dehaze == -6 * strength &&
                    rendered.gradingSettings.shadows.hue == 210 && rendered.gradingSettings.shadows.saturation == 8 * strength,
                "V4 strength scales final new controls once, preserving hue"
            )
            XCTAssertTrue(
                rendered.curveSettings.isValid && (strength != 0 || rendered.curveSettings.isIdentity),
                "V4 curve remains valid and bypasses exactly at zero"
            )
            XCTAssertTrue(
                state.blackPoint == 50 && state.curveSettings.points.count == 5 && state.temperature == 8000 && state.sharpening == 0.75,
                "Rendering preserves stored controls and unrelated adjustments"
            )
        }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        legacy.removeValue(forKey: "masterRecipeSettingsVersion")
        let old = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        let oldRendered = old.renderedRecipe(cameraTemperature: 6000, cameraTint: 0)
        XCTAssertTrue(
            oldRendered.blackPoint == 50 && oldRendered.gradingSettings.shadows.saturation == 8 &&
                oldRendered.curveSettings == old.curveSettings && oldRendered.hslSettings == old.hslSettings.scaled(by: 2),
            "Missing version retains old independent controls and scaled HSL"
        )
        legacy["masterRecipeSettingsVersion"] = 5
        assertRejects("Unknown recipe versions cannot silently change old photos") {
            _ = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        }
    }

    func testUnavailable() throws {
        let directory = root.appendingPathComponent("unavailable")
        let store = try EditPersistence(directory: directory), identity = PhotoIdentity(resourceIdentifier: "loaded")
        var settings = RawSettings.default; settings.exposure = 0.4
        try store.save(identity, state: .init(settings: settings))
        let receipt = try store.readState(for: identity, isX3f: false)
        let backup = directory.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data([1]).write(to: directory)
        XCTAssertEqual(try store.state(for: identity)?.settings, settings, "Legacy read retains the last accepted record during storage failure")
        assertRejects("Strict transaction read never falls back to cached records") { _ = try store.readState(for: identity, isX3f: false) }
        assertRejects("Unavailable store cannot commit using the cache") { _ = try store.saveState(identity: receipt.identity, state: nil) }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        XCTAssertTrue(try store.readState(for: identity, isX3f: false).hasSameAdjustments(as: receipt), "Restored storage reads the original record")
    }

    func testLegacy() throws {
        let directory = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = PhotoIdentity(contentIdentifier: "stable-hash")
        var settings = RawSettings.default; settings.lutID = "PROVIA"
        let state = PhotoEditState(settings: settings).replacing(settings: settings, preservingFilmID: nil)
        let file = directory.appendingPathComponent("edits.json")
        let bytes = try JSONEncoder().encode(["records": [identity.key: state]])
        try bytes.write(to: file)
        let store = try EditPersistence(directory: directory), before = try store.readState(for: identity, isX3f: false)
        XCTAssertTrue(
            try before.state == state && Data(contentsOf: file) == bytes,
            "Legacy records read without rewriting or inventing a revision map"
        )
        settings.exposure = 1
        let next = try store.saveState(identity: before.identity, state: state.replacing(settings: settings, preservingFilmID: nil))
        let rewritten = try Data(contentsOf: file)
        XCTAssertTrue(
            next.state?.filmID == nil && !String(data: rewritten, encoding: .utf8)!.contains("Revisions"),
            "Legacy writes preserve explicit nil look metadata without generating revisions"
        )
    }

    func testLegacyDeletionFallback() throws {
        let directory = root.appendingPathComponent("legacy-deletion-fallback")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = PhotoIdentity(contentIdentifier: "legacy-content")
        let deleted = PhotoIdentity(resourceIdentifier: "deleted-photo", contentIdentifier: content.contentIdentifier)
        var settings = RawSettings.default; settings.exposure = 0.6
        let record = PhotoEditState(settings: settings)
        let file = directory.appendingPathComponent("edits.json")
        let object: [String: Any] = [
            "version": 1,
            "records": [content.key: try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))],
            "revisions": [deleted.key: "legacy-tombstone"]
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let store = try EditPersistence(directory: directory)
        XCTAssertNil(try store.state(for: deleted), "Legacy revision tombstone blocks an old content fallback")
        try store.save(.init(resourceIdentifier: "new-photo"), state: .init(settings: .default))
        let reopened = try EditPersistence(directory: directory)
        XCTAssertNil(try reopened.state(for: deleted), "Saving another photo preserves migrated legacy deletion markers")
    }

    func testCorrupt() throws {
        let directory = root.appendingPathComponent("corrupt")
        let store = try EditPersistence(directory: directory), identity = PhotoIdentity(resourceIdentifier: "future")
        let before = try store.readState(for: identity, isX3f: false), file = directory.appendingPathComponent("edits.json")
        let future = Data("{\"version\":99,\"records\":{}}".utf8)
        try future.write(to: file)
        assertRejects("Future registry version blocks ordinary writes") {
            _ = try store.saveState(identity: before.identity, state: .init(settings: .default))
        }
        XCTAssertEqual(try Data(contentsOf: file), future, "Future registry bytes are preserved")
        let broken = Data("broken".utf8)
        try broken.write(to: file)
        var settings = RawSettings.default; settings.exposure = 0.5
        try store.save(identity, state: .init(settings: settings))
        let archived = store.lastQuarantinedURL
        XCTAssertTrue(
            archived != nil && (try? Data(contentsOf: archived!)) == broken && store.consumeQuarantinedError() != nil,
            "Corrupt root registry is quarantined and self-heals on subsequent save"
        )
        XCTAssertEqual(try EditPersistence(directory: directory).state(for: identity)?.settings.exposure, 0.5, "Recovered store persists new edits cleanly")
    }

    func testConcurrent() throws {
        let directory = root.appendingPathComponent("concurrent")
        let stores = try [EditPersistence(directory: directory), EditPersistence(directory: directory)]
        let group = DispatchGroup(), errorLock = NSLock()
        var errors: [Error] = []
        for index in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    for item in 0..<8 {
                        try stores[index].save(.init(resourceIdentifier: "\(index)-\(item)"), state: .init(settings: .default))
                    }
                } catch { errorLock.lock(); errors.append(error); errorLock.unlock() }
            }
        }
        XCTAssertTrue(group.wait(timeout: .now() + 10) == .success && errors.isEmpty, "Concurrent native store writers finish")
        let reader = try EditPersistence(directory: directory)
        XCTAssertTrue(
            try (0..<2).allSatisfy { index in try (0..<8).allSatisfy { try reader.state(for: .init(resourceIdentifier: "\(index)-\($0)")) != nil } },
            "Concurrent writers retain every photo record"
        )
    }

    func testPerRecordIsolationAndRecovery() throws {
        let directory = root.appendingPathComponent("per-record-isolation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try EditPersistence(directory: directory)

        let brokenAssetBytes1 = PhotoIdentity(resourceIdentifier: "ph-asset", contentIdentifier: "bytes-1")
        let sameAssetBytes2 = PhotoIdentity(resourceIdentifier: "ph-asset", contentIdentifier: "bytes-2")
        let independentContent = PhotoIdentity(contentIdentifier: "bytes-1")
        let brokenSubSetting = PhotoIdentity(resourceIdentifier: "bad-sub", contentIdentifier: "bytes-sub")
        let healthySibling = PhotoIdentity(resourceIdentifier: "healthy-sibling", contentIdentifier: "bytes-healthy")

        func diskKey(_ id: PhotoIdentity) -> String {
            guard let resource = id.resourceIdentifier, let content = id.contentIdentifier else { return id.key }
            return "photo-content:\(resource.utf8.count):\(resource):\(content)"
        }

        var c5 = RawSettings.default; c5.processing = .c5; c5.exposure = 0.6
        let c5State = PhotoEditState(settings: c5, filmID: "look-c5", updatedAt: Date(timeIntervalSince1970: 50))
        var newer = c5; newer.processing = .current
        let migratedState = c5State.replacing(settings: newer, preservingFilmID: c5State.filmID)
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.002, worstTileRMSE: 0.002,
                                                 detailRMSE: 0.001, evaluations: 20)

        for id in [brokenAssetBytes1, sameAssetBytes2, independentContent, brokenSubSetting, healthySibling] {
            try store.save(id, state: c5State)
            _ = try store.commitProcessingMigration(expected: store.readState(for: id, isX3f: false),
                                                    candidate: migratedState,
                                                    quality: quality)
        }

        let file = directory.appendingPathComponent("edits.json")
        let baseObject = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let baseRecords = baseObject["records"] as! [String: Any]
        let verbatimFutureProcessingSlice = """
        { "filmID" : "look-c5", "settings" : { "exposure" : 0.6, "processing" : { "family" : "rawlab", "quality" : "standard", "version" : 99 } }, "updatedAt" : 50 }
        """
        let verbatimBadSubSlice = """
        {"updatedAt":50,"filmID":"","settings":{"exposure":0,"toneControls":{"blackPoint":999,"whitePoint":0,"vibrance":0}}}
        """
        func jsonString(_ s: String) throws -> String {
            String(data: try JSONEncoder().encode(s), encoding: .utf8)!
        }
        func rawSlice(_ key: String) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: baseRecords[key]!), encoding: .utf8)!
        }
        let migrationsJSON = String(data: try JSONSerialization.data(withJSONObject: baseObject["processingMigrations"]!), encoding: .utf8)!
        let injected = """
        {"version":1,"records":{\(try jsonString(diskKey(brokenAssetBytes1))):\(verbatimFutureProcessingSlice),\(try jsonString(diskKey(brokenSubSetting))):\(verbatimBadSubSlice),\(try jsonString(diskKey(sameAssetBytes2))):\(try rawSlice(diskKey(sameAssetBytes2))),\(try jsonString(diskKey(independentContent))):\(try rawSlice(diskKey(independentContent))),\(try jsonString(diskKey(healthySibling))):\(try rawSlice(diskKey(healthySibling)))},"processingMigrations":\(migrationsJSON)}
        """
        try Data(injected.utf8).write(to: file)

        let reopened = try EditPersistence(directory: directory)
        XCTAssertTrue(
            try reopened.state(for: healthySibling)?.settings.exposure == 0.6 &&
                reopened.state(for: sameAssetBytes2)?.settings.exposure == 0.6 &&
                reopened.state(for: independentContent)?.settings.exposure == 0.6,
            "Healthy records remain readable alongside unusable entries"
        )

        for broken in [brokenAssetBytes1, brokenSubSetting] {
            do {
                _ = try reopened.state(for: broken)
                XCTFail("Broken record must throw UnusableEditRecordError on state(for:)")
            } catch is UnusableEditRecordError {}
            do {
                _ = try reopened.readState(for: broken, isX3f: false)
                XCTFail("Broken record must throw UnusableEditRecordError on readState")
            } catch is UnusableEditRecordError {}
            do {
                try reopened.save(broken, state: PhotoEditState(settings: .default))
                XCTFail("Ordinary save must refuse to overwrite unusable record")
            } catch is UnusableEditRecordError {}
            do {
                try reopened.reset(broken)
                XCTFail("Ordinary reset must refuse to overwrite unusable record without explicit recovery")
            } catch is UnusableEditRecordError {}
        }

        // High 2: Even during transient storage failure (fallback to lastReadableStore), state(for:) must still throw UnusableEditRecordError.
        let ioBackup = directory.appendingPathExtension("io-backup")
        try FileManager.default.moveItem(at: directory, to: ioBackup)
        try Data("offline".utf8).write(to: directory)
        XCTAssertEqual(
            try reopened.state(for: healthySibling)?.settings.exposure,
            0.6,
            "Healthy cached record still falls back during transient storage failure"
        )
        do {
            _ = try reopened.state(for: brokenAssetBytes1)
            XCTFail("Cached fallback must still throw UnusableEditRecordError for unusable record")
        } catch is UnusableEditRecordError {}
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: ioBackup, to: directory)

        // D1/b: Saving another photo preserves broken entries byte-for-byte verbatim on disk.
        var updatedHealthy = RawSettings.default; updatedHealthy.exposure = 1.35
        try reopened.save(healthySibling, state: PhotoEditState(settings: updatedHealthy))
        let diskAfterSave = String(data: try Data(contentsOf: file), encoding: .utf8)!
        XCTAssertTrue(
            try diskAfterSave.contains("\(jsonString(diskKey(brokenAssetBytes1))):\(verbatimFutureProcessingSlice)") &&
                diskAfterSave.contains("\(jsonString(diskKey(brokenSubSetting))):\(verbatimBadSubSlice)"),
            "Saving another photo preserves broken entries verbatim on disk"
        )

        // D3/c + D5/e: resetToUnmodified clears ONLY target editKey record & receipt, adds tombstone,
        // and preserves both same-PHAsset-other-bytes AND independent content:<id> record + receipt.
        let cleared = try reopened.resetToUnmodified(brokenAssetBytes1)
        XCTAssertTrue(
            try cleared.state == nil &&
                reopened.readState(for: brokenAssetBytes1, isX3f: false).state == nil &&
                reopened.state(for: brokenAssetBytes1) == nil,
            "resetToUnmodified removes broken PhotoKit record and tombstones content fallback"
        )
        XCTAssertNil(try reopened.processingMigration(for: brokenAssetBytes1), "resetToUnmodified clears target PhotoKit migration receipt")
        XCTAssertTrue(
            try reopened.readState(for: sameAssetBytes2, isX3f: false).state?.settings.exposure == 0.6 &&
                reopened.processingMigration(for: sameAssetBytes2)?.status == .migrated,
            "Same PHAsset with different bytes keeps its record and migration receipt"
        )
        XCTAssertTrue(
            try reopened.readState(for: independentContent, isX3f: false).state?.settings.exposure == 0.6 &&
                reopened.processingMigration(for: independentContent)?.status == .migrated,
            "Independent content:<id> record and migration receipt remain untouched"
        )
        let diskAfterReset = String(data: try Data(contentsOf: file), encoding: .utf8)!
        XCTAssertTrue(
            try diskAfterReset.contains("\(jsonString(diskKey(brokenSubSetting))):\(verbatimBadSubSlice)"),
            "Unrelated broken entry remains verbatim after resetting one broken photo"
        )

        // Recovered PhotoKit asset can be edited and saved again normally.
        var recoveredSettings = RawSettings.default; recoveredSettings.exposure = -0.45
        try reopened.save(brokenAssetBytes1, state: PhotoEditState(settings: recoveredSettings))
        XCTAssertEqual(
            try EditPersistence(directory: directory).readState(for: brokenAssetBytes1, isX3f: false).state?.settings.exposure,
            -0.45,
            "Recovered photo can save new adjustments normally"
        )

        // Medium 1: Broken legacy asset-only record (photo:<asset-id>) surfaces UnusableEditRecordError and recovers via resetToUnmodified.
        let legacyBrokenDir = directory.appendingPathComponent("legacy-broken-asset")
        try FileManager.default.createDirectory(at: legacyBrokenDir, withIntermediateDirectories: true)
        let legacyBrokenAsset = PhotoIdentity(resourceIdentifier: "legacy-only-asset")
        let legacyBrokenCurrent = PhotoIdentity(resourceIdentifier: "legacy-only-asset", contentIdentifier: "current-bytes")
        try Data("""
        {"version":1,"records":{\(try jsonString(legacyBrokenAsset.key)):\(verbatimBadSubSlice)}}
        """.utf8).write(to: legacyBrokenDir.appendingPathComponent("edits.json"))
        let legacyBrokenStore = try EditPersistence(directory: legacyBrokenDir)
        do {
            _ = try legacyBrokenStore.unverifiedAssetEdit(for: legacyBrokenCurrent)
            XCTFail("Broken legacy photo:<asset-id> record must throw UnusableEditRecordError on unverifiedAssetEdit")
        } catch is UnusableEditRecordError {}
        do {
            _ = try legacyBrokenStore.readState(for: legacyBrokenCurrent, requiringLegacyDecision: true, isX3f: false)
            XCTFail("Broken legacy photo:<asset-id> record must throw UnusableEditRecordError when legacy decision is required")
        } catch is UnusableEditRecordError {}
        _ = try legacyBrokenStore.resetToUnmodified(legacyBrokenCurrent)
        XCTAssertTrue(
            try legacyBrokenStore.unverifiedAssetEdit(for: legacyBrokenCurrent) == nil &&
                legacyBrokenStore.readState(for: legacyBrokenCurrent, requiringLegacyDecision: true, isX3f: false).state == nil &&
                legacyBrokenStore.state(for: legacyBrokenCurrent) == nil,
            "resetToUnmodified tombstones broken legacy photo:<asset-id> record for the recovered photo"
        )

        // D2/d: Future version remains fail-closed, while root-level corruption self-heals via quarantine.
        let futureDir = directory.appendingPathComponent("whole-store-future")
        try FileManager.default.createDirectory(at: futureDir, withIntermediateDirectories: true)
        let futureFile = futureDir.appendingPathComponent("edits.json")
        let futureBytes = Data("{\"version\":99,\"records\":{}}".utf8)
        try futureBytes.write(to: futureFile)
        do {
            _ = try EditPersistence(directory: futureDir)
            XCTFail("Future store version must fail closed")
        } catch EditPersistenceError.corruptStore {}
        XCTAssertEqual(try Data(contentsOf: futureFile), futureBytes, "Future store bytes remain untouched")

        let corruptDir = directory.appendingPathComponent("whole-store-corrupt")
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptFile = corruptDir.appendingPathComponent("edits.json")
        for badJSON in [
            "{\"version\":1,\"records\":{",
            "{\"version\":1,\"records\":[]}",
            "{\"version\":1,\"records\":{},\"processingMigrations\":[]}",
            "{\"version\":1,\"records\":{},\"deleted\":\"bad\"}",
            "{\"version\":1,\"version\":1,\"records\":{}}"
        ] {
            let badBytes = Data(badJSON.utf8)
            try badBytes.write(to: corruptFile)
            let healed = try EditPersistence(directory: corruptDir)
            let archived = healed.lastQuarantinedURL
            XCTAssertTrue(
                archived != nil && archived!.lastPathComponent.hasPrefix("edits.json.corrupt-"),
                "Root corruption quarantines edits.json: \(badJSON)"
            )
            XCTAssertTrue(
                try Data(contentsOf: archived!) == badBytes && !FileManager.default.fileExists(atPath: corruptFile.path),
                "Quarantined archive preserves exact bytes and clears active path: \(badJSON)"
            )
            XCTAssertTrue(
                healed.consumeQuarantinedError() != nil && healed.consumeQuarantinedError() == nil,
                "Quarantine error is surfaced once: \(badJSON)"
            )
        }
        let healedID = PhotoIdentity(resourceIdentifier: "healed-after-root-corruption")
        var healedSettings = RawSettings.default; healedSettings.exposure = 0.85
        try EditPersistence(directory: corruptDir).save(healedID, state: PhotoEditState(settings: healedSettings))
        XCTAssertEqual(
            try EditPersistence(directory: corruptDir).readState(for: healedID, isX3f: false).state?.settings.exposure,
            0.85,
            "Recovered iOS store persists new edits cleanly"
        )
    }

    func testWriteThenReadHitsRegistryCache() throws {
        let directory = root.appendingPathComponent("write-then-read-cache")
        let store = try EditPersistence(directory: directory)
        let identity = PhotoIdentity(resourceIdentifier: "cache-hit-after-write")
        var settings = RawSettings.default; settings.exposure = 0.5
        try store.save(identity, state: .init(settings: settings))
        let readsAfterSave = EditPersistence.registryDiskReadCount(forDirectory: directory)
        _ = try store.state(for: identity)
        _ = try store.readState(for: identity, isX3f: false)
        XCTAssertEqual(
            EditPersistence.registryDiskReadCount(forDirectory: directory),
            readsAfterSave,
            "Reading after a successful write updates the cache in place instead of re-reading the ledger"
        )
        let file = directory.appendingPathComponent("edits.json")
        try (try Data(contentsOf: file) + Data(" ".utf8)).write(to: file)
        XCTAssertEqual(
            try store.readState(for: identity, isX3f: false).state?.settings.exposure,
            0.5,
            "An externally appended byte still parses the same record"
        )
        XCTAssertEqual(
            EditPersistence.registryDiskReadCount(forDirectory: directory),
            readsAfterSave + 1,
            "An externally modified ledger is read from disk again"
        )
    }

    func testRemoveStaleAtomicTempFiles() throws {
        let directory = root.appendingPathComponent("atomic-temp-cleanup")
        XCTAssertTrue(
            EditPersistence.defaultDirectory.path.hasSuffix("/RawLab/Edits"),
            "EditPersistence.defaultDirectory targets RawLab/Edits"
        )
        let missing = directory.appendingPathComponent("missing")
        XCTAssertTrue(
            EditPersistence.removeStaleAtomicTempFiles(in: missing) == 0 &&
                !FileManager.default.fileExists(atPath: missing.path),
            "Cleanup skips missing directories without creating them"
        )

        let store = try EditPersistence(directory: directory)
        let id = PhotoIdentity(resourceIdentifier: "atomic-cleanup")
        var settings = RawSettings.default; settings.exposure = 0.35
        try store.save(id, state: PhotoEditState(settings: settings))

        let stale = ["edits.json.sb-1234", ".dat.nosync0001.tmp", "edits.json.swap.tmp", ".edits-001.tmp"]
        for name in stale {
            try Data("stale".utf8).write(to: directory.appendingPathComponent(name))
        }
        let stagingDir = directory.appendingPathComponent("(A Document Being Saved By RawLab)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: stagingDir.appendingPathComponent("edits.json"))

        let archive = directory.appendingPathComponent("edits.json.corrupt-20261120-000000")
        try Data("{archive".utf8).write(to: archive)
        let unrelated = directory.appendingPathComponent("recent-looks.json")
        try Data("{}".utf8).write(to: unrelated)

        let removed = EditPersistence.removeStaleAtomicTempFiles(in: directory)
        XCTAssertEqual(removed, stale.count + 1, "Cleanup removes only orphaned .atomic staging artifacts")
        for name in stale {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                "Removed stale .atomic artifact: \(name)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagingDir.path),
            "Removed stale (A Document Being Saved By ...) directory"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("edits.json").path) &&
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(".edits.lock").path) &&
                FileManager.default.fileExists(atPath: archive.path) &&
                FileManager.default.fileExists(atPath: unrelated.path),
            "Cleanup preserves edits.json, .edits.lock, .corrupt-*, and unrelated files"
        )
        XCTAssertEqual(
            try EditPersistence(directory: directory).readState(for: id, isX3f: false).state?.settings.exposure,
            0.35,
            "Store remains readable after stale .atomic temp cleanup"
        )
    }
}
