import SwiftUI

struct AISettingsView: View {
    @ObservedObject var settings: AISettings
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = AIConfiguration()
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var status = ""
    @State private var error: String?
    @State private var checking = false
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("AI 服务").font(.headline)
                Spacer()
                Text("用户 API").font(.caption).foregroundStyle(.secondary)
            }
            Form {
                TextField("API 地址", text: $configuration.baseURL)
                    .textContentType(.URL).accessibilityIdentifier("ai-base-url")
                TextField("模型", text: $configuration.model).accessibilityIdentifier("ai-model")
                SecureField(hasSavedKey ? "API Key（已保存，留空不更改）" : "API Key", text: $key)
                    .accessibilityIdentifier("ai-api-key")
            }.textFieldStyle(.roundedBorder)
            HStack {
                Label(hasSavedKey ? "密钥已保存在 Keychain" : "密钥保存在本机 Keychain", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if hasSavedKey {
                    Button("删除密钥", role: .destructive) {
                        do { try settings.keychain.remove(configuration); key = ""; refreshKeyStatus() }
                        catch { self.error = error.localizedDescription }
                    }.font(.caption).disabled(checking)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if !status.isEmpty {
                Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("测试连接", action: test).disabled(checking)
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try settings.save(configuration, key: key); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(checking)
            }
        }.padding(24).frame(width: 540)
            .onAppear { configuration = settings.configuration; refreshKeyStatus() }
            .onChange(of: configuration.baseURL) { _, _ in
                key = ""; status = ""; error = nil; checkTask?.cancel(); checking = false; refreshKeyStatus()
            }
            .onChange(of: configuration.model) { _, _ in status = ""; error = nil; checkTask?.cancel(); checking = false }
            .onDisappear { checkTask?.cancel(); key = "" }
    }

    private func refreshKeyStatus() { hasSavedKey = (try? settings.keychain.read(configuration)) != nil }

    private func test() {
        error = nil; status = ""
        do {
            let config = try configuration.validated()
            let secret = key.isEmpty ? try settings.keychain.read(config) : key
            guard let secret, !secret.isEmpty else { throw AIError.message("请填写此服务的 API Key。") }
            checking = true
            checkTask = Task { @MainActor in
                defer { if !Task.isCancelled { checking = false } }
                do {
                    let models = try await AIService().models(configuration: config, key: secret)
                    try Task.checkCancellation()
                    status = models.contains(config.model) ? "连接成功，找到 \(config.model)。图片能力将在生成时验证。" :
                        "连接成功，但模型列表中没有 \(config.model)，请核对名称。"
                } catch is CancellationError {} catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}
