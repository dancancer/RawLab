import SwiftUI

@main
struct RawLabApp: App {
    @AppStorage(L10n.preferenceKey) private var languagePreference = AppLanguage.system.rawValue

    init() {
        // 场景创建前还没有导入或批量任务，此时清理上次进程遗留的中间产物不会与之竞争。
        PhotoImportFile.removeStaleImports()
        (try? BatchJournalStore.appStore())?.removeOrphanedJobDirectories()
        // Q6：批量产物保留 30 天/100 条（双条件先到先清）；相机原件不自动删，
        // iOS 联机记录为 manifest 单条，无 90 天集合回收。
        _ = BatchArtifactRetention.reclaim(exportsRoot: BatchFileOutputStore.root(),
                                           journalRoot: BatchArtifactRetention.defaultJournalRoot)
        // Q6：相机手动清理的「已导出」证据 = 最近打开索引中的私有副本内容标识；
        // 采集在 backend 队列执行，这里只注入闭包，UI 层不直接依赖 RecentPhotoStore。
        IOSCameraController.exportedContentIdentifiersProvider = {
            guard let store = try? RecentPhotoStore.appStore(), let records = try? store.records() else { return [] }
            var identifiers: Set<String> = []
            for record in records {
                if let content = record.identity.contentIdentifier { identifiers.insert(content) }
                if let legacy = record.identity.legacyContentIdentifier { identifiers.insert(legacy) }
            }
            return identifiers
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
