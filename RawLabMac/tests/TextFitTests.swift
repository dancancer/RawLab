import AppKit
import SwiftUI

// ============================================================================
//  界面文字在各语言下放得下：用 SwiftUI 实际排版量尺寸，不靠估算
//  用法：text-fit <仓库根目录>
// ============================================================================
@main
struct TextFitTests {
    static let languages = ["zh-Hans", "en", "de", "fr", "ja", "es"]

    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let catalogs = try Dictionary(uniqueKeysWithValues: languages.map { language in
            (language, try catalog(root, language))
        })
        var failures: [String] = []
        failures += recipeSubtitles(root, catalogs)
        guard failures.isEmpty else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }

    static func catalog(_ root: URL, _ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("RawLabMac/Resources/\(language).lproj/Localizable.strings")
        guard let strings = NSDictionary(contentsOf: url) as? [String: String] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return strings
    }

    @MainActor static func singleLineWidth(_ text: String, size: CGFloat) -> CGFloat {
        NSHostingView(rootView: Text(text).font(.system(size: size)).fixedSize()).fittingSize.width
    }

    @MainActor static func fittingHeight(_ text: String, size: CGFloat, width: CGFloat) -> CGFloat {
        let view = NSHostingView(rootView: Text(text).font(.system(size: size)).multilineTextAlignment(.center)
            .frame(width: width).fixedSize(horizontal: false, vertical: true))
        return view.fittingSize.height
    }

    // ------------------------------------------------------------------------
    //  配方卡片的说明行数有上限，上限内的每一行都要完整显示，不能被截成省略号
    // ------------------------------------------------------------------------
    @MainActor static func recipeSubtitles(_ root: URL, _ catalogs: [String: [String: String]]) -> [String] {
        struct Recipe: Decodable { let subtitle: String }
        let data = (try? Data(contentsOf: root.appendingPathComponent("Shared/master-recipes.json"))) ?? Data()
        let keys = ((try? JSONDecoder().decode([Recipe].self, from: data)) ?? []).map(\.subtitle) + ["中性直出"]
        let card = AdjustmentPanelLayout.RecipeCard.self
        let lines = fittingHeight((1...card.subtitleLines).map(String.init).joined(separator: "\n"),
                                  size: card.subtitleSize, width: card.width)
        var failures: [String] = []
        if lines > card.subtitleHeight {
            failures.append("\(card.subtitleLines) subtitle lines need \(lines) pt, the card gives \(card.subtitleHeight) pt")
        }
        if card.dockHeight - 16 < 32 + card.textHeight(subtitle: true) {
            failures.append("the recipe dock is too short to show subtitles")
        }
        for language in languages {
            for key in keys {
                let text = catalogs[language]?[key] ?? key
                let needed = fittingHeight(text, size: card.subtitleSize, width: card.width)
                if needed > max(lines, card.subtitleHeight) { failures.append("\(language): \(text) needs \(needed) pt") }
            }
        }
        if failures.isEmpty { print("PASS: recipe subtitles fit \(card.subtitleLines) lines in every language") }
        return failures
    }

    // 横排工具名按自然宽度滚动；真实多语言可达性由 HorizontalPickerNativeTests 验证。
}
