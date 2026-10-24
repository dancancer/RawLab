import SwiftUI

struct AdjustmentPresetView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [AdjustmentPreset] = []
    @State private var libraryError: String?
    @State private var message: String?
    @State private var editing = false
    @State private var renaming: AdjustmentPreset?
    @State private var name = ""
    @State private var scope = "custom"
    @State private var fields = AdjustmentTransferField.common
    @State private var applying: AdjustmentPreset?
    @State private var confirmation: Confirmation?
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
    private var selectedScope: AdjustmentTransferScope {
        scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields)
    }

    var body: some View {
        Group {
            if let applying {
                AdjustmentTransferView(model: model, kind: .paste, preset: applying, onClose: { self.applying = nil; reload() })
                    .id(applying.id)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(L10n.text(title)).font(.title2.weight(.semibold))
                        Spacer()
                        Button(L10n.text(editing ? "取消" : "关闭")) {
                            if editing { editing = false; renaming = nil; message = nil }
                            else { dismiss() }
                        }.keyboardShortcut(.cancelAction).accessibilityIdentifier("preset.close")
                    }
                    if editing { editorContent } else { libraryContent }
                    if let message {
                        Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("preset.message")
                    }
                }.padding(24).frame(width: 600).frame(minHeight: 380, maxHeight: 680).tint(.yellow)
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: Binding(get: { model.geometryDraftDeparturePending }, set: { _ in })) {
            MacGeometryDeparturePrompt(model: model)
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
            } message: { pending in Text(pending.preset.name).fixedSize(horizontal: false, vertical: true) }
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(L10n.text("保存当前调整为预设…")) {
                model.preparePresetAction {
                    name = L10n.text("新预设"); scope = "custom"; fields = AdjustmentTransferField.common
                    renaming = nil; message = nil; editing = true; nameFocused = true
                }
            }.buttonStyle(.borderedProminent).disabled(!model.canUsePresetPhoto || libraryError != nil)
                .accessibilityIdentifier("preset.create")
            if let libraryError {
                Text(libraryError).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("preset.libraryError")
                Button(L10n.text("重新载入"), action: reload).accessibilityIdentifier("preset.reload")
                Spacer(minLength: 0)
            } else if presets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("尚无用户预设")).font(.headline)
                    Text(L10n.text("保存所选调整，之后可应用到其他照片。")).foregroundStyle(.secondary)
                }.padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(presets) { preset in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name).font(.headline).lineLimit(2).help(preset.name)
                                    Text(L10n.format("已选 %@ 项", String(preset.payload.fields.count))).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button(L10n.text("应用")) {
                                    model.preparePresetAction { applying = preset; message = nil }
                                }.disabled(!model.canUsePresetPhoto).accessibilityIdentifier("preset.apply.\(preset.id)")
                                Menu {
                                    Button(L10n.text("重命名")) { renaming = preset; name = preset.name; message = nil; editing = true; nameFocused = true }
                                    Button(L10n.text("删除"), role: .destructive) { confirmation = .delete(preset) }
                                } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton).fixedSize()
                                    .accessibilityLabel(L10n.format("管理预设：%@", preset.name))
                                    .accessibilityIdentifier("preset.manage.\(preset.id)")
                            }.padding(.vertical, 12).accessibilityIdentifier("preset.row.\(preset.id)")
                            Divider()
                        }
                    }
                }.frame(minHeight: 220, maxHeight: 460)
            }
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L10n.text("预设名称"), text: $name).textFieldStyle(.roundedBorder)
                .focused($nameFocused).accessibilityIdentifier("preset.name")
            if renaming == nil { AdjustmentScopeEditor(scope: $scope, fields: $fields, identifier: "preset.save", titleKey: "调整范围") }
            HStack {
                Spacer()
                Button(L10n.text("保存"), action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(AdjustmentPreset.normalizedName(name).isEmpty || renaming == nil && scope == "custom" && fields.isEmpty)
                    .accessibilityIdentifier("preset.save.confirm")
            }
        }
    }
    private func save() {
        if let renaming { perform { _ = try model.presetStore.rename(renaming, name: name) }; return }
        do {
            let payload = try model.capturePresetAdjustments(scope: selectedScope)
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
    private func saved() { editing = false; renaming = nil; message = nil; reload() }
    private func reload() {
        do { presets = try model.presetStore.list(); libraryError = nil }
        catch { presets = []; libraryError = model.presetErrorMessage(error) }
    }
}
