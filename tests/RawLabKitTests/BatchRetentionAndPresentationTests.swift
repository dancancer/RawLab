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

    func testRenderSchedulerHistogramAndParameterPrecision() {
        var scheduler = RenderScheduler<Int>()
        scheduler.setInteracting(true)
        let req1 = scheduler.submit(10, fileID: "a.arw")
        XCTAssertEqual(req1.pass, .interactive)
        XCTAssertEqual(scheduler.startNext()?.id, req1.id)
        let req2 = scheduler.submit(20, fileID: "a.arw")
        XCTAssertEqual(scheduler.finish(req1), .publishInteractive)
        XCTAssertEqual(scheduler.startNext()?.id, req2.id)
        scheduler.setInteracting(false)
        let exact = scheduler.submit(20, fileID: "a.arw")
        XCTAssertEqual(scheduler.finish(req2), .publishInteractive)
        XCTAssertEqual(scheduler.startNext()?.id, exact.id)
        XCTAssertEqual(scheduler.finish(exact), .publishExact)

        let histogram = HistogramPresentation(bins: [
            [100] + [Double](repeating: 0, count: 255),
            [50] + [Double](repeating: 0, count: 255),
            [50] + [Double](repeating: 0, count: 255)
        ])
        XCTAssertEqual(histogram.peak, 100)
        let segs = histogram.segments(at: 0)
        XCTAssertEqual(segs.map(\.fill), [.neutralGray, .red])

        XCTAssertEqual(ParameterPrecision.exposure.text(0.5, signed: true), "+0.50")
        XCTAssertEqual(ParameterPrecision.temperature.stepped(6500, direction: 1, fine: false, in: 2000...50000), 6600)
    }

    func testBatchSettingsSummaryAndFilmPresentation() {
        var settings = RawSettings.default
        settings.exposure = 0.5
        settings.photoEffects.vignetteAmount = -25
        let headline = BatchSettingsSummary.headline(settings)
        XCTAssertEqual(headline.count, 4)
        let details = BatchSettingsSummary.details(settings)
        XCTAssertTrue(details.contains { $0.value == "-25" })

        let film = FilmPresentation(fileName: "FLog2_to_CLASSIC-CHROME_65grid_V.1.00.cube")
        XCTAssertEqual(film.artworkName, "classic-chrome")
        XCTAssertEqual(film.group, .fuji)
    }
}
