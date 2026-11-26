import Foundation
import XCTest
@testable import RawLabKit

final class BatchRetentionAndPresentationTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLabKitBatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testBatchRetentionRespectsAgeCountAndProtectedJobs() throws {
        let exports = temporaryRoot.appendingPathComponent("Exports", isDirectory: true)
        let journals = temporaryRoot.appendingPathComponent("BatchJobs", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)

        let now = Date()
        let oldDate = now.addingTimeInterval(-35 * 24 * 60 * 60)
        let recentDate = now.addingTimeInterval(-1 * 24 * 60 * 60)

        let expiredID = UUID()
        let protectedID = UUID()
        let freshID = UUID()

        for (id, date) in [(expiredID, oldDate), (protectedID, oldDate), (freshID, recentDate)] {
            let exportDir = exports.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: exportDir.path)

            let journalFile = journals.appendingPathComponent("\(id.uuidString).json")
            try Data("{}".utf8).write(to: journalFile)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: journalFile.path)
        }

        BatchArtifactRetention.protectJob(protectedID)
        defer { BatchArtifactRetention.unprotectJob(protectedID) }

        let reclaimed = BatchArtifactRetention.reclaim(exportsRoot: exports, journalRoot: journals, now: now)
        XCTAssertEqual(reclaimed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.appendingPathComponent(expiredID.uuidString).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exports.appendingPathComponent(protectedID.uuidString).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exports.appendingPathComponent(freshID.uuidString).path))
    }

    func testRUMConfigurationValidatesProductionAndLocalEndpoints() throws {
        let prodIOS = try RUMConfiguration.production(environment: [:])
        XCTAssertEqual(prodIOS.environment, .production)

        let prodMac = try RUMPCConfiguration.production(environment: [:])
        XCTAssertEqual(prodMac.environment, .production)

        XCTAssertThrowsError(try RUMConfiguration(environment: [
            "RAWLAB_RUM_SERVICE_ID": "abc@123",
            "RAWLAB_RUM_WORKSPACE": "ws",
            "RAWLAB_RUM_ENDPOINT": "https://evil.example.com"
        ]))
        XCTAssertThrowsError(try RUMPCConfiguration(environment: [
            "RAWLAB_RUM_APP_ID": "abc@123",
            "RAWLAB_RUM_CONFIG_ADDRESS": "http://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2"
        ]))
    }

    func testErrorDiagnosticsRedactsExtensionsAndBoundsHistory() throws {
        let diagDir = temporaryRoot.appendingPathComponent("diag", isDirectory: true)
        let diag = ErrorDiagnostics(
            directory: diagDir,
            environment: DiagnosticEnvironment(platform: "macos", appVersion: "1.0", build: "1", osVersion: "14.0", deviceModel: "Mac"),
            capacity: 2
        )
        let nsErr = NSError(domain: "com.rawlab.test", code: 42)
        diag.record(nsErr, operation: .photoImport, stage: "probe", context: ["extension": "secret_ext", "declaredType": "dyn.abc"])
        diag.record(nsErr, operation: .photoExport, stage: "write", context: ["extension": "dng"])
        diag.record(nsErr, operation: .batchExport, stage: "run", context: ["extension": "arw"])

        let data = try XCTUnwrap(diag.reportData())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("secret_ext"))
        XCTAssertTrue(text.contains("\"arw\""))
        XCTAssertTrue(text.contains("\"dng\""))
    }

    func testBatchSettingsSummaryAndFilmPresentation() {
        var settings = RawSettings.default
        settings.exposure = 0.5
        settings.effectSettings.vignetteAmount = -25
        let headline = BatchSettingsSummary.headline(settings)
        XCTAssertEqual(headline.count, 4)
        let details = BatchSettingsSummary.details(settings)
        XCTAssertTrue(details.contains { $0.value == "-25" })

        let film = FilmPresentation(fileName: "FLog2_to_CLASSIC-CHROME_65grid_V.1.00.cube")
        XCTAssertEqual(film.artworkName, "classic-chrome")
        XCTAssertEqual(film.group, .fuji)
    }

    func testMacBatchExportItemSymlinkCanonicalizationAndDevInodeResume() throws {
        let realDNG = temporaryRoot.appendingPathComponent("real.dng")
        try Data("raw-bytes".utf8).write(to: realDNG)
        let symDNG = temporaryRoot.appendingPathComponent("sym.dng")
        try FileManager.default.createSymbolicLink(at: symDNG, withDestinationURL: realDNG)

        let itemReal = try MacBatchExportItem(url: realDNG)
        let itemSym = try MacBatchExportItem(url: symDNG)
        let canonicalURL = realDNG.resolvingSymlinksInPath().standardizedFileURL
        let attrs = try FileManager.default.attributesOfItem(atPath: canonicalURL.path)
        let dev = try XCTUnwrap(attrs[.systemNumber] as? NSNumber).uint64Value
        let ino = try XCTUnwrap(attrs[.systemFileNumber] as? NSNumber).uint64Value
        let expectedResourceKey = "\(dev):\(ino)"

        XCTAssertEqual(itemReal.input, canonicalURL)
        XCTAssertEqual(itemSym.input, canonicalURL)
        XCTAssertEqual(itemReal.resourceIdentifier, expectedResourceKey)
        XCTAssertEqual(itemSym.resourceIdentifier, expectedResourceKey)
        XCTAssertEqual(try MacBatchExportItem.resourceKey(symDNG), expectedResourceKey)
        XCTAssertThrowsError(try MacBatchExportItem(url: temporaryRoot.appendingPathComponent("missing.dng")))

        var duplicateJob = MacBatchExportJob(source: canonicalURL, settings: Adjustments(), look: nil, lookName: "Dup")
        duplicateJob.version = 3
        duplicateJob.settingsMode = .perTargetFrozen
        var dupA = itemReal
        dupA.selected = true
        dupA.frozen = MacBatchFrozenSettings(ordinal: 0, settings: Adjustments(), look: nil, lookSHA256: nil, lookName: "Dup", outputFormat: .jpeg, longEdge: nil)
        var dupB = itemSym
        dupB.selected = true
        dupB.frozen = MacBatchFrozenSettings(ordinal: 1, settings: Adjustments(), look: nil, lookSHA256: nil, lookName: "Dup", outputFormat: .jpeg, longEdge: nil)
        duplicateJob.items = [dupA, dupB]
        XCTAssertThrowsError(try duplicateJob.validate())

        let outputDir = temporaryRoot.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let journal = MacBatchJournal(directory: temporaryRoot.appendingPathComponent("journal", isDirectory: true))
        var resumeJob = MacBatchExportJob(source: canonicalURL, settings: Adjustments(), look: nil, lookName: "Resume")
        resumeJob.version = 3
        resumeJob.settingsMode = .perTargetFrozen
        resumeJob.outputDirectory = outputDir
        var item = itemReal
        item.selected = true
        item.resourceIdentifier = expectedResourceKey
        item.frozen = MacBatchFrozenSettings(ordinal: 0, settings: Adjustments(), look: nil, lookSHA256: nil, lookName: "Resume", outputFormat: .png, longEdge: 2048)
        resumeJob.items = [item]

        let encodedData = try JSONEncoder().encode(resumeJob)
        var decoded = try JSONDecoder().decode(MacBatchExportJob.self, from: encodedData)
        XCTAssertEqual(decoded.items[0].resourceIdentifier, expectedResourceKey)
        try MacBatchExportRunner.run(job: &decoded, journal: journal, scope: .unfinished, shouldCancel: { false }) { _, _, _, destination in
            try Data("exported".utf8).write(to: destination)
        }
        XCTAssertEqual(decoded.succeededCount, 1)
        XCTAssertEqual(decoded.items[0].status, .succeeded)
    }

    func testMacBatchExportJobEffectiveOutputSharpeningAndFrozenValidation() throws {
        let source = temporaryRoot.appendingPathComponent("src.dng")
        try Data("src".utf8).write(to: source)
        var job = MacBatchExportJob(source: source, settings: Adjustments(), look: nil, lookName: "Sharp")
        job.outputFormat = .jpeg
        job.outputSharpening = .high
        XCTAssertEqual(job.effectiveOutputSharpening, .high)
        job.outputFormat = .renderedDNG
        XCTAssertEqual(job.effectiveOutputSharpening, .off)

        var badSettings = Adjustments()
        badSettings.exposure = 999.0
        let digest = String(repeating: "a", count: 64)
        let badIOSFrozen = BatchFrozenSettings(ordinal: 0, settings: badSettings, inputSHA256: digest, outputFormat: .jpeg)
        XCTAssertThrowsError(try badIOSFrozen.validate())

        let macLongEdge65535 = MacBatchFrozenSettings(ordinal: 0, settings: Adjustments(), look: nil, lookSHA256: nil, lookName: "Max", outputFormat: .jpeg, longEdge: 65535)
        XCTAssertNoThrow(try macLongEdge65535.validate())
        let iosLongEdge65535 = BatchFrozenSettings(ordinal: 0, settings: Adjustments(), inputSHA256: digest, outputFormat: .jpeg, longEdge: 65535)
        XCTAssertThrowsError(try iosLongEdge65535.validate())
        var macJob65535 = MacBatchExportJob(source: source, settings: Adjustments(), look: nil, lookName: "Max")
        macJob65535.longEdge = 65535
        XCTAssertNoThrow(try macJob65535.validate())
    }

    func testAdjustmentTransferPreflightCancelResetsIsRunning() throws {
        let queue = DispatchQueue(label: "preflight-cancel-isrunning-test")
        let preflight = AdjustmentTransferPreflight(queue: queue)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var completedCalls = 0

        let payload = try AdjustmentTransferPayload(
            source: .init(identifier: "src", isRaw: true, processingVersion: ProcessingIdentity.current.version, recipe: nil, hdrProcessingVersion: nil),
            values: ["light.exposure": .number(0.5)]
        )
        let prepared = PreparedAdjustmentTransfer(id: UUID(), payload: payload, action: .paste, targets: [])

        preflight.start({ shouldCancel in
            entered.signal()
            release.wait()
            if shouldCancel() { throw CancellationError() }
            return prepared
        }, completed: { _ in
            completedCalls += 1
        })
        XCTAssertTrue(preflight.isRunning)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)

        preflight.cancel()
        XCTAssertFalse(preflight.isRunning)

        release.signal()
        let drained = DispatchSemaphore(value: 0)
        queue.async { DispatchQueue.main.async { drained.signal() } }
        let deadline = Date().addingTimeInterval(5)
        while drained.wait(timeout: .now()) != .success {
            guard Date() < deadline else { XCTFail("Preflight queue did not drain"); return }
            RunLoop.main.run(mode: .default, before: deadline)
        }
        XCTAssertFalse(preflight.isRunning)
        XCTAssertEqual(completedCalls, 0)
    }

    func testBatchExportPreservesDefringeAcrossRasterTransitionsAndGrainEffectReset() throws {
        var settings = Adjustments()
        settings.lensCorrection = LensCorrectionSettings(
            distortion: true, tca: true, autoCrop: false, mode: .manual, profileID: "lens-a", vignetting: true,
            defringePurpleAmount: 7, defringePurpleHue: 42, defringeGreenAmount: 3, defringeGreenHue: 62
        )
        let sourceURL = temporaryRoot.appendingPathComponent("src.jpg")
        try Data("jpg".utf8).write(to: sourceURL)

        let rasterSnapshot = BatchSourceSnapshot(
            identity: PhotoIdentity(resourceIdentifier: "raster-1"),
            sourceURL: sourceURL,
            displayName: "src.jpg",
            sourceKind: .raster,
            settings: settings
        )
        let rasterToRaw = rasterSnapshot.settings(for: .raw)
        XCTAssertEqual(rasterToRaw.lensCorrection?.distortion, false)
        XCTAssertEqual(rasterToRaw.lensCorrection?.tca, false)
        XCTAssertEqual(rasterToRaw.lensCorrection?.vignetting, false)
        XCTAssertNil(rasterToRaw.lensCorrection?.profileID)
        XCTAssertEqual(rasterToRaw.lensCorrection?.defringePurpleAmount, 7)
        XCTAssertEqual(rasterToRaw.lensCorrection?.defringePurpleHue, 42)
        XCTAssertEqual(rasterToRaw.lensCorrection?.defringeGreenAmount, 3)
        XCTAssertEqual(rasterToRaw.lensCorrection?.defringeGreenHue, 62)

        let rawSnapshot = BatchSourceSnapshot(
            identity: PhotoIdentity(resourceIdentifier: "raw-1"),
            sourceURL: temporaryRoot.appendingPathComponent("src.arw"),
            displayName: "src.arw",
            sourceKind: .raw,
            settings: settings
        )
        let rawToRaster = rawSnapshot.settings(for: .raster)
        XCTAssertEqual(rawToRaster.lensCorrection?.distortion, false)
        XCTAssertEqual(rawToRaster.lensCorrection?.defringePurpleAmount, 7)

        let job = MacBatchExportJob(source: sourceURL, settings: settings, look: nil, lookName: "Sharp")
        let jobToRaw = try job.settings(for: temporaryRoot.appendingPathComponent("target.dng"), resolveX3fMode: { _ in X3fMode.normal })
        XCTAssertEqual(jobToRaw.lensCorrection?.distortion, false)
        XCTAssertEqual(jobToRaw.lensCorrection?.defringePurpleAmount, 7)
        XCTAssertEqual(jobToRaw.lensCorrection?.defringeGreenAmount, 3)

        var grainSettings = Adjustments()
        grainSettings.effectSettings.grainToneCurve = .negativeAsymmetric
        grainSettings.effectSettings.grainFormatPreset = .film135
        XCTAssertFalse(grainSettings.isEffectDefault(.grainAmount))
        grainSettings.resetEffect(.grainAmount)
        XCTAssertTrue(grainSettings.isEffectDefault(.grainAmount))
        XCTAssertNil(grainSettings.photoEffects)
    }
}
