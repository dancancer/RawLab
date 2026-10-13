import SwiftUI

struct AboutView: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var updates: UpdateChecker
    @AppStorage(L10n.preferenceKey) private var languagePreference = AppLanguage.system.rawValue

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("RawLab").font(.title2.bold())
                    Text(L10n.format("版本 %@", String(describing: updates.currentVersion))).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text(L10n.text("项目与作者")).font(.headline)
            Link(L10n.text("GitHub 仓库"), destination: UpdateRelease.repository)
            Link(L10n.text("作者的小红书主页"), destination: UpdateRelease.author)
            Divider()
            Picker(L10n.text("语言"), selection: $languagePreference) {
                ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0.rawValue) }
            }.id(localizationLocale.identifier).accessibilityIdentifier("settings.language")
            Toggle(L10n.text("自动检查更新"), isOn: $updates.automatic)
            Text(updates.status).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button { Task { await updates.check(manual: true) } } label: {
                    Label(L10n.text("检查更新"), systemImage: "arrow.clockwise")
                }.disabled(updates.checking)
                if updates.checking { ProgressView().controlSize(.small) }
                if let release = updates.available {
                    Link(L10n.format("前往下载 %@", String(describing: release.version)), destination: release.url)
                }
            }
            if let release = updates.available, !release.notes.isEmpty {
                ScrollView { Text(release.notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180)
            }
        }
        .padding(24).frame(width: 440).fixedSize(horizontal: false, vertical: true)
        .navigationTitle(L10n.text("关于 RawLab"))
    }
}
