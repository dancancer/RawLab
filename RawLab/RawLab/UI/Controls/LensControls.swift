import SwiftUI

struct IOSLensControls: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: RawSettings
    let info: LensInfo?
    @State private var choosingProfile = false
    private var lens: LensCorrectionSettings { settings.lensSettings }
    private var selectedTitle: String {
        if lens.mode == .manual { return info?.candidates.first { $0.id == lens.profileID }?.title ?? L10n.text("选择镜头") }
        return info?.selectedLens.isEmpty == false ? info!.selectedLens : L10n.text("未匹配镜头")
    }
    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(L10n.text("镜头匹配"), selection: Binding(get: { lens.mode }, set: { mode in update { $0.mode = mode } })) {
                    Text(L10n.text("自动")).tag(LensProfileMode.automatic)
                    Text(L10n.text("手动")).tag(LensProfileMode.manual)
                }.pickerStyle(.segmented).id(localizationLocale.identifier).accessibilityIdentifier("lens.mode")
                    .frame(minHeight: 44)
                Button { settings.lensCorrection = nil } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                }.accessibilityLabel(L10n.text("重置镜头校正")).accessibilityIdentifier("lens.reset")
                    .disabled(lens == LensCorrectionSettings())
            }
            Toggle(L10n.text("畸变矫正"), isOn: value(\.distortion)).frame(minHeight: 44).accessibilityIdentifier("lens.distortion")
            Toggle(L10n.text("横向色差"), isOn: value(\.tca)).frame(minHeight: 44).accessibilityIdentifier("lens.tca")
            Toggle(L10n.text("自动裁边"), isOn: value(\.autoCrop)).frame(minHeight: 44).accessibilityIdentifier("lens.crop")
            Button { choosingProfile = true } label: {
                HStack {
                    Text(selectedTitle).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                }.frame(minHeight: 44)
            }.disabled(lens.mode != .manual || info?.candidates.isEmpty != false)
                .accessibilityLabel(L10n.text("选择镜头配置文件")).accessibilityIdentifier("lens.profile")
                .accessibilityValue(selectedTitle)
            Text(info?.message ?? L10n.text("镜头信息尚未就绪")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lens.status")
            if let info, !info.detectedLens.isEmpty {
                Text(info.detectedLens).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let scale = info?.cropScale, scale > 1.0001 {
                Text(L10n.format("裁边 %@%%", String(format: "%.1f", locale: L10n.locale, Double((1 - 1 / scale) * 100))))
                    .font(.caption).monospacedDigit()
            }
        }
        .sheet(isPresented: $choosingProfile) {
            IOSLensChooser(candidates: info?.candidates ?? [], selectedID: lens.profileID) { profile in
                update { $0.mode = .manual; $0.profileID = profile.id }
                choosingProfile = false
            }
        }
    }
    private func value(_ key: WritableKeyPath<LensCorrectionSettings, Bool>) -> Binding<Bool> {
        Binding(get: { lens[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }
    private func update(_ edit: (inout LensCorrectionSettings) -> Void) {
        var value = lens
        edit(&value)
        settings.lensCorrection = value == LensCorrectionSettings() ? nil : value
    }
}

private struct IOSLensChooser: View {
    @Environment(\.locale) private var localizationLocale
    @Environment(\.dismiss) private var dismiss
    let candidates: [LensCandidate]
    let selectedID: String?
    let select: (LensCandidate) -> Void
    @State private var search = ""
    private var filtered: [LensCandidate] {
        candidates.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { $0.isMatch != $1.isMatch ? $0.isMatch : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        let _ = localizationLocale
        NavigationStack {
            List(filtered) { candidate in
                Button { select(candidate) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.title).foregroundStyle(.primary)
                            Text([candidate.hasDistortion ? L10n.text("畸变") : nil, candidate.hasTCA ? L10n.text("横向色差") : nil,
                                  candidate.isMatch ? L10n.text("元数据匹配") : nil].compactMap { $0 }.joined(separator: " / "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if candidate.id == selectedID { Image(systemName: "checkmark") }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.accessibilityIdentifier("lens.candidate")
                    .accessibilityAddTraits(candidate.id == selectedID ? .isSelected : [])
            }
            .overlay { if filtered.isEmpty { ContentUnavailableView(L10n.text("未找到镜头"), systemImage: "magnifyingglass") } }
            .searchable(text: $search, prompt: L10n.text("搜索镜头"))
            .navigationTitle(L10n.text("镜头配置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } } }
        }
    }
}
