import Foundation

private enum TestFailure: Error { case storage, start }
private final class Consent: UsageConsentStore {
    var value = true
    var fails = false
    func load() throws -> Bool { value }
    func save(_ enabled: Bool) throws {
        if fails { throw TestFailure.storage }
        value = enabled
    }
}
private final class Transport: UsageAnalyticsTransport {
    var isAvailable = true
    var starts = 0
    var stops = 0
    var events: [UsageEvent] = []
    var fails = false
    func start() throws {
        if fails { throw TestFailure.start }
        starts += 1
    }
    func record(_ event: UsageEvent) { events.append(event) }
    func stop() { stops += 1 }
}

@main struct UsageAnalyticsTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        let consent = Consent(), transport = Transport()
        let usage = UsageAnalytics(store: consent, transport: transport)
        usage.beginSession()
        usage.beginSession()
        check(usage.isEnabled && transport.starts == 1 && transport.events == [.appStarted], "never-chosen consent starts once and counts one launch")
        usage.record(.photoImported)
        usage.setEnabled(false)
        usage.record(.exportCompleted)
        check(!consent.value && transport.stops == 1 && transport.events == [.appStarted, .photoImported], "withdrawal stops and drops events")
        usage.setEnabled(true)
        check(transport.events.filter { $0 == .appStarted }.count == 1, "re-enable does not count a second launch")
        consent.fails = true
        usage.setEnabled(false)
        check(!usage.isEnabled && usage.issue != nil, "failed persistence still disables this process")
        usage.setEnabled(true)
        check(!usage.isEnabled, "failed consent write cannot start tracking")

        let unavailable = Transport(); unavailable.isAvailable = false
        let declined = Consent(); declined.value = false
        let disabled = UsageAnalytics(store: declined, transport: unavailable)
        disabled.beginSession(); disabled.setEnabled(true)
        check(!disabled.isEnabled && unavailable.starts == 0, "missing SDK cannot be enabled")
        let oldConsent = Consent()
        let oldDisabled = UsageAnalytics(store: oldConsent, transport: unavailable)
        oldDisabled.beginSession()
        check(oldDisabled.isEnabled && unavailable.starts == 0, "unavailable build shows saved permission but never starts")
        oldDisabled.setEnabled(false)
        check(!oldConsent.value && !oldDisabled.isEnabled, "saved permission remains visible and withdrawable without SDK")
        let failing = Transport(); failing.fails = true
        let kept = Consent()
        let failed = UsageAnalytics(store: kept, transport: failing)
        failed.beginSession(); failed.record(.photoImported)
        check(failing.events.isEmpty && failed.issue != nil, "failed startup does not report success or record")
        check(kept.value, "a startup failure never rewrites the user's consent")

        let batch = UsageEvent.batchExportCompleted(succeeded: -10, failed: 200_000, outcome: .partial)
        check(batch.group == "usage", "event group is fixed across clients")
        check(batch.name == "batch_export_completed" && batch.value == 0, "batch counts bounded below")
        check(batch.properties(platform: .macos) == ["schema_version": "1", "platform": "macos", "outcome": "partial", "succeeded_count": "0", "failed_count": "100000"], "only fixed safe fields")
        check(UsageEvent.filmSelected(.custom).properties(platform: .ios)["kind"] == "custom", "custom names are not accepted")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-usage-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("consent.json")
        let disk = FileUsageConsentStore(url: path)
        let missing = try disk.load()
        check(missing, "missing consent defaults on")
        try disk.save(false)
        let declinedOnDisk = try FileUsageConsentStore(url: path).load()
        check(!declinedOnDisk, "explicit opt-out persists")
        try disk.save(true)
        let restored = try FileUsageConsentStore(url: path).load()
        check(restored, "explicit consent persists")
        try installIdentity(directory)
        try Data("invalid".utf8).write(to: path)
        let corrupt = UsageAnalytics(store: disk, transport: Transport())
        corrupt.beginSession()
        check(!corrupt.isEnabled, "corrupt consent fails closed")
        print("PASS: consent, withdrawal, failures, fixed payloads, persistence and install identity")
    }

    // 安装标识：随机 UUID，跨进程保持；关闭统计即删除，重新开启换新的
    static func installIdentity(_ directory: URL) throws {
        let path = directory.appendingPathComponent("identity-consent.json")
        let idFile = FileUsageConsentStore(url: path).installIDURL
        let first = try FileUsageConsentStore(url: path).installID()
        check(UUID(uuidString: first) != nil, "install id is a random UUID")
        let again = try FileUsageConsentStore(url: path).installID()
        check(again == first, "install id persists across launches")
        try FileUsageConsentStore(url: path).save(false)
        check(!FileManager.default.fileExists(atPath: idFile.path), "opting out deletes the install id")
        try FileUsageConsentStore(url: path).save(true)
        let second = try FileUsageConsentStore(url: path).installID()
        check(second != first, "re-enabling issues a new install id")
        try Data("not-a-uuid".utf8).write(to: idFile)
        let repaired = try FileUsageConsentStore(url: path).installID()
        check(UUID(uuidString: repaired) != nil, "a damaged install id is replaced")
    }
}
