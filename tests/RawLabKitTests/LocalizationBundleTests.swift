import Foundation
import XCTest
@testable import RawLabKit

final class LocalizationBundleTests: XCTestCase {
    private var tempRoot: URL!
    private var fixtureBundleURL: URL!
    private var macosBundleURL: URL!
    private var iosBundleURL: URL!
    private var previousPreference: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousPreference = UserDefaults.standard.object(forKey: L10n.preferenceKey)

        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("RawLabLocalizationTests-\(UUID().uuidString)")
        fixtureBundleURL = tempRoot.appendingPathComponent("Fixture.bundle")
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.rawlab.localization-tests</string><key>CFBundleDevelopmentRegion</key><string>en</string></dict></plist>
        """
        for language in ["en", "de", "ja"] {
            try fm.createDirectory(
                at: fixtureBundleURL.appendingPathComponent("Contents/Resources/\(language).lproj"),
                withIntermediateDirectories: true
            )
        }
        try Data((infoPlist + "\n").utf8).write(to: fixtureBundleURL.appendingPathComponent("Contents/Info.plist"))
        try Data("\"语言\" = \"Language\";\n\"仅英文\" = \"English fallback\";\n\"导出 %@ 张\" = \"Export %@ photos\";\n".utf8)
            .write(to: fixtureBundleURL.appendingPathComponent("Contents/Resources/en.lproj/Localizable.strings"))
        try Data("\"语言\" = \"Sprache\";\n".utf8)
            .write(to: fixtureBundleURL.appendingPathComponent("Contents/Resources/de.lproj/Localizable.strings"))
        try Data("\"导出 %@ 张\" = \"%@ 枚を書き出す\";\n".utf8)
            .write(to: fixtureBundleURL.appendingPathComponent("Contents/Resources/ja.lproj/Localizable.strings"))

        let repoRoot = RawLabKitTestSupport.repoRoot
        macosBundleURL = tempRoot.appendingPathComponent("macos.bundle")
        iosBundleURL = tempRoot.appendingPathComponent("ios.bundle")
        for (bundleURL, resourceRoot) in [
            (macosBundleURL!, repoRoot.appendingPathComponent("RawLabMac/Resources")),
            (iosBundleURL!, repoRoot.appendingPathComponent("RawLab/RawLab/Resources")),
        ] {
            try fm.createDirectory(
                at: bundleURL.appendingPathComponent("Contents/Resources"),
                withIntermediateDirectories: true
            )
            try fm.copyItem(
                at: fixtureBundleURL.appendingPathComponent("Contents/Info.plist"),
                to: bundleURL.appendingPathComponent("Contents/Info.plist")
            )
            for language in ["en", "zh-Hans", "de", "fr", "ja", "es"] {
                let targetDir = bundleURL.appendingPathComponent("Contents/Resources/\(language).lproj")
                try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
                try fm.copyItem(
                    at: resourceRoot.appendingPathComponent("\(language).lproj/Localizable.strings"),
                    to: targetDir.appendingPathComponent("Localizable.strings")
                )
            }
        }
    }

    override func tearDownWithError() throws {
        if let previousPreference {
            UserDefaults.standard.set(previousPreference, forKey: L10n.preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: L10n.preferenceKey)
        }
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    func testLanguageResolutionAndStableChoices() {
        XCTAssertEqual(
            AppLanguage.resolve(preference: "system", preferredLanguages: ["de-DE"]),
            .de,
            "System regional language resolves to German"
        )
        XCTAssertEqual(
            AppLanguage.resolve(preference: "system", preferredLanguages: ["zh-Hans-CN"]),
            .zhHans,
            "Simplified Chinese resolves correctly"
        )
        XCTAssertEqual(
            AppLanguage.resolve(preference: "system", preferredLanguages: ["zh-Hant-TW"]),
            .en,
            "Unsupported Traditional Chinese falls back to English"
        )
        XCTAssertEqual(
            AppLanguage.resolve(preference: "system", preferredLanguages: ["pt-BR"]),
            .en,
            "Unsupported language falls back to English"
        )
        XCTAssertEqual(
            AppLanguage.resolve(preference: "ja", preferredLanguages: ["fr-FR"]),
            .ja,
            "Explicit selection overrides system language"
        )
        XCTAssertEqual(
            AppLanguage.resolve(preference: "invalid", preferredLanguages: ["es-MX"]),
            .es,
            "Invalid stored choice follows system preferences"
        )
        XCTAssertTrue(
            AppLanguage.allCases.count == 7 && Set(AppLanguage.allCases.map(\.id)).count == 7,
            "System plus six stable language choices"
        )
    }

    func testFixtureBundleFallbackAndFormatting() throws {
        let bundle = try XCTUnwrap(Bundle(url: fixtureBundleURL))
        UserDefaults.standard.set("de", forKey: L10n.preferenceKey)
        XCTAssertEqual(L10n.text("语言", bundle: bundle), "Sprache", "Explicit locale selects its resource bundle")
        XCTAssertEqual(L10n.text("仅英文", bundle: bundle), "English fallback", "Missing translation falls back to English")
        XCTAssertEqual(L10n.text("unregistered.key", bundle: bundle), "unregistered.key", "Unknown key remains diagnosable")

        UserDefaults.standard.set("ja", forKey: L10n.preferenceKey)
        XCTAssertTrue(L10n.language == .ja && L10n.locale.identifier == "ja", "Stored preference immediately changes lookup locale")
        let formatted = String(format: L10n.text("导出 %@ 张", bundle: bundle), locale: L10n.locale, arguments: ["2"])
        XCTAssertEqual(formatted, "2 枚を書き出す", "Translated interpolation preserves arguments")
    }

    func testClientResourceCatalogsAcrossAllSixLanguages() throws {
        let boundaryMessages = [
            "en": "Channel-boundary pixels: candidate 12.5% · reference 6.3%",
            "zh-Hans": "通道边界像素：方案 12.5% · 参考 6.3%",
            "de": "Pixel an Kanalgrenzen: Option 12.5% · Referenz 6.3%",
            "fr": "Pixels aux limites des canaux : proposition 12.5% · référence 6.3%",
            "ja": "チャンネル境界ピクセル：候補 12.5% · 参照 6.3%",
            "es": "Píxeles en los límites de canal: candidato 12.5% · referencia 6.3%",
        ]
        for url in [macosBundleURL!, iosBundleURL!] {
            let catalog = try XCTUnwrap(Bundle(url: url))
            for (language, expected) in boundaryMessages {
                UserDefaults.standard.set(language, forKey: L10n.preferenceKey)
                let template = L10n.text("通道边界像素：方案 %@% · 参考 %@%", bundle: catalog)
                let message = String(format: template, locale: L10n.locale, arguments: ["12.5", "6.3"])
                XCTAssertEqual(message, expected, "\(catalog.bundleURL.lastPathComponent) \(language) localizes both percentages")
                XCTAssertTrue(
                    L10n.text("线性 sRGB", bundle: catalog).contains("sRGB"),
                    "\(catalog.bundleURL.lastPathComponent) \(language) preserves the sRGB spelling"
                )
                let forceGpuText = L10n.text("当前照片、外观或处理方式不支持强制 GPU，可切换为自动（Auto）回退。", bundle: catalog)
                XCTAssertTrue(
                    !forceGpuText.isEmpty && (language == "zh-Hans" || forceGpuText != "当前照片、外观或处理方式不支持强制 GPU，可切换为自动（Auto）回退。"),
                    "\(catalog.bundleURL.lastPathComponent) \(language) translates Force GPU unsupported message"
                )
            }
        }
    }
}
