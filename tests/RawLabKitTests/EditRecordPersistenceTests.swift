import Foundation
import XCTest
@testable import RawLabKit

final class EditRecordPersistenceTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLabKitPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    private func loadFixtureRoot() throws -> [String: Any] {
        let url = RawLabKitTestSupport.repoRoot.appendingPathComponent("Shared/fixtures/edit-records-v1.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeTempFile(named name: String, contents: Data = Data("rawlab-sample-bytes\n".utf8)) throws -> URL {
        let dir = temporaryRoot.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private func sampleIOSSettingsFull() throws -> RawSettings {
        var s = RawSettings.default
        s.processing = .c5
        s.x3fMode = .legacy
        s.proRAWDecodeVersion = 2
        s.exposureMode = .scene
        s.exposure = 0.625
        s.contrast = 1.25
        s.saturation = 1.15
        s.temperature = 6150
        s.tint = -8.5
        s.whiteBalanceMode = .custom
        s.highlights = -0.375
        s.shadows = 0.4375
        s.toneCurve = 0.25
        s.sharpening = 0.75
        s.displayChromaDenoise = 1
        s.denoise = RawDenoiseSettings(enabled: true, luma: 18, chroma: 54, coarse: 62)
        s.blackPoint = -15.5
        s.whitePoint = 22.25
        s.vibrance = 14.75
        s.clarity = 26.5
        s.dehaze = -14.25
        s.photoEffects = PhotoEffectsSettings(
            vignetteAmount: -35.5,
            vignetteMidpoint: 62.25,
            vignetteRoundness: -18.5,
            vignetteFeather: 44.75,
            vignetteHighlights: 28.5,
            grainAmount: 19.25,
            grainSize: 32.5,
            grainRoughness: 58.25
        )
        s.hsl.set(.hue, channel: 0, value: 12.5)
        s.hsl.set(.saturation, channel: 5, value: -16.5)
        s.hsl.set(.lightness, channel: 4, value: 14.25)
        s.gradingSettings = ColorGradingSettings(
            shadows: ColorGradingWheel(hue: 215.25, saturation: 35.5),
            midtones: ColorGradingWheel(hue: 42.5, saturation: 18.25),
            highlights: ColorGradingWheel(hue: 120.75, saturation: 24.5)
        )
        s.curveSettings = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.1875), .init(x: 0.75, y: 0.8125), .init(x: 1, y: 1)],
            channels: ToneCurveChannels(
                red: ToneCurveShape(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.5625), .init(x: 1, y: 1)]),
                green: .identity,
                blue: .identity
            )
        )
        s.geometry = GeometrySettings(
            cropX: 0.0625, cropY: 0.125, cropWidth: 0.75, cropHeight: 0.625,
            quarterTurns: 1, flipHorizontal: true, flipVertical: false,
            straightenDegrees: -3.5, perspectiveHorizontal: 0.25, perspectiveVertical: -0.125
        )
        s.lensCorrection = LensCorrectionSettings(
            distortion: true, tca: true, autoCrop: false, mode: .manual,
            profileID: "Fujinon XF35mmF1.4 R", vignetting: true
        )
        var dormantHDR = HDRSettings()
        dormantHDR.mode = .sdr
        dormantHDR.exposure = -0.5
        dormantHDR.temperature = 6200
        dormantHDR.tint = -6.0
        dormantHDR.renditionSettings = HDRRenditionSettings(
            peakLimitEV: 2.5, sdrExposureEV: -0.25, sdrContrast: 12.0, sdrSaturation: -8.0
        )
        dormantHDR.detailSettings.denoise = 0.375
        s.hdr = dormantHDR
        return s
    }

    private func sampleMacAdjustmentsFull() -> Adjustments {
        var a = Adjustments()
        a.processing = .c5
        a.x3fMode = .legacy
        a.proRAWDecodeVersion = 2
        a.exposureMode = .scene
        a.exposure = 0.625
        a.contrast = 25.0
        a.saturation = 15.0
        a.resolveWhiteBalance(WhiteBalance(temperature: 5400, tint: 4.5))
        a.set(.temperature, to: 6150)
        a.set(.tint, to: -8.5)
        a.highlights = 37.5
        a.shadows = 43.75
        a.toneCurve = 25.0
        a.sharpening = 75.0
        a.chromaNoiseReduction = 1
        a.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 18, chroma: 54, coarse: 62, preset: .custom)
        a.aiDenoiseEnabled = true
        a.blackPoint = -15.5
        a.whitePoint = 22.25
        a.vibrance = 14.75
        a.clarity = 26.5
        a.dehaze = -14.25
        a.photoEffects = PhotoEffectsSettings(
            vignetteAmount: -35.5,
            vignetteMidpoint: 62.25,
            vignetteRoundness: -18.5,
            vignetteFeather: 44.75,
            vignetteHighlights: 28.5,
            grainAmount: 19.25,
            grainSize: 32.5,
            grainRoughness: 58.25
        )
        a.setHSL(.hue, channel: 0, value: 12.5)
        a.setHSL(.saturation, channel: 5, value: -16.5)
        a.setHSL(.lightness, channel: 4, value: 14.25)
        a.gradingSettings = ColorGradingSettings(
            shadows: ColorGradingWheel(hue: 215.25, saturation: 35.5),
            midtones: ColorGradingWheel(hue: 42.5, saturation: 18.25),
            highlights: ColorGradingWheel(hue: 120.75, saturation: 24.5)
        )
        a.curveSettings = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.1875), .init(x: 0.75, y: 0.8125), .init(x: 1, y: 1)],
            channels: ToneCurveChannels(
                red: ToneCurveShape(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.5625), .init(x: 1, y: 1)]),
                green: .identity,
                blue: .identity
            )
        )
        a.setGeometrySettings(GeometrySettings(
            cropX: 0.0625, cropY: 0.125, cropWidth: 0.75, cropHeight: 0.625,
            quarterTurns: 1, flipHorizontal: true, flipVertical: false,
            straightenDegrees: -3.5, perspectiveHorizontal: 0.25, perspectiveVertical: -0.125
        ))
        a.lensCorrection = LensCorrectionSettings(
            distortion: true, tca: true, autoCrop: false, mode: .manual,
            profileID: "Fujinon XF35mmF1.4 R", vignetting: true
        )
        var dormantHDR = HDRSettings()
        dormantHDR.mode = .sdr
        dormantHDR.exposure = -0.5
        dormantHDR.temperature = 6200
        dormantHDR.tint = -6.0
        dormantHDR.renditionSettings = HDRRenditionSettings(
            peakLimitEV: 2.5, sdrExposureEV: -0.25, sdrContrast: 12.0, sdrSaturation: -8.0
        )
        dormantHDR.detailSettings.denoise = 0.375
        a.hdr = dormantHDR
        return a
    }

    func testRoundtripFullStateOnIOSAndMacStores() throws {
        let iosStoreDir = temporaryRoot.appendingPathComponent("ios-edits", isDirectory: true)
        let macStoreDir = temporaryRoot.appendingPathComponent("mac-edits", isDirectory: true)
        try FileManager.default.createDirectory(at: macStoreDir, withIntermediateDirectories: true)

        let iosStore = try EditPersistence(directory: iosStoreDir)
        let iosID = PhotoIdentity(resourceIdentifier: "PH-ROUNDTRIP-1", contentIdentifier: "sha256-roundtrip-1")
        let iosState = PhotoEditState(settings: try sampleIOSSettingsFull(), filmID: "classic-chrome", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try iosStore.save(iosID, state: iosState)

        let iosReloaded = try EditPersistence(directory: iosStoreDir).readState(for: iosID)
        XCTAssertEqual(iosReloaded.state, iosState)

        let photoURL = try makeTempFile(named: "sample-01.ARW")
        let macStore = try MacEditPersistence(directory: macStoreDir)
        let macState = MacPhotoEditState(settings: sampleMacAdjustmentsFull(), filmID: "classic-chrome", masterRecipeID: nil)
        try macStore.save(photoURL, state: macState)

        let macReloaded = try MacEditPersistence(directory: macStoreDir).readState(for: photoURL)
        XCTAssertEqual(macReloaded.state, macState)
    }

    func testFixtureLegacyWireSamplesDecodeOnBothIOSAndMac() throws {
        let root = try loadFixtureRoot()
        let compat = try XCTUnwrap(root["compatibility_scenarios"] as? [[String: Any]])
        let legacyScenario = try XCTUnwrap(compat.first { ($0["id"] as? String) == "compat-legacy-omitted-extensions" })
        let samples = try XCTUnwrap(legacyScenario["legacy_wire_samples"] as? [String: Any])

        // iOS legacy wire sample
        let iosSample = try XCTUnwrap(samples["ios_json"] as? [String: Any])
        let iosBytesText = try XCTUnwrap(iosSample["photo_bytes_utf8"] as? String)
        let iosPhotoURL = try makeTempFile(named: "legacy-ios.JPG", contents: Data(iosBytesText.utf8))
        let iosIdentity = try PhotoIdentity.fallback(for: iosPhotoURL)
        let iosRawStoreJSON = try XCTUnwrap(iosSample["store_json"] as? String)
        let iosDir = temporaryRoot.appendingPathComponent("legacy-ios-store", isDirectory: true)
        try FileManager.default.createDirectory(at: iosDir, withIntermediateDirectories: true)
        try Data(iosRawStoreJSON.utf8).write(to: iosDir.appendingPathComponent("edits.json"))
        let iosLoaded = try XCTUnwrap(try EditPersistence(directory: iosDir).readState(for: iosIdentity).state)
        XCTAssertEqual(iosLoaded.filmID, "provia-legacy")
        XCTAssertEqual(iosLoaded.settings.processing, .legacy)
        XCTAssertEqual(iosLoaded.settings.x3fMode, .legacy)
        XCTAssertEqual(iosLoaded.settings.exposure, 0.35, accuracy: 1e-9)
        XCTAssertEqual(iosLoaded.settings.contrast, 1.15, accuracy: 1e-9)
        XCTAssertEqual(iosLoaded.settings.saturation, 1.08, accuracy: 1e-9)
        XCTAssertEqual(iosLoaded.settings.temperature, 5800.0, accuracy: 1e-9)
        XCTAssertEqual(iosLoaded.settings.tint, 4.5, accuracy: 1e-9)

        // macOS legacy wire sample
        let macSample = try XCTUnwrap(samples["macos_json"] as? [String: Any])
        let macPhotoName = try XCTUnwrap(macSample["photo_name"] as? String)
        let macPhotoURL = try makeTempFile(named: macPhotoName)
        let macIdentity = try OriginalFileIdentity(macPhotoURL)
        let template = try XCTUnwrap(macSample["store_json"] as? String)
        let resolvedStoreJSON = template
            .replacingOccurrences(of: "__PHOTO_PATH__", with: macIdentity.path)
            .replacingOccurrences(of: "__SIZE__", with: String(macIdentity.size))
            .replacingOccurrences(of: "__MODIFIED__", with: String(macIdentity.modified.timeIntervalSinceReferenceDate))
            .replacingOccurrences(of: "__FILE_NUMBER__", with: String(macIdentity.fileNumber))
        let macDir = temporaryRoot.appendingPathComponent("legacy-mac-store", isDirectory: true)
        try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)
        try Data(resolvedStoreJSON.utf8).write(to: macDir.appendingPathComponent("edits.json"))
        let macLoaded = try XCTUnwrap(try MacEditPersistence(directory: macDir).readState(for: macPhotoURL).state)
        XCTAssertEqual(macLoaded.filmID, "provia-legacy")
        XCTAssertEqual(macLoaded.settings.processing, .legacy)
        XCTAssertEqual(macLoaded.settings.x3fMode, .legacy)
        XCTAssertEqual(macLoaded.settings.exposure, 0.35, accuracy: 1e-9)
        XCTAssertEqual(macLoaded.settings.contrast, 12.5, accuracy: 1e-9)
        XCTAssertEqual(macLoaded.settings.saturation, 8.5, accuracy: 1e-9)
        XCTAssertEqual(macLoaded.settings.temperature, 5800.0, accuracy: 1e-9)
        XCTAssertEqual(macLoaded.settings.tint, 4.5, accuracy: 1e-9)
    }

    func testUnknownFieldTier1ToleranceAndTier2IsolationWithSiblingPreservation() throws {
        // Tier 1: extra field in settings root & photoEffects tolerated on iOS and Mac
        let iosDir = temporaryRoot.appendingPathComponent("x1-ios", isDirectory: true)
        let macDir = temporaryRoot.appendingPathComponent("x1-mac", isDirectory: true)
        try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)

        let iosStore = try EditPersistence(directory: iosDir)
        let idHealthy = PhotoIdentity(contentIdentifier: "healthy-1")
        let idTarget = PhotoIdentity(contentIdentifier: "target-1")
        let state = PhotoEditState(settings: try sampleIOSSettingsFull(), filmID: "velvia", updatedAt: Date(timeIntervalSince1970: 100))
        try iosStore.save(idHealthy, state: state)
        try iosStore.save(idTarget, state: state)

        // Mutate target record on disk: Tier 1 extra field inside photoEffects + settings root
        let iosFileURL = iosDir.appendingPathComponent("edits.json")
        var storeObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: iosFileURL)) as? [String: Any])
        var records = try XCTUnwrap(storeObj["records"] as? [String: Any])
        var targetRec = try XCTUnwrap(records[idTarget.editKey] as? [String: Any])
        var targetSettings = try XCTUnwrap(targetRec["settings"] as? [String: Any])
        var targetEffects = try XCTUnwrap(targetSettings["photoEffects"] as? [String: Any])
        targetEffects["future_halation"] = 12.0
        targetSettings["photoEffects"] = targetEffects
        targetSettings["future_adjustment_slider"] = 42.5
        targetRec["settings"] = targetSettings
        targetRec["future_record_field"] = "ignore-safely"
        records[idTarget.editKey] = targetRec
        storeObj["records"] = records
        storeObj["future_store_root"] = "vnext"
        try JSONSerialization.data(withJSONObject: storeObj, options: [.sortedKeys]).write(to: iosFileURL)

        XCTAssertEqual(try EditPersistence(directory: iosDir).readState(for: idTarget).state, state)

        // Tier 2: unknown field inside processing OR hdr.tone must isolate target & preserve raw entry across sibling saves
        var tier2Rec = targetRec
        var tier2Settings = targetSettings
        var processing = try XCTUnwrap(tier2Settings["processing"] as? [String: Any])
        processing["future_pipeline_flag"] = true
        tier2Settings["processing"] = processing
        tier2Rec["settings"] = tier2Settings
        records[idTarget.editKey] = tier2Rec
        storeObj["records"] = records
        try JSONSerialization.data(withJSONObject: storeObj, options: [.sortedKeys]).write(to: iosFileURL)

        let preSaveDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: iosFileURL)) as? [String: Any])
        let preSaveTargetEntry = try XCTUnwrap((preSaveDoc["records"] as? [String: Any])?[idTarget.editKey] as? [String: Any])

        let iosAfterTier2 = try EditPersistence(directory: iosDir)
        XCTAssertThrowsError(try iosAfterTier2.readState(for: idTarget)) { error in
            XCTAssertTrue(error is UnusableEditRecordError)
        }
        // Sibling remains readable and writable without clobbering unreadable entry!
        var updatedSibling = state
        var s2 = updatedSibling.settings
        s2.exposure = 1.25
        updatedSibling = updatedSibling.replacing(settings: s2, preservingFilmID: "provia")
        try iosAfterTier2.save(idHealthy, state: updatedSibling)
        XCTAssertEqual(try iosAfterTier2.readState(for: idHealthy).state?.settings.exposure, 1.25)

        let postSaveDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: iosFileURL)) as? [String: Any])
        let postSaveTargetEntry = try XCTUnwrap((postSaveDoc["records"] as? [String: Any])?[idTarget.editKey] as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: postSaveTargetEntry), NSDictionary(dictionary: preSaveTargetEntry))

        // Mac: future processing version=99 & corrupt entry isolation + raw entry preservation
        let macHealthyURL = try makeTempFile(named: "mac-healthy.DNG")
        let macBadURL = try makeTempFile(named: "mac-future.DNG")
        let macCorruptURL = try makeTempFile(named: "mac-corrupt.DNG")
        let macStore = try MacEditPersistence(directory: macDir)
        let macState = MacPhotoEditState(settings: sampleMacAdjustmentsFull(), filmID: "velvia")
        try macStore.save([macHealthyURL, macBadURL, macCorruptURL], state: macState)

        let macFileURL = macDir.appendingPathComponent("edits.json")
        var macDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: macFileURL)) as? [String: Any])
        var macRecords = try XCTUnwrap(macDoc["records"] as? [String: Any])
        let badKey = try OriginalFileIdentity(macBadURL).path
        var badEntry = try XCTUnwrap(macRecords[badKey] as? [String: Any])
        var badState = try XCTUnwrap(badEntry["state"] as? [String: Any])
        var badSettings = try XCTUnwrap(badState["settings"] as? [String: Any])
        var badProc = try XCTUnwrap(badSettings["processing"] as? [String: Any])
        badProc["version"] = 99
        badSettings["processing"] = badProc
        badState["settings"] = badSettings
        badEntry["state"] = badState
        macRecords[badKey] = badEntry

        let corruptKey = try OriginalFileIdentity(macCorruptURL).path
        macRecords[corruptKey] = ["broken": true]
        macDoc["records"] = macRecords
        try JSONSerialization.data(withJSONObject: macDoc, options: [.sortedKeys]).write(to: macFileURL)

        let macReloadedStore = try MacEditPersistence(directory: macDir)
        XCTAssertThrowsError(try macReloadedStore.readState(for: macBadURL)) { error in
            XCTAssertTrue(error is UnusableEditRecordError)
        }
        XCTAssertThrowsError(try macReloadedStore.readState(for: macCorruptURL)) { error in
            XCTAssertTrue(error is UnusableEditRecordError)
        }
        var updatedMac = macState
        updatedMac.settings.exposure = -1.25
        try macReloadedStore.save(macHealthyURL, state: updatedMac)
        XCTAssertEqual(try macReloadedStore.readState(for: macHealthyURL).state?.settings.exposure, -1.25)

        let macPostDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: macFileURL)) as? [String: Any])
        let macPostRecords = try XCTUnwrap(macPostDoc["records"] as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(macPostRecords[badKey] as? [String: Any])),
                       NSDictionary(dictionary: badEntry))
        XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(macPostRecords[corruptKey] as? [String: Any])),
                       NSDictionary(dictionary: ["broken": true]))
    }

    func testBoundaryRejectionsAndNegativeZeroCanonicalization() throws {
        // Test boundary rejections for BOTH EditPersistence (iOS) and MacEditPersistence (Mac)
        let iosDir = temporaryRoot.appendingPathComponent("bounds-ios", isDirectory: true)
        let macDir = temporaryRoot.appendingPathComponent("bounds-mac", isDirectory: true)
        try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)

        let iosStore = try EditPersistence(directory: iosDir)
        let iosID = PhotoIdentity(contentIdentifier: "bounds-target")
        let iosState = PhotoEditState(settings: try sampleIOSSettingsFull(), filmID: "provia", updatedAt: Date(timeIntervalSince1970: 100))
        try iosStore.save(iosID, state: iosState)

        let macURL = try makeTempFile(named: "mac-bounds.RAF")
        let macStore = try MacEditPersistence(directory: macDir)
        let macState = MacPhotoEditState(settings: sampleMacAdjustmentsFull(), filmID: "provia")
        try macStore.save(macURL, state: macState)

        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("exposure-99", { $0["exposure"] = 99.0 }),
            ("temperature-90000", { $0["temperature"] = 90000.0 }),
            ("effects-150", {
                var fx = ($0["photoEffects"] as? [String: Any]) ?? [:]
                fx["vignetteAmount"] = 150.0
                $0["photoEffects"] = fx
            }),
            ("hsl-150", {
                var hsl = ($0["hsl"] as? [String: Any]) ?? [:]
                var hue = (hsl["hue"] as? [Double]) ?? [Double](repeating: 0, count: 8)
                hue[0] = 150.0
                hsl["hue"] = hue
                $0["hsl"] = hsl
            }),
            ("grading-360", {
                var cg = ($0["colorGrading"] as? [String: Any]) ?? [:]
                cg["shadows"] = ["hue": 360.0, "saturation": 10.0]
                $0["colorGrading"] = cg
            }),
            ("crop-overflow", {
                var g = ($0["geometry"] as? [String: Any]) ?? [:]
                g["cropX"] = 0.6
                g["cropWidth"] = 0.6
                $0["geometry"] = g
            }),
            ("hdr-peak-10", {
                var hdr = ($0["hdr"] as? [String: Any]) ?? [:]
                var rendition = (hdr["renditionSettings"] as? [String: Any]) ?? [:]
                rendition["peakLimitEV"] = 10.0
                hdr["renditionSettings"] = rendition
                $0["hdr"] = hdr
            }),
            ("invalid-exposure-mode", { $0["exposureMode"] = 999 }),
            ("non-monotonic-curve", {
                var c = ($0["toneCurveConfig"] as? [String: Any]) ?? [:]
                c["mode"] = "custom"
                c["points"] = [[0.0, 0.0], [0.7, 0.5], [0.3, 0.8], [1.0, 1.0]]
                $0["toneCurveConfig"] = c
            })
        ]

        let iosFileURL = iosDir.appendingPathComponent("edits.json")
        let baseIOSData = try Data(contentsOf: iosFileURL)
        let macFileURL = macDir.appendingPathComponent("edits.json")
        let baseMacData = try Data(contentsOf: macFileURL)
        let macKey = try OriginalFileIdentity(macURL).path

        for (label, mutate) in mutations {
            var iosDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: baseIOSData) as? [String: Any])
            var iosRecs = try XCTUnwrap(iosDoc["records"] as? [String: Any])
            var iosRec = try XCTUnwrap(iosRecs[iosID.editKey] as? [String: Any])
            var iosSettings = try XCTUnwrap(iosRec["settings"] as? [String: Any])
            mutate(&iosSettings)
            iosRec["settings"] = iosSettings
            iosRecs[iosID.editKey] = iosRec
            iosDoc["records"] = iosRecs
            try JSONSerialization.data(withJSONObject: iosDoc, options: [.sortedKeys]).write(to: iosFileURL)
            XCTAssertThrowsError(try EditPersistence(directory: iosDir).readState(for: iosID), "iOS should reject \(label)") { error in
                XCTAssertTrue(error is UnusableEditRecordError, "iOS \(label) error: \(error)")
            }

            var macDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: baseMacData) as? [String: Any])
            var macRecs = try XCTUnwrap(macDoc["records"] as? [String: Any])
            var macRec = try XCTUnwrap(macRecs[macKey] as? [String: Any])
            var macStateObj = try XCTUnwrap(macRec["state"] as? [String: Any])
            var macSettings = try XCTUnwrap(macStateObj["settings"] as? [String: Any])
            mutate(&macSettings)
            macStateObj["settings"] = macSettings
            macRec["state"] = macStateObj
            macRecs[macKey] = macRec
            macDoc["records"] = macRecs
            try JSONSerialization.data(withJSONObject: macDoc, options: [.sortedKeys]).write(to: macFileURL)
            XCTAssertThrowsError(try MacEditPersistence(directory: macDir).readState(for: macURL), "Mac should reject \(label)") { error in
                XCTAssertTrue(error is UnusableEditRecordError, "Mac \(label) error: \(error)")
            }
        }

        // Negative zero canonical equivalence
        let negZeroMacJSON = """
        {"records":{"\(macKey)":{"identity":{"fileNumber":\(try OriginalFileIdentity(macURL).fileNumber),"modified":\(try OriginalFileIdentity(macURL).modified.timeIntervalSinceReferenceDate),"path":"\(macKey)","size":\(try OriginalFileIdentity(macURL).size)},"state":{"filmID":"","settings":{"exposure":-0.0,"highlights":-0.0,"shadows":-0.0}}}},"version":1}
        """
        try Data(negZeroMacJSON.utf8).write(to: macFileURL)
        let loadedNegZero = try XCTUnwrap(try MacEditPersistence(directory: macDir).readState(for: macURL).state)
        XCTAssertEqual(loadedNegZero.settings.exposure, 0.0)
        XCTAssertEqual(loadedNegZero.settings.highlights, 0.0)
        XCTAssertEqual(loadedNegZero.settings.shadows, 0.0)
    }

    func testDormantHDRAndProRAWPreservedAcrossMacReset() throws {
        var settings = sampleMacAdjustmentsFull()
        settings.hdrCameraAIEnabled = true
        let snapshot = MacPhotoEditState(settings: settings, filmID: "velvia")
        let context = MacEditorAdjustmentContext(isRaw: true, defaultExposureMode: .preview, neutralFilmID: "")
        guard case .candidate(let resetCandidate) = MacEditorAdjustmentRules.prepareReset(scope: .all, snapshot: snapshot, context: context) else {
            XCTFail("Expected reset candidate")
            return
        }
        XCTAssertEqual(resetCandidate.settings.processing, .c5)
        XCTAssertEqual(resetCandidate.settings.x3fMode, .legacy)
        XCTAssertEqual(resetCandidate.settings.proRAWDecodeVersion, 2)
        XCTAssertTrue(resetCandidate.settings.hdrCameraAIEnabled)
        XCTAssertEqual(resetCandidate.settings.hdr?.renditionSettings.peakLimitEV, 2.5)
    }

    func testRegistryCacheInvalidatesAndUpdatesAfterWrite() throws {
        let dir = temporaryRoot.appendingPathComponent("cache-test", isDirectory: true)
        let store = try EditPersistence(directory: dir)
        let id = PhotoIdentity(contentIdentifier: "cache-photo-1")
        let state = PhotoEditState(settings: RawSettings.default, filmID: "provia", updatedAt: Date(timeIntervalSince1970: 500))
        let beforeReads = EditPersistence.registryDiskReadCount(forDirectory: dir)
        try store.save(id, state: state)
        _ = try EditPersistence(directory: dir).readState(for: id)
        _ = try EditPersistence(directory: dir).readState(for: id)
        let afterReads = EditPersistence.registryDiskReadCount(forDirectory: dir)
        XCTAssertEqual(afterReads, beforeReads, "Write updates registry cache in place and subsequent reads hit cache")
    }
}
