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
        try Data("FOVb-nil-lens".utf8).write(to: nilLensURL)
        var nilLensSettings = Adjustments()
        nilLensSettings.x3fMode = .normal
        nilLensSettings.aiDenoiseEnabled = true
        nilLensSettings.lensCorrection = nil
        try seedStore.save(nilLensURL, state: PhotoEditState(settings: nilLensSettings, filmID: ""))

        // Mislabeled X3F with FOVb header.
        let mislabeledURL = root.appendingPathComponent("mislabeled.jpeg")
        try Data("FOVb-mislabeled".utf8).write(to: mislabeledURL)
        var mislabeledSettings = Adjustments()
        mislabeledSettings.x3fMode = .normal
        mislabeledSettings.lensCorrection = LensCorrectionSettings(distortion: true)
        try seedStore.save(mislabeledURL, state: PhotoEditState(settings: mislabeledSettings, filmID: ""))

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

        let mislabeledRecord = try store.readState(for: mislabeledURL)
        XCTAssertFalse(try XCTUnwrap(mislabeledRecord.state?.settings).lensSettings.isEnabled,
                       "Mislabeled FOVb X3F must be repaired")

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
        let repairedFlags = try store.repairLegacyNormalX3fOnOpen(for: flagsOnlyURL)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(repairedFlags.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(repairedFlags.state?.settings.lensSettings.isEnabled, false)
        XCTAssertNil(MacEditPersistence.editedRevision(for: repairedFlags.state, atPath: flagsOnlyURL.path))
        XCTAssertTrue(session.transactions.isEmpty)

        // Second open writes 0 times because edits.json is already repaired on disk.
        let reopenedFlags = try store.repairLegacyNormalX3fOnOpen(for: flagsOnlyURL)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reopenedFlags, repairedFlags)

        // Legacy X3F and non-X3F normal do 0 writes on open.
        let openedLegacy = try store.repairLegacyNormalX3fOnOpen(for: legacyURL)
        let openedArw = try store.repairLegacyNormalX3fOnOpen(for: arwURL)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(openedLegacy.state?.settings, legacy)
        XCTAssertEqual(openedArw.state?.settings, flagsOnly)

        // v2 X3F record repaired on open commits processing migration cleanly and rollback restores repaired baseline.
        let repairedMigrate = try store.repairLegacyNormalX3fOnOpen(for: migrateURL)
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
        let writesBeforeOpen = writes
        let openedX3f = try store.repairLegacyNormalX3fOnOpen(for: x3fID, isX3f: true)
        XCTAssertEqual(writes, writesBeforeOpen + 1)
        XCTAssertEqual(openedX3f.state?.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(openedX3f.state?.settings.lensSettings.isEnabled, false)

        // Reopen does 0 extra writes; non-X3F / legacy X3F do 0 writes.
        _ = try store.repairLegacyNormalX3fOnOpen(for: x3fID, isX3f: true)
        _ = try store.repairLegacyNormalX3fOnOpen(for: legacyID, isX3f: true)
        _ = try store.repairLegacyNormalX3fOnOpen(for: arwID, isX3f: false)
        XCTAssertEqual(writes, writesBeforeOpen + 1)
    }

    func testUniformBatchDetectsMislabeledFOVbX3f() throws {
        let mislabeled = root.appendingPathComponent("mislabeled.raw")
        try Data("FOVb-batch".utf8).write(to: mislabeled)

        var sourceSettings = Adjustments()
        sourceSettings.x3fMode = .legacy
        sourceSettings.aiDenoiseEnabled = true
        sourceSettings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, vignetting: true)

        let job = MacBatchExportJob(source: root.appendingPathComponent("src.ARW"), settings: sourceSettings, look: nil, lookName: "neutral")
        let resolved = try job.settings(for: mislabeled, resolveX3fMode: { _ in .normal })
        XCTAssertEqual(resolved.x3fMode, .normal)
        XCTAssertFalse(resolved.aiDenoiseEnabled)
        XCTAssertFalse(resolved.lensSettings.isEnabled)
    }
}
