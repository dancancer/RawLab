import SwiftUI

struct LensControls: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    @State private var choosingProfile = false

    private var settings: LensCorrectionSettings { model.settings.lensSettings }
    private var info: LensInfo? { model.result?.lensInfo }
    private var selectedTitle: String {
        if settings.mode == .manual {
            return info?.candidates.first { $0.id == settings.profileID }?.title ?? L10n.text("选择镜头…")
        }
        if let selected = info?.selectedLens, !selected.isEmpty { return selected }
        let matches = info?.candidates.filter(\.isMatch) ?? []
        return matches.count == 1 ? matches[0].title : L10n.text("自动匹配")
    }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Picker(L10n.text("镜头匹配"), selection: Binding(get: { settings.mode }, set: { mode in update { $0.mode = mode } })) {
                    Text(L10n.text("自动")).tag(LensProfileMode.automatic)
                    Text(L10n.text("手动")).tag(LensProfileMode.manual)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    .id(localizationLocale.identifier).accessibilityIdentifier("lens.mode")
                Spacer(minLength: 0)
                Button { model.settings.reset(.lens) } label: { Image(systemName: "arrow.counterclockwise").frame(width: 20, height: 20) }
                    .buttonStyle(.borderless).help(L10n.text("重置镜头校正")).accessibilityLabel(L10n.text("重置镜头校正"))
                    .accessibilityIdentifier("lens.reset").disabled(model.settings.isDefault(.lens))
            }.controlSize(.small)
            HStack(spacing: 16) {
                Toggle(L10n.text("畸变矫正"), isOn: value(\.distortion)).accessibilityIdentifier("lens.distortion")
                Toggle(L10n.text("横向色差"), isOn: value(\.tca)).accessibilityIdentifier("lens.tca")
                Toggle(L10n.text("自动裁边"), isOn: value(\.autoCrop)).accessibilityIdentifier("lens.crop")
                    .disabled(!settings.isEnabled)
                Spacer(minLength: 0)
            }.controlSize(.small)
            HStack(spacing: 8) {
                Button { choosingProfile = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "viewfinder")
                        Text(selectedTitle).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.borderless).help(L10n.text("选择镜头配置文件"))
                    .accessibilityLabel(L10n.text("选择镜头配置文件")).accessibilityIdentifier("lens.profile")
                    .accessibilityValue(selectedTitle)
                    .disabled(info?.candidates.isEmpty != false)
                    .popover(isPresented: $choosingProfile) {
                        LensProfileChooser(candidates: info?.candidates ?? [], selectedID: settings.profileID) { candidate in
                            update { $0.mode = .manual; $0.profileID = candidate.id }
                            choosingProfile = false
                        }
                    }
                if let info, settings.isEnabled, info.cropScale > 1.0001 {
                    Text(L10n.format("裁边 %@%%", String(Int(((1 - 1 / info.cropScale) * 100).rounded()))))
                        .monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
            }.font(.system(size: 12)).frame(height: 22)
            HStack(spacing: 8) {
                Text(info?.message ?? L10n.text("正在读取镜头信息…")).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("lens.status")
                if let info, settings.tca, info.appliedDistortion, !info.appliedTCA {
                    Text(L10n.text("横向色差未应用")).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if let info, !info.detectedLens.isEmpty {
                    Text(info.detectedLens).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }.font(.system(size: 11)).frame(minHeight: 16)
        }.frame(maxWidth: 760).padding(.horizontal, 16)
    }

    private func value(_ keyPath: WritableKeyPath<LensCorrectionSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { enabled in update { $0[keyPath: keyPath] = enabled } })
    }

    private func update(_ edit: (inout LensCorrectionSettings) -> Void) {
        var lens = settings
        edit(&lens)
        model.settings.lensCorrection = lens == LensCorrectionSettings() ? nil : lens
    }
}

private struct LensProfileChooser: View {
    @Environment(\.locale) private var localizationLocale
    let candidates: [LensCandidate]
    let selectedID: String?
    let select: (LensCandidate) -> Void
    @State private var search = ""

    private var filtered: [LensCandidate] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? candidates : candidates.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("搜索镜头"), text: $search).textFieldStyle(.plain).accessibilityIdentifier("lens.search")
            }.padding(12)
            Divider()
            if filtered.isEmpty {
                Text(L10n.text("未找到镜头")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { candidate in
                            Button { select(candidate) } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.title).lineLimit(2).foregroundStyle(.primary)
                                        HStack(spacing: 8) {
                                            if candidate.isMatch { Text(L10n.text("匹配照片")).foregroundStyle(.yellow) }
                                            Text([candidate.hasDistortion ? L10n.text("畸变") : nil, candidate.hasTCA ? L10n.text("横向色差") : nil]
                                                .compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                                        }.font(.system(size: 11))
                                    }
                                    Spacer()
                                    if candidate.id == selectedID { Image(systemName: "checkmark").foregroundStyle(.yellow) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(candidate.title)
                                .accessibilityAddTraits(candidate.id == selectedID ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }.frame(width: 540, height: 400)
    }
}
