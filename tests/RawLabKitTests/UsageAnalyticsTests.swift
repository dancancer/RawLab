import Foundation
import XCTest
@testable import RawLabKit

private enum UsageTestFailure: Error { case storage, start }

private final class MockUsageConsentStore: UsageConsentStore {
    var value = true
    var fails = false
    func load() throws -> Bool { value }
    func save(_ enabled: Bool) throws {
        if fails { throw UsageTestFailure.storage }
        value = enabled
    }
}

private final class MockUsageTransport: UsageAnalyticsTransport {
    var isAvailable = true
    var starts = 0
    var stops = 0
    var events: [UsageEvent] = []
    var fails = false
    func start() throws {
        if fails { throw UsageTestFailure.start }
        starts += 1
    }
    func record(_ event: UsageEvent) { events.append(event) }
    func stop() { stops += 1 }
}

final class UsageAnalyticsTests: XCTestCase {
    func testConsentWithdrawalFailuresPayloadsAndInstallIdentity() throws {
        let consent = MockUsageConsentStore()
        let transport = MockUsageTransport()
        let usage = UsageAnalytics(store: consent, transport: transport)
        usage.beginSession()
        usage.beginSession()
        XCTAssertTrue(usage.isEnabled)
        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(transport.events, [.appStarted])

        usage.record(.photoImported)
        usage.setEnabled(false)
        usage.record(.exportCompleted)
        XCTAssertFalse(consent.value)
        XCTAssertEqual(transport.stops, 1)
        XCTAssertEqual(transport.events, [.appStarted, .photoImported])

        usage.setEnabled(true)
        XCTAssertEqual(transport.events.filter { $0 == .appStarted }.count, 1)

        consent.fails = true
        usage.setEnabled(false)
        XCTAssertFalse(usage.isEnabled)
        XCTAssertNotNil(usage.issue)
        usage.setEnabled(true)
        XCTAssertFalse(usage.isEnabled)

        let unavailable = MockUsageTransport(); unavailable.isAvailable = false
        let declined = MockUsageConsentStore(); declined.value = false
        let disabled = UsageAnalytics(store: declined, transport: unavailable)
        disabled.beginSession()
        disabled.setEnabled(true)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(unavailable.starts, 0)

        let oldConsent = MockUsageConsentStore()
        let oldDisabled = UsageAnalytics(store: oldConsent, transport: unavailable)
        oldDisabled.beginSession()
        XCTAssertTrue(oldDisabled.isEnabled)
        XCTAssertEqual(unavailable.starts, 0)
        oldDisabled.setEnabled(false)
        XCTAssertFalse(oldConsent.value)
        XCTAssertFalse(oldDisabled.isEnabled)

        let failing = MockUsageTransport(); failing.fails = true
        let kept = MockUsageConsentStore()
        let failed = UsageAnalytics(store: kept, transport: failing)
        failed.beginSession()
        failed.record(.photoImported)
        XCTAssertTrue(failing.events.isEmpty)
        XCTAssertNotNil(failed.issue)
        XCTAssertTrue(kept.value)

        let batch = UsageEvent.batchExportCompleted(succeeded: -10, failed: 200_000, outcome: .partial)
        XCTAssertEqual(batch.group, "usage")
        XCTAssertEqual(batch.name, "batch_export_completed")
        XCTAssertEqual(batch.value, 0)
        XCTAssertEqual(
            batch.properties(platform: .macos),
            ["schema_version": "1", "platform": "macos", "outcome": "partial", "succeeded_count": "0", "failed_count": "100000"]
        )
        XCTAssertEqual(UsageEvent.filmSelected(.custom).properties(platform: .ios)["kind"], "custom")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-usage-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("consent.json")
        let disk = FileUsageConsentStore(url: path)
        XCTAssertTrue(try disk.load())
        try disk.save(false)
        XCTAssertFalse(try FileUsageConsentStore(url: path).load())
        try disk.save(true)
        XCTAssertTrue(try FileUsageConsentStore(url: path).load())

        let idPath = directory.appendingPathComponent("identity-consent.json")
        let idFile = FileUsageConsentStore(url: idPath).installIDURL
        let first = try FileUsageConsentStore(url: idPath).installID()
        XCTAssertNotNil(UUID(uuidString: first))
        let again = try FileUsageConsentStore(url: idPath).installID()
        XCTAssertEqual(again, first)
        try FileUsageConsentStore(url: idPath).save(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: idFile.path))
        try FileUsageConsentStore(url: idPath).save(true)
        let second = try FileUsageConsentStore(url: idPath).installID()
        XCTAssertNotEqual(second, first)
        try Data("not-a-uuid".utf8).write(to: idFile)
        let repaired = try FileUsageConsentStore(url: idPath).installID()
        XCTAssertNotNil(UUID(uuidString: repaired))

        try Data("invalid".utf8).write(to: path)
        let corrupt = UsageAnalytics(store: disk, transport: MockUsageTransport())
        corrupt.beginSession()
        XCTAssertFalse(corrupt.isEnabled)
    }
}
