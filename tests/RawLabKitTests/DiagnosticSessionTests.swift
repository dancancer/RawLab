import Foundation
import XCTest
@testable import RawLabKit

final class DiagnosticSessionTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawlab-diag-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeEnvironment() -> DiagnosticEnvironment {
        DiagnosticEnvironment(
            platform: "macos",
            appVersion: "0.12.1",
            build: "24",
            osVersion: "15.1.0",
            deviceModel: "arm64"
        )
    }

    func testDefaultOffRecordsNoBreadcrumbsUntilEnabled() throws {
        let errors = ErrorDiagnostics(directory: tempDir, environment: makeEnvironment())
        let store = DiagnosticSessionStore(directory: tempDir, errorDiagnostics: errors)

        XCTAssertFalse(store.isRecording)
        store.record(category: "import", stage: "openPhoto", message: "Should be ignored while off")

        let state = store.stateSnapshot()
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(state.breadcrumbCount, 0)
        XCTAssertFalse(state.hasExportableLogs)
        XCTAssertThrowsError(try store.buildReportBundle()) { error in
            XCTAssertEqual(error as? DiagnosticUploadError, .emptyDiagnostics)
        }
    }

    func testLeaseSurvivesSingleRelaunchAndExpiresAutomatically() throws {
        final class Clock: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 1_795_000_000)
        }
        let clock = Clock()
        let env = makeEnvironment()

        // Session 1: User enables recording and records an event
        do {
            let errors = ErrorDiagnostics(directory: tempDir, environment: env)
            let store = DiagnosticSessionStore(
                directory: tempDir,
                errorDiagnostics: errors,
                leaseDuration: 1800,
                now: { clock.now }
            )
            let enabled = store.setRecordingEnabled(true)
            XCTAssertTrue(enabled.isRecording)
            store.record(category: "import", stage: "decodeRaw", message: "Decoded RAW header", context: ["extension": "arw"])
            XCTAssertGreaterThanOrEqual(store.stateSnapshot().breadcrumbCount, 2)
        }

        // Session 2 (relaunch #1 within 30m): Recording stays active to capture startup issues
        clock.now.addTimeInterval(60)
        do {
            let errors = ErrorDiagnostics(directory: tempDir, environment: env)
            let store = DiagnosticSessionStore(
                directory: tempDir,
                errorDiagnostics: errors,
                leaseDuration: 1800,
                now: { clock.now }
            )
            let resumed = store.resumeOnLaunch()
            XCTAssertTrue(resumed.isRecording, "First relaunch within lease window stays active")
            store.record(level: .warn, category: "preview", stage: "gpuFallback", message: "Fell back to CPU")
            XCTAssertGreaterThanOrEqual(store.stateSnapshot().breadcrumbCount, 4)
        }

        // Session 3 (relaunch #2): remainingLaunches is now 0, so recording auto-disables while preserving logs
        clock.now.addTimeInterval(60)
        do {
            let errors = ErrorDiagnostics(directory: tempDir, environment: env)
            let store = DiagnosticSessionStore(
                directory: tempDir,
                errorDiagnostics: errors,
                leaseDuration: 1800,
                now: { clock.now }
            )
            let secondRelaunch = store.resumeOnLaunch()
            XCTAssertFalse(secondRelaunch.isRecording, "Second relaunch must auto-reset recording switch to off")
            XCTAssertTrue(secondRelaunch.recoveredPreviousSession)
            XCTAssertTrue(secondRelaunch.hasExportableLogs)
        }

        // Time-based expiration after 30 minutes
        do {
            let errors = ErrorDiagnostics(directory: tempDir, environment: env)
            let store = DiagnosticSessionStore(
                directory: tempDir,
                errorDiagnostics: errors,
                leaseDuration: 1800,
                now: { clock.now }
            )
            _ = store.setRecordingEnabled(true)
            XCTAssertTrue(store.isRecording)
            clock.now.addTimeInterval(1801)
            XCTAssertFalse(store.isRecording)
            store.record(category: "export", stage: "afterExpiry", message: "Ignored after lease expiry")
            let expired = store.stateSnapshot()
            XCTAssertFalse(expired.isRecording)
            XCTAssertTrue(expired.hasExportableLogs)
        }
    }

    func testRedactionScrubsPersonalPathsUrlsAndPrivateExtensions() throws {
        let errors = ErrorDiagnostics(directory: tempDir, environment: makeEnvironment())
        let store = DiagnosticSessionStore(directory: tempDir, errorDiagnostics: errors)
        _ = store.setRecordingEnabled(true)

        store.record(
            level: .error,
            category: "import",
            stage: "openFile",
            message: "Failed opening /Users/alice/Pictures/SecretVacation/DSC0001.ARW and C:\\Users\\Bob\\Photos\\IMG_1.CR3 via file:///private/var/mobile/Containers/Data/photo.dng",
            context: [
                "extension": "secretformat",
                "declaredType": "dyn.ah62d4rv4ge81g6pq",
                "sourcePath": "/Users/alice/Desktop/raw/test.arw",
                "bytes": "42891008",
            ]
        )
        errors.record(
            NSError(
                domain: "RawLab.Decode",
                code: -42,
                userInfo: [NSLocalizedDescriptionKey: "/Users/alice/secret.arw failed"]
            ),
            operation: .photoImport,
            stage: "librawOpen",
            context: ["extension": "arw"]
        )
        // Synchronize errorDiagnostics background queue by reading reportData
        _ = try errors.reportData()

        let bundle = try store.buildReportBundle(
            userNote: "导入 /Users/alice/Pictures/family.arw 黑屏",
            stopActiveRecording: true
        )
        let combined = [bundle.manifestJSON, bundle.breadcrumbsJSONL, bundle.recentErrorsJSON].joined(separator: "\n")

        XCTAssertFalse(combined.contains("alice"), "Personal macOS username must be redacted")
        XCTAssertFalse(combined.contains("SecretVacation"), "Personal folder names must be redacted")
        XCTAssertFalse(combined.contains("DSC0001"), "Original photo filenames must be redacted")
        XCTAssertFalse(combined.contains("C:\\Users\\Bob"), "Windows paths must be redacted")
        XCTAssertFalse(combined.contains("file:///private"), "File URLs must be redacted")
        XCTAssertFalse(combined.contains("secretformat"), "Unrecognized extensions must be masked")
        XCTAssertFalse(combined.contains("dyn."), "Dynamic UTIs must be stripped")
        XCTAssertTrue(combined.contains("42891008"), "Safe byte size diagnostics remain intact")
        XCTAssertTrue(combined.contains("RawLab.Decode"), "Error domain forwarded to breadcrumbs and recent-errors")
        XCTAssertTrue(DiagnosticReportID.isValid(bundle.reportID))
    }

    func testBoundedRingBufferAndZipArchiveIntegrity() throws {
        let errors = ErrorDiagnostics(directory: tempDir, environment: makeEnvironment())
        let store = DiagnosticSessionStore(directory: tempDir, errorDiagnostics: errors)
        _ = store.setRecordingEnabled(true)

        for idx in 1...560 {
            store.record(
                category: "preview",
                stage: "step",
                message: "Step \(idx) completed",
                context: ["iteration": String(idx)]
            )
        }

        let zipURL = tempDir.appendingPathComponent("exported-diag.zip")
        let reportID = try store.exportZip(to: zipURL, userNote: "Repro export test", stopActiveRecording: true)
        XCTAssertTrue(DiagnosticReportID.isValid(reportID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))

        let bundle = try store.buildReportBundle()
        XCTAssertLessThanOrEqual(bundle.manifest.breadcrumbCount, DiagnosticSessionStore.maxBreadcrumbs)
        XCTAssertGreaterThan(bundle.manifest.droppedBreadcrumbs, 0)
        XCTAssertTrue(bundle.breadcrumbsJSONL.contains("\"stage\":\"recordingStarted\""), "Preserves session header")
        XCTAssertTrue(bundle.breadcrumbsJSONL.contains("Step 560 completed"), "Preserves newest tail events")

        // Verify standard PKZIP integrity with /usr/bin/unzip -t
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", zipURL.path]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        unzip.standardError = pipe
        try unzip.run()
        unzip.waitUntilExit()
        let unzipOutput = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(unzip.terminationStatus, 0, "Generated ZIP must pass standard unzip -t: \(unzipOutput)")
        XCTAssertTrue(unzipOutput.contains("manifest.json"))
        XCTAssertTrue(unzipOutput.contains("breadcrumbs.jsonl"))
        XCTAssertTrue(unzipOutput.contains("recent-errors.json"))
        XCTAssertTrue(unzipOutput.contains("README.txt"))
    }

    @MainActor
    func testSLSUploadConfigurationPayloadAndCoordinatorLifecycle() async throws {
        // Endpoint validation
        XCTAssertNoThrow(try SLSDiagnosticUploadConfiguration.parse(SLSDiagnosticUploadConfiguration.productionURLString))
        XCTAssertThrowsError(try SLSDiagnosticUploadConfiguration.parse("http://proj-x.cn-shanghai.log.aliyuncs.com/logstores/diag/track"))
        XCTAssertThrowsError(try SLSDiagnosticUploadConfiguration.parse("https://evil.example.com/logstores/diag/track"))
        XCTAssertThrowsError(try SLSDiagnosticUploadConfiguration.parse("https://user:pass@proj-x.cn-shanghai.log.aliyuncs.com/logstores/diag/track"))
        XCTAssertThrowsError(try SLSDiagnosticUploadConfiguration.parse("https://proj-x.cn-shanghai.log.aliyuncs.com/logstores/diag/track?token=1"))

        final class MockUploadTransport: DiagnosticUploadTransport, @unchecked Sendable {
            var capturedPayloads: [SLSDiagnosticPayload] = []
            var capturedIDs: [String] = []
            var shouldFail = false

            func upload(payload: SLSDiagnosticPayload, reportID: String) async throws {
                if shouldFail {
                    throw DiagnosticUploadError.serviceUnavailable(statusCode: 503)
                }
                capturedPayloads.append(payload)
                capturedIDs.append(reportID)
            }
        }

        let errors = ErrorDiagnostics(directory: tempDir, environment: makeEnvironment())
        let store = DiagnosticSessionStore(directory: tempDir, errorDiagnostics: errors)
        let mock = MockUploadTransport()
        let center = DiagnosticCenter(store: store, uploadTransport: mock)

        center.setRecordingEnabled(true)
        XCTAssertTrue(center.isRecording)
        center.record(category: "hdr", stage: "toneMap", message: "HDR gain map rendered", context: ["headroom": "4.0"])

        // Simulated cloud outage keeps local logs intact
        mock.shouldFail = true
        let failedID = await center.uploadLogs(userNote: "HDR highlight clipping")
        XCTAssertNil(failedID)
        XCTAssertTrue(center.feedbackIsError)
        XCTAssertTrue(center.hasExportableLogs, "Upload failure must never discard local diagnostic logs")
        XCTAssertFalse(center.isRecording, "Attempting upload seals active recording")

        // Subsequent retry succeeds and produces valid SLS PutWebtracking JSON
        mock.shouldFail = false
        let uploadedID = await center.uploadLogs(userNote: "HDR highlight clipping")
        XCTAssertNotNil(uploadedID)
        XCTAssertEqual(uploadedID, center.lastUploadedReportID)
        XCTAssertFalse(center.feedbackIsError)
        XCTAssertEqual(mock.capturedPayloads.count, 1)

        let payload = mock.capturedPayloads[0]
        XCTAssertEqual(payload.rawByteCount, payload.body.count)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        XCTAssertEqual(envelope["__topic__"] as? String, "rawlab-diagnostic-v1")
        XCTAssertEqual(envelope["__source__"] as? String, "macos")
        let logs = try XCTUnwrap(envelope["__logs__"] as? [[String: String]])
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0]["report_id"], uploadedID)
        XCTAssertEqual(logs[0]["chunk_index"], "0")
        XCTAssertEqual(logs[0]["chunk_count"], "1")
        XCTAssertTrue((logs[0]["breadcrumbs_jsonl"] ?? "").contains("HDR gain map rendered"))

        center.clearLogs()
        XCTAssertFalse(center.hasExportableLogs)
        XCTAssertNil(center.lastUploadedReportID)
    }
}
