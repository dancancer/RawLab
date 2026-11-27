import RawLabKit
import SwiftUI
import AppKit

struct DenoiseControls: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    var onExpansionChanged: (Bool) -> Void = { _ in }
    var onReset: () -> Void = {}
    @State private var advanced = false

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 8) {
            if model.aiControlsVisible { MacAIDenoiseControls(model: model) }
            ordinaryControls.disabled(model.settings.aiDenoiseEnabled || model.result == nil)
        }.frame(maxWidth: 720)
    }

    private var ordinaryControls: some View {
        Group {
            if model.settings.hasLegacyFBDD {
                legacyControls
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    modeControls
                    parameterRow(.luma)
                    groupActions
                    if advanced {
                        parameterRow(.chroma)
                        parameterRow(.coarse)
                    }
                    if !model.settings.waveletSettings.enabled && !model.settings.aiDenoiseEnabled {
                        Text(L10n.text("降噪已停用，参数会保留。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.top, 4)
                            .accessibilityIdentifier("denoise.disabledReason")
                    }
                }
            }
        }
    }

    private var modeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L10n.text("降噪"), isOn: Binding(
                get: { model.settings.waveletSettings.enabled },
                set: { enabled in
                    ParameterValueField.cancelPendingInputs()
                    model.settings.setDenoiseEnabled(enabled)
                }
            )).toggleStyle(.switch).controlSize(.mini)
                .accessibilityIdentifier("denoise.enabled")
            Picker(L10n.text("预设"), selection: Binding(
                get: { model.settings.waveletSettings.preset },
                set: { preset in
                    ParameterValueField.cancelPendingInputs()
                    model.settings.applyDenoisePreset(preset)
                }
            )) {
                Text(DenoisePreset.detail.title).tag(DenoisePreset.detail)
                Text(DenoisePreset.clean.title).tag(DenoisePreset.clean)
                if model.settings.waveletSettings.preset == .custom {
                    Text(DenoisePreset.custom.title).tag(DenoisePreset.custom).disabled(true)
                }
            }.pickerStyle(.menu).controlSize(.small)
                .id(localizationLocale.identifier)
                .accessibilityIdentifier("denoise.preset")
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupActions: some View {
        HStack(spacing: 8) {
            Button {
                ParameterValueField.cancelPendingInputs()
                advanced.toggle()
            } label: {
                Text(L10n.text(advanced ? "收起精细调整" : "展开精细调整"))
                    .fixedSize(horizontal: false, vertical: true)
            }
                .buttonStyle(.borderless).font(.system(size: 11))
                .accessibilityIdentifier("denoise.advanced")
            Spacer(minLength: 0)
            Button {
                ParameterValueField.cancelPendingInputs()
                onReset()
            } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 28, height: 28)
            }.buttonStyle(.borderless).help(L10n.text("重置降噪"))
                .accessibilityLabel(L10n.text("重置降噪"))
                .accessibilityIdentifier("denoise.reset")
                .disabled(!model.isAdjustmentModified(.tool(.denoise)))
        }
    }

    private func parameterRow(_ parameter: DenoiseParameter) -> some View {
        ParameterRow(title: parameter.shortTitle, value: Binding(
            get: { model.settings.waveletSettings[keyPath: parameter.keyPath] },
            set: { model.settings.setDenoiseParameter(parameter, to: $0) }
        ), range: 0...100, defaultValue: parameter.defaultValue,
        identifier: "denoise.value.\(parameter.rawValue)", onEditingChanged: model.setInteracting)
            .disabled(!model.settings.waveletSettings.enabled)
    }

    private var legacyControls: some View {
        VStack(spacing: 4) {
            Text(L10n.text("旧版 FBDD"))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text("旧版 FBDD"), selection: $model.settings.rawNoiseReduction) {
                ForEach(RawNoiseReductionLevel.allCases) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.menu).labelsHidden().id(localizationLocale.identifier)
            Button(L10n.text("使用可调降噪")) { model.settings.applyDenoisePreset(.detail) }
                .buttonStyle(.link).accessibilityIdentifier("denoise.upgrade")
        }
    }
}

struct MacAIDenoiseControls: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    @State private var showingLicenses = false
    @State private var confirmingRemoveModel = false

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { toggle.fixedSize(); Spacer(minLength: 0); action }
                VStack(alignment: .leading, spacing: 4) { toggle; action }
            }.font(.system(size: 12))
            if model.aiModelDownloadVisible {
                modelPackageSection
            }
            switch model.aiState {
            case .running(_, let done, let total):
                if total > 0 { ProgressView(value: Double(done), total: Double(total)).controlSize(.small) }
                else { ProgressView().controlSize(.small) }
                Text(model.aiState.progressTitle + (total > 0 ? " · \(done)/\(total)" : ""))
                    .accessibilityIdentifier("denoise.ai.progress")
            case .failed(let message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("denoise.ai.error")
            case .cancelled:
                Text(L10n.text("AI 降噪已取消。"))
            case .ready:
                Text(L10n.text("已应用 AI 降噪；曝光和外观调整复用结果。"))
                    .accessibilityIdentifier("denoise.ai.ready")
            case .idle:
                if !model.canStartAI {
                    if !model.aiModelDownloadVisible || model.hasAIModel {
                        Text(L10n.text("此照片或构建尚不能使用 AI 降噪。"))
                    }
                } else if !model.settings.isHDREditing {
                    Text(L10n.text("支持多种 RAW 格式。首次处理时间取决于设备，完成后可复用结果。"))
                }
            }
            if !model.settings.isHDREditing && (model.settings.activeAIDenoise || model.aiManuallyRequested) {
                ParameterRow(title: L10n.text("AI 降噪强度"), value: Binding(
                    get: { model.settings.aiDenoiseStrength },
                    set: {
                        guard $0.isFinite, (0...100).contains($0) else { return }
                        model.settings.aiDenoiseStrength = $0
                    }
                ), range: 0...100, defaultValue: 100, unit: "%", identifier: "denoise.ai.strength",
                onEditingChanged: model.setInteracting, compact: true)
                    .foregroundStyle(.primary)
                    .disabled(model.result == nil)
            }
            if !model.settings.isHDREditing && model.settings.aiDenoiseEnabled {
                Text(L10n.text(model.aiState == .ready ? "AI 已接管降噪，普通降噪参数会保留。白平衡变化需要重新处理。" :
                    "普通降噪参数已保留，关闭 AI 降噪即可恢复。"))
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheet(isPresented: $showingLicenses) {
                MacAIModelLicenseSheet(installedDirectory: model.aiModelManager.store.installedPackageURL())
                    .environment(\.locale, localizationLocale)
            }
            .alert(L10n.text("确定删除已下载的 AI 降噪模型？"), isPresented: $confirmingRemoveModel) {
                Button(L10n.text("删除"), role: .destructive) { model.removeDownloadedAIModel() }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                if case .installed(_, let unpackedBytes) = model.aiModelPackageState {
                    Text(L10n.format("删除后将释放约 %@ MB 磁盘空间，需要时可重新下载。",
                                     AIModelPackageError.formatMegabytes(unpackedBytes)))
                }
            }
    }

    @ViewBuilder private var modelPackageSection: some View {
        switch model.aiModelPackageState {
        case .notInstalled(let downloadBytes, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("尚未下载 AI 降噪模型（约 %@ MB）。",
                                 AIModelPackageError.formatMegabytes(downloadBytes)))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("denoise.ai.model.notInstalled")
                Text(L10n.text("模型（DualDn、Restormer）仅限非商业用途。"))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("denoise.ai.model.licenseNotice")
                HStack(spacing: 8) {
                    Button(L10n.text("下载模型")) { model.downloadAIModel() }
                        .controlSize(.small)
                        .disabled(model.exporting)
                        .accessibilityIdentifier("denoise.ai.model.download")
                    Button(L10n.text("查看许可")) { showingLicenses = true }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("denoise.ai.model.license")
                }
            }
        case .downloading(let completed, let total):
            VStack(alignment: .leading, spacing: 4) {
                if total > 0 {
                    ProgressView(value: Double(completed), total: Double(total)).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
                HStack(spacing: 8) {
                    Text(total > 0
                         ? L10n.format("正在下载 AI 降噪模型… %@ / %@ MB",
                                       AIModelPackageError.formatProgressMegabytes(completed),
                                       AIModelPackageError.formatMegabytes(total))
                         : L10n.text("正在下载 AI 降噪模型…"))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("denoise.ai.model.progress")
                    Spacer(minLength: 0)
                    Button(L10n.text("取消")) { model.cancelAIModelDownload() }
                        .controlSize(.small)
                        .accessibilityIdentifier("denoise.ai.model.cancel")
                }
            }
        case .verifying:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView().controlSize(.small)
                HStack(spacing: 8) {
                    Text(L10n.text("正在校验 AI 降噪模型…"))
                        .accessibilityIdentifier("denoise.ai.model.verifying")
                    Spacer(minLength: 0)
                    Button(L10n.text("取消")) { model.cancelAIModelDownload() }
                        .controlSize(.small)
                        .accessibilityIdentifier("denoise.ai.model.cancel")
                }
            }
        case .installing:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView().controlSize(.small)
                HStack(spacing: 8) {
                    Text(L10n.text("正在安装 AI 降噪模型…"))
                        .accessibilityIdentifier("denoise.ai.model.installing")
                    Spacer(minLength: 0)
                    Button(L10n.text("取消")) { model.cancelAIModelDownload() }
                        .controlSize(.small)
                        .accessibilityIdentifier("denoise.ai.model.cancel")
                }
            }
        case .cancelled(let downloadBytes, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("已取消下载 AI 降噪模型。"))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("denoise.ai.model.cancelled")
                Text(L10n.format("尚未下载 AI 降噪模型（约 %@ MB）。",
                                 AIModelPackageError.formatMegabytes(downloadBytes)))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("模型（DualDn、Restormer）仅限非商业用途。"))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L10n.text("下载模型")) { model.downloadAIModel() }
                        .controlSize(.small)
                        .disabled(model.exporting)
                        .accessibilityIdentifier("denoise.ai.model.download")
                    Button(L10n.text("查看许可")) { showingLicenses = true }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("denoise.ai.model.license")
                }
            }
        case .failed(let error, _, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(error.macLocalizedMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("denoise.ai.model.error")
                Text(L10n.text("模型（DualDn、Restormer）仅限非商业用途。"))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L10n.text("重试")) { model.downloadAIModel() }
                        .controlSize(.small)
                        .disabled(model.exporting)
                        .accessibilityIdentifier("denoise.ai.model.retry")
                    Button(L10n.text("查看许可")) { showingLicenses = true }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("denoise.ai.model.license")
                }
            }
        case .installed(.downloaded, let unpackedBytes):
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("已下载 AI 降噪模型（约 %@ MB）。",
                                 AIModelPackageError.formatMegabytes(unpackedBytes)))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("denoise.ai.model.installed")
                HStack(spacing: 8) {
                    Button(L10n.text("查看许可")) { showingLicenses = true }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("denoise.ai.model.license")
                    Spacer(minLength: 0)
                    Button(L10n.text("删除已下载模型")) { confirmingRemoveModel = true }
                        .buttonStyle(.borderless)
                        .disabled(!model.canRemoveDownloadedAIModel)
                        .accessibilityIdentifier("denoise.ai.model.remove")
                }
            }
        case .installed(.bundled, _), .installed(.override, _), .unavailable:
            EmptyView()
        }
    }

    private var toggle: some View {
        Toggle(L10n.text("AI 降噪（实验）"), isOn: Binding(
            get: { model.settings.activeAIDenoise || model.aiManuallyRequested },
            set: { model.setAIEnabled($0) }
        )).toggleStyle(.switch).controlSize(.mini)
            .disabled(!model.canStartAI && !model.settings.activeAIDenoise)
            .accessibilityIdentifier("denoise.ai.enabled")
    }

    @ViewBuilder private var action: some View {
        switch model.aiState {
        case .running:
            Button(L10n.text("取消")) { model.cancelAIDenoise() }
                .accessibilityIdentifier("denoise.ai.cancel")
        case .failed, .cancelled:
            Button(L10n.text("重试")) { model.requestAIDenoise() }.disabled(!model.canStartAI)
                .accessibilityIdentifier("denoise.ai.retry")
        default:
            EmptyView()
        }
    }
}

private struct MacAIModelLicenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let installedDirectory: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("AI 降噪模型许可")).font(.headline)
            Text(L10n.text("以下模型仅限非商业用途，各自沿用原作者的许可，不适用 RawLab 的 GPL 许可。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    licenseBlock(
                        title: "DualDn (CC BY-NC 4.0)",
                        text: dualDnLicenseText,
                        url: URL(string: "https://creativecommons.org/licenses/by-nc/4.0/")!
                    )
                    licenseBlock(
                        title: "Restormer (Academic Public License)",
                        text: restormerLicenseText,
                        url: URL(string: "https://github.com/swz30/Restormer")!
                    )
                }
            }
            .frame(height: 300)
            HStack(spacing: 10) {
                if let folder = licenseDirectoryURL {
                    Button(L10n.text("打开许可文件夹")) {
                        NSWorkspace.shared.open(folder)
                    }
                }
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func licenseBlock(title: String, text: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Link(url.absoluteString, destination: url).font(.caption)
            }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var licenseDirectoryURL: URL? {
        // 去内置模型发布包中 Licenses/DualDn 只放运行时许可；优先打开已下载的模型目录，未下载时再回退到应用内目录。
        if let installedDirectory, FileManager.default.fileExists(atPath: installedDirectory.path) {
            return installedDirectory
        }
        if let dir = Bundle.main.url(forResource: "DualDn", withExtension: nil, subdirectory: "Licenses"),
           FileManager.default.fileExists(atPath: dir.path) {
            return dir
        }
        if let licenses = Bundle.main.url(forResource: "Licenses", withExtension: nil),
           FileManager.default.fileExists(atPath: licenses.path) {
            return licenses
        }
        return nil
    }

    private var dualDnLicenseText: String {
        let candidates: [URL?] = [
            installedDirectory?.appendingPathComponent("DualDn-LICENSE.txt"),
            Bundle.main.url(forResource: "LICENSE", withExtension: nil, subdirectory: "Licenses/DualDn"),
            Bundle.main.url(forResource: "DualDn-LICENSE", withExtension: "txt", subdirectory: "AI/DualDn"),
        ]
        for case let url? in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return """
        Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)
        Copyright (c) 2024 OpenImagingLab
        NonCommercial — You may not use the model weights or converted artifacts for commercial purposes.
        Full license: https://creativecommons.org/licenses/by-nc/4.0/
        """
    }

    private var restormerLicenseText: String {
        let candidates: [URL?] = [
            installedDirectory?.appendingPathComponent("Restormer-LICENSE.txt"),
            Bundle.main.url(forResource: "Restormer-LICENSE", withExtension: "txt", subdirectory: "Licenses/DualDn"),
            Bundle.main.url(forResource: "Restormer-LICENSE", withExtension: "txt", subdirectory: "AI/DualDn"),
        ]
        for case let url? in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return """
        Restormer Academic Public License
        Free for non-commercial, research, academic, and personal use only. Commercial use is not permitted without upstream authorization.
        Source: https://github.com/swz30/Restormer
        """
    }
}

extension AIModelPackageError {
    var macLocalizedMessage: String {
        switch self {
        case .networkUnavailable:
            return L10n.text("无法连接网络，请检查网络后重试。")
        case .networkTimeout:
            return L10n.text("下载超时，请检查网络后重试。")
        case .httpNotFound:
            return L10n.text("服务器上暂未找到模型文件（HTTP 404），请稍后重试或更新应用。")
        case .httpStatus(let code):
            return L10n.format("下载失败（HTTP %@），请稍后重试。", String(code))
        case .insufficientDiskSpace(let requiredBytes, _):
            return L10n.format("磁盘可用空间不足，至少需要约 %@ MB。", Self.formatMegabytes(requiredBytes))
        case .diskFull:
            return L10n.text("磁盘可用空间不足，请清理空间后重试。")
        case .archiveSizeMismatch:
            return L10n.text("下载的模型文件大小与校验信息不符，已清除临时文件，请重试。")
        case .archiveDigestMismatch:
            return L10n.text("下载的模型文件校验失败，已清除临时文件，请重试。")
        case .memberVerificationFailed, .archiveExtractionFailed:
            return L10n.text("模型压缩包校验失败，已清除临时文件，请重试。")
        case .insecureURL:
            return L10n.text("模型下载地址不安全，已阻止下载。")
        case .cancelled:
            return L10n.text("已取消下载 AI 降噪模型。")
        case .removeFailed:
            return L10n.text("无法删除已下载的模型文件，请重试。")
        case .invalidCatalog, .networkError, .fileSystemError:
            return L10n.text("下载或安装模型失败，请重试。")
        }
    }
}
