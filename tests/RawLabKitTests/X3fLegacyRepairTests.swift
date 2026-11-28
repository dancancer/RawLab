import Foundation
import XCTest
@testable import RawLabKit

final class X3fLegacyRepairTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawlab-x3f-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testMacReadStateRepairsLegacyNormalX3fInMemoryWithoutWritingDisk() throws {
        let editDir = root.appendingPathComponent("edits", isDirectory: true)
        let seedStore = try MacEditPersistence(directory: editDir)

        let combinations: [(Bool, Bool, Bool, Bool)] = [
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
            (true, true, true, true),
        ]

        var urls: [URL] = []
        for (index, (distortion, tca, vignetting, ai)) in combinations.enumerated() {
            let x3fURL = root.appendingPathComponent("sigma-\(index).X3F")
            try Data("FOVb-fixture-\(index)".utf8).write(to: x3fURL)
            urls.append(x3fURL)

            var settings = Adjustments()
            settings.processing = .c5
            settings.x3fMode = .normal
            settings.exposure = 0.25
            settings.aiDenoiseEnabled = ai
            settings.lensCorrection = LensCorrectionSettings(
                distortion: distortion,
                tca: tca,
                autoCrop: false,
                mode: .manual,
                profileID: "saved-lens-profile",
                focalLength: 35,
                cropFactor: 1.5,
                vignetting: vignetting
            )
            try seedStore.save(x3fURL, state: PhotoEditState(settings: settings, filmID: "builtin:provia.cube"))
        }

        // Null lens block with AI denoise enabled must stay nil after clearing AI denoise.
        let nilLensURL = root.appendingPathComponent("sigma-nil-lens.X3F")
        try Data("x3f-nil-lens".utf8).write(to: nilLensURL)
        var nilLensSettings = Adjustments()
        nilLensSettings.x3fMode = .normal
        nilLensSettings.aiDenoiseEnabled = true
        nilLensSettings.lensCorrection = nil
        try seedStore.save(nilLensURL, state: PhotoEditState(settings: nilLensSettings, filmID: ""))

        // Legacy-mode X3F must remain untouched.
        let legacyX3fURL = root.appendingPathComponent("legacy.X3F")
        try Data("FOVb-legacy".utf8).write(to: legacyX3fURL)
        var legacySettings = Adjustments()
        legacySettings.x3fMode = .legacy
        legacySettings.aiDenoiseEnabled = true
        legacySettings.lensCorrection = LensCorrectionSettings(
            distortion: true, tca: true, autoCrop: false, mode: .manual, profileID: "legacy-profile", vignetting: true
        )
        try seedStore.save(legacyX3fURL, state: PhotoEditState(settings: legacySettings, filmID: ""))

        // Non-X3F file with x3fMode == .normal must remain untouched.
        let arwURL = root.appendingPathComponent("sony.ARW")
        try Data("II*\0raw-arw".utf8).write(to: arwURL)
        var arwSettings = Adjustments()
        arwSettings.x3fMode = .normal
        arwSettings.aiDenoiseEnabled = true
        arwSettings.lensCorrection = LensCorrectionSettings(
            distortion: true, tca: true, autoCrop: false, mode: .manual, profileID: "arw-profile", vignetting: true
        )
        try seedStore.save(arwURL, state: PhotoEditState(settings: arwSettings, filmID: ""))

        let editsJSON = editDir.appendingPathComponent("edits.json")
        let rawBefore = try Data(contentsOf: editsJSON)
        var writes = 0
        let store = try MacEditPersistence(directory: editDir, writeData: { data, destination in
            writes += 1
            try data.write(to: destination, options: .atomic)
        })

        for x3fURL in urls {
            let record = try store.readState(for: x3fURL)
            let repaired = try XCTUnwrap(record.state?.settings)
            XCTAssertEqual(repaired.x3fMode, .normal)
            XCTAssertFalse(repaired.aiDenoiseEnabled, "Normal X3F repair must clear AI denoise")
            XCTAssertFalse(repaired.lensSettings.isEnabled, "Normal X3F repair must clear distortion, TCA and vignetting")
            XCTAssertEqual(repaired.lensCorrection?.autoCrop, false)
            XCTAssertEqual(repaired.lensCorrection?.mode, .manual)
            XCTAssertEqual(repaired.lensCorrection?.profileID, "saved-lens-profile")
            XCTAssertEqual(repaired.lensCorrection?.focalLength, 35)
            XCTAssertEqual(repaired.lensCorrection?.cropFactor, 1.5)
            XCTAssertEqual(repaired.exposure, 0.25)
            XCTAssertEqual(repaired.processing, .c5)
            XCTAssertEqual(record.state?.filmID, "builtin:provia.cube")
        }

        let nilLensRecord = try store.readState(for: nilLensURL)
        let nilLensRepaired = try XCTUnwrap(nilLensRecord.state?.settings)
        XCTAssertFalse(nilLensRepaired.aiDenoiseEnabled)
        XCTAssertNil(nilLensRepaired.lensCorrection, "Missing lensCorrection block must remain nil")

        let legacyRecord = try store.readState(for: legacyX3fURL)
        XCTAssertEqual(legacyRecord.state?.settings, legacySettings,
                       "Legacy-mode X3F record must remain untouched")

        let arwRecord = try store.readState(for: arwURL)
        XCTAssertEqual(arwRecord.state?.settings, arwSettings,
                       "Non-X3F record with normal x3fMode must remain untouched")

        // Flags-only broken normal X3F must not produce an edited revision.
        var flagsOnly = Adjustments()
        flagsOnly.x3fMode = .normal
        flagsOnly.aiDenoiseEnabled = true
        flagsOnly.lensCorrection = LensCorrectionSettings(distortion: true)
        XCTAssertNil(
            MacEditPersistence.editedRevision(for: PhotoEditState(settings: flagsOnly, filmID: ""), atPath: urls[0].path),
            "Flags-only legacy normal X3F must not be reported as edited"
        )

        XCTAssertEqual(writes, 0, "Read-only readState must not write edits.json")
        XCTAssertEqual(try Data(contentsOf: editsJSON), rawBefore, "Read-only readState must leave edits.json untouched on disk")
    }

    func testMacRepairOnOpenWritesOncePreservesHistoryAndSupportsProcessingMigration() throws {
        let editDir = root.appendingPathComponent("open-edits", isDirectory: true)
        let seedStore = try MacEditPersistence(directory: editDir)

        let flagsOnlyURL = root.appendingPathComponent("flags-only.X3F")
        let migrateURL = root.appendingPathComponent("migrate.X3F")
        let legacyURL = root.appendingPathComponent("legacy-open.X3F")
        let arwURL = root.appendingPathComponent("arw-open.ARW")
        for url in [flagsOnlyURL, migrateURL, legacyURL] {
            try Data("FOVb-\(url.lastPathComponent)".utf8).write(to: url)
        }
        try Data("II*\0arw".utf8).write(to: arwURL)

        var flagsOnly = Adjustments()
        flagsOnly.x3fMode = .normal
        flagsOnly.aiDenoiseEnabled = true
        flagsOnly.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, vignetting: true)
        try seedStore.save(flagsOnlyURL, state: PhotoEditState(settings: flagsOnly, filmID: ""))

        var migrate = Adjustments()
        migrate.processing = .c5
        migrate.x3fMode = .normal
        migrate.aiDenoiseEnabled = true
        migrate.exposure = 0.7
        migrate.lensCorrection = LensCorrectionSettings(distortion: true, tca: false, autoCrop: false, mode: .manual, profileID: "sigma-35", vignetting: true)
        try seedStore.save(migrateURL, state: PhotoEditState(settings: migrate, filmID: ""))

        var legacy = flagsOnly
        legacy.x3fMode = .legacy
        try seedStore.save(legacyURL, state: PhotoEditState(settings: legacy, filmID: ""))
        try seedStore.save(arwURL, state: PhotoEditState(settings: flagsOnly, filmID: ""))

        var writes = 0
        let store = try MacEditPersistence(directory: editDir, writeData: { data, destination in
            writes += 1
            try data.write(to: destination, options: .atomic)
        })
        let session = MacAdjustmentTransferSession(store: store)

        // First open repairs disk record once without adding undo history.
        let repairedFlagsResult = try store.repairLegacyNormalX3fOnOpen(for: flagsOnlyURL)
        let repairedFlags = repairedFlagsResult.record
        XCTAssertTrue(repairedFlagsResult.repaired)
        XCTAssertNil(repairedFlagsResult.writeError)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(repairedFlags.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(repairedFlags.state?.settings.lensSettings.isEnabled, false)
        XCTAssertNil(MacEditPersistence.editedRevision(for: repairedFlags.state, atPath: flagsOnlyURL.path))
        XCTAssertTrue(session.transactions.isEmpty)

        // Second open writes 0 times because edits.json is already repaired on disk.
        let reopenedFlagsResult = try store.repairLegacyNormalX3fOnOpen(for: flagsOnlyURL)
        XCTAssertFalse(reopenedFlagsResult.repaired)
        XCTAssertNil(reopenedFlagsResult.writeError)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reopenedFlagsResult.record, repairedFlags)

        // Legacy X3F and non-X3F normal do 0 writes on open.
        let openedLegacy = try store.repairLegacyNormalX3fOnOpen(for: legacyURL)
        let openedArw = try store.repairLegacyNormalX3fOnOpen(for: arwURL)
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(openedLegacy.repaired)
        XCTAssertFalse(openedArw.repaired)
        XCTAssertEqual(openedLegacy.record.state?.settings, legacy)
        XCTAssertEqual(openedArw.record.state?.settings, flagsOnly)

        // v2 X3F record repaired on open commits processing migration cleanly and rollback restores repaired baseline.
        let repairedMigrateResult = try store.repairLegacyNormalX3fOnOpen(for: migrateURL)
        let repairedMigrate = repairedMigrateResult.record
        XCTAssertTrue(repairedMigrateResult.repaired)
        XCTAssertNil(repairedMigrateResult.writeError)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(repairedMigrate.state?.settings.processing, .c5)
        XCTAssertEqual(repairedMigrate.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(repairedMigrate.state?.settings.lensSettings.isEnabled, false)

        var migratedSettings = try XCTUnwrap(repairedMigrate.state?.settings)
        migratedSettings.processing = .current
        migratedSettings.exposure = 1.1
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.002, p99Error: 0.01, worstTileRMSE: 0.004, detailRMSE: 0.003, evaluations: 8)
        let migratedRecord = try store.commitProcessingMigration(
            expected: repairedMigrate,
            candidate: PhotoEditState(settings: migratedSettings, filmID: ""),
            quality: quality
        )
        XCTAssertEqual(migratedRecord.state?.settings.processing, ProcessingIdentity.current)
        XCTAssertEqual(migratedRecord.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(migratedRecord.state?.settings.lensSettings.isEnabled, false)

        let rolledBack = try store.rollbackProcessingMigration(expected: migratedRecord)
        XCTAssertEqual(rolledBack.state, repairedMigrate.state)
        XCTAssertEqual(rolledBack.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(rolledBack.state?.settings.lensSettings.isEnabled, false)
    }

    func testMacPastePresetAndSyncOnUnopenedLegacyNormalX3f() throws {
        let editDir = root.appendingPathComponent("transfer-edits", isDirectory: true)
        let seedStore = try MacEditPersistence(directory: editDir)

        let sourceURL = root.appendingPathComponent("source.ARW")
        let x3fURL = root.appendingPathComponent("unopened.X3F")
        try Data("raw-source".utf8).write(to: sourceURL)
        try Data("FOVb-unopened".utf8).write(to: x3fURL)

        var broken = Adjustments()
        broken.x3fMode = .normal
        broken.aiDenoiseEnabled = true
        broken.exposure = 0.35
        broken.lensCorrection = LensCorrectionSettings(
            distortion: true, tca: true, autoCrop: true, mode: .manual,
            profileID: "sigma-45", focalLength: 45, cropFactor: 1.0, vignetting: true
        )
        try seedStore.save(x3fURL, state: PhotoEditState(settings: broken, filmID: ""))

        var sourceSettings = Adjustments()
        sourceSettings.exposure = 0.9
        sourceSettings.waveletNoiseReduction.apply(.clean)
        sourceSettings.lensCorrection = LensCorrectionSettings(autoCrop: false)
        try seedStore.save(sourceURL, state: PhotoEditState(settings: sourceSettings, filmID: ""))

        let editsJSON = editDir.appendingPathComponent("edits.json")
        let rawBefore = try Data(contentsOf: editsJSON)
        var writes = 0
        let store = try MacEditPersistence(directory: editDir, writeData: { data, destination in
            writes += 1
            try data.write(to: destination, options: .atomic)
        })
        let session = MacAdjustmentTransferSession(store: store)

        let sourceContext = MacAdjustmentTransferContext(identifier: sourceURL.path, isRaw: true)
        let targetContext = MacAdjustmentTransferContext(identifier: x3fURL.path, isRaw: true)
        let target = AdjustmentTransferTarget(
            url: x3fURL,
            defaultState: PhotoEditState(settings: Adjustments(), filmID: ""),
            context: targetContext
        )

        let payload = try session.copy(
            scope: .custom([.exposure, .waveletDenoise, .lensAutoCrop]),
            snapshot: PhotoEditState(settings: sourceSettings, filmID: ""),
            context: sourceContext
        )
        let prepared = try session.prepare(payload: payload, targets: [target], action: .paste)
        let preparedTarget = try XCTUnwrap(prepared.targets.first)
        XCTAssertNil(preparedTarget.error, "Paste prepare onto unopened legacy normal X3F must succeed")
        XCTAssertEqual(preparedTarget.original?.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(preparedTarget.original?.state?.settings.lensSettings.isEnabled, false)
        XCTAssertEqual(preparedTarget.candidate?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(preparedTarget.candidate?.settings.lensSettings.isEnabled, false)
        XCTAssertEqual(preparedTarget.candidate?.settings.lensCorrection?.autoCrop, false)
        XCTAssertEqual(preparedTarget.candidate?.settings.lensCorrection?.profileID, "sigma-45")
        XCTAssertEqual(preparedTarget.candidate?.settings.exposure ?? 0, 0.9, accuracy: 1e-6)
        XCTAssertEqual(writes, 0, "Prepare must not write edits.json")
        XCTAssertEqual(try Data(contentsOf: editsJSON), rawBefore)

        let applied = session.apply(prepared)
        XCTAssertEqual(applied.first?.status, .applied)
        let undone = session.undoTransaction(prepared.id)
        XCTAssertEqual(undone.first?.status, .applied)
        XCTAssertEqual(undone.first?.saved?.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(undone.first?.saved?.state?.settings.lensSettings.isEnabled, false)
        XCTAssertEqual(undone.first?.saved?.state?.settings.lensCorrection?.profileID, "sigma-45")
        XCTAssertEqual(undone.first?.saved?.state?.settings.exposure ?? 0, 0.35, accuracy: 1e-6)
    }

    func testIOSReadOpenAndTransferRepairLegacyNormalX3f() throws {
        let editDir = root.appendingPathComponent("ios-edits", isDirectory: true)
        let seedStore = try EditPersistence(directory: editDir)

        let x3fID = PhotoIdentity(resourceIdentifier: "ios-x3f")
        let nilLensID = PhotoIdentity(resourceIdentifier: "ios-nil-lens")
        let legacyID = PhotoIdentity(resourceIdentifier: "ios-legacy")
        let arwID = PhotoIdentity(resourceIdentifier: "ios-arw")
        let transferID = PhotoIdentity(resourceIdentifier: "ios-transfer-x3f")

        var broken = Adjustments()
        broken.processing = .c5
        broken.x3fMode = .normal
        broken.aiDenoiseEnabled = true
        broken.exposure = 0.35
        broken.lensCorrection = LensCorrectionSettings(
            distortion: true, tca: true, autoCrop: false, mode: .manual,
            profileID: "sigma-45", focalLength: 45, cropFactor: 1.0, vignetting: true
        )
        var nilLens = Adjustments()
        nilLens.x3fMode = .normal
        nilLens.aiDenoiseEnabled = true
        nilLens.lensCorrection = nil

        var legacy = broken
        legacy.x3fMode = .legacy

        try seedStore.save(x3fID, state: PhotoEditState(settings: broken))
        try seedStore.save(nilLensID, state: PhotoEditState(settings: nilLens))
        try seedStore.save(legacyID, state: PhotoEditState(settings: legacy))
        try seedStore.save(arwID, state: PhotoEditState(settings: broken))
        try seedStore.save(transferID, state: PhotoEditState(settings: broken))

        let editsJSON = editDir.appendingPathComponent("edits.json")
        let rawBefore = try Data(contentsOf: editsJSON)
        var writes = 0
        let store = try EditPersistence(directory: editDir, writeData: { data, destination in
            writes += 1
            try data.write(to: destination, options: .atomic)
        })

        // 1) Read-only readState(..., isX3f: true) repairs in memory without disk writes.
        let readX3f = try store.readState(for: x3fID, isX3f: true)
        XCTAssertEqual(readX3f.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(readX3f.state?.settings.lensSettings.isEnabled, false)
        XCTAssertEqual(readX3f.state?.settings.lensCorrection?.profileID, "sigma-45")
        XCTAssertEqual(readX3f.state?.settings.lensCorrection?.autoCrop, false)
        XCTAssertEqual(readX3f.state?.settings.exposure, 0.35)

        let readNilLens = try store.readState(for: nilLensID, isX3f: true)
        XCTAssertEqual(readNilLens.state?.settings.aiDenoiseEnabled, false)
        XCTAssertNil(readNilLens.state?.settings.lensCorrection)

        let readLegacy = try store.readState(for: legacyID, isX3f: true)
        XCTAssertEqual(readLegacy.state?.settings, legacy)

        let readArw = try store.readState(for: arwID, isX3f: false)
        XCTAssertEqual(readArw.state?.settings, broken)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: editsJSON), rawBefore)

        // 2) Paste onto unopened iOS normal X3F target: prepare is read-only, apply passes CAS, undo restores repaired baseline.
        let session = IOSAdjustmentTransferSession(store: store)
        var sourceSettings = Adjustments()
        sourceSettings.exposure = 0.9
        sourceSettings.lensCorrection = LensCorrectionSettings(autoCrop: true)
        let payload = try session.copy(
            scope: .custom([.exposure, .lensAutoCrop]),
            snapshot: PhotoEditState(settings: sourceSettings),
            context: IOSAdjustmentTransferContext(identifier: arwID.key, isRaw: true)
        )
        let target = IOSAdjustmentTransferTarget(
            identity: transferID,
            displayName: "unopened.X3F",
            defaultState: PhotoEditState(settings: Adjustments()),
            context: IOSAdjustmentTransferContext(identifier: transferID.key, isRaw: true),
            isX3f: true
        )
        let prepared = try session.prepare(payload: payload, targets: [target], action: .paste)
        let preparedTarget = try XCTUnwrap(prepared.targets.first)
        XCTAssertNil(preparedTarget.error)
        XCTAssertEqual(preparedTarget.original?.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(preparedTarget.original?.state?.settings.lensSettings.isEnabled, false)
        XCTAssertEqual(preparedTarget.candidate?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(preparedTarget.candidate?.settings.lensSettings.isEnabled, false)
        XCTAssertEqual(preparedTarget.candidate?.settings.lensCorrection?.autoCrop, true)
        XCTAssertEqual(preparedTarget.candidate?.settings.lensCorrection?.profileID, "sigma-45")
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: editsJSON), rawBefore)

        let applied = session.apply(prepared)
        XCTAssertEqual(applied.first?.status, .applied)
        XCTAssertEqual(writes, 1)
        let undone = session.undoTransaction(prepared.id)
        XCTAssertEqual(undone.first?.status, .applied)
        XCTAssertEqual(undone.first?.saved?.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(undone.first?.saved?.state?.settings.lensSettings.isEnabled, false)
        XCTAssertEqual(undone.first?.saved?.state?.settings.exposure, 0.35)

        // 3) CAS on saveTransferredState still rejects concurrent modifications on disk.
        let casID = PhotoIdentity(resourceIdentifier: "x3f-cas", contentIdentifier: "sha-cas")
        try seedStore.save(casID, state: PhotoEditState(settings: broken))
        let expectedCas = try store.readState(for: casID, isX3f: true)
        var concurrent = broken
        concurrent.exposure = 1.9
        try seedStore.save(casID, state: PhotoEditState(settings: concurrent))
        var pasted = expectedCas.state!
        pasted.settings.exposure = 0.8
        XCTAssertThrowsError(try store.saveTransferredState(pasted, expected: expectedCas, isX3f: true)) { error in
            XCTAssertEqual(error as? AdjustmentCommitError, .expired)
        }

        // 4) Open writes repaired record once; reopen / legacy / non-X3F do 0 writes.
        let writesBeforeOpen = writes
        let openedX3f = try store.repairLegacyNormalX3fOnOpen(for: x3fID, isX3f: true)
        XCTAssertTrue(openedX3f.repaired)
        XCTAssertNil(openedX3f.writeError)
        XCTAssertEqual(writes, writesBeforeOpen + 1)
        XCTAssertEqual(openedX3f.record.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(openedX3f.record.state?.settings.lensSettings.isEnabled, false)

        // Reopen does 0 extra writes; non-X3F / legacy X3F do 0 writes.
        XCTAssertFalse(try store.repairLegacyNormalX3fOnOpen(for: x3fID, isX3f: true).repaired)
        XCTAssertFalse(try store.repairLegacyNormalX3fOnOpen(for: legacyID, isX3f: true).repaired)
        XCTAssertFalse(try store.repairLegacyNormalX3fOnOpen(for: arwID, isX3f: false).repaired)
        XCTAssertEqual(writes, writesBeforeOpen + 1)
    }

    func testRollbackPreExistingMigrationRepairsLegacyNormalX3fOnDiskAndInMemory() throws {
        // Pre-existing v2->v3 receipt whose original still carries stale normal-X3F switches.
        var staleV2 = Adjustments()
        staleV2.processing = .c5
        staleV2.exposure = 0.5
        staleV2.x3fMode = .normal
        staleV2.aiDenoiseEnabled = true
        staleV2.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, profileID: "sigma-50", vignetting: true)

        var migratedV3 = staleV2
        migratedV3.processing = .current
        migratedV3.exposure = 0.65
        migratedV3.selectX3fMode(.normal)

        let quality = ProcessingMigrationQuality(rgbRMSE: 0.002, p99Error: 0.01, worstTileRMSE: 0.004, detailRMSE: 0.003, evaluations: 8)

        // Mac: seed a pre-existing migrated receipt whose original still carries stale normal-X3F switches.
        let macDir = root.appendingPathComponent("mac-rollback-edits")
        let macX3f = root.appendingPathComponent("rollback.X3F")
        let macArw = root.appendingPathComponent("rollback.ARW")
        try Data("x3f-bytes".utf8).write(to: macX3f)
        try Data("arw-bytes".utf8).write(to: macArw)
        let macSeedStore = try MacEditPersistence(directory: macDir)
        let x3fIdentity = try OriginalFileIdentity(macX3f)
        let arwIdentity = try OriginalFileIdentity(macArw)
        var cleanV2 = staleV2
        cleanV2.selectX3fMode(.normal)
        try macSeedStore.save(macX3f, state: PhotoEditState(settings: cleanV2, filmID: ""))
        try macSeedStore.save(macArw, state: PhotoEditState(settings: staleV2, filmID: ""))
        _ = try macSeedStore.commitProcessingMigration(expected: try macSeedStore.readState(for: macX3f), candidate: PhotoEditState(settings: migratedV3, filmID: ""), quality: quality)
        _ = try macSeedStore.commitProcessingMigration(expected: try macSeedStore.readState(for: macArw), candidate: PhotoEditState(settings: migratedV3, filmID: ""), quality: quality)
        // Patch the stored v2->v3 receipt's original for X3F to simulate a receipt created before PR #209.
        let macEditsJSON = macDir.appendingPathComponent("edits.json")
        var macRootObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: macEditsJSON)) as? [String: Any])
        var macMigrations = try XCTUnwrap(macRootObj["processingMigrations"] as? [String: Any])
        var x3fMigration = try XCTUnwrap(macMigrations[x3fIdentity.path] as? [String: Any])
        var x3fReceipt = try XCTUnwrap(x3fMigration["receipt"] as? [String: Any])
        var x3fOriginal = try XCTUnwrap(x3fReceipt["original"] as? [String: Any])
        var x3fOrigSettings = try XCTUnwrap(x3fOriginal["settings"] as? [String: Any])
        x3fOrigSettings["aiDenoiseEnabled"] = true
        var x3fOrigLens = try XCTUnwrap(x3fOrigSettings["lensCorrection"] as? [String: Any])
        x3fOrigLens["distortion"] = true
        x3fOrigLens["tca"] = true
        x3fOrigLens["vignetting"] = true
        x3fOrigSettings["lensCorrection"] = x3fOrigLens
        x3fOriginal["settings"] = x3fOrigSettings
        x3fReceipt["original"] = x3fOriginal
        x3fMigration["receipt"] = x3fReceipt
        macMigrations[x3fIdentity.path] = x3fMigration
        macRootObj["processingMigrations"] = macMigrations
        try JSONSerialization.data(withJSONObject: macRootObj, options: [.sortedKeys]).write(to: macEditsJSON)

        let macReopened = try MacEditPersistence(directory: macDir)
        let macRolledX3f = try macReopened.rollbackProcessingMigration(expected: try macReopened.readState(for: macX3f))
        XCTAssertEqual(macRolledX3f.state?.settings.processing.version, 2)
        XCTAssertEqual(macRolledX3f.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(macRolledX3f.state?.settings.lensSettings.isEnabled, false)
        XCTAssertEqual(macRolledX3f.state?.settings.lensCorrection?.profileID, "sigma-50")
        let macRolledArw = try macReopened.rollbackProcessingMigration(expected: try macReopened.readState(for: macArw))
        XCTAssertEqual(macRolledArw.state?.settings.aiDenoiseEnabled, true)
        XCTAssertEqual(macRolledArw.state?.settings.lensSettings.isEnabled, true)

        // Verify raw disk JSON for Mac X3F is ALSO repaired (not just read-side masked).
        let rawMacObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: macEditsJSON)) as? [String: Any])
        let rawMacRecords = try XCTUnwrap(rawMacObj["records"] as? [String: Any])
        let rawMacX3fRec = try XCTUnwrap(rawMacRecords[x3fIdentity.path] as? [String: Any])
        let rawMacX3fState = try XCTUnwrap(rawMacX3fRec["state"] as? [String: Any])
        let rawMacX3fSettings = try XCTUnwrap(rawMacX3fState["settings"] as? [String: Any])
        XCTAssertEqual(rawMacX3fSettings["aiDenoiseEnabled"] as? Bool, false, "Mac rollback must write repaired AI flag to disk")
        let rawMacX3fLens = try XCTUnwrap(rawMacX3fSettings["lensCorrection"] as? [String: Any])
        XCTAssertEqual(rawMacX3fLens["distortion"] as? Bool, false, "Mac rollback must write repaired distortion flag to disk")
        XCTAssertEqual(rawMacX3fLens["tca"] as? Bool, false, "Mac rollback must write repaired tca flag to disk")
        XCTAssertEqual(rawMacX3fLens["vignetting"] as? Bool, false, "Mac rollback must write repaired vignetting flag to disk")
        XCTAssertEqual(rawMacX3fLens["profileID"] as? String, "sigma-50")
        _ = arwIdentity

        // iOS: seed a pre-existing migrated receipt with unrepaired original, then roll back.
        let iosDir = root.appendingPathComponent("ios-rollback-edits")
        let iosStore = try EditPersistence(directory: iosDir)
        let iosX3fID = PhotoIdentity(resourceIdentifier: "ios-rollback-x3f", contentIdentifier: "sha-rx3f")
        let iosArwID = PhotoIdentity(resourceIdentifier: "ios-rollback-arw", contentIdentifier: "sha-rarw")
        try iosStore.save(iosX3fID, state: PhotoEditState(settings: staleV2))
        try iosStore.save(iosArwID, state: PhotoEditState(settings: staleV2))
        _ = try iosStore.commitProcessingMigration(expected: try iosStore.readState(for: iosX3fID, isX3f: false), candidate: PhotoEditState(settings: migratedV3), quality: quality)
        _ = try iosStore.commitProcessingMigration(expected: try iosStore.readState(for: iosArwID, isX3f: false), candidate: PhotoEditState(settings: migratedV3), quality: quality)

        let iosRolledX3f = try iosStore.rollbackProcessingMigration(expected: try iosStore.readState(for: iosX3fID, isX3f: true), isX3f: true)
        XCTAssertEqual(iosRolledX3f.state?.settings.processing.version, 2)
        XCTAssertEqual(iosRolledX3f.state?.settings.aiDenoiseEnabled, false, "iOS rollback must return repaired AI flag")
        XCTAssertEqual(iosRolledX3f.state?.settings.lensSettings.isEnabled, false, "iOS rollback must return repaired lens flags")
        XCTAssertEqual(iosRolledX3f.state?.settings.lensCorrection?.profileID, "sigma-50")
        let iosRawDiskX3f = try iosStore.readState(for: iosX3fID, isX3f: false)
        XCTAssertEqual(iosRawDiskX3f.state?.settings.aiDenoiseEnabled, false, "iOS rollback must write repaired AI flag to disk")
        XCTAssertEqual(iosRawDiskX3f.state?.settings.lensSettings.isEnabled, false, "iOS rollback must write repaired lens flags to disk")

        let iosRolledArw = try iosStore.rollbackProcessingMigration(expected: try iosStore.readState(for: iosArwID, isX3f: false), isX3f: false)
        XCTAssertEqual(iosRolledArw.state?.settings.aiDenoiseEnabled, true, "iOS non-X3F rollback preserves AI flag")
        XCTAssertEqual(iosRolledArw.state?.settings.lensSettings.isEnabled, true, "iOS non-X3F rollback preserves lens flags")
    }

    func testOpenRepairWriteFailureReturnsRepairedInMemoryWithoutThrowing() throws {
        var broken = Adjustments()
        broken.x3fMode = .normal
        broken.exposure = 0.45
        broken.aiDenoiseEnabled = true
        broken.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, profileID: "sigma-40", vignetting: true)

        // iOS store with failing writeData.
        let iosDir = root.appendingPathComponent("ios-readonly-edits")
        let iosID = PhotoIdentity(resourceIdentifier: "ios-ro-x3f", contentIdentifier: "sha-ro")
        try EditPersistence(directory: iosDir).save(iosID, state: PhotoEditState(settings: broken))
        var failWrites = true
        let iosStore = try EditPersistence(directory: iosDir, writeData: { data, url in
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let iosRepair = try iosStore.repairLegacyNormalX3fOnOpen(for: iosID, isX3f: true)
        XCTAssertTrue(iosRepair.repaired)
        XCTAssertNotNil(iosRepair.writeError)
        XCTAssertEqual(iosRepair.record.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(iosRepair.record.state?.settings.lensSettings.isEnabled, false)
        XCTAssertEqual(try iosStore.readState(for: iosID, isX3f: false).state?.settings.aiDenoiseEnabled, true,
                       "Disk remains unrepaired while writes fail")

        // Later user edit once writes succeed saves and persists the repaired state.
        failWrites = false
        let iosSession = IOSAdjustmentTransferSession(store: iosStore)
        var iosEdited = try XCTUnwrap(iosRepair.record.state)
        iosEdited.settings.exposure = 1.25
        let iosCommit = iosSession.commitEdit(expected: iosRepair.record, state: iosEdited)
        XCTAssertEqual(iosCommit.status, .applied)
        XCTAssertEqual(try iosStore.readState(for: iosID, isX3f: false).state?.settings.exposure, 1.25)
        XCTAssertEqual(try iosStore.readState(for: iosID, isX3f: false).state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(try iosStore.readState(for: iosID, isX3f: false).state?.settings.lensSettings.isEnabled, false)

        // Mac store with failing writeData.
        let macDir = root.appendingPathComponent("mac-readonly-edits")
        let macX3f = root.appendingPathComponent("ro.X3F")
        try Data("x3f-ro".utf8).write(to: macX3f)
        try MacEditPersistence(directory: macDir).save(macX3f, state: PhotoEditState(settings: broken, filmID: ""))
        failWrites = true
        let macStore = try MacEditPersistence(directory: macDir, writeData: { data, url in
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let macRepair = try macStore.repairLegacyNormalX3fOnOpen(for: macX3f)
        XCTAssertTrue(macRepair.repaired)
        XCTAssertNotNil(macRepair.writeError)
        XCTAssertEqual(macRepair.record.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(macRepair.record.state?.settings.lensSettings.isEnabled, false)

        failWrites = false
        let macSession = MacAdjustmentTransferSession(store: macStore)
        var macEdited = try XCTUnwrap(macRepair.record.state)
        macEdited.settings.exposure = 1.25
        let macCommit = macSession.commitEdit(expected: macRepair.record, state: macEdited)
        XCTAssertEqual(macCommit.status, .applied)
        XCTAssertEqual(try macStore.readState(for: macX3f).state?.settings.exposure, 1.25)
        let rawMacText = String(decoding: try Data(contentsOf: macDir.appendingPathComponent("edits.json")), as: UTF8.self)
        XCTAssertFalse(rawMacText.contains("\"aiDenoiseEnabled\":true"))
    }

    func testOpenRepairLedgerSyncOnMacAndIOS() throws {
        var initial = Adjustments()
        initial.x3fMode = .normal
        initial.exposure = 0.5

        var externalBroken = Adjustments()
        externalBroken.x3fMode = .normal
        externalBroken.exposure = 1.0
        externalBroken.aiDenoiseEnabled = true
        externalBroken.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, vignetting: true)

        // Mac ledger sync: previously edited 0.5 -> externally replaced with legacy broken 1.0 -> open repair + rememberExternalSave
        // -> editing back to 0.5 via commitEditAsync must actually save 0.5 instead of falsely returning .unchanged.
        let macDir = root.appendingPathComponent("mac-ledger-edits")
        let macX3f = root.appendingPathComponent("ledger.X3F")
        try Data("x3f-ledger".utf8).write(to: macX3f)
        let macStore = try MacEditPersistence(directory: macDir)
        let macSession = MacAdjustmentTransferSession(store: macStore)
        let firstMac = macSession.commitEdit(expected: try macStore.readState(for: macX3f), state: PhotoEditState(settings: initial, filmID: ""))
        XCTAssertEqual(firstMac.status, .applied)

        try MacEditPersistence(directory: macDir).save(macX3f, state: PhotoEditState(settings: externalBroken, filmID: ""))
        let genBeforeMac = macSession.editGeneration(for: macX3f)
        let repairedMac = try macStore.repairLegacyNormalX3fOnOpen(for: macX3f)
        XCTAssertTrue(repairedMac.repaired)
        macSession.rememberExternalSave(repairedMac.record)
        XCTAssertGreaterThan(macSession.editGeneration(for: macX3f), genBeforeMac)
        XCTAssertEqual(macSession.transactions.count, 1, "Open repair must not append an undo transaction")

        let revertedMac = macSession.commitEditAsync(expected: repairedMac.record, state: PhotoEditState(settings: initial, filmID: ""))
        XCTAssertEqual(revertedMac.status, .applied)
        _ = macStore.flushPendingCommits()
        XCTAssertEqual(try macStore.readState(for: macX3f).state?.settings.exposure, 0.5)

        // iOS ledger sync: previously edited 0.5 -> externally replaced with legacy broken 1.0 -> open repair + refreshSource/rememberExternalSave
        // -> editing back to 0.5 must advance generation and persist 0.5.
        let iosDir = root.appendingPathComponent("ios-ledger-edits")
        let iosID = PhotoIdentity(resourceIdentifier: "ios-ledger-x3f", contentIdentifier: "sha-ledger")
        let iosStore = try EditPersistence(directory: iosDir)
        let iosSession = IOSAdjustmentTransferSession(store: iosStore)
        let firstIOS = iosSession.commitEdit(expected: try iosStore.readState(for: iosID, isX3f: true), state: PhotoEditState(settings: initial))
        XCTAssertEqual(firstIOS.status, .applied)

        try EditPersistence(directory: iosDir).save(iosID, state: PhotoEditState(settings: externalBroken))
        let genBeforeIOS = iosSession.editGeneration(for: iosID)
        let repairedIOS = try iosStore.repairLegacyNormalX3fOnOpen(for: iosID, isX3f: true)
        XCTAssertTrue(repairedIOS.repaired)
        iosSession.rememberExternalSave(repairedIOS.record)
        iosSession.refreshSource(iosID, validate: {}, record: repairedIOS.record)
        XCTAssertGreaterThan(iosSession.editGeneration(for: iosID), genBeforeIOS)
        XCTAssertEqual(iosSession.transactions.count, 1, "iOS open repair must not append an undo transaction")

        let revertedIOS = iosSession.commitEdit(expected: repairedIOS.record, state: PhotoEditState(settings: initial))
        XCTAssertEqual(revertedIOS.status, .applied)
        XCTAssertEqual(try iosStore.readState(for: iosID, isX3f: true).state?.settings.exposure, 0.5)
    }

    func testUniformBatchRepairsNormalX3fTargetByExtension() throws {
        let x3fTarget = root.appendingPathComponent("target.X3F")
        try Data("x3f-batch".utf8).write(to: x3fTarget)

        var sourceSettings = Adjustments()
        sourceSettings.x3fMode = .legacy
        sourceSettings.aiDenoiseEnabled = true
        sourceSettings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, vignetting: true)

        let job = MacBatchExportJob(source: root.appendingPathComponent("src.ARW"), settings: sourceSettings, look: nil, lookName: "neutral")
        let resolved = try job.settings(for: x3fTarget, resolveX3fMode: { _ in .normal })
        XCTAssertEqual(resolved.x3fMode, .normal)
        XCTAssertFalse(resolved.aiDenoiseEnabled)
        XCTAssertFalse(resolved.lensSettings.isEnabled)
    }
}
