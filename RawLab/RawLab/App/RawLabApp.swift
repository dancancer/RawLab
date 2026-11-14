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
