import Foundation
import Combine

enum UsagePlatform: String { case macos, ios, android, windows }
enum UsageFilmKind: String { case none, builtIn = "built_in", custom }
enum UsageBatchOutcome: String { case completed, partial, cancelled, interrupted }

enum UsageEvent: Equatable {
    case appStarted, photoImported, filmSelected(UsageFilmKind), exportCompleted
    case batchExportCompleted(succeeded: Int, failed: Int, outcome: UsageBatchOutcome)
    var group: String { "usage" }
    var name: String {
        switch self {
        case .appStarted: return "app_started"
        case .photoImported: return "photo_imported"
        case .filmSelected: return "film_selected"
        case .exportCompleted: return "export_completed"
        case .batchExportCompleted: return "batch_export_completed"
        }
    }
    var value: Int {
        if case .batchExportCompleted(let succeeded, _, _) = self { return Self.count(succeeded) }
        return 1
    }
    func properties(platform: UsagePlatform) -> [String: String] {
        var result = ["schema_version": "1", "platform": platform.rawValue]
        switch self {
        case .filmSelected(let kind): result["kind"] = kind.rawValue
        case .batchExportCompleted(let succeeded, let failed, let outcome):
            result["succeeded_count"] = String(Self.count(succeeded))
            result["failed_count"] = String(Self.count(failed))
            result["outcome"] = outcome.rawValue
        default: break
        }
        return result
    }
    private static func count(_ value: Int) -> Int { min(100_000, max(0, value)) }
}

protocol UsageConsentStore {
    func load() throws -> Bool
    func save(_ enabled: Bool) throws
}

// ----------------------------------------------------------------------------
//  同意与安装标识存在同一个目录
//  - 从未选择过 → 开启；明确关闭 → 关闭；文件损坏 → 读取失败，由模型保守关闭
//  - 安装标识是应用自己生成的随机 UUID，只用来统计活跃设备数，不读取任何硬件编号
//  - 标识只在同意开启时存在：保存"关闭"即删除，重新开启后首次启动统计时生成新的
// ----------------------------------------------------------------------------
struct FileUsageConsentStore: UsageConsentStore {
    private struct Consent: Codable { let version: Int; let enabled: Bool }
    let url: URL
    var installIDURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(
            url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "consent", with: "install-id"))
    }
    static var standard: FileUsageConsentStore {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab", isDirectory: true)
        #if RAWLAB_RUM_LOCAL
        return FileUsageConsentStore(url: directory.appendingPathComponent("usage-consent-local.json"))
        #else
        return FileUsageConsentStore(url: directory.appendingPathComponent("usage-consent.json"))
        #endif
    }
    func load() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let consent = try JSONDecoder().decode(Consent.self, from: Data(contentsOf: url))
        return consent.version == 1 && consent.enabled
    }
    func save(_ enabled: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Consent(version: 1, enabled: enabled)).write(to: url, options: .atomic)
        if !enabled, FileManager.default.fileExists(atPath: installIDURL.path) {
            try FileManager.default.removeItem(at: installIDURL)
        }
    }
    // 由 SDK 适配器在启动统计时调用
    func installID() throws -> String {
        let saved = try? String(contentsOf: installIDURL, encoding: .utf8)
        if let saved, let id = UUID(uuidString: saved.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id.uuidString
        }
        let fresh = UUID().uuidString
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(fresh.utf8).write(to: installIDURL, options: .atomic)
        return fresh
    }
}

protocol UsageAnalyticsTransport: AnyObject {
    var isAvailable: Bool { get }
    func start() throws
    func record(_ event: UsageEvent)
    func stop()
}

protocol UsageTransportFailureReporting: AnyObject {
    var onFailure: (() -> Void)? { get set }
    var hasFailed: Bool { get }
}

protocol UsageTransportAvailability: AnyObject {
    var unavailableReason: String? { get }
}

final class UnavailableUsageTransport: UsageAnalyticsTransport {
    let isAvailable = false
    func start() throws { throw CocoaError(.featureUnsupported) }
    func record(_ event: UsageEvent) { }
    func stop() { }
}

// 业务调用在主线程，适配器负责将网络和 SDK 关闭工作移出主线程。
final class UsageAnalytics: ObservableObject {
    static let shared = UsageAnalytics(store: FileUsageConsentStore.standard, transport: UnavailableUsageTransport())
    @Published private(set) var isEnabled = false
    @Published private(set) var issue: String?
    private let store: UsageConsentStore
    private var transport: UsageAnalyticsTransport
    private var sessionBegan = false
    private var active = false
    private var countedLaunch = false
    var isAvailable: Bool { transport.isAvailable }
    // 返回翻译键，由界面层按当前语言翻译；模型本身不依赖本地化模块
    var statusKey: String {
        if let issue { return issue }
        if !isAvailable {
            return (transport as? UsageTransportAvailability)?.unavailableReason ?? "当前构建未配置使用统计，未采集或上报。"
        }
        return isEnabled ? "已允许使用统计；可随时关闭。" : "使用统计已关闭。"
    }
    init(store: UsageConsentStore, transport: UsageAnalyticsTransport) {
        self.store = store; self.transport = transport
        do { isEnabled = try store.load() }
        catch { issue = "无法读取统计设置，已保持关闭。" }
        bindFailures()
    }
    func configure(_ transport: UsageAnalyticsTransport) {
        guard !sessionBegan else { return }
        objectWillChange.send()
        self.transport = transport
        bindFailures()
    }
    private func bindFailures() {
        if let reporting = transport as? UsageTransportFailureReporting {
            reporting.onFailure = { [weak self, weak reporting] in
                DispatchQueue.main.async {
                    guard let self, reporting?.hasFailed == true else { return }
                    self.objectWillChange.send()
                    guard self.active else { return }
                    self.stop()
                    self.issue = "统计服务未能启动，照片编辑不受影响。"
                }
            }
        }
    }
    func beginSession() {
        guard !sessionBegan else { return }
        sessionBegan = true
        startIfAllowed()
    }
    func setEnabled(_ enabled: Bool) {
        guard !enabled || isAvailable else { return }
        if !enabled {
            isEnabled = false
            stop()
        }
        do {
            try store.save(enabled)
            issue = nil; isEnabled = enabled
            if enabled { startIfAllowed() }
        } catch {
            isEnabled = false; stop()
            issue = "统计设置未能保存，当前进程已停止统计；重启前请检查存储权限。"
        }
    }
    func record(_ event: UsageEvent) {
        guard isEnabled, active else { return }
        transport.record(event)
    }
    func endSession() { stop() }
    private func startIfAllowed() {
        guard sessionBegan, isEnabled, isAvailable, !active else { return }
        do {
            try transport.start()
            active = true
            if !countedLaunch { transport.record(.appStarted); countedLaunch = true }
        } catch {
            stop()
            issue = "统计服务未能启动，照片编辑不受影响。"
        }
    }
    private func stop() {
        guard active else { return }
        active = false
        transport.stop()
    }
}
