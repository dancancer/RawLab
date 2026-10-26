import SwiftUI

struct SoftwareUpdateView: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var updates: DesktopUpdateController
    @ObservedObject var legacy: UpdateChecker
    var settings = true
    private var detailFont: Font { .system(size: textSize.isAccessibilitySize ? 18 : 13) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text(settings ? "软件更新" : "RawLab 更新")).font(.system(size: textSize.isAccessibilitySize ? 28 : 20, weight: .bold))
                Text(L10n.format("版本 %@", updates.currentVersion)).foregroundStyle(.secondary)
                if settings {
                    Toggle(L10n.text("自动检查更新"), isOn: Binding(get: { updates.preferences.automaticCheck }, set: {
                        updates.setAutomaticCheck($0); legacy.automatic = updates.preferences.automaticCheck
                    })).disabled(updates.storageError != nil || updates.requiresRecovery || updates.requiresStartupHealthCheck).accessibilityIdentifier("updates.automaticCheck")
                    Toggle(L10n.text("自动下载并在退出时安装"), isOn: Binding(get: { updates.preferences.automaticInstall }, set: updates.setAutomaticInstall))
                        .disabled(updates.unavailableReason != nil || updates.requiresRecovery || updates.requiresStartupHealthCheck).accessibilityIdentifier("updates.automaticInstall")
                    Text(L10n.text("自动安装默认关闭。安装前会保存已提交的编辑，并等待草稿和任务处理完成。"))
                        .font(detailFont).foregroundStyle(.secondary)
                    Divider()
                }
                if updates.unavailableReason != nil {
                    Label(L10n.text("此安装暂不支持自动安装更新"), systemImage: "info.circle")
                    Text(legacy.status).font(detailFont)
                } else {
                    Text(L10n.text(UpdatePresentation.phase(updates.state.phase))).font(.system(size: textSize.isAccessibilitySize ? 22 : 13, weight: .semibold))
                }
                if let release = updates.state.release {
                    Text(L10n.format("发现新版本 %@", release.version)).font(.system(size: textSize.isAccessibilitySize ? 22 : 13, weight: .semibold))
                    if !release.notes.isEmpty { Text(release.notes).textSelection(.enabled) }
                } else if let release = legacy.available, updates.unavailableReason != nil {
                    Text(L10n.format("发现新版本 %@", release.version)).font(.system(size: textSize.isAccessibilitySize ? 22 : 13, weight: .semibold))
                    if !release.notes.isEmpty { Text(release.notes).textSelection(.enabled) }
                }
                if updates.state.phase == .downloading {
                    ProgressView(value: updates.state.progress).accessibilityLabel(L10n.text("正在下载更新…"))
                    Text(updates.state.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                } else if updates.state.phase == .checking || updates.state.phase == .verifying || updates.preparingInstallation {
                    ProgressView().controlSize(.small)
                }
                if let error = updates.startupTrustError, updates.requiresStartupHealthCheck, !updates.requiresRecovery {
                    Text(error).font(detailFont).textSelection(.enabled)
                    Button(L10n.text("重试")) { updates.retryStartup?() }
                        .disabled(updates.checkingStartupTrust).accessibilityIdentifier("updates.retryStartup")
                }
                if let failure = updates.state.failure {
                    Label(L10n.text("更新未完成，请查看恢复说明"), systemImage: "exclamationmark.triangle")
                    Text(L10n.text(UpdatePresentation.phase(failure.stage))).font(detailFont)
                    DisclosureGroup(L10n.text("错误详情")) {
                        Text(failure.code + (failure.detail.isEmpty ? "" : "\n" + failure.detail)).font(.caption).textSelection(.enabled)
                    }
                }
                if let error = updates.storageError {
                    Text(error).font(detailFont).textSelection(.enabled)
                    Text(L10n.text(updates.canRepairState ? "保留损坏文件并重建更新设置。重启后会检查数据，自动更新保持关闭。" : "无法确认更新或恢复状态，请保留全部文件并联系支持。"))
                    if updates.canRepairState {
                        Button(L10n.text("重建更新设置"), action: updates.repairState).accessibilityIdentifier("updates.repairState")
                    }
                }
                if updates.preferences.stateRepairReceipt != nil {
                    Text(L10n.text(updates.recoveryNeedsRestart ? "更新设置已重建，请退出并重新打开应用" : "数据检查未通过，编辑暂未开放。请保留文件并联系支持。"))
                    if let error = updates.recoveryError { Text(error).font(detailFont).textSelection(.enabled) }
                } else if updates.requiresRecovery {
                    Text(L10n.text(updates.recoveryNeedsRestart ? "数据已恢复，请退出并重新打开应用" : "请先安装更新前的同一可信版本，再恢复数据。当前数据会另存保留；恢复后需退出并重新打开应用。"))
                    if updates.recovering { ProgressView(L10n.text("正在恢复更新前的数据…")) }
                    if let error = updates.recoveryError { Text(error).font(detailFont).textSelection(.enabled) }
                    if updates.canRestorePreviousData {
                        Button(L10n.text("恢复更新前的数据")) { Task { await updates.restorePreviousData() } }
                            .accessibilityIdentifier("updates.restore")
                    }
                }
                ForEach(updates.state.blockers, id: \.self) { Text(L10n.text(UpdatePresentation.blocker($0))).font(detailFont) }
                if updates.state.choice == .onQuit || updates.state.choice == .automaticOnQuit {
                    Text(L10n.text("将在下次正常退出时重新检查并安装"))
                }
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }
                Divider()
                DisclosureGroup(L10n.text("安装支持与恢复说明")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Mac 需要同架构、签名身份匹配的应用。Windows 需要 x64 当前用户 Setup 安装版。旧 ZIP 请先从官方发布页迁移到支持更新的版本。"))
                        Text(L10n.text("查看此说明不会启用自动安装。失败后请保留现有应用和数据，使用官方可信安装包恢复；不要用旧版覆盖新版编辑记录。"))
                    }.font(detailFont)
                }
                Link(L10n.text("官方手动下载"), destination: UpdateRelease.repository.appendingPathComponent("releases"))
                if let path = updates.state.backupPath {
                    Button(L10n.text("查看更新前的数据备份")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                if let path = updates.preferences.recoveryReceipt {
                    Button(L10n.text("查看恢复时保留的数据")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                if let path = updates.stateArchive {
                    Button(L10n.text("查看保留的更新状态文件")) { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: textSize.isAccessibilitySize ? 22 : 13))
            .frame(minWidth: 420, idealWidth: 560, minHeight: 320, idealHeight: 600)
            .accessibilityIdentifier(settings ? "updates.settings" : "updates.prompt")
    }

    @ViewBuilder private var actions: some View {
        Button(L10n.text("检查更新")) {
            if updates.unavailableReason != nil { Task { await legacy.check(manual: true) } }
            else { updates.check(manual: true) }
        }.disabled(updates.requiresRecovery || legacy.checking || updates.unavailableReason == nil && !updates.canCheck)
            .accessibilityIdentifier("updates.check")
        if updates.canDownload {
            Button(L10n.text("安装更新"), action: updates.download).accessibilityIdentifier("updates.download")
            Button(L10n.text("跳过此版本")) { updates.skip(); if !settings && updates.storageError == nil { dismiss() } }
            Button(L10n.text("稍后提醒")) { updates.remindLater(); if !settings && updates.storageError == nil { dismiss() } }
        }
        if updates.canChooseInstall {
            Menu(L10n.text("选择安装时间")) {
                Button(L10n.text("立即重启安装")) { updates.choose(.restartNow) }
                Button(L10n.text("任务结束后安装")) { updates.choose(.afterTasks) }
                Button(L10n.text("下次退出时安装")) { updates.choose(.onQuit) }
            }.accessibilityIdentifier("updates.installChoice")
        }
        if updates.canCancel { Button(L10n.text("取消更新"), action: updates.cancel) }
        if updates.state.phase == .failed && updates.canCheck { Button(L10n.text("重试"), action: updates.retry) }
    }
}

enum UpdatePresentation {
    static func phase(_ phase: UpdatePhase) -> String {
        switch phase {
        case .idle: return "尚未发现可安装的更新"
        case .checking: return "正在检查更新…"
        case .available: return "有可用更新"
        case .downloading: return "正在下载更新…"
        case .verifying: return "正在校验并准备更新…"
        case .packageReady: return "更新已校验，请选择安装时间"
        case .waitingForTasks: return "正在等待编辑和任务处理完成"
        case .readyToInstall: return "已具备安装条件"
        case .installing: return "正在安装更新…"
        case .pendingRestart: return "等待重新启动"
        case .complete: return "更新已完成"
        case .failed: return "更新失败"
        }
    }
    static func blocker(_ value: String) -> String {
        switch value {
        case "draft": return "请返回编辑器应用或放弃草稿和未提交输入"
        case "unsaved": return "照片编辑尚未保存"
        case "save": return "照片编辑保存失败，请先重试保存"
        case "journal": return "批量任务记录尚未安全保存"
        default: return "正在等待预览、导出或批量任务结束"
        }
    }
}
