import SwiftUI

@main
struct RawLabApp: App {
    @AppStorage(L10n.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    var body: some Scene {
        WindowGroup {
            ContentView().environment(\.locale, Locale(identifier: AppLanguage.resolve(
                preference: languagePreference, preferredLanguages: Locale.preferredLanguages).rawValue))
        }
    }
}
