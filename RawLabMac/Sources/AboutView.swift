import SwiftUI

struct AboutView: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("RawLab").font(.title2.bold())
                    Text("版本 \(updates.currentVersion)").foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("项目与作者").font(.headline)
            Link("GitHub 仓库", destination: UpdateRelease.repository)
            Link("作者的小红书主页", destination: UpdateRelease.author)
            Divider()
            Toggle("自动检查更新", isOn: $updates.automatic)
            Text(updates.status).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button { Task { await updates.check(manual: true) } } label: {
                    Label("检查更新", systemImage: "arrow.clockwise")
                }.disabled(updates.checking)
                if updates.checking { ProgressView().controlSize(.small) }
                if let release = updates.available {
                    Link("前往下载 \(release.version)", destination: release.url)
                }
            }
            if let release = updates.available, !release.notes.isEmpty {
                ScrollView { Text(release.notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180)
            }
        }
        .padding(24).frame(width: 440).fixedSize(horizontal: false, vertical: true)
    }
}
