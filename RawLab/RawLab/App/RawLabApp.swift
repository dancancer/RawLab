import SwiftUI

@main
struct RawLabApp: App {
    @AppStorage(L10n.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
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
