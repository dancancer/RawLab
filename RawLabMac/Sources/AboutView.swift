import SwiftUI

struct AboutView: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var updates: UpdateChecker
    @AppStorage(L10n.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    @ObservedObject private var usage = UsageAnalytics.shared

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
            Divider()
            Toggle(L10n.text("允许使用统计"), isOn: Binding(get: { usage.isEnabled }, set: { usage.setEnabled($0) }))
                .disabled(!usage.isAvailable && !usage.isEnabled)
            Text(L10n.text(usage.statusKey)).font(.callout).foregroundStyle(.secondary)
            Text(L10n.text("开启后，由阿里云处理功能使用次数，数据存储在中国大陆；SDK 可能采集设备标识、设备与系统信息、网络/IP、地区及会话信息。不采集照片、预览、文件名、路径、EXIF 或 AI 内容。关闭后停止新采集，已发出的请求无法撤回。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link(L10n.text("阿里云隐私政策"), destination: URL(string: "https://terms.alicdn.com/legal-agreement/terms/privacy_policy_full/20240308104330389/20240308104330389.html")!)
                .font(.callout)
        }
        .padding(24).frame(width: 440).fixedSize(horizontal: false, vertical: true)
        .navigationTitle(L10n.text("关于 RawLab"))
    }
}
