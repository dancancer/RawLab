import RawLabKit
import SwiftUI

@main
struct RawLabApp: App {
    @AppStorage(L10n.preferenceKey) private var languagePreference = AppLanguage.system.rawValue

    init() {
        // 冷启动历史目录树清扫挪出首屏：浅列举快照仍同步执行，递归删除（可能上百 MB
        // 的导入/产物目录树）放到 utility 后台队列，不再挡主线程首帧。
        // 保守拆分（沿用「场景创建前没有导入或批量任务在跑」的既有顺序契约）：
        // - 导入目录：上次进程遗留条目在场景创建前同步快照，快照语义与同步清扫一致；
        //   快照之后新导入写入的 <uuid> 目录不会被误删。
        // - Batch journal 孤儿：<uuid>/inputs 目录先于 <uuid>.json 写入，判据是存在性
        //   而非时长，保留同步执行，避免后台晚跑误删启动中任务的输入目录。
        // - Q6 批量产物保留 30 天/100 条（双条件先到先清）：判据只作用于历史时间/条数
        //   边界，与启动后新写入不相交，随同一后台队列执行；已关闭任务本就无 journal。
        // 相机原件不自动删，iOS 联机记录为 manifest 单条，无 90 天集合回收。
        let staleImportEntries = (try? FileManager.default.contentsOfDirectory(
            at: PhotoImportFile.directory, includingPropertiesForKeys: nil)) ?? []
        (try? BatchJournalStore.appStore())?.removeOrphanedJobDirectories()
        let batchExportRoot = BatchFileOutputStore.root()
        let batchJournalRoot = BatchArtifactRetention.defaultJournalRoot
        DispatchQueue.global(qos: .utility).async {
            for entry in staleImportEntries { try? FileManager.default.removeItem(at: entry) }
            _ = BatchArtifactRetention.reclaim(exportsRoot: batchExportRoot,
                                               journalRoot: batchJournalRoot)
        }
        // Q6（B1 判据）：相机手动清理的「已导出」证据 = 外部出口成功后写入的持久账本
        // （保存图库 / Files 另存 / 渲染 DNG / 批量导出）。读取在 backend 队列执行，
        // RecentPhotoStore 的 LRU 副本不再充当判据——打开 ≠ 导出。
        IOSCameraController.exportedContentIdentifiersProvider = {
            ExportEvidenceStore.shared.exportedContentIdentifiers()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environment(\.locale, Locale(identifier: AppLanguage.resolve(
                preference: languagePreference, preferredLanguages: Locale.preferredLanguages).rawValue))
                .task {
#if RAWLAB_RUM
                    if RawLabRUM.start() { return }
#endif
                    if ProcessInfo.processInfo.environment["RAWLAB_SMOKE_TEST"] != "1" {
                        UsageAnalytics.shared.beginSession()
                    }
                }
        }
    }
}
