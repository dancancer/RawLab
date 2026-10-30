import SwiftUI

struct QuickPresetView: View {
    @ObservedObject var model: EditorModel
    @State private var presets: [AdjustmentPreset] = []
    @State private var libraryError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { libraryActions; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 6) { libraryActions }
            }
            status
            if let libraryError {
                Text(libraryError).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("preset.quick.libraryError")
                Button(L10n.text("重新载入"), action: reload).accessibilityIdentifier("preset.quick.reload")
                Spacer(minLength: 0)
            } else if presets.isEmpty {
                Text(L10n.text("尚无用户预设")).font(.headline).accessibilityIdentifier("preset.quick.empty")
                Text(L10n.text("保存所选调整，之后可应用到其他照片。")).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(presets) { preset in
                            presetRow(preset)
                            Divider()
                        }
                    }
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 8).controlSize(.small)
            .onAppear(perform: reload)
            .onChange(of: model.adjustmentSheet) { _, kind in if kind == nil { reload() } }
            .onDisappear { model.cancelQuickPreset() }
            .onExitCommand { model.closeQuickPresets() }
    }

    @ViewBuilder private var libraryActions: some View {
        Button(L10n.text("管理预设")) { model.requestAdjustmentSheet(.presets) }
            .disabled(model.quickPresetState.isPreparing)
            .accessibilityIdentifier("preset.quick.manage")
        Button(L10n.text("保存当前调整为预设…")) {
            model.preparePresetAction { model.requestAdjustmentSheet(.presets, savingPreset: true) }
        }.disabled(!model.canUsePresetPhoto || model.quickPresetState.isPreparing || libraryError != nil)
            .accessibilityIdentifier("preset.quick.create")
    }

    private func presetRow(_ preset: AdjustmentPreset) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("preset.quick.name.\(preset.id)")
                    Text(AdjustmentTransferSummary(payload: preset.payload).groups.map {
                        AdjustmentTransferField.groupTitle($0.id) + " · " + String($0.fields.count)
                    }.joined(separator: "  /  ")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.text("应用到当前照片")) { model.applyPresetToCurrentPhoto(preset) }
                    .disabled(!model.canUsePresetPhoto || model.quickPresetState.isPreparing)
                    .accessibilityIdentifier("preset.quick.apply.\(preset.id)")
                Menu {
                    Button(L10n.text("应用到多张照片")) {
                        model.preparePresetAction { model.requestAdjustmentSheet(.paste, preset: preset) }
                    }.disabled(!model.canUsePresetPhoto || model.quickPresetState.isPreparing)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(L10n.format("管理预设：%@", preset.name))
                    .accessibilityIdentifier("preset.quick.more.\(preset.id)")
            }
            DisclosureGroup(L10n.text("查看调整范围")) {
                AdjustmentSummaryView(payload: preset.payload, lookName: model.adjustmentSummaryLookName,
                    identifier: "preset.quick.summary.\(preset.id)")
            }.font(.caption).accessibilityIdentifier("preset.quick.details.\(preset.id)")
        }.padding(.vertical, 8)
    }

    @ViewBuilder private var status: some View {
        switch model.quickPresetState {
        case .idle: EmptyView()
        case .preparing(let preset):
            HStack {
                ProgressView().controlSize(.small)
                Text(preset.name + " · " + L10n.text("正在检查预设…")).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L10n.text("取消"), action: model.cancelQuickPreset).accessibilityIdentifier("preset.quick.cancel")
            }.accessibilityElement(children: .contain).accessibilityIdentifier("preset.quick.status")
        case .saved(let preset, _):
            HStack {
                Text(preset.name + " · " + L10n.text("已保存")).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L10n.text("撤销"), action: model.undoQuickPreset).accessibilityIdentifier("preset.quick.undo")
            }.accessibilityElement(children: .contain).accessibilityIdentifier("preset.quick.status")
        case .unchanged(let preset): result(preset, "未变化")
        case .undone(let preset): result(preset, "已撤销")
        case .failed(let preset, let message): failure(preset, message: message) { model.applyPresetToCurrentPhoto(preset) }
        case .undoFailed(let preset, _, let message): failure(preset, message: message, retry: model.undoQuickPreset)
        }
    }

    private func result(_ preset: AdjustmentPreset, _ key: String) -> some View {
        Text(preset.name + " · " + L10n.text(key)).font(.callout).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("preset.quick.status")
    }

    private func failure(_ preset: AdjustmentPreset, message: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Text(preset.name + " · " + message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L10n.text("重试"), action: retry).accessibilityIdentifier("preset.quick.retry")
            Button(L10n.text("取消"), action: model.cancelQuickPreset).accessibilityIdentifier("preset.quick.cancel")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("preset.quick.status")
    }

    private func reload() {
        do { presets = try model.presetStore.list(); libraryError = nil }
        catch { presets = []; libraryError = model.presetErrorMessage(error) }
    }
}
