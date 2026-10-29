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

        let boundaryMessages = [
            "en": "Channel-boundary pixels: candidate 12.5% · reference 6.3%",
            "zh-Hans": "通道边界像素：方案 12.5% · 参考 6.3%",
            "de": "Pixel an Kanalgrenzen: Option 12.5% · Referenz 6.3%",
            "fr": "Pixels aux limites des canaux : proposition 12.5% · référence 6.3%",
            "ja": "チャンネル境界ピクセル：候補 12.5% · 参照 6.3%",
            "es": "Píxeles en los límites de canal: candidato 12.5% · referencia 6.3%"
        ]
        for path in CommandLine.arguments.dropFirst(2) {
            let catalog = Bundle(path: path)!
            for (language, expected) in boundaryMessages {
                UserDefaults.standard.set(language, forKey: L10n.preferenceKey)
                let template = L10n.text("通道边界像素：方案 %@% · 参考 %@%", bundle: catalog)
                let message = String(format: template, locale: L10n.locale, arguments: ["12.5", "6.3"])
                check(message == expected, "\(catalog.bundleURL.lastPathComponent) \(language) localizes both percentages")
                check(L10n.text("线性 sRGB", bundle: catalog).contains("sRGB"),
                      "\(catalog.bundleURL.lastPathComponent) \(language) preserves the sRGB spelling")
            }
        }
    }
}
