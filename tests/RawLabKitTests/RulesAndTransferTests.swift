import Foundation
import XCTest
@testable import RawLabKit

final class RulesAndTransferTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLabKitRulesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testIOSClearMasterRecipeMaterializesEffectiveAdjustmentsAndBlocksMissingWB() throws {
        var settings = RawSettings.default
        settings.applyMasterRecipe(.hamadaDaylightV2)
        settings.lutStrength = 0.5
        settings.whiteBalanceMode = .camera

        let missingWB = EditorAdjustmentContext(isRaw: true, defaultExposureMode: .preview, cameraTemperature: nil, cameraTint: nil)
        XCTAssertEqual(settings.clearMasterRecipe(context: missingWB), .missingCameraWhiteBalance)

        let rawContext = EditorAdjustmentContext(isRaw: true, defaultExposureMode: .preview, cameraTemperature: 5400, cameraTint: 6)
        let before = settings.editorEffectiveValues(isRaw: true, cameraTemperature: 5400, cameraTint: 6)
        XCTAssertNil(settings.clearMasterRecipe(context: rawContext))
        XCTAssertNil(settings.masterRecipeID)
        XCTAssertEqual(settings.lutStrength, 0.5, accuracy: 1e-9)
        var detachedCheck = settings
        detachedCheck.lutStrength = 1
        XCTAssertEqual(detachedCheck.editorEffectiveValues(isRaw: true, cameraTemperature: 5400, cameraTint: 6), before)
    }

    func testMacEditorAdjustmentRulesPrepareResetAndMaterializeRecipe() throws {
        var adj = Adjustments()
        adj.resolveWhiteBalance(WhiteBalance(temperature: 5600, tint: 4))
        adj.applyMasterRecipe(.hamadaDaylightV2)
        adj.strength = 0.75
        let snapshot = MacPhotoEditState(settings: adj, filmID: "", masterRecipeID: MasterRecipe.hamadaDaylightV2.id)
        let context = MacEditorAdjustmentContext(isRaw: true, defaultExposureMode: .preview, neutralFilmID: "")

        guard case .candidate(let detached) = MacEditorAdjustmentRules.prepareReset(scope: .tool(.recipe), snapshot: snapshot, context: context) else {
            XCTFail("Expected reset candidate when detaching master recipe")
            return
        }
        XCTAssertNil(detached.masterRecipeID)
        XCTAssertNil(detached.settings.masterRecipeID)
        XCTAssertEqual(detached.settings.resolvedRenderValues().exposureEV, adj.resolvedRenderValues().exposureEV, accuracy: 1e-5)
    }

    func testIOSTransferCapturePrepareAndSessionUndoRedo() throws {
        let store = try EditPersistence(directory: temporaryRoot.appendingPathComponent("ios-tx-store", isDirectory: true))
        let session = IOSAdjustmentTransferSession(store: store)
        let srcID = PhotoIdentity(contentIdentifier: "src-1")
        let dstID = PhotoIdentity(contentIdentifier: "dst-1")

        var srcSettings = RawSettings.default
        srcSettings.exposure = 1.25
        srcSettings.contrast = 1.2
        srcSettings.clarity = 18.0
        let srcState = PhotoEditState(settings: srcSettings, filmID: "classic-chrome", updatedAt: Date(timeIntervalSince1970: 10))
        try store.save(srcID, state: srcState)

        let srcContext = IOSAdjustmentTransferContext(identifier: srcID.key, isRaw: true, availableLookIDs: ["managed:classic-chrome"], cameraTemperature: 6000, cameraTint: 2)
        let payload = try session.copy(scope: .modified, snapshot: srcState, context: srcContext)

        let dstTarget = IOSAdjustmentTransferTarget(
            identity: dstID,
            displayName: "dst.ARW",
            defaultState: PhotoEditState(settings: .default),
            context: IOSAdjustmentTransferContext(identifier: dstID.key, isRaw: true, availableLookIDs: ["managed:classic-chrome"], cameraTemperature: 5500, cameraTint: -1)
        )
        let prepared = try session.prepare(payload: payload, targets: [dstTarget])
        let outcomes = session.apply(prepared)
        XCTAssertEqual(outcomes.first?.status, .applied)
        XCTAssertEqual(try store.readState(for: dstID).state?.settings.exposure, 1.25)

        XCTAssertTrue(session.canUndoPhoto(dstID))
        let undone = session.undoPhoto(dstID)
        XCTAssertEqual(undone.first?.status, .applied)
        XCTAssertNil(try store.readState(for: dstID).state)

        XCTAssertTrue(session.canRedoPhoto(dstID))
        let redone = session.redoPhoto(dstID)
        XCTAssertEqual(redone.first?.status, .applied)
        XCTAssertEqual(try store.readState(for: dstID).state?.settings.clarity, 18.0)
    }

    func testMacTransferSessionCopyApplyUndoRedo() throws {
        let storeDir = temporaryRoot.appendingPathComponent("mac-tx-store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = try MacEditPersistence(directory: storeDir)
        let session = AdjustmentTransferSession(store: store)
        let dstURL = temporaryRoot.appendingPathComponent("dst.DNG")
        try Data("dng-bytes".utf8).write(to: dstURL)

        var srcAdj = Adjustments()
        srcAdj.exposure = 0.75
        srcAdj.highlights = 25
        srcAdj.dehaze = -12
        let srcState = MacPhotoEditState(settings: srcAdj, filmID: "")
        let payload = try session.copy(scope: .modified, snapshot: srcState,
                                       context: MacAdjustmentTransferContext(identifier: "/tmp/src.DNG", isRaw: true))

        let target = AdjustmentTransferTarget(
            url: dstURL,
            defaultState: MacPhotoEditState(settings: Adjustments(), filmID: ""),
            context: MacAdjustmentTransferContext(identifier: dstURL.path, isRaw: true)
        )
        let prepared = try session.prepare(payload: payload, targets: [target])
        let applied = session.apply(prepared)
        XCTAssertEqual(applied.first?.status, .applied)
        XCTAssertEqual(try store.readState(for: dstURL).state?.settings.dehaze, -12)

        XCTAssertTrue(session.canUndoPhoto(dstURL))
        _ = session.undoPhoto(dstURL)
        XCTAssertNil(try store.readState(for: dstURL).state)
        XCTAssertTrue(session.canRedoPhoto(dstURL))
        _ = session.redoPhoto(dstURL)
        XCTAssertEqual(try store.readState(for: dstURL).state?.settings.highlights, 25)
    }

    func testIOSSessionSequentialABAConflictsOutOfOrderUndo() throws {
        let store = try EditPersistence(directory: temporaryRoot.appendingPathComponent("ios-aba-store", isDirectory: true))
        let session = IOSAdjustmentTransferSession(store: store)
        let id = PhotoIdentity(resourceIdentifier: "ios-aba-photo")

        func editState(_ ev: Double) -> PhotoEditState {
            var settings = RawSettings.default
            settings.exposure = ev
            return PhotoEditState(settings: settings, updatedAt: Date(timeIntervalSince1970: 100))
        }

        for value in [1.0, 2.0, 1.0] {
            let outcome = session.commitEdit(expected: try store.readState(for: id), state: editState(value))
            XCTAssertEqual(outcome.status, .applied)
        }
        XCTAssertEqual(session.transactions.count, 3)
        XCTAssertEqual(try store.readState(for: id).state?.settings.exposure, 1.0)

        let firstTxID = session.transactions[0].id
        let outOfOrder = session.undoTransaction(firstTxID)
        XCTAssertEqual(outOfOrder.count, 1)
        XCTAssertEqual(outOfOrder[0].status, .conflict)
        XCTAssertTrue(outOfOrder[0].requiresHistoryDecision)
        if case .historyOrder? = outOfOrder[0].error as? AdjustmentCommitError {
        } else {
            XCTFail("Expected AdjustmentCommitError.historyOrder, got \(String(describing: outOfOrder[0].error))")
        }
        XCTAssertEqual(try store.readState(for: id).state?.settings.exposure, 1.0)

        XCTAssertEqual(session.undoPhoto(id).first?.status, .applied)
        XCTAssertEqual(try store.state(for: id)?.settings.exposure, 2.0)
        XCTAssertEqual(session.undoPhoto(id).first?.status, .applied)
        XCTAssertEqual(try store.state(for: id)?.settings.exposure, 1.0)
        XCTAssertEqual(session.undoTransaction(firstTxID).first?.status, .applied)
        XCTAssertNil(try store.state(for: id))
    }

    func testMacSessionSequentialABAConflictsOutOfOrderUndo() throws {
        let storeDir = temporaryRoot.appendingPathComponent("mac-aba-store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = try MacEditPersistence(directory: storeDir)
        let session = AdjustmentTransferSession(store: store)
        let photoURL = temporaryRoot.appendingPathComponent("mac-aba.DNG")
        try Data("mac-aba-bytes".utf8).write(to: photoURL)

        func editState(_ ev: Double) -> MacPhotoEditState {
            var settings = Adjustments()
            settings.exposure = ev
            return MacPhotoEditState(settings: settings, filmID: "")
        }

        for value in [1.0, 2.0, 1.0] {
            let outcome = session.commitEdit(expected: try store.readState(for: photoURL), state: editState(value))
            XCTAssertEqual(outcome.status, .applied)
        }
        XCTAssertEqual(session.transactions.count, 3)
        XCTAssertEqual(try store.state(for: photoURL)?.settings.exposure, 1.0)

        let firstTxID = session.transactions[0].id
        let outOfOrder = session.undoTransaction(firstTxID)
        XCTAssertEqual(outOfOrder.count, 1)
        XCTAssertEqual(outOfOrder[0].status, .conflict)
        XCTAssertTrue(outOfOrder[0].requiresHistoryDecision)
        if case .historyOrder? = outOfOrder[0].error as? AdjustmentCommitError {
        } else {
            XCTFail("Expected AdjustmentCommitError.historyOrder, got \(String(describing: outOfOrder[0].error))")
        }
        XCTAssertEqual(try store.state(for: photoURL)?.settings.exposure, 1.0)

        XCTAssertEqual(session.undoPhoto(photoURL).first?.status, .applied)
        XCTAssertEqual(try store.state(for: photoURL)?.settings.exposure, 2.0)
        XCTAssertEqual(session.undoPhoto(photoURL).first?.status, .applied)
        XCTAssertEqual(try store.state(for: photoURL)?.settings.exposure, 1.0)
        XCTAssertEqual(session.undoTransaction(firstTxID).first?.status, .applied)
        XCTAssertNil(try store.state(for: photoURL))
    }

    func testIOSSessionPartialPasteRetryAndSelectiveUndo() throws {
        var writeCount = 0
        var failSecondWrite = true
        let store = try EditPersistence(
            directory: temporaryRoot.appendingPathComponent("ios-partial-retry", isDirectory: true),
            writeData: { data, url in
                writeCount += 1
                if failSecondWrite && writeCount == 2 {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let session = IOSAdjustmentTransferSession(store: store)
        let idA = PhotoIdentity(resourceIdentifier: "ios-batch-a")
        let idB = PhotoIdentity(resourceIdentifier: "ios-batch-b")

        var srcSettings = RawSettings.default
        srcSettings.exposure = 1.25
        let srcState = PhotoEditState(settings: srcSettings, updatedAt: Date(timeIntervalSince1970: 50))
        let srcContext = IOSAdjustmentTransferContext(identifier: "ios-src", isRaw: true)
        let payload = try session.copy(scope: .custom([.exposure]), snapshot: srcState, context: srcContext)

        let defaultState = PhotoEditState(settings: .default, updatedAt: Date(timeIntervalSince1970: 0))
        let targets = [
            IOSAdjustmentTransferTarget(identity: idA, displayName: "A.ARW", defaultState: defaultState,
                                        context: IOSAdjustmentTransferContext(identifier: idA.key, isRaw: true)),
            IOSAdjustmentTransferTarget(identity: idB, displayName: "B.ARW", defaultState: defaultState,
                                        context: IOSAdjustmentTransferContext(identifier: idB.key, isRaw: true)),
        ]
        let operation = try session.prepare(payload: payload, targets: targets)

        let firstOutcomes = session.apply(operation)
        XCTAssertEqual(firstOutcomes.map(\.status), [.applied, .failed])
        XCTAssertEqual(writeCount, 2)
        let savedA = try store.readState(for: idA)
        XCTAssertEqual(savedA.state?.settings.exposure, 1.25)
        XCTAssertNil(try store.state(for: idB))
        XCTAssertEqual(session.transactions.count, 1)
        XCTAssertEqual(session.transactions[0].parts.map(\.identity), [idA])

        failSecondWrite = false
        let retryOutcomes = session.apply(operation)
        XCTAssertEqual(retryOutcomes.map(\.status), [.applied, .applied])
        XCTAssertEqual(writeCount, 3, "Retry must write only previously failed photo B, not photo A")
        XCTAssertEqual(try store.readState(for: idA), savedA)
        XCTAssertEqual(try store.state(for: idB)?.settings.exposure, 1.25)
        XCTAssertEqual(session.transactions.count, 1)
        XCTAssertEqual(session.transactions[0].parts.map(\.identity), [idA, idB])

        let undoA = session.undoPhoto(idA)
        XCTAssertEqual(undoA.map(\.targetID), [idA.key])
        XCTAssertEqual(undoA.map(\.status), [.applied])
        XCTAssertEqual(writeCount, 4)
        XCTAssertNil(try store.state(for: idA))
        XCTAssertEqual(try store.state(for: idB)?.settings.exposure, 1.25)

        let undoRemaining = session.undoTransaction(operation.id)
        XCTAssertEqual(undoRemaining.map(\.targetID), [idB.key])
        XCTAssertEqual(undoRemaining.map(\.status), [.applied])
        XCTAssertEqual(writeCount, 5, "Transaction undo must undo only remaining applied photo B")
        XCTAssertNil(try store.state(for: idA))
        XCTAssertNil(try store.state(for: idB))
    }

    func testMacSessionPartialPasteRetryAndSelectiveUndo() throws {
        let storeDir = temporaryRoot.appendingPathComponent("mac-partial-retry", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        var writeCount = 0
        var failSecondWrite = true
        let store = try MacEditPersistence(directory: storeDir, writeData: { data, url in
            writeCount += 1
            if failSecondWrite && writeCount == 2 {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        })
        let session = AdjustmentTransferSession(store: store)
        let urlA = temporaryRoot.appendingPathComponent("mac-batch-a.DNG")
        let urlB = temporaryRoot.appendingPathComponent("mac-batch-b.DNG")
        try Data("a-bytes".utf8).write(to: urlA)
        try Data("b-bytes".utf8).write(to: urlB)
        let keyA = urlA.resolvingSymlinksInPath().standardizedFileURL.path
        let keyB = urlB.resolvingSymlinksInPath().standardizedFileURL.path

        var srcAdj = Adjustments()
        srcAdj.exposure = 0.75
        let srcState = MacPhotoEditState(settings: srcAdj, filmID: "")
        let payload = try session.copy(scope: .custom([.exposure]), snapshot: srcState,
                                       context: MacAdjustmentTransferContext(identifier: "/tmp/src.DNG", isRaw: true))
        let defaultState = MacPhotoEditState(settings: Adjustments(), filmID: "")
        let targets = [
            AdjustmentTransferTarget(url: urlA, defaultState: defaultState,
                                     context: MacAdjustmentTransferContext(identifier: keyA, isRaw: true)),
            AdjustmentTransferTarget(url: urlB, defaultState: defaultState,
                                     context: MacAdjustmentTransferContext(identifier: keyB, isRaw: true)),
        ]
        let operation = try session.prepare(payload: payload, targets: targets)

        let firstOutcomes = session.apply(operation)
        XCTAssertEqual(firstOutcomes.map(\.status), [.applied, .failed])
        XCTAssertEqual(writeCount, 2)
        let savedA = try store.readState(for: urlA)
        XCTAssertEqual(savedA.state?.settings.exposure, 0.75)
        XCTAssertNil(try store.state(for: urlB))
        XCTAssertEqual(session.transactions.count, 1)
        XCTAssertEqual(session.transactions[0].parts.map(\.identity.path), [keyA])

        failSecondWrite = false
        let retryOutcomes = session.apply(operation)
        XCTAssertEqual(retryOutcomes.map(\.status), [.applied, .applied])
        XCTAssertEqual(writeCount, 3, "Retry must write only previously failed photo B, not photo A")
        XCTAssertEqual(try store.readState(for: urlA), savedA)
        XCTAssertEqual(try store.state(for: urlB)?.settings.exposure, 0.75)
        XCTAssertEqual(session.transactions.count, 1)
        XCTAssertEqual(session.transactions[0].parts.map(\.identity.path), [keyA, keyB])

        let undoA = session.undoPhoto(urlA)
        XCTAssertEqual(undoA.map(\.targetID), [keyA])
        XCTAssertEqual(undoA.map(\.status), [.applied])
        XCTAssertEqual(writeCount, 4)
        XCTAssertNil(try store.state(for: urlA))
        XCTAssertEqual(try store.state(for: urlB)?.settings.exposure, 0.75)

        let undoRemaining = session.undoTransaction(operation.id)
        XCTAssertEqual(undoRemaining.map(\.targetID), [keyB])
        XCTAssertEqual(undoRemaining.map(\.status), [.applied])
        XCTAssertEqual(writeCount, 5, "Transaction undo must undo only remaining applied photo B")
        XCTAssertNil(try store.state(for: urlA))
        XCTAssertNil(try store.state(for: urlB))
    }

    func testLedgerCallbacksDoNotDeadlockWhenQueryingSessionState() throws {
        let store = try EditPersistence(directory: temporaryRoot.appendingPathComponent("ios-reentrant", isDirectory: true))
        let session = IOSAdjustmentTransferSession(store: store)
        let id = PhotoIdentity(resourceIdentifier: "ios-reentrant-photo")

        var settings = RawSettings.default
        settings.exposure = 0.5
        let targetState = PhotoEditState(settings: settings, updatedAt: Date(timeIntervalSince1970: 10))
        let payload = try session.copy(scope: .custom([.exposure]), snapshot: targetState,
                                       context: IOSAdjustmentTransferContext(identifier: "src", isRaw: true))

        var callbackQueries = 0
        let target = IOSAdjustmentTransferTarget(
            identity: id,
            displayName: "reentrant.ARW",
            defaultState: PhotoEditState(settings: .default),
            context: IOSAdjustmentTransferContext(identifier: id.key, isRaw: true),
            isCurrent: {
                callbackQueries += 1
                _ = session.editGeneration(for: id)
                _ = session.transactions
                return true
            },
            validateSource: {
                callbackQueries += 1
                _ = session.editGeneration(for: id)
                _ = session.isCurrentSave(PhotoEditRecord(identity: id, state: nil))
            }
        )
        let prepared = try session.prepare(payload: payload, targets: [target])
        let applied = session.apply(prepared)
        XCTAssertEqual(applied.first?.status, .applied)
        guard let saved = applied.first?.saved else {
            XCTFail("Expected saved record")
            return
        }
        XCTAssertTrue(session.isCurrentSave(saved))
        let undone = session.undoPhoto(id, isCurrent: { _ in
            callbackQueries += 1
            _ = session.editGeneration(for: id)
            _ = session.isCurrentSave(saved)
            return true
        })
        XCTAssertEqual(undone.first?.status, .applied)
        XCTAssertGreaterThanOrEqual(callbackQueries, 6)
    }

    func testMacAiDenoiseStrengthRulesAndRasterWhiteBalanceResetAndTransfer() throws {
        var macSettings = Adjustments()
        macSettings.aiDenoiseEnabled = true
        macSettings.aiDenoiseStrength = 45
        let rawCtx = MacEditorAdjustmentContext(isRaw: true, defaultExposureMode: .preview, neutralFilmID: "")
        let macSnap = MacPhotoEditState(settings: macSettings, filmID: "")
        XCTAssertTrue(MacEditorAdjustmentRules.isModified(scope: .tool(.denoise), snapshot: macSnap, context: rawCtx))
        XCTAssertTrue(MacEditorAdjustmentRules.isModified(scope: .group(.detail), snapshot: macSnap, context: rawCtx))
        guard case .candidate(let resetDenoise) = MacEditorAdjustmentRules.prepareReset(scope: .tool(.denoise), snapshot: macSnap, context: rawCtx) else {
            return XCTFail("Expected candidate reset for aiDenoiseStrength")
        }
        XCTAssertEqual(resetDenoise.settings.aiDenoiseEnabled, false)
        XCTAssertEqual(resetDenoise.settings.aiDenoiseStrength, 100)

        // Raster relative WB: dirty detection, reset, raster->raster transfer, and recipe detach parity with v2 grading
        var rasterSrc = Adjustments()
        rasterSrc.temperature = 5200
        rasterSrc.tint = -12
        let rasterCtx = MacEditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor, neutralFilmID: "")
        let rasterSnap = MacPhotoEditState(settings: rasterSrc, filmID: "")
        XCTAssertTrue(MacEditorAdjustmentRules.isModified(scope: .tool(.whiteBalance), snapshot: rasterSnap, context: rasterCtx))
        XCTAssertTrue(MacEditorAdjustmentRules.isModified(scope: .group(.color), snapshot: rasterSnap, context: rasterCtx))

        let payload = try MacAdjustmentTransfer.capture(
            scope: .custom([.whiteBalanceMode, .temperature, .tint]),
            snapshot: rasterSnap,
            context: MacAdjustmentTransferContext(identifier: "raster-a.png", isRaw: false)
        )
        XCTAssertEqual(payload[.whiteBalanceMode]?.string, "relative")
        let applied = try MacAdjustmentTransfer.prepare(
            payload: payload,
            target: MacPhotoEditState(settings: Adjustments(), filmID: ""),
            context: MacAdjustmentTransferContext(identifier: "raster-b.png", isRaw: false)
        )
        XCTAssertEqual(applied.settings.temperature, 5200)
        XCTAssertEqual(applied.settings.tint, -12)

        // iOS raster->raster transfer + rules
        var iosSrc = RawSettings.default
        iosSrc.temperature = 4900
        iosSrc.tint = 18
        let iosCtx = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor)
        XCTAssertTrue(EditorAdjustmentRules.isModified(.tool(.adjustment(.temperature)),
                                                     snapshot: PhotoEditState(settings: iosSrc), context: iosCtx))
        let iosPayload = try IOSAdjustmentTransfer.capture(
            scope: .custom([.whiteBalanceMode, .temperature, .tint]),
            snapshot: PhotoEditState(settings: iosSrc),
            context: IOSAdjustmentTransferContext(identifier: "ios-a.jpg", isRaw: false)
        )
        XCTAssertEqual(iosPayload[.whiteBalanceMode]?.string, "relative")
        let iosApplied = try IOSAdjustmentTransfer.prepare(
            payload: iosPayload,
            target: PhotoEditState(settings: .default),
            context: IOSAdjustmentTransferContext(identifier: "ios-b.jpg", isRaw: false)
        )
        XCTAssertEqual(iosApplied.settings.temperature, 4900)
        XCTAssertEqual(iosApplied.settings.tint, 18)

        // Mac recipe detach parity preserves v2 grading (luminance/global/blending/balance)
        var v2GradingSettings = Adjustments()
        if let firstRecipe = MasterRecipe.allRecipes.first {
            v2GradingSettings.applyMasterRecipe(firstRecipe)
            v2GradingSettings.gradingSettings.shadows = ColorGradingWheel(hue: 210, saturation: 40, luminance: -20)
            v2GradingSettings.gradingSettings.global = ColorGradingWheel(hue: 35, saturation: 25, luminance: 10)
            v2GradingSettings.gradingSettings.blending = 75
            v2GradingSettings.gradingSettings.balance = -30
            let v2Snap = MacPhotoEditState(settings: v2GradingSettings, filmID: "", masterRecipeID: firstRecipe.id)
            guard case .candidate(let detached) = MacEditorAdjustmentRules.prepareReset(scope: .tool(.recipe), snapshot: v2Snap, context: rasterCtx) else {
                return XCTFail("Expected clean recipe detach on v2 grading")
            }
            XCTAssertEqual(detached.settings.gradingSettings.shadows.luminance, -20)
            XCTAssertEqual(detached.settings.gradingSettings.global.luminance, 10)
            XCTAssertEqual(detached.settings.gradingSettings.blending, 75)
            XCTAssertEqual(detached.settings.gradingSettings.balance, -30)
        }

        // Color Grading v2 Global tab reset (.gradingGlobal) on Mac & iOS (SDR + HDR)
        var macGrading = Adjustments()
        macGrading.gradingSettings.shadows = ColorGradingWheel(hue: 210, saturation: 40, luminance: -20)
        macGrading.gradingSettings.global = ColorGradingWheel(hue: 35, saturation: 25, luminance: 10)
        macGrading.gradingSettings.blending = 75
        macGrading.gradingSettings.balance = -30
        let macGradingSnap = MacPhotoEditState(settings: macGrading, filmID: "")
        XCTAssertTrue(MacEditorAdjustmentRules.isModified(scope: .gradingGlobal, snapshot: macGradingSnap, context: rasterCtx))
        guard case .candidate(let macGlobalReset) = MacEditorAdjustmentRules.prepareReset(scope: .gradingGlobal, snapshot: macGradingSnap, context: rasterCtx) else {
            return XCTFail("Expected Mac .gradingGlobal reset candidate")
        }
        XCTAssertTrue(macGlobalReset.settings.gradingSettings.global.isDefault)
        XCTAssertEqual(macGlobalReset.settings.gradingSettings.shadows, macGrading.gradingSettings.shadows)
        XCTAssertEqual(macGlobalReset.settings.gradingSettings.blending, 75)
        XCTAssertEqual(macGlobalReset.settings.gradingSettings.balance, -30)
        XCTAssertFalse(MacEditorAdjustmentRules.isModified(scope: .gradingGlobal, snapshot: macGlobalReset, context: rasterCtx))

        var iosGrading = RawSettings.default
        iosGrading.gradingSettings = macGrading.gradingSettings
        let iosGradingSnap = PhotoEditState(settings: iosGrading)
        XCTAssertTrue(EditorAdjustmentRules.isModified(.gradingGlobal, snapshot: iosGradingSnap, context: iosCtx))
        guard case .candidate(let iosGlobalReset, let requiresConfirm) = EditorAdjustmentRules.prepareReset(.gradingGlobal, snapshot: iosGradingSnap, context: iosCtx) else {
            return XCTFail("Expected iOS .gradingGlobal reset candidate")
        }
        XCTAssertFalse(requiresConfirm)
        XCTAssertTrue(iosGlobalReset.settings.gradingSettings.global.isDefault)
        XCTAssertEqual(iosGlobalReset.settings.gradingSettings.shadows, iosGrading.gradingSettings.shadows)
        XCTAssertEqual(iosGlobalReset.settings.gradingSettings.blending, 75)
        XCTAssertEqual(iosGlobalReset.settings.gradingSettings.balance, -30)

        var hdrGrading = RawSettings.default
        hdrGrading.hdr = HDRSettings()
        hdrGrading.editingGradingSettings = macGrading.gradingSettings
        let hdrSnap = PhotoEditState(settings: hdrGrading)
        XCTAssertTrue(EditorAdjustmentRules.isModified(.gradingGlobal, snapshot: hdrSnap, context: iosCtx))
        guard case .candidate(let hdrReset, _) = EditorAdjustmentRules.prepareReset(.gradingGlobal, snapshot: hdrSnap, context: iosCtx) else {
            return XCTFail("Expected HDR .gradingGlobal reset candidate")
        }
        XCTAssertTrue(hdrReset.settings.editingGradingSettings.global.isDefault)
        XCTAssertEqual(hdrReset.settings.editingGradingSettings.shadows, macGrading.gradingSettings.shadows)

        var macNav = EditorAdjustmentNavigation(tool: .colorGrading, selectedGradingZone: .shadows, gradingGlobalSelected: true)
        XCTAssertEqual(macNav.currentGradingResetScope, .gradingGlobal)
        macNav.gradingGlobalSelected = false
        XCTAssertEqual(macNav.currentGradingResetScope, .gradingZone(.shadows))

        // Mac Adjustments.set(.temperature/.tint) on raster keeps .asShot mode so resolvedForRaster retains relative WB
        var macRasterWb = Adjustments()
        macRasterWb.set(.temperature, to: 5200)
        macRasterWb.set(.tint, to: 14)
        XCTAssertEqual(macRasterWb.whiteBalanceMode, .asShot)
        XCTAssertEqual(macRasterWb.resolvedForRaster.temperature, 5200)
        XCTAssertEqual(macRasterWb.resolvedForRaster.tint, 14)
    }
}
