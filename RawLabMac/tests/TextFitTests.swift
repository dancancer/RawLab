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
        failures += aiModelDownloadSection(catalogs)
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

    @MainActor static func singleLineWidth(_ text: String, size: CGFloat, weight: Font.Weight = .regular) -> CGFloat {
        NSHostingView(rootView: Text(text).font(.system(size: size, weight: weight)).fixedSize()).fittingSize.width
    }

    @MainActor static func fittingHeight(_ text: String, size: CGFloat, weight: Font.Weight = .regular, width: CGFloat) -> CGFloat {
        let view = NSHostingView(rootView: Text(text).font(.system(size: size, weight: weight)).multilineTextAlignment(.center)
            .frame(width: width).fixedSize(horizontal: false, vertical: true))
        return view.fittingSize.height
    }

    // ------------------------------------------------------------------------
    //  配方卡片在最窄调整栏三列网格下自然换行完整排版，不被固定高度截成省略号
    // ------------------------------------------------------------------------
    @MainActor static func recipeSubtitles(_ root: URL, _ catalogs: [String: [String: String]]) -> [String] {
        struct Recipe: Decodable { let name: String; let subtitle: String }
        let data = (try? Data(contentsOf: root.appendingPathComponent("Shared/master-recipes.json"))) ?? Data()
        let recipes = (try? JSONDecoder().decode([Recipe].self, from: data)) ?? []
        let titles = ["无配方"] + recipes.map(\.name)
        let subtitles = ["中性直出"] + recipes.map(\.subtitle)
        let card = AdjustmentPanelLayout.RecipeCard.self
        let textWidth = card.textWidth(inspectorWidth: MacWorkspaceLayout.inspectorRange.lowerBound)
        // 280 pt 最窄调整栏（列文本宽 ~75.33 pt）下已接受德文长复合词字符级硬拆（最多 5 行）
        let acceptedSubtitleWrapWords: Set<String> = [
            "Abenddämmerung", "Minimalistisches", "Kameraausgabe", "Streetfotografie"
        ]
        var failures: [String] = []
        if card.columns != 3 || card.artworkSize != 46 {
            failures.append("recipe grid layout (\(card.columns) columns, \(card.artworkSize) pt artwork) must match film grid")
        }
        if textWidth <= card.artworkSize {
            failures.append("narrow recipe column text width \(textWidth) pt is too narrow")
        }
        let oneTitleLine = fittingHeight("A", size: card.titleSize, weight: .semibold, width: textWidth)
        let oneSubtitleLine = fittingHeight("A", size: card.subtitleSize, width: textWidth)
        for language in languages {
            for key in titles {
                let text = catalogs[language]?[key] ?? key
                let height = fittingHeight(text, size: card.titleSize, weight: .semibold, width: textWidth)
                if height <= 0 || height > oneTitleLine * 2 + 0.5 {
                    failures.append("\(language): title '\(text)' height \(height) exceeds 2 lines at width \(textWidth)")
                }
                for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
                    let wordWidth = singleLineWidth(word, size: card.titleSize, weight: .semibold)
                    if wordWidth > ceil(textWidth) + 0.5 {
                        failures.append("\(language): title word '\(word)' width \(wordWidth) exceeds column width \(textWidth)")
                    }
                }
            }
            for key in subtitles {
                let text = catalogs[language]?[key] ?? key
                let height = fittingHeight(text, size: card.subtitleSize, width: textWidth)
                if height < oneSubtitleLine - 0.5 || height > oneSubtitleLine * 5 + 0.5 {
                    failures.append("\(language): subtitle '\(text)' height \(height) exceeds 5 lines at width \(textWidth)")
                }
                if language != "zh-Hans" && language != "ja" {
                    for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init) {
                        let wordWidth = singleLineWidth(word, size: card.subtitleSize)
                        if wordWidth > ceil(textWidth) + 0.5 && !(language == "de" && acceptedSubtitleWrapWords.contains(word)) {
                            failures.append("\(language): subtitle word '\(word)' width \(wordWidth) exceeds column width \(textWidth)")
                        }
                    }
                }
            }
        }
        if failures.isEmpty {
            print("PASS: recipe titles and subtitles fit 3-column narrow grid (\(textWidth) pt) in every language")
        }
        return failures
    }

    // ------------------------------------------------------------------------
    //  AI 模型按需下载区在最窄调整栏（280 pt - 20 pt 内边距 = 260 pt）下 6 语言完整排版
    // ------------------------------------------------------------------------
    @MainActor static func aiModelDownloadSection(_ catalogs: [String: [String: String]]) -> [String] {
        let panelWidth = MacWorkspaceLayout.inspectorRange.lowerBound - 20
        let sampleTexts: [(key: String, args: [String])] = [
            ("尚未下载 AI 降噪模型（约 %@ MB）。", ["588"]),
            ("模型（DualDn、Restormer）仅限非商业用途。", []),
            ("正在下载 AI 降噪模型… %@ / %@ MB", ["588", "588"]),
            ("正在校验 AI 降噪模型…", []),
            ("正在安装 AI 降噪模型…", []),
            ("已取消下载 AI 降噪模型。", []),
            ("已下载 AI 降噪模型（约 %@ MB）。", ["652"]),
            ("无法删除已下载的模型文件，请重试。", []),
            ("AI 降噪需要 Apple Silicon GPU 和 macOS 14.4 或更新版本。", []),
        ]
        let buttonKeys = ["下载模型", "查看许可", "删除已下载模型", "重试", "取消"]
        let oneLineHeight = fittingHeight("A", size: 11, width: panelWidth)
        var failures: [String] = []

        for language in languages {
            guard let strings = catalogs[language] else {
                failures.append("\(language): missing Localizable.strings catalog")
                continue
            }
            for item in sampleTexts {
                guard let template = strings[item.key] else {
                    failures.append("\(language): missing localized key '\(item.key)'")
                    continue
                }
                let rendered = formatString(template, args: item.args)
                let height = fittingHeight(rendered, size: 11, width: panelWidth)
                if height < oneLineHeight - 0.5 || height > oneLineHeight * 4 + 0.5 {
                    failures.append("\(language): AI model text '\(rendered)' height \(height) out of 1..4 lines at \(panelWidth) pt")
                }
            }
            for key in buttonKeys {
                guard let title = strings[key] else {
                    failures.append("\(language): missing button key '\(key)'")
                    continue
                }
                let width = singleLineWidth(title, size: 11)
                if width > panelWidth - 16 {
                    failures.append("\(language): button '\(title)' width \(width) exceeds narrow panel width \(panelWidth)")
                }
            }
            // 验证“查看许可 + 删除已下载模型”通过 ViewThatFits 在 260 pt 下不溢出（如法语长文案自动折成两行）
            let licenseTitle = strings["查看许可"] ?? "查看许可"
            let removeTitle = strings["删除已下载模型"] ?? "删除已下载模型"
            let adaptiveRow = ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button(licenseTitle) {}.buttonStyle(.link).fixedSize()
                    Spacer(minLength: 0)
                    Button(removeTitle) {}.buttonStyle(.borderless).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Button(licenseTitle) {}.buttonStyle(.link)
                    Button(removeTitle) {}.buttonStyle(.borderless)
                }
            }
            .font(.system(size: 11))
            .frame(width: panelWidth, alignment: .leading)
            let rowSize = NSHostingView(rootView: adaptiveRow).fittingSize
            if rowSize.width > panelWidth + 0.5 {
                failures.append("\(language): adaptive installed action row width \(rowSize.width) exceeds \(panelWidth) pt")
            }
        }
        if failures.isEmpty {
            print("PASS: AI model download section texts and adaptive action rows fit narrow inspector (\(panelWidth) pt) in every language")
        }
        return failures
    }

    private static func formatString(_ template: String, args: [String]) -> String {
        var result = template
        for arg in args {
            if let range = result.range(of: "%@") {
                result.replaceSubrange(range, with: arg)
            }
        }
        return result
    }

    // 横排工具名按自然宽度滚动；真实多语言可达性由 HorizontalPickerNativeTests 验证。
}
