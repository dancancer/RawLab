import Foundation

// ============================================================================
//  Q6 保留策略：常量集中定义（各端一处）。
//  裁定（docs/architecture/remediation-plan-2026-11-13/g-product-decisions.md）：
//  「批量产物保留 30 天 / 100 条；相机原件不自动删、只提供手动清理入口；联机记录保留 90 天」
//  清理时机：场景创建前的启动路径（RawLabApp.init），与 #249 遗留产物清理同一时机，
//  此刻没有导入或批量任务在跑，不引入后台任务框架。
//  iOS 的联机记录是 manifest 中的单条进行中 tether，不随时间累积成记录集合，
//  90 天天数上限只落在此结构会增长的 Android（camera-tether-runs）。
//  相机原件不自动删：手动入口在相机「保存位置」页（CameraOriginalStore.pruneExportedOriginals）。
// ============================================================================

enum RetentionPolicy {
    /// 批量产物保留时长（双条件之一，超过即清退）。
    static let batchArtifactMaxAge: TimeInterval = 30 * 24 * 60 * 60
    /// 批量产物保留条数（双条件之一，按时间排序超出最近 100 条的最旧条目先清）。
    static let batchArtifactMaxCount = 100
}

enum BatchArtifactRetention {
    private static let fileManager = FileManager.default

    /// journal 根目录（与 `BatchJournalStore.appStore()` 同一布局：App Support/RawLab/BatchJobs）。
    static var defaultJournalRoot: URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("RawLab/BatchJobs", isDirectory: true)
    }

    /// 批量产物 = 一个任务的两部分：Documents/Exports/<uuid>/ 产物目录与
    /// App Support journal 的 `<uuid>.json` 记录（含 `<uuid>/inputs` 输入副本）。
    /// 双条件先到先清：超过 30 天（产物目录按创建时间、缺失时按修改时间；
    /// journal 按最后写入时间），或按时间排序已超出最近 100 条。
    /// 已完成未关闭的 DNG 任务被清退后，`BatchExportJob.recovered()` 视缺失产物为可重开，
    /// 不会崩溃；已关闭（discard）的任务本就没有 journal，产物目录独立清退。
    /// 返回被清退的任务条目数（同一 id 的两部分同进同退）。
    @discardableResult
    static func reclaim(exportsRoot: URL, journalRoot: URL, now: Date = Date(),
                        maxAge: TimeInterval = RetentionPolicy.batchArtifactMaxAge,
                        maxCount: Int = RetentionPolicy.batchArtifactMaxCount) -> Int {
        // 以任务 id 归组：一个条目的产物目录与 journal 记录（含输入副本目录）同进同退。
        var groups: [String: (key: String, date: Date, parts: [(url: URL, companion: URL?)])] = [:]
        func add(_ id: UUID, _ date: Date, url: URL, companion: URL?) {
            let key = id.uuidString
            let existing = groups[key]
            groups[key] = (key, max(existing?.date ?? date, date), (existing?.parts ?? []) + [(url, companion)])
        }
        for url in (try? fileManager.contentsOfDirectory(at: exportsRoot,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? [] {
            guard let id = UUID(uuidString: url.lastPathComponent),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let date = artifactDate(url) else { continue }
            add(id, date, url: url, companion: nil)
        }
        for url in (try? fileManager.contentsOfDirectory(at: journalRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? [] {
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            add(id, date, url: url, companion: journalRoot.appendingPathComponent(id.uuidString, isDirectory: true))
        }
        // 同日期时按 id 倒序，保证 100 条边界上的清退选取可复现。
        var reclaimed = 0
        for (index, group) in groups.values.sorted(by: { $0.date != $1.date ? $0.date > $1.date : $0.key > $1.key }).enumerated() {
            if now.timeIntervalSince(group.date) <= maxAge && index < maxCount { continue }
            var removed = false
            for part in group.parts {
                if (try? fileManager.removeItem(at: part.url)) != nil { removed = true }
                if let companion = part.companion { try? fileManager.removeItem(at: companion) }
            }
            if removed { reclaimed += 1 }
        }
        return reclaimed
    }

    private static func artifactDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}
