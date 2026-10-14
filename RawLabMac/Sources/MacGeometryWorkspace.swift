import AppKit
import SwiftUI

struct MacGeometryWorkspace: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(L10n.text("几何编辑")).font(.system(size: 13, weight: .semibold))
                ForEach(MacGeometryTab.allCases, id: \.self) { tab in
                    Button {
                        finishInput()
                        _ = model.selectGeometryDraftTab(tab)
                    } label: {
                        Text(tab.title).font(.system(size: 13))
                            .padding(.vertical, 7)
                            .overlay(alignment: .bottom) {
                                if model.geometryDraftTab == tab { Capsule().fill(.yellow).frame(height: 2) }
                            }
                    }.buttonStyle(.plain)
                        .foregroundStyle(model.geometryDraftTab == tab ? Color.yellow : Color.secondary)
                        .accessibilityIdentifier("geometry.tab.\(tab.rawValue)")
                        .accessibilityAddTraits(model.geometryDraftTab == tab ? .isSelected : [])
                        .disabled(!model.invalidGeometryDraftInputs.isEmpty && model.geometryDraftTab != tab)
                }
                Spacer(minLength: 8)
                Button {
                    finishInput()
                    if model.geometryDraftTab == .lens { model.resetLensDraft() }
                    else { model.resetGeometryDraft() }
                } label: { Image(systemName: "arrow.counterclockwise").frame(width: 28, height: 28) }
                    .buttonStyle(.borderless).help(L10n.text("重置本工具"))
                    .accessibilityLabel(L10n.text("重置本工具")).accessibilityIdentifier("geometry.draft.reset")
                Button(L10n.text("取消")) { finishInput(); model.cancelGeometryDraft() }
                    .accessibilityLabel(L10n.text("取消几何和镜头编辑"))
                    .accessibilityIdentifier("geometry.draft.cancel")
                Button(L10n.text("应用")) { finishInput(); _ = model.applyGeometryDraft() }
                    .buttonStyle(.borderedProminent).tint(.yellow)
                    .disabled(!model.geometryDraftCanApply)
                    .accessibilityLabel(L10n.text("应用几何和镜头编辑"))
                    .accessibilityIdentifier("geometry.draft.apply")
            }.controlSize(.small).padding(.horizontal, 16).frame(minHeight: 38)
            ScrollView(.vertical) {
                if model.geometryDraftTab == .lens { LensControls(model: model) }
                else { GeometryControls(model: model, tab: model.geometryDraftTab) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if !model.invalidGeometryDraftInputs.isEmpty {
                    Label(L10n.text("请先纠正无效数值"), systemImage: "exclamationmark.circle").foregroundStyle(.yellow)
                } else if !model.geometryDraftPreviewReady {
                    Label(L10n.text("正在准备编辑画布…"), systemImage: "hourglass").foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("草稿尚未应用")).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.font(.system(size: 11)).padding(.horizontal, 16).padding(.bottom, 8)
        }.accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("几何与镜头草稿"))
    }

    private func finishInput() { NSApp.keyWindow?.makeFirstResponder(nil) }
}

struct MacGeometryDeparturePrompt: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("保留这次几何或镜头修改？")).font(.headline)
            Text(L10n.text("这些修改尚未应用。应用并离开，放弃修改，或继续编辑。"))
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { stayButton; Spacer(minLength: 0); discardButton; applyButton }
                VStack(alignment: .trailing, spacing: 10) {
                    applyButton; discardButton; stayButton
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled()
    }

    private var stayButton: some View {
        Button(L10n.text("继续编辑")) { model.resolveGeometryDraftDeparture(.stay) }
            .fixedSize().keyboardShortcut(.cancelAction)
    }
    private var discardButton: some View {
        Button(L10n.text("放弃修改")) { model.resolveGeometryDraftDeparture(.discard) }.fixedSize()
    }
    private var applyButton: some View {
        Button(L10n.text("应用并离开")) { model.resolveGeometryDraftDeparture(.apply) }
            .fixedSize().buttonStyle(.borderedProminent).tint(.yellow)
            .disabled(!model.geometryDraftCanApply).keyboardShortcut(.defaultAction)
    }
}
