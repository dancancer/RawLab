import Foundation
import XCTest
@testable import RawLabKit

final class ExternalReloadAndTransferTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLabKitExternalReload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testTransferJSONEncodeDecodeRoundTripPreservesV012Fields() throws {
        var settings = Adjustments()
        settings.exposure = 0.65
        settings.contrast = 1.18
        settings.atmosphere = AtmosphereSettings(clarity: 0.35, dehaze: 0)
        settings.toneControls = ToneControlsSettings(blackPoint: -0.15, whitePoint: 0, vibrance: 0)
        settings.toneCurveConfig = ToneCurveSettings(
            mode: .custom,
            points: [
                ToneCurvePoint(x: 0, y: 0),
                ToneCurvePoint(x: 0.25, y: 0.2),
                ToneCurvePoint(x: 1, y: 1)
            ],
            applyToLuminosity: true,
            parametric: ToneCurveParametric(highlights: -12, lights: 8, darks: -6, shadows: 14)
        )
        settings.colorGrading = ColorGradingSettings(
            shadows: ColorGradingWheel(hue: 215, saturation: 25, luminance: -8),
            midtones: ColorGradingWheel(),
            highlights: ColorGradingWheel(hue: 35, saturation: 18, luminance: 5),
            global: ColorGradingWheel(hue: 180, saturation: 10, luminance: 3),
            blending: 62,
            balance: -15
        )
        let snapshot = MacPhotoEditState(settings: settings, filmID: "")
        let context = MacAdjustmentTransferContext(
            identifier: "/tmp/example.dng",
            isRaw: true,
            sourceIsHDR: false,
            sourceSupportsCameraHDR: false,
            sourceIsBayerHDR: false,
            availableLookIDs: [],
            defaultExposureMode: .preview,
            hasUncommittedDraft: false
        )
        let payload = try MacAdjustmentTransfer.capture(
            scope: .custom(AdjustmentTransferField.legacyFields),
            snapshot: snapshot,
            context: context
        )
        let data = try payload.encodeTransferJSONData(prettyPrinted: true)
        let decoded = try AdjustmentTransferPayload.decodeTransferJSON(data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded[.curveApplyToLuminosity], .boolean(true))
        XCTAssertEqual(decoded[.gradingBlending]?.number, 62)
        XCTAssertEqual(decoded[.gradingBalance]?.number, -15)
    }

    func testTransferJSONDecodeRejectsCorruptOrUnsupportedPayload() throws {
        XCTAssertThrowsError(try AdjustmentTransferPayload.decodeTransferJSON(Data("not json".utf8)))
        let badVersion = Data(#"{"payload_version":99,"scope_version":1,"source":{"identifier":"a","is_raw":true,"processing_version":3},"values":{"light.exposure":0.5}}"#.utf8)
        XCTAssertThrowsError(try AdjustmentTransferPayload.decodeTransferJSON(badVersion))
    }

    func testAdoptExternalReloadRecordsSingleUndoableStepAndRespectsUnchanged() throws {
        let photoURL = temporaryRoot.appendingPathComponent("sample.png")
        try Data("png-stub".utf8).write(to: photoURL)
        let editsDir = temporaryRoot.appendingPathComponent("Edits", isDirectory: true)
        let store = try MacEditPersistence(directory: editsDir)
        let session = AdjustmentTransferSession(store: store)
        let identity = try OriginalFileIdentity(photoURL)

        var initialAdj = Adjustments()
        initialAdj.exposure = 0.25
        let initialState = MacPhotoEditState(settings: initialAdj, filmID: "")
        let expected = try store.saveState(identity: identity, state: initialState)

        let unchangedOutcome = session.adoptExternalReload(expected: expected, reloaded: expected)
        XCTAssertEqual(unchangedOutcome.status, .unchanged)
        XCTAssertTrue(session.transactions.isEmpty)

        // External writer updates edits.json
        let externalStore = try MacEditPersistence(directory: editsDir)
        var reloadedAdj = Adjustments()
        reloadedAdj.exposure = 1.15
        let reloadedState = MacPhotoEditState(settings: reloadedAdj, filmID: "")
        let reloaded = try externalStore.saveState(identity: identity, state: reloadedState)

        let appliedOutcome = session.adoptExternalReload(expected: expected, reloaded: reloaded)
        XCTAssertEqual(appliedOutcome.status, .applied)
        XCTAssertEqual(session.transactions.count, 1)
        XCTAssertTrue(session.canUndoPhoto(photoURL))

        let undone = session.undoPhoto(photoURL)
        XCTAssertEqual(undone.first?.status, .applied)
        XCTAssertEqual(undone.first?.saved?.state?.settings.exposure, 0.25)

        let redone = session.redoPhoto(photoURL)
        XCTAssertEqual(redone.first?.status, .applied)
        XCTAssertEqual(redone.first?.saved?.state?.settings.exposure, 1.15)
    }

    func testExternalStoreFileWatcherHandlesMissingDirAndAtomicReplace() throws {
        let editsURL = temporaryRoot.appendingPathComponent("Edits/edits.json")
        let presetsURL = temporaryRoot.appendingPathComponent("Presets/presets.json")

        let firstExp = expectation(description: "Detects initial creation from missing directory")
        let secondExp = expectation(description: "Detects atomic replacement after inode swap")
        var observed: [URL] = []
        var firedCount = 0

        let watcher = ExternalStoreFileWatcher(urls: [editsURL, presetsURL], debounceInterval: 0.03) { url in
            observed.append(url)
            firedCount += 1
            if firedCount == 1 {
                firstExp.fulfill()
            } else if firedCount == 2 {
                secondExp.fulfill()
            }
        }
        defer { watcher.stop() }

        try FileManager.default.createDirectory(at: editsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"records\":{},\"version\":1}".utf8).write(to: editsURL, options: .atomic)
        wait(for: [firstExp], timeout: 3.0)

        // Ensure mtime/size/inode advance across atomic swap
        Thread.sleep(forTimeInterval: 0.05)
        try Data("{\"records\":{\"k\":{}},\"version\":1}".utf8).write(to: editsURL, options: .atomic)
        wait(for: [secondExp], timeout: 3.0)

        XCTAssertEqual(observed.count, 2)
    }

    func testStoreLastWriteFingerprintTracksWritesAndDetectsExternalChanges() throws {
        let editsDir = temporaryRoot.appendingPathComponent("Edits", isDirectory: true)
        let presetsDir = temporaryRoot.appendingPathComponent("Presets", isDirectory: true)
        let photoURL = temporaryRoot.appendingPathComponent("p.png")
        try Data("stub".utf8).write(to: photoURL)
        let identity = try OriginalFileIdentity(photoURL)

        let editStoreA = try MacEditPersistence(directory: editsDir)
        let editStoreB = try MacEditPersistence(directory: editsDir)
        var adjA = Adjustments(); adjA.exposure = 0.5
        _ = try editStoreA.saveState(identity: identity, state: MacPhotoEditState(settings: adjA, filmID: ""))
        let editsPath = editsDir.appendingPathComponent("edits.json").resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(editStoreA.lastWriteFingerprint, FileStatFingerprint(resolvedPath: editsPath))

        var adjB = Adjustments(); adjB.exposure = 1.2
        _ = try editStoreB.saveState(identity: identity, state: MacPhotoEditState(settings: adjB, filmID: ""))
        XCTAssertNotEqual(editStoreA.lastWriteFingerprint, FileStatFingerprint(resolvedPath: editsPath))

        let presetStoreA = AdjustmentPresetStore(directory: presetsDir)
        let presetStoreB = AdjustmentPresetStore(directory: presetsDir)
        let context = MacAdjustmentTransferContext(
            identifier: photoURL.path, isRaw: false, sourceIsHDR: false, sourceSupportsCameraHDR: false,
            sourceIsBayerHDR: false, availableLookIDs: [], defaultExposureMode: .sensor, hasUncommittedDraft: false
        )
        let payload = try MacAdjustmentTransfer.capture(
            scope: .custom([.exposure]),
            snapshot: MacPhotoEditState(settings: adjA, filmID: ""),
            context: context
        )
        _ = try presetStoreA.create(name: "Test A", payload: payload)
        let presetsPath = presetsDir.appendingPathComponent("presets.json").resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(presetStoreA.lastWriteFingerprint, FileStatFingerprint(resolvedPath: presetsPath))

        _ = try presetStoreB.create(name: "Test B", payload: payload)
        XCTAssertNotEqual(presetStoreA.lastWriteFingerprint, FileStatFingerprint(resolvedPath: presetsPath))
    }

    func testMcpGuiSyncOutputsDecodeCleanlyInMacEditPersistenceAndAdjustmentPresetStore() throws {
        let photoURL = temporaryRoot.appendingPathComponent("probe.dng")
        try Data("dng-stub".utf8).write(to: photoURL)
        let dataDir = temporaryRoot.appendingPathComponent("AppData", isDirectory: true)
        let presetsDir = dataDir.appendingPathComponent("Presets", isDirectory: true)
        let editsDir = dataDir.appendingPathComponent("Edits", isDirectory: true)
        try FileManager.default.createDirectory(at: presetsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: editsDir, withIntermediateDirectories: true)

        let rawUnreadable = #"{  "name" : "Future V99",  "id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "created_at": 1, "updated_at": 1, "payload": { "payload_version": 99, "ratio": 1.000, "extra": [ 1, 2 ] }  }"#
        let sdrPresetID = "10000000-0000-4000-8000-000000000001"
        let hdrPresetID = "20000000-0000-4000-8000-000000000002"
        let sdrPresetObject: [String: Any] = [
            "id": sdrPresetID,
            "name": "CLI SDR V013",
            "created_at": 1_700_000_000_000 as Int64,
            "updated_at": 1_700_000_000_000 as Int64,
            "payload": [
                "payload_version": 1,
                "scope_version": 1,
                "source": [
                    "identifier": "preset:\(sdrPresetID)",
                    "is_raw": true,
                    "processing_version": 3,
                    "recipe": NSNull(),
                ],
                "values": [
                    "looks.reference": ["kind": "neutral", "id": NSNull()],
                    "looks.strength": 1.5,
                    "light.exposure": -2.5,
                    "light.contrast": 1.2,
                    "light.highlights": -0.3,
                    "light.shadows": 0.4,
                    "color.saturation": 1.15,
                    "color.hsl.hue.red": 65.0,
                    "light.curve": [
                        "mode": "custom",
                        "points": [[0.0, 0.0], [0.5, 0.55], [1.0, 1.0]],
                        "channels": ["red": ["mode": "custom", "points": [[0.0, 0.0], [0.5, 0.65], [1.0, 1.0]]]],
                    ],
                    "light.curve.apply_to_luminosity": true,
                    "light.curve.parametric": [
                        "highlights": -10.0, "lights": 8.0, "darks": -4.0, "shadows": 12.0,
                        "split_shadow": 0.2, "split_midtone": 0.5, "split_highlight": 0.8,
                    ],
                    "color.grading.shadows": ["hue": 220.0, "saturation": 25.0, "luminance": -6.0],
                    "color.grading.global": ["hue": 180.0, "saturation": 10.0, "luminance": 2.0],
                    "color.grading.blending": 62.0,
                    "color.grading.balance": -8.0,
                ],
            ],
        ]
        let hdrPresetObject: [String: Any] = [
            "id": hdrPresetID,
            "name": "CLI HDR V9",
            "created_at": 1_700_000_000_100 as Int64,
            "updated_at": 1_700_000_000_100 as Int64,
            "payload": [
                "payload_version": 2,
                "scope_version": 2,
                "source": [
                    "identifier": "preset:\(hdrPresetID)",
                    "is_raw": false,
                    "processing_version": 3,
                    "hdr_processing_version": 9,
                    "recipe": NSNull(),
                ],
                "values": [
                    "light.exposure": 1.25,
                    "hdr.relative_temperature": 6000.0,
                    "hdr.relative_tint": -5.0,
                    "hdr.peak_limit_ev": 2.5,
                    "hdr.sdr_exposure_ev": -0.5,
                    "hdr.sdr_contrast": 10.0,
                    "hdr.sdr_saturation": 15.0,
                    "hdr.look": ["sha256": String(repeating: "a", count: 64), "name": "HDR Silver", "strength": 1.5],
                    "hdr.camera_development": [
                        "version": 1,
                        "white_balance_mode": "as_shot",
                        "temperature": 0.0,
                        "tint": 0.0,
                        "exposure_reference": "metadata",
                        "fbdd_level": 0,
                    ],
                    "light.curve.parametric": [
                        "highlights": 5.0, "lights": 0.0, "darks": 0.0, "shadows": -5.0,
                        "split_shadow": 0.25, "split_midtone": 0.5, "split_highlight": 0.75,
                    ],
                ],
            ],
        ]
        let sdrData = try JSONSerialization.data(withJSONObject: sdrPresetObject, options: [.sortedKeys])
        let hdrData = try JSONSerialization.data(withJSONObject: hdrPresetObject, options: [.sortedKeys])
        let presetsPayload = "{\"presets\":[\(String(decoding: sdrData, as: UTF8.self)),\(String(decoding: hdrData, as: UTF8.self)),\(rawUnreadable)],\"registry_version\":1,\"retired_ids\":[\"11111111-2222-4333-8444-555555555555\"]}"
        try Data(presetsPayload.utf8).write(to: presetsDir.appendingPathComponent("presets.json"))

        let identity = try OriginalFileIdentity(photoURL)
        let editStateObject: [String: Any] = [
            "filmID": "",
            "masterRecipeID": NSNull(),
            "settings": [
                "processing": ["family": "rawlab", "quality": "standard", "version": 3],
                "x3fMode": "normal-v1",
                "exposureMode": "匹配内嵌预览",
                "exposure": -4.5,
                "temperature": 6500.0,
                "tint": 0.0,
                "whiteBalanceMode": "拍摄时设置",
                "strength": 1.0,
                "contrast": 0.0,
                "highlights": 0.0,
                "shadows": 0.0,
                "toneCurve": 25.0,
                "saturation": 0.0,
                "sharpening": 150.0,
                "rawNoiseReduction": 0.0,
                "aiDenoiseEnabled": false,
                "supportsRawNoiseReduction": true,
                "masterRecipeSettingsVersion": 3,
                "hsl": [
                    "hue": [85.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                    "saturation": [10.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                    "lightness": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                ],
                "toneCurveConfig": [
                    "mode": "legacy",
                    "points": [] as [Any],
                    "channels": ["red": ["mode": "custom", "points": [[0.0, 0.0], [0.5, 0.65], [1.0, 1.0]]]],
                    "apply_to_luminosity": true,
                    "parametric": [
                        "highlights": -10.0, "lights": 5.0, "darks": -3.0, "shadows": 8.0,
                        "split_shadow": 0.2, "split_midtone": 0.5, "split_highlight": 0.8,
                    ],
                ],
                "colorGrading": [
                    "shadows": ["hue": 220.0, "saturation": 30.0, "luminance": 0.0],
                    "midtones": ["hue": 0.0, "saturation": 0.0, "luminance": 0.0],
                    "highlights": ["hue": 0.0, "saturation": 0.0, "luminance": 0.0],
                    "global": ["hue": 190.0, "saturation": 12.0, "luminance": 3.0],
                    "blending": 65.0,
                    "balance": -10.0,
                ],
                "geometry": [
                    "cropX": 0.1, "cropY": 0.2, "cropWidth": 0.9, "cropHeight": 0.8,
                    "quarterTurns": 0, "flipHorizontal": false, "flipVertical": false,
                    "straightenDegrees": 0.0, "perspectiveHorizontal": -0.75, "perspectiveVertical": 0.0,
                ],
            ],
        ]
        let editsObject: [String: Any] = [
            "version": 1,
            "records": [
                identity.path: [
                    "identity": [
                        "fileNumber": identity.fileNumber,
                        "modified": identity.modified.timeIntervalSinceReferenceDate,
                        "path": identity.path,
                        "size": identity.size,
                    ],
                    "state": editStateObject,
                ],
            ],
        ]
        let editsData = try JSONSerialization.data(withJSONObject: editsObject, options: [.sortedKeys])
        try editsData.write(to: editsDir.appendingPathComponent("edits.json"))

        let presetStore = AdjustmentPresetStore(directory: presetsDir)
        let presets = try presetStore.list()
        let unreadable = try presetStore.listUnreadable()
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(unreadable.count, 1)
        XCTAssertEqual(unreadable.first?.json, rawUnreadable)
        XCTAssertEqual(Set(presets.map(\.name)), ["CLI SDR V013", "CLI HDR V9"])
        let hdrPreset = try XCTUnwrap(presets.first { $0.name == "CLI HDR V9" })
        XCTAssertEqual(hdrPreset.payload.source.hdrProcessingVersion, 9)
        XCTAssertFalse(hdrPreset.payload.source.isRaw)

        let editStore = try MacEditPersistence(directory: editsDir)
        let record = try editStore.readState(for: photoURL)
        let state = try XCTUnwrap(record.state)
        XCTAssertEqual(state.settings.exposure, -4.5, accuracy: 1e-6)
        XCTAssertEqual(state.settings.toneCurve, 0.25, accuracy: 1e-6)
        XCTAssertEqual(state.settings.sharpening, 1.5, accuracy: 1e-6)
        XCTAssertEqual(state.settings.hslSettings.hue[0], 85.0, accuracy: 1e-6)
        XCTAssertEqual(state.settings.curveSettings.channels.red.mode, .custom)
        XCTAssertEqual(state.settings.curveSettings.parametric.splitMidtone, 0.5, accuracy: 1e-6)
        XCTAssertTrue(state.settings.curveSettings.applyToLuminosity)
        XCTAssertEqual(state.settings.gradingSettings.shadows.hue, 220.0, accuracy: 1e-6)
        XCTAssertEqual(state.settings.gradingSettings.midtones, ColorGradingWheel())
        XCTAssertEqual(state.settings.gradingSettings.highlights, ColorGradingWheel())
        XCTAssertEqual(state.settings.gradingSettings.global.hue, 190.0, accuracy: 1e-6)
        XCTAssertEqual(state.settings.geometrySettings.perspectiveHorizontal, -0.75, accuracy: 1e-6)
    }

    func testAdoptExternalReloadFlushesPendingCommits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-reload-flush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let photoURL = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3, 4]).write(to: photoURL)
        let identity = try OriginalFileIdentity(photoURL)

        let editsDir = root.appendingPathComponent("Edits")
        let store = try MacEditPersistence(directory: editsDir)
        let session = AdjustmentTransferSession(store: store)

        var firstAdj = Adjustments()
        firstAdj.exposureMode = .sensor
        firstAdj.exposure = 0.25
        let firstState = MacPhotoEditState(settings: firstAdj, filmID: "")
        try store.enqueueSaveState(identity: identity, state: firstState)

        var extAdj = Adjustments()
        extAdj.exposureMode = .sensor
        extAdj.exposure = 1.15
        let extRecord = MacPhotoEditRecord(identity: identity, state: MacPhotoEditState(settings: extAdj, filmID: ""))

        let outcome = session.adoptExternalReload(
            expected: MacPhotoEditRecord(identity: identity, state: firstState),
            reloaded: extRecord
        )
        XCTAssertFalse(store.hasPendingCommits, "adoptExternalReload must flush pending async commits before adopting external reload")
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(outcome.saved?.state?.settings.exposure ?? 0, 1.15, accuracy: 1e-6)
    }
}
