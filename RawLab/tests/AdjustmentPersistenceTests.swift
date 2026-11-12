import Foundation

@main struct AdjustmentPersistenceTests {
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw NSError(domain: label, code: 1) }; print("PASS: \(label)")
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { print("PASS: \(label)"); return }
        throw NSError(domain: label, code: 1)
    }
    static func main() async throws {
        try processingMigration()
        try await processingMigrationResetAndIsolation()
        try await reopenedLegacyMigration()
        try refinedRecipe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try EditPersistence(directory: root), second = try EditPersistence(directory: root)
        let a = PhotoIdentity(resourceIdentifier: "a"), b = PhotoIdentity(resourceIdentifier: "b")
        var settings = RawSettings.default; settings.exposure = 1
        try first.save(a, state: .init(settings: settings))
        settings.exposure = 2; try second.save(b, state: .init(settings: settings))
        let reopened = try EditPersistence(directory: root)
        try check(reopened.state(for: a)?.settings.exposure == 1 && reopened.state(for: b)?.settings.exposure == 2,
            "Independent store instances preserve both photos")
        try check(first.state(for: b)?.settings.exposure == 2, "Existing readers observe another instance's save")
        let saved = try first.readState(for: a)
        try check(saved.state?.settings.exposure == 1, "A successful edit creates a readable photo record")
        let metadataOnly = PhotoEditState(settings: saved.state!.settings, updatedAt: Date(timeIntervalSince1970: 999))
        let unchanged = try first.saveState(identity: saved.identity, state: metadataOnly)
        try check(unchanged.hasSameAdjustments(as: saved), "Timestamp-only changes do not rewrite the stored adjustments")
        settings.exposure = 3
        let changed = try first.saveState(identity: saved.identity, state: .init(settings: settings))
        try check(changed.state?.settings.exposure == 3, "SaveState writes the requested adjustment atomically")
        let later = try second.saveState(identity: saved.identity, state: metadataOnly)
        try check(later.state?.settings.exposure == 1, "Independent writers use the current session intent instead of a disk revision")
        let missing = PhotoIdentity(resourceIdentifier: "missing")
        let absent = try first.readState(for: missing)
        _ = try first.saveState(identity: absent.identity, state: metadataOnly)
        try first.reset(missing)
        let deleted = try first.readState(for: missing)
        try check(deleted.state == nil, "Deletion removes the current record without a revision tombstone")
        _ = try first.saveState(identity: absent.identity, state: metadataOnly)
        try check(first.state(for: missing)?.settings == metadataOnly.settings, "A later ordinary save can recreate a deleted record")
        let file = root.appendingPathComponent("edits.json"), bytes = try Data(contentsOf: file)
        let failing = try EditPersistence(directory: root, writeData: { _, _ in throw NSError(domain: "injected write", code: 1) })
        settings.exposure = -1
        try rejects("Injected atomic write failure is reported") { _ = try failing.saveState(identity: changed.identity, state: .init(settings: settings)) }
        try check(try Data(contentsOf: file) == bytes && first.readState(for: a).state?.settings.exposure == 1, "Write failure preserves the registry")
        var invalid = settings; invalid.exposure = .nan
        try rejects("Invalid JSON cannot replace the old registry") { try first.save(a, state: .init(settings: invalid)) }
        try check(try Data(contentsOf: file) == bytes, "Encoding failure preserves the registry")
        try rejects("Invalid identity cannot be saved") { try first.save(.init(resourceIdentifier: ""), state: metadataOnly) }
        try legacy(root.appendingPathComponent("legacy"))
        try corrupt(root.appendingPathComponent("corrupt"))
        try concurrent(root.appendingPathComponent("concurrent"))
        try unavailable(root.appendingPathComponent("unavailable"))
        try photoLibraryFallback(root.appendingPathComponent("photo-library-fallback"))
        try photoLibraryContentChange(root.appendingPathComponent("photo-content-change"))
        try transferableFallback(root.appendingPathComponent("transferable-fallback"))
        try legacyDeletionFallback(root.appendingPathComponent("legacy-deletion-fallback"))
        try await lazyTransferableFallback(root.appendingPathComponent("lazy-transferable-fallback"))
    }

    static func processingMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EditPersistence(directory: root)
        let content = PhotoIdentity(contentIdentifier: "migration-content")
        let photo = PhotoIdentity(resourceIdentifier: "migration-asset", contentIdentifier: "migration-content")
        var old = RawSettings.default; old.processing = .c5; old.exposure = 0.5; old.highlights = 0.2
        old.lutID = "saved-look"; old.clarity = 14
        let before = PhotoEditState(settings: old, filmID: "exact-film-id", updatedAt: Date(timeIntervalSince1970: 42))
        try store.save(content, state: before)
        let expected = try store.readState(for: content)
        var newer = old; newer.processing = .current; newer.highlights = 0.12
        let candidate = before.replacing(settings: newer, preservingFilmID: before.filmID)
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.002, worstTileRMSE: 0.003,
            detailRMSE: 0.001, evaluations: 20)
        let file = root.appendingPathComponent("edits.json"), bytes = try Data(contentsOf: file)
        let failing = try EditPersistence(directory: root, writeData: { _, _ in throw NSError(domain: "injected write", code: 1) })
        try rejects("Migration write failure is atomic") {
            _ = try failing.commitProcessingMigration(expected: expected, candidate: candidate, quality: quality)
        }
        try check(try Data(contentsOf: file) == bytes, "Failed migration preserves old record bytes")
        _ = try store.commitProcessingMigration(expected: expected, candidate: candidate, quality: quality)
        let reopened = try EditPersistence(directory: root)
        try check(try reopened.processingMigration(for: photo)?.original == before,
            "PhotoKit content fallback retains migration rollback")
        var later = newer; later.exposure = 1.5
        try reopened.save(photo, state: before.replacing(settings: later, preservingFilmID: before.filmID))
        try check(try reopened.processingMigration(for: photo)?.original == before,
            "Creating a preferred resource record preserves the alias backup")
        let restored = try reopened.rollbackProcessingMigration(expected: reopened.readState(for: photo))
        try check(restored.state == before, "Restart-safe rollback restores full old state and exact film ID")
        let receipt = try reopened.processingMigration(for: photo)!
        try check(receipt.status == .rolledBack && !receipt.shouldAttempt(current: before, sourceVersion: 2),
            "Rolled-back resource no longer automatically migrates")
        try check(reopened.state(for: content) == candidate, "Resource rollback does not rewrite independent content record")

        let rejected = PhotoIdentity(resourceIdentifier: "rejected")
        try store.save(rejected, state: before)
        let rejectedExpected = try store.readState(for: rejected)
        _ = try store.commitProcessingMigration(expected: rejectedExpected, candidate: nil, quality: quality)
        try check(try store.readState(for: rejected) == rejectedExpected, "Rejected migration retains old version and parameters")
        try rejects("Unchanged rejected record is not repeatedly migrated") {
            _ = try store.commitProcessingMigration(expected: rejectedExpected, candidate: nil, quality: quality)
        }
        let changed = before.replacing(settings: later, preservingFilmID: before.filmID)
        try reopened.save(rejected, state: changed)
        try rejects("Stale migration cannot overwrite another instance's edit") {
            _ = try store.commitProcessingMigration(expected: rejectedExpected, candidate: candidate, quality: quality)
        }
        try check(store.state(for: rejected) == changed, "Concurrent saved state wins")

        for legacy in [false, true] {
            let alias = PhotoIdentity(contentIdentifier: "rejected-alias-\(legacy)")
            let asset = PhotoIdentity(resourceIdentifier: "rejected-asset-\(legacy)",
                contentIdentifier: legacy ? "unrecorded-content" : alias.contentIdentifier,
                legacyContentIdentifier: legacy ? alias.contentIdentifier : nil)
            try store.save(alias, state: before)
            let expected = try store.readState(for: asset)
            _ = try store.commitProcessingMigration(expected: expected, candidate: nil, quality: quality)
            let restarted = try EditPersistence(directory: root)
            try check(try restarted.readState(for: asset) == expected,
                "Rejected alias migration preserves the resolved old edit")
            let kept = try restarted.processingMigration(for: asset)
            try check(kept?.status == .kept && kept?.original == before &&
                kept?.shouldAttempt(current: before, sourceVersion: 2) == false,
                "Rejected resource receipt survives reopening a content or legacy-content fallback")
            try rejects("Rejected alias edit does not repeat fitting after restart") {
                _ = try restarted.commitProcessingMigration(expected: expected, candidate: nil, quality: quality)
            }
            try check(try restarted.processingMigration(for: alias) == nil,
                "Resource rejection does not modify an independent content receipt")
            var editedOld = old; editedOld.exposure = 0.75
            let edited = before.replacing(settings: editedOld, preservingFilmID: before.filmID)
            try restarted.save(alias, state: edited)
            try check(try restarted.processingMigration(for: asset)?.shouldAttempt(current: edited, sourceVersion: 2) == true,
                "Changing the fallback edit permits a new attempt")
            try restarted.save(asset, state: before)
            try check(try restarted.processingMigration(for: asset)?.original == before,
                "Creating the resource record keeps its rejection receipt")
        }
    }

    static func processingMigrationResetAndIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EditPersistence(directory: root)
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
        _ = try store.commitProcessingMigration(expected: store.readState(for: primary), candidate: migrated, quality: quality)
        try check(try store.processingMigration(for: primary)?.status == .migrated, "Migration receipt exists before reset")
        _ = try store.saveState(identity: primary, state: neutralCandidate, clearsProcessingMigration: true)
        try check(try store.processingMigration(for: primary) == nil, "Explicit reset commit clears migrated receipt")
        do {
            _ = try store.rollbackProcessingMigration(expected: store.readState(for: primary))
            throw NSError(domain: "Rollback after reset must throw expired", code: 1)
        } catch AdjustmentCommitError.expired { print("PASS: Rollback throws expired after reset") }
        let reopenedPrimary = try EditPersistence(directory: root)
        try check(try reopenedPrimary.processingMigration(for: primary) == nil,
                  "Cleared receipt remains nil after reopening store")
        do {
            _ = try reopenedPrimary.rollbackProcessingMigration(expected: reopenedPrimary.readState(for: primary))
            throw NSError(domain: "Reopened rollback after reset must throw expired", code: 1)
        } catch AdjustmentCommitError.expired { print("PASS: Reopened store keeps rollback unavailable") }

        // Also verify .rolledBack and .kept-only (no primary record) receipts are cleared.
        let rolled = PhotoIdentity(resourceIdentifier: "rolled-asset", contentIdentifier: "rolled-bytes")
        try store.save(rolled, state: original)
        let rolledMigrated = try store.commitProcessingMigration(expected: store.readState(for: rolled), candidate: migrated, quality: quality)
        _ = try store.rollbackProcessingMigration(expected: rolledMigrated)
        try check(try store.processingMigration(for: rolled)?.status == .rolledBack, "Rolled-back receipt exists before reset")
        try store.reset(rolled)
        try check(try EditPersistence(directory: root).processingMigration(for: rolled) == nil,
                  "Reset clears rolled-back receipt")

        let keptAlias = PhotoIdentity(contentIdentifier: "kept-only-alias")
        let keptAsset = PhotoIdentity(resourceIdentifier: "kept-only-asset", contentIdentifier: keptAlias.contentIdentifier)
        try store.save(keptAlias, state: original)
        _ = try store.commitProcessingMigration(expected: store.readState(for: keptAsset), candidate: nil, quality: quality)
        try store.reset(keptAlias)
        try check(store.state(for: keptAsset) == nil && (try store.processingMigration(for: keptAsset)?.status) == .kept,
                  "Kept-only asset has a receipt without a primary record")
        try store.reset(keptAsset)
        try check(try EditPersistence(directory: root).processingMigration(for: keptAsset) == nil,
                  "write(nil) clears a kept-only receipt even when current.state is already nil")

        // 2(a). Same PHAsset (resourceIdentifier) with different bytes (contentIdentifier) keeps its receipt intact.
        let assetV1 = PhotoIdentity(resourceIdentifier: "shared-phasset", contentIdentifier: "bytes-v1")
        let assetV2 = PhotoIdentity(resourceIdentifier: "shared-phasset", contentIdentifier: "bytes-v2")
        let unboundAsset = PhotoIdentity(resourceIdentifier: "shared-phasset")
        for id in [assetV1, assetV2, unboundAsset] {
            try store.save(id, state: original)
            _ = try store.commitProcessingMigration(expected: store.readState(for: id), candidate: migrated, quality: quality)
        }
        _ = try store.saveState(identity: assetV1, state: neutralCandidate, clearsProcessingMigration: true)
        try store.reset(assetV1)
        let reopenedShared = try EditPersistence(directory: root)
        try check(try reopenedShared.processingMigration(for: assetV1) == nil, "Reset clears target PHAsset+bytes receipt")
        try check(try reopenedShared.processingMigration(for: assetV2)?.status == .migrated &&
                  reopenedShared.processingMigration(for: assetV2)?.original == original,
                  "Another identity on the same PHAsset with different bytes keeps its receipt intact")
        try check(try reopenedShared.processingMigration(for: unboundAsset)?.status == .migrated,
                  "Legacy photo:<res> receipt with non-matching contentIdentifier is not deleted")
        let restoredV2 = try reopenedShared.rollbackProcessingMigration(expected: reopenedShared.readState(for: assetV2))
        try check(restoredV2.state == original, "Sibling PHAsset identity with different bytes can still roll back")

        // 2(b). Independent content:<id> import record keeps its receipt intact under both commitEdit-style and write(nil) resets.
        let contentImport = PhotoIdentity(contentIdentifier: "independent-file-sha")
        let photoSharingContent = PhotoIdentity(resourceIdentifier: "photo-sharing-sha", contentIdentifier: contentImport.contentIdentifier)
        let photoResetNil = PhotoIdentity(resourceIdentifier: "photo-reset-nil", contentIdentifier: contentImport.contentIdentifier)
        try store.save(contentImport, state: original)
        _ = try store.commitProcessingMigration(expected: store.readState(for: contentImport), candidate: migrated, quality: quality)
        try check(try store.processingMigration(for: photoSharingContent)?.status == .migrated &&
                  store.processingMigration(for: photoResetNil)?.status == .migrated,
                  "PhotoKit identities initially observe fallback receipt before reset")
        _ = try store.saveState(identity: photoSharingContent, state: neutralCandidate, clearsProcessingMigration: true)
        try store.reset(photoResetNil)
        let rawStore = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("edits.json"))) as! [String: Any]
        let rawMigrations = rawStore["processingMigrations"] as? [String: Any] ?? [:]
        try check(!rawMigrations.keys.contains { $0.contains("photo-reset-nil") || $0.contains("photo-sharing-sha") },
                  "write(nil) and reset saveState never copy an alias receipt into receipts[editKey]")
        let reopenedAlias = try EditPersistence(directory: root)
        let resolvedAfterReset = await reopenedAlias.resolvingLegacyContent(for: photoResetNil) { contentImport.contentIdentifier }
        try check(try reopenedAlias.processingMigration(for: photoSharingContent) == nil &&
                  reopenedAlias.processingMigration(for: resolvedAfterReset) == nil &&
                  reopenedAlias.state(for: photoResetNil) == nil,
                  "Both neutral-commit reset and tombstone reset block alias receipt fallback across reopen")
        try check(try reopenedAlias.processingMigration(for: contentImport)?.status == .migrated &&
                  reopenedAlias.processingMigration(for: contentImport)?.original == original &&
                  reopenedAlias.state(for: contentImport) == migrated,
                  "Independent content:<id> import record and its migration receipt remain completely unaffected")
        let restoredContent = try reopenedAlias.rollbackProcessingMigration(expected: reopenedAlias.readState(for: contentImport))
        try check(restoredContent.state == original, "Independent content:<id> import record can still roll back after PhotoKit reset")
    }

    static func reopenedLegacyMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EditPersistence(directory: root)
        let legacy = PhotoIdentity(contentIdentifier: "migration-transferable")
        let stable = PhotoIdentity(resourceIdentifier: "migration-resource", contentIdentifier: "original-bytes")
        var settings = RawSettings.default; settings.processing = .c5; settings.exposure = 0.5
        let original = PhotoEditState(settings: settings, filmID: "original-look", updatedAt: Date(timeIntervalSince1970: 42))
        try store.save(legacy, state: original)
        let resolved = await store.resolvingLegacyContent(for: stable) { legacy.contentIdentifier }
        try check(resolved.legacyContentIdentifier == legacy.contentIdentifier,
            "First open resolves the transferable alias before migration")
        let expected = try store.readState(for: resolved)
        settings.processing = .current
        let candidate = original.replacing(settings: settings, preservingFilmID: original.filmID)
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.002, worstTileRMSE: 0.003,
            detailRMSE: 0.001, evaluations: 20)
        _ = try store.commitProcessingMigration(expected: expected, candidate: candidate, quality: quality)
        let reopened = try EditPersistence(directory: root)
        var loads = 0
        let current = await reopened.resolvingLegacyContent(for: stable) { loads += 1; return legacy.contentIdentifier }
        try check(current.legacyContentIdentifier == nil && loads == 0,
            "Reopening the migrated resource does not reload the legacy alias")
        try check(try reopened.processingMigration(for: current)?.status == .migrated &&
            reopened.processingMigration(for: current)?.original == original,
            "Accepted migration retains rollback after the legacy lookup hint disappears")
        let changedHint = PhotoIdentity(resourceIdentifier: stable.resourceIdentifier, contentIdentifier: stable.contentIdentifier,
            legacyContentIdentifier: "another-transferable-hint")
        try check(try reopened.processingMigration(for: changedHint)?.original == original,
            "A changed legacy lookup hint does not change the original identity")

        let changedContent = PhotoIdentity(resourceIdentifier: stable.resourceIdentifier, contentIdentifier: "changed-bytes")
        try check(try reopened.processingMigration(for: changedContent) == nil,
            "A changed original content identifier cannot reuse the old backup")
        try check(try reopened.processingMigration(for: PhotoIdentity(resourceIdentifier: "migration-resource")) == nil,
            "A missing content identifier cannot match a content-verified backup")
        try rejects("Changed content cannot roll back the previous original") {
            _ = try reopened.rollbackProcessingMigration(expected: reopened.readState(for: changedContent))
        }
        _ = try reopened.rollbackProcessingMigration(expected: reopened.readState(for: current))
        let restarted = try EditPersistence(directory: root)
        let again = await restarted.resolvingLegacyContent(for: stable) { loads += 1; return legacy.contentIdentifier }
        let rolledBack = try restarted.processingMigration(for: again)
        try check(again.legacyContentIdentifier == nil && loads == 0 && rolledBack?.status == .rolledBack &&
            rolledBack?.shouldAttempt(current: original, sourceVersion: 2) == false &&
            restarted.readState(for: again).state == original,
            "Rollback marker survives reopening without the legacy lookup hint")
        try rejects("Reopened rollback cannot migrate automatically again") {
            _ = try restarted.commitProcessingMigration(expected: restarted.readState(for: again), candidate: candidate, quality: quality)
        }
        try check(restarted.state(for: legacy) == original, "Resource migration and rollback preserve the independent legacy record")

        let direct = PhotoIdentity(resourceIdentifier: "rollback-before-reopen", contentIdentifier: "direct-original-bytes")
        let directResolved = await restarted.resolvingLegacyContent(for: direct) { legacy.contentIdentifier }
        let migrated = try restarted.commitProcessingMigration(expected: restarted.readState(for: directResolved),
            candidate: candidate, quality: quality)
        _ = try restarted.rollbackProcessingMigration(expected: migrated)
        let directReopened = try EditPersistence(directory: root)
        let directIdentity = await directReopened.resolvingLegacyContent(for: direct) { loads += 1; return legacy.contentIdentifier }
        let directReceipt = try directReopened.processingMigration(for: directIdentity)
        try check(directIdentity.legacyContentIdentifier == nil && loads == 0 && directReceipt?.status == .rolledBack &&
            directReceipt?.shouldAttempt(current: original, sourceVersion: 2) == false,
            "Rollback performed before closing survives the first reopen without a legacy hint")
    }

    static func lazyTransferableFallback(_ directory: URL) async throws {
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
        try check(await resolve(photo) == photo && loads == 0,
                  "An empty registry does not load extra transferable bytes")
        try store.save(.init(resourceIdentifier: "other-photo"), state: .init(settings: .default))
        try check(await resolve(photo) == photo && loads == 0,
                  "A registry with only photo records does not load transferable bytes")
        var settings = RawSettings.default; settings.exposure = 0.75
        try store.save(legacy, state: .init(settings: settings))
        let resolved = await resolve(photo)
        try check(loads == 1 && resolved.contentIdentifier == "original" &&
                  store.state(for: resolved)?.settings.exposure == 0.75,
                  "Missing photo and original records load the old transferable hash once")
        try check(await resolve(resolved) == resolved && loads == 1,
                  "An already resolved identity does not reload its transferable")
        try check(await resolve(legacy) == legacy && loads == 1,
                  "A file identity never requests photo picker bytes")
        try store.save(photo, state: .init(settings: .default))
        try check(await resolve(photo) == photo && loads == 1,
                  "An existing photo edit skips transferable loading")
        try store.reset(photo)
        try check(await resolve(photo) == photo && loads == 1,
                  "A photo deletion marker skips transferable loading")
        let other = PhotoIdentity(resourceIdentifier: "other-asset", contentIdentifier: "original")
        let original = PhotoIdentity(contentIdentifier: "original")
        try store.save(original, state: .init(settings: .default))
        try check(await resolve(other) == other && loads == 1,
                  "An existing original content edit skips transferable loading")
        try store.reset(original)
        try check(await resolve(other) == other && loads == 1,
                  "An original deletion marker skips transferable loading")
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("edits.json"))
        let absent = PhotoIdentity(resourceIdentifier: "absent", contentIdentifier: "absent-original")
        try check(await resolve(absent) == absent && loads == 1,
                  "Unreadable storage does not trigger a speculative transferable load")
    }

    static func transferableFallback(_ directory: URL) throws {
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
        let receipt = try store.readState(for: photo)
        try check(receipt.state == legacy && receipt.identity.key == "photo:edited-asset",
                  "Different transferable bytes restore the old content edit under the library identity")
        try check(try Data(contentsOf: file) == before,
                  "Transferable fallback does not migrate or rewrite the old record")
        let roundTrip = try JSONDecoder().decode(PhotoIdentity.self, from: JSONEncoder().encode(photo))
        try check(store.state(for: roundTrip) == legacy,
                  "A journal round-trip retains the transferable fallback")
        settings.exposure = 2
        try store.save(legacyID, state: .init(settings: settings))
        settings.exposure = -0.5
        try store.save(originalID, state: .init(settings: settings))
        try check(store.state(for: photo)?.settings.exposure == -0.5,
                  "Original content adjustments take priority over transferable adjustments")
        try store.reset(originalID)
        try check(store.state(for: photo) == nil,
                  "An original content tombstone prevents transferable edits from reappearing")
        try store.save(photo, state: legacy)
        try check(store.state(for: photo) == legacy && store.state(for: legacyID)?.settings.exposure == 2,
                  "Saving a resolved photo writes its library key and preserves transferable edits")
        try store.reset(photo)
        try check(store.state(for: photo) == nil && store.state(for: legacyID) != nil,
                  "A library tombstone also blocks the transferable fallback")
        try Data("corrupt".utf8).write(to: file)
        try check(store.state(for: photo) == nil,
                  "Cached reads preserve the library tombstone with a transferable fallback")
    }

    static func photoLibraryFallback(_ directory: URL) throws {
        let store = try EditPersistence(directory: directory)
        let source = directory.appendingPathComponent("source.raw")
        try Data("same original photo".utf8).write(to: source)
        let content = try PhotoIdentity.fallback(for: source)
        let photo = PhotoIdentity(resourceIdentifier: "asset-id", contentIdentifier: content.contentIdentifier)
        try check(try PhotoIdentity.fallback(for: source, resourceIdentifier: "asset-id") == photo,
                  "Photo import keeps both the library identifier and the original content hash")
        var settings = RawSettings.default; settings.exposure = 1.25
        let legacy = PhotoEditState(settings: settings)
        try store.save(content, state: legacy)
        let file = directory.appendingPathComponent("edits.json")
        let before = try Data(contentsOf: file)
        let restored = try store.readState(for: photo)
        try check(photo.key == "photo:asset-id" && restored.identity == photo && restored.state == legacy,
                  "Photo library identity reads an existing content edit without changing its key")
        try check(store.state(for: photo) == legacy && Data(contentsOf: file) == before,
                  "Content fallback reads never migrate or rewrite the registry")
        let resetFallback = PhotoIdentity(resourceIdentifier: "reset-fallback", contentIdentifier: content.contentIdentifier)
        try store.reset(resetFallback)
        try check(store.state(for: resetFallback) == nil && store.state(for: content) == legacy,
                  "Resetting a fallback-only photo preserves the old record without restoring it")
        let afterReset = try Data(contentsOf: file)
        let unchanged = try store.saveState(identity: restored.identity, state: legacy)
        try check(unchanged.hasSameAdjustments(as: restored) && Data(contentsOf: file) == afterReset,
                  "Unchanged fallback adjustments do not create a photo record")
        settings.exposure = 2
        try store.save(content, state: .init(settings: settings))
        _ = try store.saveState(identity: restored.identity, state: legacy)
        let refreshed = try store.readState(for: photo)
        let legacyState = store.state(for: content)
        settings.exposure = -0.5
        let saved = try store.saveState(identity: refreshed.identity, state: .init(settings: settings))
        try check(saved.state?.settings.exposure == -0.5 && store.state(for: photo)?.settings.exposure == -0.5,
                  "Explicit edits write a preferred photo record")
        try check(store.state(for: content) == legacyState,
                  "Saving photo edits preserves the old content record")
        try store.reset(photo)
        let deleted = try store.readState(for: photo)
        try check(deleted.state == nil && store.state(for: content) != nil,
                  "Photo deletion tombstone prevents old content edits from reappearing")
        try Data("corrupt".utf8).write(to: file)
        try check(store.state(for: photo) == nil,
                  "Cached reads also respect the photo deletion tombstone")

        let oldDirectory = directory.appendingPathComponent("unversioned")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldFile = oldDirectory.appendingPathComponent("edits.json")
        let oldBytes = try JSONEncoder().encode(["records": [content.key: legacy]])
        try oldBytes.write(to: oldFile)
        let oldStore = try EditPersistence(directory: oldDirectory)
        let oldRecord = try oldStore.readState(for: photo)
        try check(oldRecord.state == legacy && Data(contentsOf: oldFile) == oldBytes,
                  "Unversioned content edits remain readable without adding a revision map")
        try Data("corrupt".utf8).write(to: oldFile)
        try check(oldStore.state(for: photo) == legacy,
                  "Storage failure retains the last readable fallback edit")
        try rejects("Strict fallback reads still report corrupt storage") { _ = try oldStore.readState(for: photo) }
    }

    static func photoLibraryContentChange(_ directory: URL) throws {
        let store = try EditPersistence(directory: directory)
        let original = PhotoIdentity(resourceIdentifier: "reused-asset", contentIdentifier: "original-sha")
        let replacement = PhotoIdentity(resourceIdentifier: "reused-asset", contentIdentifier: "replacement-sha")
        var settings = RawSettings.default; settings.exposure = 1.25
        let edit = PhotoEditState(settings: settings)
        try store.save(original, state: edit)
        let reopened = try EditPersistence(directory: directory)
        try check(reopened.state(for: original) == edit && reopened.state(for: replacement) == nil,
                  "A new source with the same Photos asset ID starts without the old edits")
        settings.exposure = -0.5
        try reopened.save(replacement, state: .init(settings: settings))
        try reopened.reset(replacement)
        try check(reopened.state(for: original) == edit && reopened.state(for: replacement) == nil,
                  "Saving or resetting the replacement leaves the original revision's edits intact")
        let legacy = PhotoIdentity(resourceIdentifier: "unbound-asset")
        try reopened.save(legacy, state: edit)
        let unknown = PhotoIdentity(resourceIdentifier: legacy.resourceIdentifier, contentIdentifier: "unverified-sha")
        try check(reopened.state(for: unknown) == nil && reopened.state(for: legacy) == edit,
                  "Unbound historical edits remain stored without being applied to unverified bytes")
        try check(try reopened.unverifiedAssetEdit(for: unknown) == edit,
                  "An older asset-only adjustment is available for explicit recovery")
        try reopened.resolveUnverifiedAssetEdit(for: unknown, expected: edit, restore: true)
        try check(reopened.state(for: unknown) == edit && reopened.unverifiedAssetEdit(for: unknown) == nil,
                  "Confirming recovery binds the historical adjustments to the selected original")
        let differentBytes = PhotoIdentity(resourceIdentifier: legacy.resourceIdentifier, contentIdentifier: "different-sha")
        try check(try reopened.unverifiedAssetEdit(for: differentBytes) == edit && reopened.state(for: differentBytes) == nil,
                  "The previous confirmation does not apply edits to a different original")
        try reopened.resolveUnverifiedAssetEdit(for: differentBytes, expected: edit, restore: false)
        let decided = try EditPersistence(directory: directory)
        try check(try decided.unverifiedAssetEdit(for: differentBytes) == nil && decided.state(for: differentBytes) == nil &&
                  decided.state(for: unknown) == edit && decided.state(for: legacy) == edit,
                  "Opening the original records that choice without overwriting the historical adjustment")
    }

    static func refinedRecipe() throws {
        let recipe = try JSONDecoder().decode(MasterRecipe.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Shared/fixtures/master-recipe-v4.json")))
        var state = RawSettings.default
        state.blackPoint = -20; state.clarity = -40; state.toneCurve = 0.35
        state.temperature = 8000; state.sharpening = 0.75
        state.applyMasterRecipe(recipe)
        try check(state.blackPoint == 50 && state.whitePoint == -60 && state.vibrance == 15 &&
                  state.clarity == 12 && state.dehaze == -6 && state.curveSettings.mode == .custom &&
                  state.gradingSettings.shadows.saturation == 8 && state.toneCurve == 0,
                  "Explicit refined recipe replaces all visible new controls")
        let restored = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(state))
        try check(restored == state, "Refined recipe survives photo settings round-trip")
        for strength in [0.0, 0.5, 1.0, 2.0] {
            state.lutStrength = strength
            let rendered = state.renderedRecipe(cameraTemperature: 6000, cameraTint: 0)
            try check(rendered.blackPoint == min(100, 50 * strength) && rendered.whitePoint == max(-100, -60 * strength) &&
                      rendered.vibrance == 15 * strength && rendered.clarity == 12 * strength && rendered.dehaze == -6 * strength &&
                      rendered.gradingSettings.shadows.hue == 210 && rendered.gradingSettings.shadows.saturation == 8 * strength,
                      "V4 strength scales final new controls once, preserving hue")
            try check(rendered.curveSettings.isValid && (strength != 0 || rendered.curveSettings.isIdentity),
                      "V4 curve remains valid and bypasses exactly at zero")
            try check(state.blackPoint == 50 && state.curveSettings.points.count == 5 && state.temperature == 8000 && state.sharpening == 0.75,
                      "Rendering preserves stored controls and unrelated adjustments")
        }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        legacy.removeValue(forKey: "masterRecipeSettingsVersion")
        let old = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        let oldRendered = old.renderedRecipe(cameraTemperature: 6000, cameraTint: 0)
        try check(oldRendered.blackPoint == 50 && oldRendered.gradingSettings.shadows.saturation == 8 &&
                  oldRendered.curveSettings == old.curveSettings && oldRendered.hsl == old.hsl.scaled(by: 2),
                  "Missing version retains old independent controls and scaled HSL")
        legacy["masterRecipeSettingsVersion"] = 5
        try rejects("Unknown recipe versions cannot silently change old photos") {
            _ = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        }
    }

    static func unavailable(_ directory: URL) throws {
        let store = try EditPersistence(directory: directory), identity = PhotoIdentity(resourceIdentifier: "loaded")
        var settings = RawSettings.default; settings.exposure = 0.4
        try store.save(identity, state: .init(settings: settings))
        let receipt = try store.readState(for: identity)
        let backup = directory.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data([1]).write(to: directory)
        try check(store.state(for: identity)?.settings == settings, "Legacy read retains the last accepted record during storage failure")
        try rejects("Strict transaction read never falls back to cached records") { _ = try store.readState(for: identity) }
        try rejects("Unavailable store cannot commit using the cache") { _ = try store.saveState(identity: receipt.identity, state: nil) }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        try check(try store.readState(for: identity).hasSameAdjustments(as: receipt), "Restored storage reads the original record")
    }

    static func legacy(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = PhotoIdentity(contentIdentifier: "stable-hash")
        var settings = RawSettings.default; settings.lutID = "PROVIA"
        let state = PhotoEditState(settings: settings).replacing(settings: settings, preservingFilmID: nil)
        let file = directory.appendingPathComponent("edits.json")
        let bytes = try JSONEncoder().encode(["records": [identity.key: state]])
        try bytes.write(to: file)
        let store = try EditPersistence(directory: directory), before = try store.readState(for: identity)
        try check(before.state == state && Data(contentsOf: file) == bytes,
            "Legacy records read without rewriting or inventing a revision map")
        settings.exposure = 1
        let next = try store.saveState(identity: before.identity, state: state.replacing(settings: settings, preservingFilmID: nil))
        let rewritten = try Data(contentsOf: file)
        try check(next.state?.filmID == nil && !String(data: rewritten, encoding: .utf8)!.contains("Revisions"),
                  "Legacy writes preserve explicit nil look metadata without generating revisions")
    }

    static func legacyDeletionFallback(_ directory: URL) throws {
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
        try check(store.state(for: deleted) == nil,
                  "Legacy revision tombstone blocks an old content fallback")
        try store.save(.init(resourceIdentifier: "new-photo"), state: .init(settings: .default))
        let reopened = try EditPersistence(directory: directory)
        try check(reopened.state(for: deleted) == nil,
                  "Saving another photo preserves migrated legacy deletion markers")
    }

    static func corrupt(_ directory: URL) throws {
        let store = try EditPersistence(directory: directory), identity = PhotoIdentity(resourceIdentifier: "future")
        let before = try store.readState(for: identity), file = directory.appendingPathComponent("edits.json")
        let future = Data("{\"version\":99,\"records\":{}}".utf8)
        try future.write(to: file)
        try rejects("Future registry version blocks ordinary writes") { _ = try store.saveState(identity: before.identity, state: .init(settings: .default)) }
        try check(try Data(contentsOf: file) == future, "Future registry bytes are preserved")
        try Data("broken".utf8).write(to: file)
        try rejects("Corrupt registry blocks existing writers") { try store.save(identity, state: .init(settings: .default)) }
    }

    static func concurrent(_ directory: URL) throws {
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
        try check(group.wait(timeout: .now() + 10) == .success && errors.isEmpty, "Concurrent native store writers finish")
        let reader = try EditPersistence(directory: directory)
        try check((0..<2).allSatisfy { index in (0..<8).allSatisfy { reader.state(for: .init(resourceIdentifier: "\(index)-\($0)")) != nil } },
            "Concurrent writers retain every photo record")
    }
}
