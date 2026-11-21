import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans = "zh-Hans", en, de, fr, ja, es

    public var id: String { rawValue }
    public var nativeName: String {
        switch self {
        case .system: return L10n.text("跟随系统")
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .ja: return "日本語"
        case .es: return "Español"
        }
    }

    public static func resolve(preference: String, preferredLanguages: [String]) -> Self {
        if let explicit = Self(rawValue: preference), explicit != .system { return explicit }
        for identifier in preferredLanguages {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
            guard let code = parts.first else { continue }
            if code == "zh" {
                if parts.contains("hant") || parts.contains("tw") || parts.contains("hk") || parts.contains("mo") { continue }
                return .zhHans
            }
            if let language = Self(rawValue: String(code)), language != .system { return language }
        }
        return .en
    }
}

public enum L10n {
    public static let preferenceKey = "RawLab.language"

    public static var language: AppLanguage {
        AppLanguage.resolve(preference: UserDefaults.standard.string(forKey: preferenceKey) ?? "system",
                            preferredLanguages: Locale.preferredLanguages)
    }
    public static var locale: Locale { Locale(identifier: language.rawValue) }

    public static func text(_ key: String, bundle: Bundle = .main) -> String {
        let missing = "\u{0}RawLab.missing\u{0}"
        for identifier in [language.rawValue, "en"] {
            guard let path = bundle.path(forResource: identifier, ofType: "lproj"),
                  let localized = Bundle(path: path) else { continue }
            let value = localized.localizedString(forKey: key, value: missing, table: nil)
            if value != missing { return value }
        }
        return key
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}
