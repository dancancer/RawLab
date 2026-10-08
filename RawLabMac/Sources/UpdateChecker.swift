import Foundation
import Combine

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var available: UpdateRelease?
    @Published private(set) var status = "尚未检查更新"
    @Published var automatic: Bool {
        didSet { defaults.set(automatic, forKey: "updates.automatic") }
    }
    let currentVersion: String
    private let defaults: UserDefaults
    private let fetch: () async throws -> Data
    #if arch(arm64)
    private let assetSuffix = "arm64.zip"
    #else
    private let assetSuffix = "x86_64.zip"
    #endif

    init(defaults: UserDefaults = .standard,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
         fetch: @escaping () async throws -> Data = UpdateChecker.fetchRelease) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.fetch = fetch
        automatic = defaults.object(forKey: "updates.automatic") as? Bool ?? true
        if let data = defaults.data(forKey: "updates.cachedRelease") {
            available = try? UpdateRelease.parse(data, current: currentVersion, assetSuffix: assetSuffix)
            if let available { status = "发现新版本 \(available.version)" }
        }
    }

    func check(manual: Bool) async {
        guard !checking, UpdateRelease.shouldCheck(manual: manual, enabled: automatic,
            last: defaults.double(forKey: "updates.lastAttempt"), now: Date().timeIntervalSince1970) else { return }
        checking = true
        status = "正在检查更新…"
        defaults.set(Date().timeIntervalSince1970, forKey: "updates.lastAttempt")
        defer { checking = false }
        do {
            let data = try await fetch()
            available = try UpdateRelease.parse(data, current: currentVersion, assetSuffix: assetSuffix)
            defaults.set(data, forKey: "updates.cachedRelease")
            status = available.map { "发现新版本 \($0.version)" } ?? "未发现适用于此 Mac 的新版本"
        } catch {
            status = "检查失败，请稍后重试或访问 GitHub 仓库"
        }
    }

    nonisolated static func fetchRelease() async throws -> Data {
        var request = URLRequest(url: UpdateRelease.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RawLab-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
