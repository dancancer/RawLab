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
            if model.aiControlsVisible { aiControls }
            ordinaryControls.disabled(model.settings.aiDenoiseEnabled || model.result == nil)
        }.frame(maxWidth: 720)
    }

    private var ordinaryControls: some View {
        Group {
            if model.settings.hasLegacyDenoise {
                legacyControls
            } else {
                VStack(spacing: 0) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { modeControls; groupActions }
                        VStack(spacing: 0) { modeControls; groupActions }
                    }.frame(minHeight: 28).padding(.bottom, 4)
                    parameterRow(.luma)
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

    private var aiControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle(L10n.text("AI 降噪（实验）"), isOn: Binding(
                    get: { model.settings.aiDenoiseEnabled || model.aiManuallyRequested },
                    set: { model.setAIEnabled($0) }
                )).toggleStyle(.switch).controlSize(.mini)
                    .disabled(!model.canStartAI && !model.settings.aiDenoiseEnabled)
                    .accessibilityIdentifier("denoise.ai.enabled")
                Spacer(minLength: 8)
                if model.aiState.isRunning {
                    Button(L10n.text("取消")) { model.cancelAIDenoise() }
                        .accessibilityIdentifier("denoise.ai.cancel")
                } else if case .failed = model.aiState {
                    Button(L10n.text("重试")) { model.requestAIDenoise() }.disabled(!model.canStartAI)
                        .accessibilityIdentifier("denoise.ai.retry")
                } else if case .cancelled = model.aiState {
                    Button(L10n.text("重试")) { model.requestAIDenoise() }.disabled(!model.canStartAI)
                        .accessibilityIdentifier("denoise.ai.retry")
                }
            }.font(.system(size: 12))
            switch model.aiState {
            case .running(_, let done, let total):
                if total > 0 { ProgressView(value: Double(done), total: Double(total)).controlSize(.small) }
                else { ProgressView().controlSize(.small) }
                Text(model.aiState.progressTitle + (total > 0 ? " · \(done)/\(total)" : ""))
                    .accessibilityIdentifier("denoise.ai.progress")
            case .failed(let message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("denoise.ai.error")
            case .cancelled: Text(L10n.text("AI 降噪已取消。"))
            case .ready: Text(L10n.text("已应用 AI 降噪；曝光和外观调整复用结果。"))
            case .idle:
                Text(L10n.text(model.canStartAI ? "支持多种 RAW 格式。首次处理时间取决于设备，完成后可复用结果。" : "此照片或构建尚不能使用 AI 降噪。"))
            }
            if model.settings.aiDenoiseEnabled && model.aiState == .ready {
                Text(L10n.text("AI 已接管降噪，普通降噪参数会保留。白平衡变化需要重新处理。"))
            } else if model.settings.aiDenoiseEnabled {
                Text(L10n.text("普通降噪参数已保留，关闭 AI 降噪即可恢复。"))
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeControls: some View {
        HStack(spacing: 12) {
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
            }.pickerStyle(.segmented).controlSize(.small).fixedSize()
                .id(localizationLocale.identifier)
                .accessibilityIdentifier("denoise.preset")
        }.font(.system(size: 12)).fixedSize()
    }

    private var groupActions: some View {
        HStack(spacing: 12) {
            Button(L10n.text(advanced ? "收起精细调整" : "展开精细调整")) {
                ParameterValueField.cancelPendingInputs()
                advanced.toggle()
            }
                .buttonStyle(.borderless).font(.system(size: 11))
                .accessibilityIdentifier("denoise.advanced")
            Button {
                ParameterValueField.cancelPendingInputs()
                onReset()
            } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 28, height: 28)
            }.buttonStyle(.borderless).help(L10n.text("重置降噪"))
                .accessibilityLabel(L10n.text("重置降噪"))
                .accessibilityIdentifier("denoise.reset")
                .disabled(model.settings.waveletNoiseReduction == nil)
        }.fixedSize()
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
            Text(model.settings.denoiseMode == 3 ? L10n.text("旧版 FBDD") : L10n.text("旧版色度降噪"))
                .font(.caption).foregroundStyle(.secondary)
            if model.settings.denoiseMode == 3 {
                Picker(L10n.text("旧版 FBDD"), selection: $model.settings.rawNoiseReduction) {
                    ForEach(RawNoiseReductionLevel.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).frame(width: 300).id(localizationLocale.identifier)
            } else {
                Picker(L10n.text("旧版色度降噪"), selection: $model.settings.denoiseMode) {
                    ForEach(ChromaNoiseReductionMode.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).frame(width: 340).id(localizationLocale.identifier)
                    .accessibilityIdentifier("chromaNoiseReduction.mode")
            }
            Button(L10n.text("使用可调降噪")) { model.settings.applyDenoisePreset(.detail) }
                .buttonStyle(.link).accessibilityIdentifier("denoise.upgrade")
        }
    }
}
