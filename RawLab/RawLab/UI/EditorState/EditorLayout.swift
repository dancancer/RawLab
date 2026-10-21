import SwiftUI
import UIKit

extension ContentView {
    var editorToolHeight: CGFloat {
        guard UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory else { return toolHeight }
        return max(44, UIFont.preferredFont(forTextStyle: .body).lineHeight + 16)
    }

    var groupNavigationButtonWidth: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        return EditorAdjustmentGroup.allCases.map { group in
            for width in stride(from: CGFloat(44), through: 240, by: 2) {
                if groupTextMetrics(group.title, width: width, font: font).lines <= 2 { return width }
            }
            return CGFloat(240)
        }.max() ?? 44
    }

    var groupNavigationButtonHeight: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let width = groupNavigationButtonWidth
        let textHeight = EditorAdjustmentGroup.allCases.map {
            groupTextMetrics($0.title, width: width, font: font, lineLimit: 2).height
        }.max() ?? 0
        return max(44, ceil(textHeight) + 8)
    }

    private func groupTextMetrics(_ title: String, width: CGFloat, font: UIFont,
                                  lineLimit: Int = 0) -> (lines: Int, height: CGFloat) {
        let storage = NSTextStorage(string: title, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width - 8, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lineLimit
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        var lines = 0
        // 回退字形的实际行高可能超过主字体，按真实行数与 usedRect 预留完整文字空间。
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, stop in
            lines += 1
            if lines > 2 { stop.pointee = true }
        }
        return (lines, layout.usedRect(for: container).height)
    }

    private func scrollsToolsWithParameters(size: CGSize, accessibility: Bool) -> Bool {
        let bodyLine = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let actionSpace = max(44, bodyLine + 16) + 16
        let parameterSpace = max(44, bodyLine) + 8
        return accessibility && size.width > size.height &&
            size.height < groupNavigationButtonHeight + editorToolHeight + actionSpace + parameterSpace + 24
    }

    func editorWorkspace(size: CGSize, accessibility: Bool) -> some View {
        let scrollTools = scrollsToolsWithParameters(size: size, accessibility: accessibility)
        let requiredWidth = groupNavigationButtonWidth * (adjustmentsExpanded ? 6 : 3) + 16
        let sideWidth = min(320, size.width * 0.48)
        let side = EditorLayoutPolicy.usesSidePanel(width: size.width, height: size.height,
            accessibility: accessibility) && requiredWidth <= sideWidth
        let layout = side ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            previewSection.frame(maxWidth: .infinity, maxHeight: .infinity)
            if viewModel.hasImage {
                Divider()
                VStack(spacing: 0) {
                    if side { groupNavigation(side: true) }
                    if adjustmentsExpanded {
                        if side { Divider() }
                        if !scrollTools { toolStrip; Divider() }
                        VStack(spacing: 0) {
                            ScrollView(.vertical) {
                                VStack(spacing: 0) {
                                    if scrollTools { toolStrip; Divider() }
                                    adjustmentPanel
                                }
                            }
                                .id(currentEditorTool)
                                .accessibilityIdentifier("editor.panel")
                            if geometrySelected || lensSelected {
                                Divider()
                                editorDraftActions.disabled(resetDraftSuspended).padding(.horizontal, 16).padding(.vertical, scrollTools ? 4 : 8)
                            }
                        }
                        .frame(height: side ? nil : adjustmentRegionHeight(size: size, accessibility: accessibility))
                    }
                    if !side {
                        Divider()
                        groupNavigation(side: false)
                    }
                }
                .frame(width: side ? sideWidth : nil)
                .frame(maxHeight: side ? .infinity : nil, alignment: .top)
                .background(Color(.secondarySystemBackground))
            }
        }
        .background(Color(.systemBackground))
    }

    private func adjustmentRegionHeight(size: CGSize, accessibility: Bool) -> CGFloat {
        let preferred = min(panelHeight, size.height * (accessibility ? 0.64 : 0.52))
        let navigationHeight = groupNavigationButtonHeight
        let scrollTools = scrollsToolsWithParameters(size: size, accessibility: accessibility)
        let available = max(0, size.height - (scrollTools ? 0 : editorToolHeight) - navigationHeight - 3)
        let photoSpace = scrollTools ? min(32, available * 0.12) : min(96, available)
        return min(preferred, max(0, available - photoSpace))
    }
}
