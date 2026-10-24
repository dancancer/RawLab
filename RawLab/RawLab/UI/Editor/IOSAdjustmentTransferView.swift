import PhotosUI
import SwiftUI

enum IOSAdjustmentSheet: String, Identifiable { case copy, paste, history, presets, presetSave, presetApply; var id: String { rawValue } }
enum IOSAdjustmentAction: Equatable { case copy, paste, history, undo, redo, presetSave, presetApply(AdjustmentPreset) }

struct IOSAdjustmentTransferView: View {
    @ObservedObject var model: RawEditorViewModel
    let kind: IOSAdjustmentSheet
    let settings: RawSettings
    var preset: AdjustmentPreset?
    @Environment(\.dismiss) private var dismiss
    @State private var scope = "custom"
    @State private var fields = AdjustmentTransferField.common
    @State private var photos: [IOSAdjustmentPhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var loading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var payload: AdjustmentTransferPayload?
    @State private var sourceName = ""
    @State private var prepared: IOSPreparedAdjustmentTransfer?
    @State private var skipped = Set<String>()
    @State private var pasteResults: [IOSAdjustmentTransferOutcome] = []
    @State private var message: String?

    private var title: String { L10n.text(preset != nil ? "应用预设" : kind == .copy ? "复制调整" : kind == .paste ? "粘贴调整" : "本次会话历史") }
    private var busy: Bool { loading || model.adjustmentPreparing }
    private var ready: Bool {
        !busy && prepared?.targets.contains { !skipped.contains($0.id) } == true &&
            prepared?.targets.allSatisfy { $0.error == nil || skipped.contains($0.id) } == true
    }
    private var hasPending: Bool { pasteResults.isEmpty || pasteResults.contains { [.blocked, .failed, .conflict].contains($0.status) } }

    var body: some View {
        NavigationStack {
            Form {
                if kind == .copy { copyContent }
                else if kind == .paste { pasteContent }
                else { historyContent }
                if let message {
                    Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("adjustment.transfer.message") }
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("关闭")) { dismiss() }.accessibilityIdentifier("adjustment.transfer.close")
            } }
            .photosPicker(isPresented: $showingPhotos, selection: $pickerItems, matching: .images, preferredItemEncoding: .current)
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: PhotoImportFile.supportedContentTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): loadTask = Task { await addFiles(urls) }
                case .failure(let error): message = error.localizedDescription
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                loadTask = Task { await addPickerItems(items) }
            }
        }
        .tint(.yellow)
        .onAppear {
            if kind == .paste {
                payload = preset?.payload ?? model.adjustmentSession?.clipboard
                sourceName = preset?.name ?? model.adjustmentClipboardSourceName ?? payload?.source.identifier ?? ""
                photos = model.currentAdjustmentPhoto.map { [$0] } ?? []
            }
        }
        .onDisappear {
            loadTask?.cancel()
            model.cancelAdjustmentPreparation()
            model.adjustmentHistoryRequest = nil
            model.adjustmentHistoryResults = []
        }
    }

    @ViewBuilder private var copyContent: some View {
        IOSAdjustmentScopeEditor(scope: $scope, fields: $fields, sourceName: model.sourceDisplayName ?? "")
        Section {
            Button(L10n.text("复制调整")) {
                do {
                    let selection: AdjustmentTransferScope = scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields)
                    try model.copyAdjustments(scope: selection, settings: settings)
                    dismiss()
                } catch { message = model.adjustmentErrorMessage(error) }
            }.disabled(scope == "custom" && fields.isEmpty).accessibilityIdentifier("adjustment.copy.confirm")
        }
    }

    @ViewBuilder private var pasteContent: some View {
        if let payload {
            Section {
                Text(L10n.format("来源：%@ · %@ 项调整", sourceName, String(payload.fields.count))).font(.headline)
                DisclosureGroup(L10n.text("查看调整范围")) {
                    Text(payload.fields.sorted { $0.rawValue < $1.rawValue }.map(\.displayTitle).joined(separator: "、"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(L10n.format("目标：%@ 张照片", String(photos.count)))
                Button(L10n.text("选择照片…")) { showingPhotos = true }.disabled(busy)
                    .accessibilityIdentifier("adjustment.paste.chooseTargets")
                Button(L10n.text("从文件导入")) { showingFiles = true }.disabled(busy)
                    .accessibilityIdentifier("adjustment.paste.chooseFiles")
                Button(L10n.text("检查目标"), action: prepare).disabled(busy || photos.isEmpty)
                    .accessibilityIdentifier("adjustment.paste.preflight")
                if busy { ProgressView(L10n.text("正在检查目标…")) }
            }
            Section {
                ForEach(photos) { targetRow($0) }
                if photos.isEmpty { Text(L10n.text("没有可处理目标，请重新选择照片。")) }
                if let prepared, !prepared.targets.isEmpty, prepared.targets.allSatisfy({ skipped.contains($0.id) }) {
                    Text(L10n.text("没有可处理目标，请重新选择照片。"))
                }
            }
            Section {
                if let transaction = model.adjustmentSession?.transactions.first(where: { $0.id == prepared?.id }) {
                    transactionButtons(transaction)
                }
                if !pasteResults.isEmpty && !hasPending {
                    Button(L10n.text("完成")) { dismiss() }.accessibilityIdentifier("adjustment.paste.done")
                } else {
                    Button(L10n.text(pasteResults.isEmpty ? "应用并保存" : "重试未完成项")) {
                        guard let prepared else { return }
                        pasteResults = model.applyAdjustmentPaste(prepared, skipping: skipped)
                        model.adjustmentHistoryResults = []
                        updatePasteMessage()
                    }.disabled(!ready).accessibilityIdentifier("adjustment.paste.apply")
                }
            }
            historyRecovery
        } else {
            Section { Text(L10n.text("尚未复制调整。请先从一张照片复制所需范围。")) }
        }
    }

    private func targetRow(_ photo: IOSAdjustmentPhoto) -> some View {
        let target = prepared?.targets.first { $0.id == photo.id }
        let result = pasteResults.first { $0.targetID == photo.id }
        let part = model.adjustmentSession?.transactions.first { $0.id == prepared?.id }?.parts.first { $0.identity == photo.identity }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(photo.displayName).fontWeight(.medium)
                Spacer()
                if let result { Text(part?.state == .undone ? L10n.text("已撤销") : result.status.title).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = result?.error ?? target?.error ?? photo.error {
                Text(model.adjustmentErrorMessage(error)).font(.callout).foregroundStyle(.secondary)
            }
            Toggle(L10n.text("跳过"), isOn: Binding(get: { skipped.contains(photo.id) }, set: {
                if $0 { skipped.insert(photo.id) } else { skipped.remove(photo.id) }
            })).disabled(busy || result.map { [.applied, .unchanged, .skipped].contains($0.status) } == true)
                .accessibilityIdentifier("adjustment.target.skip.\(photo.id)")
            if prepared == nil {
                Button(L10n.text("移除"), role: .destructive) { photos.removeAll { $0.id == photo.id } }.disabled(busy)
            }
        }.accessibilityElement(children: .contain)
    }

    @ViewBuilder private var historyContent: some View {
        Section { Text(L10n.text("历史仅保留在本次会话；已保存的调整会在重新打开时恢复。")).font(.footnote).foregroundStyle(.secondary) }
        historyRecovery
        if model.adjustmentSession?.transactions.isEmpty != false { Section { Text(L10n.text("暂无编辑历史。")) } }
        ForEach((model.adjustmentSession?.transactions ?? []).reversed(), id: \.id) { transaction in
            Section(transaction.action.title) {
                Text(transaction.parts.map(\.displayName).joined(separator: "、"))
                transactionButtons(transaction)
            }
        }
    }

    private func transactionButtons(_ transaction: IOSAdjustmentHistoryTransaction) -> some View {
        let applied = transaction.parts.filter { $0.state == .applied }.count
        let undone = transaction.parts.filter { $0.state == .undone }.count
        return Group {
            Button(L10n.format("撤销 %@ 张", String(applied))) { runHistory(transaction.id, undo: true) }
                .disabled(applied == 0 || busy).accessibilityIdentifier("adjustment.transaction.undo.\(transaction.id)")
            Button(L10n.format("重做 %@ 张", String(undone))) { runHistory(transaction.id, undo: false) }
                .disabled(undone == 0 || busy).accessibilityIdentifier("adjustment.transaction.redo.\(transaction.id)")
        }
    }

    @ViewBuilder private var historyRecovery: some View {
        let failures = model.adjustmentHistoryResults.filter { [.failed, .blocked, .conflict].contains($0.status) }
        if !failures.isEmpty, let request = model.adjustmentHistoryRequest {
            Section {
                Text(L10n.text("以下目标尚未完成本次历史操作，请检查原因后重试。"))
                ForEach(failures, id: \.targetID) { failure in
                    let name = model.adjustmentSession?.transactions.first { $0.id == request.transactionID }?.parts.first { $0.identity.key == failure.targetID }?.displayName ?? failure.targetID
                    Text(name + " · " + model.adjustmentErrorMessage(failure.error)).font(.callout).foregroundStyle(.secondary)
                }
                Button(L10n.text("重试未完成项")) {
                    _ = model.executeAdjustmentHistory(request)
                    updateHistoryMessage(undo: request.undo)
                }.accessibilityIdentifier("adjustment.history.retry")
                if request.photo == nil, failures.contains(where: \.requiresHistoryDecision) {
                    Button(L10n.text("跳过以上目标后重试")) {
                        _ = model.executeAdjustmentHistory(request, skipping: Set(failures.filter(\.requiresHistoryDecision).map(\.targetID)))
                        updateHistoryMessage(undo: request.undo)
                    }.accessibilityIdentifier("adjustment.history.skip")
                }
            }
        }
    }

    private func runHistory(_ id: UUID, undo: Bool) {
        _ = model.performAdjustmentHistory(undo: undo, transactionID: id, wholeTransaction: true)
        updateHistoryMessage(undo: undo)
    }
    private func updateHistoryMessage(undo: Bool) {
        let results = model.adjustmentHistoryResults
        message = L10n.format(undo ? "已撤销 %@ 张 · 未完成 %@ 张" : "已重做 %@ 张 · 未完成 %@ 张",
                              String(results.filter { $0.status == .applied }.count),
                              String(results.filter { [.failed, .blocked, .conflict].contains($0.status) }.count))
    }
    private func updatePasteMessage() {
        let parts = model.adjustmentSession?.transactions.first { $0.id == prepared?.id }?.parts ?? []
        let undone = Set(parts.filter { $0.state == .undone }.map { $0.identity.key })
        message = L10n.format("已保存 %@ 张 · 未变化 %@ 张 · 已跳过 %@ 张 · 已撤销 %@ 张 · 未完成 %@ 张",
            String(pasteResults.filter { $0.status == .applied && !undone.contains($0.targetID) }.count),
            String(pasteResults.filter { $0.status == .unchanged }.count), String(pasteResults.filter { $0.status == .skipped }.count),
            String(undone.count), String(pasteResults.filter { [.failed, .blocked, .conflict].contains($0.status) }.count))
    }
    private func invalidatePreparation() {
        model.cancelAdjustmentPreparation()
        prepared = nil; pasteResults = []; skipped = []; message = nil; model.adjustmentHistoryResults = []
    }
    private func prepare() {
        guard let payload else { return }
        invalidatePreparation()
        model.prepareAdjustmentPaste(payload, photos: photos, action: preset == nil ? .paste : .preset) { result in
            switch result {
            case .success(let operation): prepared = operation
            case .failure(let error): message = model.adjustmentErrorMessage(error)
            }
        }
    }
    private func append(_ photo: IOSAdjustmentPhoto) {
        if !photos.contains(where: { $0.id == photo.id }) { photos.append(photo) }
    }
    private func appendFailure(_ name: String, error: Error) {
        append(.init(identity: .init(resourceIdentifier: "unreadable:\(UUID())"), displayName: name, file: nil, isRaw: false, error: error))
    }
    @MainActor private func addPickerItems(_ items: [PhotosPickerItem]) async {
        loading = true; invalidatePreparation()
        defer { loading = false; pickerItems = [] }
        for item in items {
            guard !Task.isCancelled else { return }
            do {
                let source = try await PhotoImportFile.load(from: item)
                defer { PhotoImportFile.release(source.url) }
                let identity = item.itemIdentifier.flatMap { $0.isEmpty ? nil : PhotoIdentity(resourceIdentifier: $0) }
                let photo = try await model.retainAdjustmentPhoto(source, identity: identity)
                guard !Task.isCancelled else { return }
                append(photo)
            } catch { if !Task.isCancelled { appendFailure(L10n.text("选择照片…"), error: error) } }
        }
    }
    @MainActor private func addFiles(_ urls: [URL]) async {
        loading = true; invalidatePreparation()
        defer { loading = false }
        for url in urls {
            guard !Task.isCancelled else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let source = try PhotoImportFile.retainSource(url)
                defer { PhotoImportFile.release(source.url) }
                let photo = try await model.retainAdjustmentPhoto(source)
                guard !Task.isCancelled else { return }
                append(photo)
            } catch { if !Task.isCancelled { appendFailure(url.lastPathComponent, error: error) } }
        }
    }
}
