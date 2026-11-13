import SwiftUI
import UIKit

extension ContentView {
    var mobileEditorGroups: [EditorAdjustmentGroup] { [.looks, .light, .color, .detail, .geometry, .effects] }
    var mobileEditorTools: [EditorToolSelection] {
        switch selectedGroup {
        case .looks: return [.film, .recipe]
        case .light: return [.adjustment(.exposure), .adjustment(.contrast), .adjustment(.highlights), .adjustment(.shadows), .adjustment(.whitePoint), .adjustment(.blackPoint), .adjustment(.toneCurve)]
        case .color: return [.adjustment(.temperature), .adjustment(.vibrance), .adjustment(.saturation), .adjustment(.hsl), .adjustment(.colorGrading)]
        case .detail: return [.adjustment(.sharpening), .adjustment(.noiseReduction)]
        default: return EditorAdjustmentRules.tools(selectedGroup)
        }
    }

    var editorToolHeight: CGFloat {
        guard UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory else { return toolHeight }
        return max(44, UIFont.preferredFont(forTextStyle: .body).lineHeight + 16)
    }

    func editorToolRowHeight(width: CGFloat, accessibility: Bool) -> CGFloat {
        guard accessibility else { return editorToolHeight }
        let font = UIFont.preferredFont(forTextStyle: .body)
        let titles = EditorAdjustmentRules.tools(selectedGroup).map(\.title) + [L10n.text("透视"), L10n.text("我的预设")]
        let height = titles.map { title in
            (title as NSString).boundingRect(with: CGSize(width: max(44, width - 79), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
        }.max() ?? 0
        return max(editorToolHeight, ceil(height) + 16)
    }

    private func editorToolStripHeight(width: CGFloat, accessibility: Bool) -> CGFloat {
        editorToolRowHeight(width: width, accessibility: accessibility) + (viewModel.quickPresetsVisible ? 0 : editorToolHeight)
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

    var singleLineGroupNavigationHeight: CGFloat {
        max(44, ceil(UIFont.preferredFont(forTextStyle: .caption1).lineHeight) + 8)
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
            size.height < groupNavigationButtonHeight + editorToolStripHeight(width: size.width, accessibility: accessibility) + actionSpace + parameterSpace + 24
    }

    func editorWorkspace(size: CGSize, accessibility: Bool) -> some View {
        let side = EditorLayoutPolicy.usesSidePanel(width: size.width, height: size.height, accessibility: accessibility)
        let layout = side ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        let panelWidth = min(336, size.width * 0.48)
        let isTool = toolWorkspaceOpen || viewModel.quickPresetsVisible
        let measured = parameterContentHeight > 0 ? parameterContentHeight : 240
        let parameterHeight = min(measured, max(44, min(size.height * (accessibility ? 0.62 : 0.52), size.height - 140)))
        return layout {
            previewSection
                .overlay(alignment: .bottom) {
                    if viewModel.hasImage && !photoViewing.previewOnly { workspaceActions.padding(.horizontal, 8) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if viewModel.hasImage {
                Divider().opacity(photoViewing.previewOnly ? 0 : 1)
                VStack(spacing: 0) {
                    if !isTool {
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: accessibility ? 3 : 4), spacing: 4) {
                                ForEach(mobileEditorTools, id: \.self) { tool in
                                    Button { geometryPerspective = false; geometryRotation = false; selectEditorTool(tool) } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: tool.symbol).font(.system(size: 21)).frame(height: 24)
                                            Text(tool.title).font(.caption).multilineTextAlignment(.center)
                                            Circle().fill(resetModified(.tool(tool)) ? Color.yellow : .clear).frame(width: 3, height: 3)
                                        }.frame(maxWidth: .infinity, minHeight: accessibility ? 68 : 52).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(editorBusy || (settings.isHDREditing && !supportsHDR(tool)) ||
                                        (tool == .lens && usesNormalX3f) ||
                                        (tool == .adjustment(.temperature) && !settings.isHDREditing && viewModel.sourceKind != .raw))
                                    .accessibilityLabel(tool.title).accessibilityValue(editorToolAccessibilityValue(tool))
                                    .accessibilityIdentifier("tool.\(tool.stableID)")
                                }

                            }.padding(.horizontal, 8).padding(.vertical, 4)
                        }.frame(height: side ? nil : accessibility ? 148 : 116)
                            .accessibilityIdentifier("editor.tools")
                        groupNavigation(side: false, singleLine: true, availableWidth: side ? panelWidth : size.width)
                    } else {
                        ScrollView(.vertical) {
                            adjustmentPanel
                                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { parameterContentHeight = $0 }
                        }
                        .id("\(currentEditorTool.stableID).\(geometryPerspective).\(geometryRotation).\(viewModel.quickPresetsVisible)")
                        .frame(height: side ? nil : parameterHeight)
                        .accessibilityIdentifier("editor.panel")
                        if toolWorkspaceOpen {
                            Divider()
                            editorDraftActions.disabled(resetDraftSuspended).padding(.horizontal, 8)
                        } else {
                            Button(L10n.text("关闭"), action: closeQuickPresets).frame(minHeight: 44)
                        }
                    }
                }
                .frame(width: side ? panelWidth : nil, height: photoViewing.previewOnly ? 0 : nil)
                .opacity(photoViewing.previewOnly ? 0 : 1).allowsHitTesting(!photoViewing.previewOnly)
                .accessibilityHidden(photoViewing.previewOnly)
                .frame(maxHeight: side ? .infinity : nil, alignment: .top)
                .background(Color(.secondarySystemBackground))
            }
        }.background(Color(.systemBackground))
    }

    var workspaceActions: some View {
        HStack(spacing: 0) {
            Button { if toolWorkspaceOpen { undoEditorDraft() } else { requestAdjustmentAction(.undo) } } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 20)).frame(width: 44, height: 44) }
                .disabled((toolWorkspaceOpen ? workspaceDraft?.canUndo != true : !viewModel.canUndoAdjustment) || editorBusy)
                .accessibilityLabel(L10n.text("撤销")).accessibilityIdentifier("editor.draft.undo")
            Button { if toolWorkspaceOpen { redoEditorDraft() } else { requestAdjustmentAction(.redo) } } label: { Image(systemName: "arrow.uturn.forward").font(.system(size: 20)).frame(width: 44, height: 44) }
                .disabled((toolWorkspaceOpen ? workspaceDraft?.canRedo != true : !viewModel.canRedoAdjustment) || editorBusy)
                .accessibilityLabel(L10n.text("重做")).accessibilityIdentifier("editor.draft.redo")
            workspaceResetControl
            Spacer(minLength: 0)
            Button { photoViewing.toggleComparison() } label: { Image(systemName: "square.on.square").font(.system(size: 20)).frame(width: 44, height: 44) }
                .disabled(geometrySelected).accessibilityLabel(L10n.text("对比"))
            if toolWorkspaceOpen {
            Menu {
                Toggle(L10n.text("精细"), isOn: $adjustmentFine).accessibilityIdentifier("editor.fine")
                if currentEditorTool == .adjustment(.hsl) { Toggle(L10n.text("目标调整"), isOn: $hslTargetEnabled) }
                Menu(L10n.text("对比方式")) { comparisonModeMenu }.disabled(geometrySelected)
                    .accessibilityIdentifier("editor.compare.mode")
                Toggle(L10n.text("直方图"), isOn: $histogramExpanded)
                Button(L10n.text("照片信息")) { photoInfoMode = photoInfoMode.next }
                    .accessibilityIdentifier("editor.photoInfo").accessibilityValue(photoInfoMode.title)
                Button(L10n.text("纯预览")) { photoViewing.togglePreview(isDraft: geometrySelected) }
                Button(L10n.text("照片处理设置")) { showingProcessingContext = true }
            } label: { Image(systemName: "ellipsis").font(.system(size: 20)).frame(width: 44, height: 44) }
                .accessibilityLabel(L10n.text("更多")).accessibilityIdentifier("editor.tool.more")
            }
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }

    var workspaceResetControl: some View {
        let available = viewModel.hasImage && !editorBusy && !viewModel.previewRendering &&
            !resetDraftSuspended && !viewModel.quickPresetState.isPreparing
        let presentation = EditorWorkspaceResetPresentation.make(
            toolWorkspaceOpen: toolWorkspaceOpen,
            quickPresetsVisible: viewModel.quickPresetsVisible,
            selectedGroup: selectedGroup,
            currentTool: currentEditorTool,
            hslChannel: hslChannel,
            gradingZone: gradingZone,
            isAvailable: available,
            isModified: resetModified
        )
        return EditorWorkspaceResetControl(presentation: presentation, onReset: requestEditorReset)
    }
}
