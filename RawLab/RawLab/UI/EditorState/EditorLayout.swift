import RawLabKit
import SwiftUI
import UIKit

extension ContentView {
    var mobileEditorGroups: [EditorAdjustmentGroup] {
        EditorLayoutPolicy.mobileEditorGroups(isHDREditing: settings.isHDREditing)
    }
    var mobileEditorTools: [EditorToolSelection] {
        EditorLayoutPolicy.mobileEditorTools(for: selectedGroup)
    }

    var editorToolHeight: CGFloat {
        EditorLayoutPolicy.editorToolHeight(
            accessibility: UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory,
            bodyLineHeight: UIFont.preferredFont(forTextStyle: .body).lineHeight,
            standardHeight: toolHeight
        )
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
        EditorLayoutPolicy.singleLineGroupNavigationHeight(
            captionLineHeight: UIFont.preferredFont(forTextStyle: .caption1).lineHeight
        )
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
        EditorLayoutPolicy.scrollsToolsWithParameters(
            width: size.width,
            height: size.height,
            accessibility: accessibility,
            bodyLineHeight: UIFont.preferredFont(forTextStyle: .body).lineHeight,
            groupButtonHeight: groupNavigationButtonHeight,
            toolStripHeight: editorToolStripHeight(width: size.width, accessibility: accessibility)
        )
    }

    func editorWorkspace(size: CGSize, accessibility: Bool) -> some View {
        let side = EditorLayoutPolicy.usesSidePanel(width: size.width, height: size.height, accessibility: accessibility)
        let layout = side ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        let panelWidth = EditorLayoutPolicy.sidePanelWidth(totalWidth: size.width)
        let isTool = toolWorkspaceOpen || viewModel.quickPresetsVisible
        let parameterHeight = EditorLayoutPolicy.parameterPanelHeight(
            measuredHeight: parameterContentHeight,
            totalHeight: size.height,
            accessibility: accessibility
        )
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
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: EditorLayoutPolicy.toolGridColumns(accessibility: accessibility)), spacing: 4) {
                                ForEach(mobileEditorTools, id: \.self) { tool in
                                    Button { coordinator.geometryPerspective = false; coordinator.geometryRotation = false; selectEditorTool(tool) } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: tool.symbol).font(.system(size: 21)).frame(height: 24)
                                            Text(tool.title).font(.caption).multilineTextAlignment(.center)
                                            Circle().fill(resetModified(.tool(tool)) ? Color.yellow : .clear).frame(width: 3, height: 3)
                                        }.frame(maxWidth: .infinity, minHeight: EditorLayoutPolicy.toolGridMinRowHeight(accessibility: accessibility)).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(editorBusy || (settings.isHDREditing && !supportsHDR(tool)) ||
                                        (tool == .lens && usesNormalX3f) ||
                                        (tool == .adjustment(.temperature) && !settings.isHDREditing && viewModel.sourceKind != .raw))
                                    .accessibilityLabel(tool.title).accessibilityValue(editorToolAccessibilityValue(tool))
                                    .accessibilityIdentifier("tool.\(tool.stableID)")
                                }

                            }.padding(.horizontal, 8).padding(.vertical, 4)
                        }.frame(height: EditorLayoutPolicy.toolGridHeight(side: side, accessibility: accessibility).map { CGFloat($0) })
                            .accessibilityIdentifier("editor.tools")
                        groupNavigation(side: false, singleLine: true, availableWidth: side ? panelWidth : size.width)
                    } else {
                        let metrics = EditorPanelLayoutMetrics(
                            width: size.width,
                            height: size.height,
                            accessibility: accessibility,
                            buttonWidth: groupNavigationButtonWidth,
                            buttonHeight: groupNavigationButtonHeight,
                            scrollTools: scrollsToolsWithParameters(size: size, accessibility: accessibility),
                            sideWidth: panelWidth,
                            side: side
                        )
                        ScrollView(.vertical) {
                            adjustmentPanel
                                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { parameterContentHeight = $0 }
                        }
                        .id("\(currentEditorTool.stableID).\(coordinator.geometryPerspective).\(coordinator.geometryRotation).\(viewModel.quickPresetsVisible)")
                        .frame(height: side ? nil : parameterHeight)
                        .modifier(OptionalGeometryObserver(action: testHooks.onPanelLayout.map { hook in
                            { frame in hook(frame, metrics) }
                        }))
                        .accessibilityIdentifier("editor.panel")
                        if toolWorkspaceOpen {
                            Divider()
                            editorDraftActions.padding(.horizontal, 8)
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
            Button { if toolWorkspaceOpen { undoEditorDraft() } else { requestAdjustmentAction(.undo) } } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .disabled((toolWorkspaceOpen ? workspaceDraft?.canUndo != true : !viewModel.canUndoAdjustment) || editorBusy)
                .accessibilityLabel(L10n.text("撤销")).accessibilityIdentifier("editor.draft.undo")
            Button { if toolWorkspaceOpen { redoEditorDraft() } else { requestAdjustmentAction(.redo) } } label: { Image(systemName: "arrow.uturn.forward").font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .disabled((toolWorkspaceOpen ? workspaceDraft?.canRedo != true : !viewModel.canRedoAdjustment) || editorBusy)
                .accessibilityLabel(L10n.text("重做")).accessibilityIdentifier("editor.draft.redo")
            workspaceResetControl
            Spacer(minLength: 0)
            Button { photoViewing.toggleComparison() } label: { Image(systemName: "square.on.square").font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .disabled(geometrySelected).accessibilityLabel(L10n.text("对比"))
            if toolWorkspaceOpen {
            Menu {
                Toggle(L10n.text("精细"), isOn: $coordinator.adjustmentFine).accessibilityIdentifier("editor.fine")
                    .modifier(OptionalGeometryObserver(action: testHooks.onFineToggleFrame))
                if currentEditorTool == .adjustment(.hsl) { Toggle(L10n.text("目标调整"), isOn: $coordinator.hslTargetEnabled) }
                if currentEditorTool == .adjustment(.toneCurve) { Toggle(L10n.text("目标调整"), isOn: $coordinator.curveTargetEnabled) }
                Menu(L10n.text("对比方式")) { comparisonModeMenu }.disabled(geometrySelected)
                    .accessibilityIdentifier("editor.compare.mode")
                Toggle(L10n.text("直方图"), isOn: $coordinator.histogramExpanded)
                Button(L10n.text("照片信息")) { coordinator.photoInfoMode = coordinator.photoInfoMode.next }
                    .accessibilityIdentifier("editor.photoInfo").accessibilityValue(coordinator.photoInfoMode.title)
                Button(L10n.text("纯预览")) { coordinator.photoViewing.togglePreview(isDraft: geometrySelected) }
                Button(L10n.text("照片处理设置")) { coordinator.presentProcessingContext() }
            } label: { Image(systemName: "ellipsis").font(.system(size: 20)).frame(width: 44, height: 44) }
                .accessibilityLabel(L10n.text("更多")).accessibilityIdentifier("editor.tool.more")
            }
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }

    var workspaceResetControl: some View {
        let available = viewModel.hasImage && !editorBusy && !viewModel.previewRendering &&
            !viewModel.quickPresetState.isPreparing
        let presentation = EditorWorkspaceResetPresentation.make(
            toolWorkspaceOpen: toolWorkspaceOpen,
            quickPresetsVisible: viewModel.quickPresetsVisible,
            selectedGroup: selectedGroup,
            currentTool: currentEditorTool,
            hslChannel: hslChannel,
            gradingZone: coordinator.gradingZone,
            gradingGlobalSelected: coordinator.gradingGlobalSelected,
            isAvailable: available,
            isModified: resetModified
        )
        return EditorWorkspaceResetControl(presentation: presentation, onReset: requestEditorReset)
    }
}
