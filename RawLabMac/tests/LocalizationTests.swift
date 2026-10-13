import Foundation

@main struct LocalizationTests {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            print("PASS: \(message)")
        }
        check(AppLanguage.resolve(preference: "system", preferredLanguages: ["de-DE"]) == .de,
              "System regional language resolves to German")
        check(AppLanguage.resolve(preference: "system", preferredLanguages: ["zh-Hans-CN"]) == .zhHans,
              "Simplified Chinese resolves correctly")
        check(AppLanguage.resolve(preference: "system", preferredLanguages: ["zh-Hant-TW"]) == .en,
              "Unsupported Traditional Chinese falls back to English")
        check(AppLanguage.resolve(preference: "system", preferredLanguages: ["pt-BR"]) == .en,
              "Unsupported language falls back to English")
        check(AppLanguage.resolve(preference: "ja", preferredLanguages: ["fr-FR"]) == .ja,
              "Explicit selection overrides system language")
        check(AppLanguage.resolve(preference: "invalid", preferredLanguages: ["es-MX"]) == .es,
              "Invalid stored choice follows system preferences")
        check(AppLanguage.allCases.count == 7 && Set(AppLanguage.allCases.map(\.id)).count == 7,
              "System plus six stable language choices")

        let previous = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: L10n.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: L10n.preferenceKey) }
        }
        let bundle = Bundle(path: CommandLine.arguments[1])!
        UserDefaults.standard.set("de", forKey: L10n.preferenceKey)
        check(L10n.text("语言", bundle: bundle) == "Sprache", "Explicit locale selects its resource bundle")
        check(L10n.text("仅英文", bundle: bundle) == "English fallback", "Missing translation falls back to English")
        check(L10n.text("unregistered.key", bundle: bundle) == "unregistered.key", "Unknown key remains diagnosable")
        UserDefaults.standard.set("ja", forKey: L10n.preferenceKey)
        check(L10n.language == .ja && L10n.locale.identifier == "ja", "Stored preference immediately changes lookup locale")
        let formatted = String(format: L10n.text("导出 %@ 张", bundle: bundle), locale: L10n.locale, arguments: ["2"])
        check(formatted == "2 枚を書き出す", "Translated interpolation preserves arguments")
    }
}
