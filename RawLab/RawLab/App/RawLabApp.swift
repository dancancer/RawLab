import SwiftUI

@main
struct RawLabApp: App {
    @AppStorage(L10n.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    var body: some Scene {
        WindowGroup {
            ContentView().environment(\.locale, Locale(identifier: AppLanguage.resolve(
                preference: languagePreference, preferredLanguages: Locale.preferredLanguages).rawValue))
                .task {
#if RAWLAB_RUM_LOCAL
                    let environment = ProcessInfo.processInfo.environment
                    if environment["RAWLAB_RUM_VALIDATE"] == "1" {
                        guard let configuration = try? RUMLocalConfiguration(environment: environment) else {
                            print("NOT SENT: invalid iOS local RUM validation configuration")
                            return
                        }
                        DispatchQueue.global(qos: .utility).async {
                            RUMLocalValidationProbe.run(configuration: configuration)
                        }
                        return
                    }
                    if let configuration = try? RUMLocalConfiguration(environment: environment) {
                        UsageAnalytics.shared.configure(RawLabIOSUsageTransport.make(configuration: configuration))
                    }
#endif
                    if ProcessInfo.processInfo.environment["RAWLAB_SMOKE_TEST"] != "1" {
                        UsageAnalytics.shared.beginSession()
                    }
                }
        }
    }
}
