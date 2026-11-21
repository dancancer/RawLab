import Foundation

public enum RetentionPolicy {
    /// 批量产物保留时长（双条件之一，超过即清退）。
    public static let batchArtifactMaxAge: TimeInterval = 30 * 24 * 60 * 60
    /// 批量产物保留条数（双条件之一，按时间排序超出最近 100 条的最旧条目先清）。
    public static let batchArtifactMaxCount = 100
}

public enum BatchArtifactRetention {
    private static let fileManager = FileManager.default
    private static let protectedJobsLock = NSLock()
    private static var protectedJobIDs: Set<UUID> = []

    public static func protectJob(_ id: UUID) {
        protectedJobsLock.lock()
        protectedJobIDs.insert(id)
        protectedJobsLock.unlock()
    }

    public static func unprotectJob(_ id: UUID) {
        protectedJobsLock.lock()
        protectedJobIDs.remove(id)
        protectedJobsLock.unlock()
    }

    private static func isJobProtected(_ id: UUID) -> Bool {
        protectedJobsLock.lock()
        defer { protectedJobsLock.unlock() }
        return protectedJobIDs.contains(id)
    }

    /// journal 根目录（与 `BatchJournalStore.appStore()` 同一布局：App Support/RawLab/BatchJobs）。
    public static var defaultJournalRoot: URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("RawLab/BatchJobs", isDirectory: true)
    }

    @discardableResult
    public static func reclaim(exportsRoot: URL, journalRoot: URL, now: Date = Date(),
                               maxAge: TimeInterval = RetentionPolicy.batchArtifactMaxAge,
                               maxCount: Int = RetentionPolicy.batchArtifactMaxCount,
                               willReclaimGroup: ((UUID) -> Void)? = nil) -> Int {
        // 以任务 id 归组：一个条目的产物目录与 journal 记录（含输入副本目录）同进同退。
        var groups: [String: (id: UUID, key: String, date: Date, parts: [(url: URL, companion: URL?, modificationDate: Date)])] = [:]
        func add(_ id: UUID, _ date: Date, url: URL, companion: URL?, modificationDate: Date) {
            let key = id.uuidString
            let existing = groups[key]
            groups[key] = (id, key, max(existing?.date ?? date, date),
                           (existing?.parts ?? []) + [(url, companion, modificationDate)])
        }
        for url in (try? fileManager.contentsOfDirectory(at: exportsRoot,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? [] {
            guard let id = UUID(uuidString: url.lastPathComponent),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let date = artifactDate(url),
                  let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            add(id, date, url: url, companion: nil, modificationDate: modificationDate)
        }
        for url in (try? fileManager.contentsOfDirectory(at: journalRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? [] {
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            add(id, date, url: url, companion: journalRoot.appendingPathComponent(id.uuidString, isDirectory: true),
                modificationDate: date)
        }
        // 同日期时按 id 倒序，保证 100 条边界上的清退选取可复现。
        var reclaimed = 0
        for (index, group) in groups.values.sorted(by: { $0.date != $1.date ? $0.date > $1.date : $0.key > $1.key }).enumerated() {
            if now.timeIntervalSince(group.date) <= maxAge && index < maxCount { continue }
            willReclaimGroup?(group.id)
            // 后台清扫期间首屏恢复或新写入可能复用同 id：删除前复核活跃保护与磁盘最新时间，避免误删已恢复任务。
            if isJobProtected(group.id) || hasNewerActivityOnDisk(parts: group.parts) {
                continue
            }
            var removed = false
            for part in group.parts {
                if (try? fileManager.removeItem(at: part.url)) != nil { removed = true }
                if let companion = part.companion { try? fileManager.removeItem(at: companion) }
            }
            if removed { reclaimed += 1 }
        }
        return reclaimed
    }

    private static func hasNewerActivityOnDisk(parts: [(url: URL, companion: URL?, modificationDate: Date)]) -> Bool {
        for part in parts {
            if let date = currentModificationDate(part.url), date > part.modificationDate {
                return true
            }
        }
        return false
    }

    private static func currentModificationDate(_ url: URL) -> Date? {
        // 用 attributesOfItem 直接 stat 磁盘，避免复用 contentsOfDirectory 缓存在 URL 上的旧时间戳。
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func artifactDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}
