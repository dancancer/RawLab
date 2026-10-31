import SwiftUI

struct IOSAdjustmentPresetView: View {
    @ObservedObject var model: RawEditorViewModel
    let settings: RawSettings
    var initialSave = false
    let requestPhotoAction: (IOSAdjustmentAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [AdjustmentPreset] = []
    @State private var libraryError: String?
    @State private var message: String?
    @State private var editing = false
    @State private var renaming: AdjustmentPreset?
    @State private var name = ""
    @State private var scope = "custom"
    @State private var fields = AdjustmentTransferField.common
    @State private var confirmation: Confirmation?
    @State private var started = false
    @FocusState private var nameFocused: Bool

    private enum Confirmation {
        case overwrite(AdjustmentPreset, AdjustmentTransferPayload), delete(AdjustmentPreset)
        var preset: AdjustmentPreset {
            switch self { case .overwrite(let value, _), .delete(let value): return value }
        }
        var title: String {
            switch self { case .overwrite: return "覆盖预设？"; case .delete: return "删除预设？" }
        }
    }
    private var title: String { editing ? renaming == nil ? "保存预设" : "重命名预设" : "我的预设" }

    private var scopePreview: Result<AdjustmentTransferPayload, Error> {
        Result { try model.previewAdjustmentPayload(scope: scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields), settings: settings) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if editing { editorContent } else { libraryContent }
                if let message {
                    Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("preset.message") }
                }
            }
            .navigationTitle(L10n.text(title)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(L10n.text(editing ? "取消" : "关闭")) {
                    if editing { editing = false; renaming = nil; message = nil; nameFocused = false }
                    else { dismiss() }
                }.accessibilityIdentifier("preset.close")
            } }
        }
        .tint(.yellow)
        .onAppear {
            reload()
            guard !started else { return }
            started = true
            if initialSave && libraryError == nil {
                fields=settings.isHDREditing ? AdjustmentTransferField.hdrCommon : AdjustmentTransferField.common
                name = L10n.text("新预设"); editing = true; nameFocused = true
            }
        }
        .alert(L10n.text(confirmation?.title ?? "我的预设"), isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { pending in
                switch pending {
                case .overwrite(let existing, let payload):
                    Button(L10n.text("覆盖"), role: .destructive) { perform { _ = try model.presetStore.overwrite(existing, payload: payload) } }
                    Button(L10n.text("另存")) { message = L10n.text("请输入不同的预设名称。"); nameFocused = true }
                case .delete(let existing):
                    Button(L10n.text("删除"), role: .destructive) { perform { try model.presetStore.delete(existing) } }
                }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: { pending in Text(pending.preset.name) }
    }

    @ViewBuilder private var libraryContent: some View {
        Section {
            Button(L10n.text("保存当前调整为预设…")) { requestPhotoAction(.presetSave) }
                .disabled(!model.hasImage || model.isBusy || libraryError != nil).accessibilityIdentifier("preset.create")
        }
        if let libraryError {
            Section {
                Text(libraryError).foregroundStyle(.secondary).accessibilityIdentifier("preset.libraryError")
                Button(L10n.text("重新载入"), action: reload).accessibilityIdentifier("preset.reload")
            }
        } else if presets.isEmpty {
            Section {
                Text(L10n.text("尚无用户预设")).font(.headline)
                Text(L10n.text("保存所选调整，之后可应用到其他照片。")).foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(presets) { preset in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(preset.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup(L10n.format("已选 %@ 项", String(preset.payload.fields.count))) {
                            IOSAdjustmentSummaryView(payload: preset.payload, lookName: model.adjustmentSummaryLookName,
                                identifier: "preset.summary.\(preset.id)")
                        }
                        HStack {
                            Button(L10n.text("应用")) { requestPhotoAction(.presetApply(preset)) }
                                .frame(minWidth: 44, minHeight: 44)
                                .disabled(!model.hasImage || model.isBusy).accessibilityIdentifier("preset.apply.\(preset.id)")
                            Spacer()
                            Menu {
                                Button(L10n.text("应用到多张照片")) { requestPhotoAction(.presetApplyMultiple(preset)) }
                                    .disabled(!model.hasImage || model.isBusy).accessibilityIdentifier("preset.multiple.\(preset.id)")
                                Button(L10n.text("重命名")) {
                                    renaming = preset; name = preset.name; message = nil; editing = true; nameFocused = true
                                }.accessibilityIdentifier("preset.rename.\(preset.id)")
                                Button(L10n.text("删除"), role: .destructive) { confirmation = .delete(preset) }
                                    .accessibilityIdentifier("preset.delete.\(preset.id)")
                            } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel(L10n.format("管理预设：%@", preset.name))
                                .accessibilityIdentifier("preset.manage.\(preset.id)")
                        }.buttonStyle(.borderless)
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("preset.row.\(preset.id)")
                }
            }
        }
    }

    @ViewBuilder private var editorContent: some View {
        Section {
            TextField(L10n.text("预设名称"), text: $name).focused($nameFocused)
                .autocorrectionDisabled().submitLabel(.done).onSubmit { nameFocused = false }
                .accessibilityIdentifier("preset.name")
        }
        if renaming == nil {
            IOSAdjustmentScopeEditor(scope: $scope, fields: $fields, preview: scopePreview,
                lookName: model.adjustmentSummaryLookName, errorMessage: { model.adjustmentErrorMessage($0) }, identifier: "preset.save",
                fieldIdentifier:"preset",titleKey:"调整范围",allowed:settings.isHDREditing ? AdjustmentTransferField.hdrSupported : AdjustmentTransferField.legacyFields)
        }
        Section {
            Button(L10n.text("保存预设"), action: save)
                .disabled(AdjustmentPreset.normalizedName(name).isEmpty || renaming == nil && (try? scopePreview.get()) == nil)
                .accessibilityIdentifier("preset.save.confirm")
        }
    }

    private func save() {
        if let renaming { perform { _ = try model.presetStore.rename(renaming, name: name) }; return }
        do {
            let selection: AdjustmentTransferScope = scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields)
            let payload = try model.capturePresetAdjustments(scope: selection, settings: settings)
            do { _ = try model.presetStore.create(name: name, payload: payload); saved() }
            catch AdjustmentPresetError.duplicateName(let existing) { confirmation = .overwrite(existing, payload) }
        } catch { message = model.presetErrorMessage(error) }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); saved() }
        catch {
            message = model.presetErrorMessage(error)
            if error as? AdjustmentPresetError == .changed { editing = false; renaming = nil; reload() }
        }
    }
    private func saved() { editing = false; renaming = nil; message = nil; nameFocused = false; reload() }
    private func reload() {
        do { presets = try model.presetStore.list(); libraryError = nil }
        catch { presets = []; libraryError = model.presetErrorMessage(error) }
    }
}
