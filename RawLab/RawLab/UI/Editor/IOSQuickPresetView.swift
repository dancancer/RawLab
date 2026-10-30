import SwiftUI

struct IOSQuickPresetView: View {
    @ObservedObject var model: RawEditorViewModel
    let requestAction: (IOSAdjustmentAction) -> Void
    let manage: () -> Void
    let undo: () -> Void
    let libraryRevision: UUID
    @State private var presets: [AdjustmentPreset] = []
    @State private var libraryError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { libraryActions }
                VStack(alignment: .leading) { libraryActions }
            }
            status
            if let libraryError {
                Text(libraryError).foregroundStyle(.secondary).accessibilityIdentifier("preset.quick.libraryError")
                actionButton("重新载入", id: "preset.quick.reload", action: reload)
            } else if presets.isEmpty {
                Text(L10n.text("尚无用户预设")).font(.headline).accessibilityIdentifier("preset.quick.empty")
                Text(L10n.text("保存所选调整，之后可应用到其他照片。")).foregroundStyle(.secondary)
            } else {
                ForEach(presets) { preset in
                    row(preset)
                    Divider()
                }
            }
        }.padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear(perform: reload)
            .onChange(of: libraryRevision) { _, _ in reload() }
            .onDisappear { model.cancelQuickPreset() }
    }

    @ViewBuilder private var libraryActions: some View {
        actionButton("管理预设", id: "preset.quick.manage", action: manage)
            .disabled(model.quickPresetState.isPreparing)
        actionButton("保存当前调整为预设…", id: "preset.quick.create") { requestAction(.presetSave) }
            .disabled(model.quickPresetState.isPreparing || libraryError != nil)
    }

    private func row(_ preset: AdjustmentPreset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preset.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("preset.quick.name.\(preset.id)")
            Text(AdjustmentTransferSummary(payload: preset.payload).groups.map {
                AdjustmentTransferField.groupTitle($0.id) + " · " + String($0.fields.count)
            }.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                actionButton("应用到当前照片", id: "preset.quick.apply.\(preset.id)") { requestAction(.presetApply(preset)) }
                    .disabled(model.quickPresetState.isPreparing || model.isBusy)
                Spacer(minLength: 4)
                Menu {
                    Button(L10n.text("应用到多张照片")) { requestAction(.presetApplyMultiple(preset)) }
                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                    .disabled(model.quickPresetState.isPreparing)
                    .accessibilityLabel(L10n.format("管理预设：%@", preset.name))
                    .accessibilityIdentifier("preset.quick.more.\(preset.id)")
            }
            DisclosureGroup {
                IOSAdjustmentSummaryView(payload: preset.payload, lookName: model.adjustmentSummaryLookName,
                    identifier: "preset.quick.summary.\(preset.id)")
            } label: { Text(L10n.text("查看调整范围")).frame(minHeight: 44) }
                .accessibilityIdentifier("preset.quick.details.\(preset.id)")
        }.accessibilityElement(children: .contain)
    }

    @ViewBuilder private var status: some View {
        switch model.quickPresetState {
        case .idle: EmptyView()
        case .preparing(let preset):
            VStack(alignment: .leading) {
                Label(preset.name + " · " + L10n.text("正在检查预设…"), systemImage: "hourglass")
                actionButton("取消", id: "preset.quick.cancel", action: model.cancelQuickPreset)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("preset.quick.status")
        case .saved(let preset, _):
            VStack(alignment: .leading) {
                result(preset, "已保存")
                actionButton("撤销", id: "preset.quick.undo", action: undo)
            }
        case .unchanged(let preset): result(preset, "未变化")
        case .undone(let preset): result(preset, "已撤销")
        case .failed(let preset, let message): failure(preset, message: message) { requestAction(.presetApply(preset)) }
        case .undoFailed(let preset, _, let message): failure(preset, message: message, retry: undo)
        }
    }
    private func result(_ preset: AdjustmentPreset, _ key: String) -> some View {
        Text(preset.name + " · " + L10n.text(key)).accessibilityIdentifier("preset.quick.status")
    }
    private func failure(_ preset: AdjustmentPreset, message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading) {
            Text(preset.name + " · " + message).accessibilityIdentifier("preset.quick.status")
            HStack {
                actionButton("重试", id: "preset.quick.retry", action: retry)
                actionButton("取消", id: "preset.quick.cancel", action: model.cancelQuickPreset)
            }
        }
    }
    private func actionButton(_ key: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.text(key)).frame(minWidth: 44, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.accessibilityIdentifier(id)
    }
    private func reload() {
        do { presets = try model.presetStore.list(); libraryError = nil }
        catch { presets = []; libraryError = model.presetErrorMessage(error) }
    }
}
