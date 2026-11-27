import Foundation
import XCTest
@testable import RawLabKit

final class ErrorDiagnosticsTests: XCTestCase {
    private var directory: URL!
    private let environment = DiagnosticEnvironment(
        platform: "ios",
        appVersion: "0.9.3",
        build: "18",
        osVersion: "26.4",
        deviceModel: "iPad14,5"
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawlab-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testErrorDetailsImportRecoveryPrivacyRestartAndBoundedHistory() throws {
        let log = ErrorDiagnostics(directory: directory, environment: environment, capacity: 3)
        let id = UUID()
        let cause = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [NSFilePathErrorKey: "/private/photo.ARW"])
        let error = NSError(domain: "RawLab.HDR", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not open secret-photo.jpeg", NSUnderlyingErrorKey: cause
        ])
        let input = ["entryPoint": "files", "extension": "jpeg", "detectedType": "com.sony.arw-raw-image"]
        log.recordImportSuccess(attemptID: UUID(), context: input)
        let empty = try log.reportData()
        XCTAssertNil(empty, "Routine successful imports do not create error logs")
        log.record(error, operation: .photoImport, stage: "probeHDR", attemptID: id, context: input,
                   native: .init(status: 2, reason: 2, field: 7))
        log.recordImportSuccess(attemptID: UUID(), context: ["entryPoint": "files", "extension": "arw"])
        log.recordImportSuccess(attemptID: UUID(), context: input)
        let data = try XCTUnwrap(log.reportData())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(!text.contains("secret-photo") && !text.contains("/private/"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let events = json["events"] as! [[String: Any]]
        XCTAssertTrue(json["schemaVersion"] as? Int == 1 && events.count == 2)
        let first = events[0]
        XCTAssertTrue(first["stage"] as? String == "probeHDR" && first["attemptID"] as? String == id.uuidString)
        let failure = first["error"] as! [String: Any]
        XCTAssertEqual(failure["domain"] as? String, "RawLab.HDR")
        XCTAssertEqual(failure["native"] as? [String: Int], ["status": 2, "reason": 2, "field": 7])
        XCTAssertEqual((failure["underlying"] as? [[String: Any]])?.first?["code"] as? Int, 260)
        XCTAssertEqual(events[1]["outcome"] as? String, "succeeded")
        XCTAssertEqual(first["context"] as? [String: String], input)

        let reopened = ErrorDiagnostics(directory: directory, environment: environment, capacity: 3)
        let afterRestart = try reopened.reportData()
        XCTAssertNotNil(afterRestart, "A later app launch can export the same failure")
        for i in 3...6 {
            reopened.record(NSError(domain: "RawLab.Test", code: i), operation: .preview, stage: "render")
        }
        let bounded = try JSONSerialization.jsonObject(with: XCTUnwrap(reopened.reportData())) as! [String: Any]
        let latest = (bounded["events"] as! [[String: Any]]).compactMap { ($0["error"] as? [String: Any])?["code"] as? Int }
        XCTAssertEqual(latest, [4, 5, 6], "Keep only the newest events in order")
    }

    func testPrivateFileExtensionsMaskedAndLegacyJournalSanitized() throws {
        let folder = directory.appendingPathComponent("extensions")
        let log = ErrorDiagnostics(directory: folder, environment: environment)
        let error = NSError(domain: "RawLab.Test", code: 1)
        let privateContext = ["extension": "clientalice", "declaredType": "dyn.declared-example",
                              "providerType": "dyn.provider-example", "entryPoint": "files"]
        log.record(error, operation: .photoImport, stage: "retainPickerSource", context: privateContext)
        log.record(error, operation: .photoImport, stage: "renderPreview",
                   context: ["extension": "cr3", "declaredType": "com.canon.cr3-raw-image"])

        let data = try XCTUnwrap(log.reportData())
        let report = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let events = report["events"] as! [[String: Any]]
        XCTAssertEqual(
            events[0]["context"] as? [String: String],
            ["extension": "unknown", "entryPoint": "files"],
            "Unknown extensions and their dynamic type identifiers must stay out of the log"
        )
        XCTAssertEqual(
            (events[1]["context"] as? [String: String])?["extension"],
            "cr3",
            "A known RAW extension remains useful for diagnostics"
        )

        var oldReport = report
        var oldEvents = events
        oldEvents[0]["context"] = privateContext
        oldReport["events"] = oldEvents
        let journal = folder.appendingPathComponent("errors.json")
        try JSONSerialization.data(withJSONObject: oldReport).write(to: journal)
        let reopened = ErrorDiagnostics(directory: folder, environment: environment)
        let exported = String(decoding: try XCTUnwrap(reopened.reportData()), as: UTF8.self)
        XCTAssertTrue(
            !exported.contains("clientalice") && !exported.contains("dyn."),
            "Exporting a v1 journal created by an older build must also mask private extensions"
        )
    }
}
