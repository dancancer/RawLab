import AppKit
import RawLabKit
import SwiftUI
import UniformTypeIdentifiers

struct AboutView: View {
    @Environment(\.locale) private var localizationLocale
    let currentVersion: String
    @AppStorage(L10n.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    @ObservedObject private var usage = UsageAnalytics.shared
    @ObservedObject private var diagnostics = DiagnosticCenter.shared
    @State private var showingDiagnosticSheet = false

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("RawLab").font(.title2.bold())
                    Text(L10n.format("版本 %@", currentVersion)).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text(L10n.text("项目与作者")).font(.headline)
            Link(L10n.text("GitHub 仓库"), destination: URL(string: "https://github.com/dancancer/RawLab")!)
            Link(L10n.text("作者的小红书主页"), destination: URL(string: "https://www.xiaohongshu.com/user/profile/6474b1560000000010037c8e")!)
            Divider()
            Picker(L10n.text("语言"), selection: $languagePreference) {
                ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0.rawValue) }
            }.id(localizationLocale.identifier).accessibilityIdentifier("settings.language")
            Divider()
            Toggle(L10n.text("允许使用统计"), isOn: Binding(get: { usage.isEnabled }, set: { usage.setEnabled($0) }))
                .disabled(!usage.isAvailable && !usage.isEnabled)
            Text(L10n.text(usage.statusKey)).font(.callout).foregroundStyle(.secondary)
            Text([
                L10n.text("开启后，由阿里云处理功能使用次数，数据存储在中国大陆；SDK 可能采集设备标识、设备与系统信息、网络/IP、地区及会话信息。"),
                L10n.text("不采集照片、预览、文件名、路径、EXIF 或 AI 内容。关闭后停止新采集，已发出的请求无法撤回。")
            ].joined(separator: L10n.language == .zhHans || L10n.language == .ja ? "" : " "))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("为统计活跃设备数，应用会在本机保存一个随机生成的安装标识，不含个人信息；关闭统计时一并删除。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link(L10n.text("阿里云隐私政策"), destination: URL(string: "https://terms.alicdn.com/legal-agreement/terms/privacy_policy_full/20240308104330389/20240308104330389.html")!)
                .font(.callout)
            Divider()
            Toggle(
                L10n.text("记录详细诊断日志"),
                isOn: Binding(
                    get: { diagnostics.isRecording },
                    set: { diagnostics.setRecordingEnabled($0) }
                )
            )
            .accessibilityIdentifier("diagnostics.recording")
            Text(L10n.text(diagnostics.statusSummaryKey))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L10n.text("保存到设备…")) {
                    saveDiagnosticPackage(userNote: nil)
                }
                .disabled(!diagnostics.hasExportableLogs && !diagnostics.isRecording)
                .accessibilityIdentifier("diagnostics.saveZip")

                Button(L10n.text("上传或预览日志…")) {
                    diagnostics.refreshState()
                    showingDiagnosticSheet = true
                }
                .accessibilityIdentifier("diagnostics.openSheet")
            }
            if let key = diagnostics.feedbackMessageKey {
                Text(L10n.text(key))
                    .font(.callout)
                    .foregroundStyle(diagnostics.feedbackIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(L10n.text("关于 RawLab"))
        .onAppear { diagnostics.refreshState() }
        .sheet(isPresented: $showingDiagnosticSheet) {
            MacDiagnosticSubmissionSheet(
                diagnostics: diagnostics,
                onSaveToDevice: { note in saveDiagnosticPackage(userNote: note) }
            )
        }
    }

    @MainActor
    private func saveDiagnosticPackage(userNote: String?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "RawLab-Diagnostics.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            _ = try diagnostics.store.exportZip(to: destination, userNote: userNote, stopActiveRecording: true)
            diagnostics.recordExportSuccess()
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            diagnostics.recordExportFailure()
        }
    }
}

private struct MacDiagnosticSubmissionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var diagnostics: DiagnosticCenter
    let onSaveToDevice: (String?) -> Void

    @State private var userNote = ""
    @State private var previewContent: String?
    @State private var copiedCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("故障诊断与错误日志")).font(.headline)
            Text(L10n.text("诊断包仅包含应用版本、系统环境、操作步骤摘要与错误代码，不包含照片内容、文件名或个人路径。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                L10n.text("记录详细诊断日志"),
                isOn: Binding(
                    get: { diagnostics.isRecording },
                    set: { diagnostics.setRecordingEnabled($0) }
                )
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("问题简述（选填，勿填个人隐私）")).font(.callout)
                TextField("", text: $userNote)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("diagnostics.note")
            }

            if let reportID = diagnostics.lastUploadedReportID {
                HStack(spacing: 8) {
                    Text(L10n.format("诊断码：%@", reportID))
                        .font(.system(.body, design: .monospaced).bold())
                        .textSelection(.enabled)
                    Button(L10n.text(copiedCode ? "已复制" : "复制诊断码")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reportID, forType: .string)
                        copiedCode = true
                    }
                    .accessibilityIdentifier("diagnostics.copyCode")
                }
                .padding(10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            if let key = diagnostics.feedbackMessageKey {
                Text(L10n.text(key))
                    .font(.callout)
                    .foregroundStyle(diagnostics.feedbackIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let previewContent {
                ScrollView {
                    Text(previewContent)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 180)
                .padding(8)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 10) {
                Button(L10n.text("保存到设备…")) {
                    onSaveToDevice(userNote)
                }
                .disabled((!diagnostics.hasExportableLogs && !diagnostics.isRecording) || diagnostics.isUploading)

                Button(L10n.text(diagnostics.isUploading ? "正在上传…" : "一键云端上传")) {
                    copiedCode = false
                    Task { _ = await diagnostics.uploadLogs(userNote: userNote) }
                }
                .buttonStyle(.borderedProminent)
                .disabled((!diagnostics.hasExportableLogs && !diagnostics.isRecording) || diagnostics.isUploading)
                .accessibilityIdentifier("diagnostics.upload")

                Button(L10n.text(previewContent == nil ? "预览日志" : "收起预览")) {
                    if previewContent != nil {
                        previewContent = nil
                    } else {
                        previewContent = (try? diagnostics.store.buildReportBundle(userNote: userNote))?.previewText
                            ?? L10n.text("暂无可导出的错误日志。")
                    }
                }
                .disabled(!diagnostics.hasExportableLogs && !diagnostics.isRecording)
                .accessibilityIdentifier("diagnostics.preview")

                if diagnostics.hasExportableLogs {
                    Button(L10n.text("清除日志"), role: .destructive) {
                        previewContent = nil
                        copiedCode = false
                        diagnostics.clearLogs()
                    }
                    .disabled(diagnostics.isUploading)
                    .accessibilityIdentifier("diagnostics.clear")
                }

                Spacer()
                Button(L10n.text("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
