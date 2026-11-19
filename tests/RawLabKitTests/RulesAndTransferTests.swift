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
}
