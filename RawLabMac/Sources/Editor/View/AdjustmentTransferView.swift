import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AdjustmentTransferView: View {
    @ObservedObject var model: EditorModel
    let kind: AdjustmentSheetKind
    var preset: AdjustmentPreset? = nil
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var scope = "custom"
    @State private var fields = AdjustmentTransferField.common
    @State private var targets: [URL] = []
    @State private var payload: AdjustmentTransferPayload?
    @State private var prepared: PreparedAdjustmentTransfer?
    @State private var skipped = Set<String>()
    @State private var historyResults: [AdjustmentTransferOutcome] = []
    @State private var pasteResults: [AdjustmentTransferOutcome] = []
    @State private var preparing = false
    @State private var message: String?
    @State private var operationGeneration = UUID()
    @State private var historyID: UUID?
    @State private var historyUndo = true
    @State private var historyPhoto: URL?
    @State private var focusedHistory: UUID?
    @State private var excludedSource: String?
    @State private var initialized = false

    private var title: String { L10n.text(preset != nil ? "应用预设" : kind == .copy ? "复制调整" : kind == .paste ? "粘贴调整" : kind == .synchronize ? "应用调整并保存到所选照片" : "本次会话历史") }
    private var selectedScope: AdjustmentTransferScope {
        scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields)
    }
    private var scopePreview: Result<AdjustmentTransferPayload, Error> {
        Result { try model.previewAdjustmentPayload(scope: selectedScope) }
    }
    private var remainingTargets: Int { prepared?.targets.filter { !skipped.contains($0.id) }.count ?? 0 }
    private var ready: Bool {
        !preparing && remainingTargets > 0 && prepared?.targets.allSatisfy { $0.error == nil || skipped.contains($0.id) } == true
    }
    private var needsRecheck: Bool {
        (prepared == nil && message != nil) || prepared?.targets.contains { $0.error != nil } == true ||
            pasteResults.contains { $0.status == .conflict || $0.status == .blocked }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("关闭")) { close() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("adjustment.transfer.close")
            }
            if kind == .copy { copyContent }
            else if kind == .paste || kind == .synchronize { pasteContent }
            else { historyContent }
            if let message { Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("adjustment.transfer.message") }
        }
        .padding(24).frame(width: 600).frame(minHeight: 380, maxHeight: 680).tint(.yellow)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if kind == .copy { fields=model.settings.isHDREditing ? AdjustmentTransferField.hdrCommon : AdjustmentTransferField.common }
            if kind == .paste || kind == .synchronize {
                payload = preset?.payload ?? model.adjustmentSheetPayload ?? model.adjustmentClipboard
                targets = preset != nil ? model.file.map { [$0] } ?? [] : model.adjustmentSheetTargets ?? model.file.map { [$0] } ?? []
                excludedSource = preset == nil ? model.adjustmentSheetExcludedSource : nil
                prepare()
            } else if kind == .history, let request = model.pendingAdjustmentHistory {
                historyID = request.transactionID; historyUndo = request.undo; historyPhoto = request.photo
                historyResults = model.adjustmentOutcomes
                if model.adjustmentSheetInCollection { focusedHistory = request.transactionID }
                if !historyResults.isEmpty { updateResultMessage() }
            }
        }
        .onChange(of: model.sourceRevision) { _, _ in
            if kind == .paste || kind == .synchronize { close() }
        }
        .onDisappear {
            invalidatePreparation(); model.adjustmentSheetPayload = nil; model.adjustmentSheetTargets = nil
            model.adjustmentSheetExcludedSource = nil; model.adjustmentSheetExcludedIdentity = nil; model.pendingAdjustmentHistory = nil
        }
    }

    private var copyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.file?.lastPathComponent ?? "").font(.headline)
            Text(model.file?.deletingLastPathComponent().path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            AdjustmentScopeEditor(scope:$scope,fields:$fields,preview:scopePreview,lookName:model.adjustmentSummaryLookName,errorMessage: { model.adjustmentErrorMessage($0) },allowed:model.settings.isHDREditing ? AdjustmentTransferField.hdrSupported : AdjustmentTransferField.legacyFields)
            HStack {
                Spacer()
                Button(L10n.text("复制调整")) {
                    do { _ = try model.copyAdjustments(scope: selectedScope); close() }
                    catch { message = model.adjustmentErrorMessage(error) }
                }.buttonStyle(.borderedProminent).disabled((try? scopePreview.get()) == nil)
                    .accessibilityIdentifier("adjustment.copy.confirm")
            }
        }
    }

    private var pasteContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let payload {
                HStack {
                    Text(L10n.format("来源：%@ · %@ 项调整", sourceName(payload), String(payload.fields.count)))
                    if payload.source.identifier.hasPrefix("/") {
                        PhotoLocationButton(url: URL(fileURLWithPath: payload.source.identifier))
                    }
                }
                if payload.source.recipe != nil {
                    Text(L10n.text("按实际生效值应用，已包含配方强度。")).font(.callout).foregroundStyle(.secondary)
                }
                DisclosureGroup(L10n.text("查看调整范围")) {
                    ScrollView {
                        AdjustmentSummaryView(payload: payload, lookName: model.adjustmentSummaryLookName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 220)
                }
                HStack {
                    Text(L10n.format("目标：%@ 张照片", String(targets.count))).fontWeight(.medium)
                    Spacer()
                    if kind != .synchronize {
                        Button(L10n.text("选择照片…"), action: chooseTargets)
                            .accessibilityIdentifier("adjustment.paste.chooseTargets")
                    }
                    if needsRecheck {
                        Button(L10n.text("重新检查"), action: prepare).disabled(preparing || targets.isEmpty)
                            .accessibilityIdentifier("adjustment.paste.preflight")
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(targets, id: \.path) { url in targetRow(url) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 160, maxHeight: 320)
                if preparing { ProgressView(L10n.text("正在检查目标…")).controlSize(.small) }
                if targets.isEmpty || (prepared != nil && remainingTargets == 0) {
                    Text(L10n.text("没有可处理目标，请重新选择照片。")).foregroundStyle(.secondary)
                }
                HStack {
                    if let transaction = model.adjustmentSession?.transactions.first(where: { $0.id == prepared?.id }) {
                        let applied = transaction.parts.filter { $0.state == .applied }.count
                        let undone = transaction.parts.filter { $0.state == .undone }.count
                        if applied > 0 {
                            Button(L10n.format("撤销 %@ 张", String(applied))) { runHistory(transaction.id, undo: true) }
                                .accessibilityIdentifier("adjustment.paste.undo")
                        }
                        if undone > 0 {
                            Button(L10n.format("重做 %@ 张", String(undone))) { runHistory(transaction.id, undo: false) }
                                .accessibilityIdentifier("adjustment.paste.redo")
                        }
                    }
                    Spacer()
                    if !pasteResults.isEmpty && !hasPendingApplication {
                        Button(L10n.text("完成")) { close() }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("adjustment.paste.done")
                    } else {
                        Button(L10n.text(pasteResults.isEmpty ? "应用并保存" : "重试未完成项")) {
                            guard let prepared else { return }
                            model.applyAdjustmentPaste(prepared, skipping: skipped)
                            pasteResults = model.adjustmentOutcomes
                            historyResults = []; historyID = nil; historyPhoto = nil
                            updateResultMessage()
                        }.buttonStyle(.borderedProminent).disabled(!ready || !hasPendingApplication)
                            .accessibilityIdentifier("adjustment.paste.apply")
                    }
                }
                if historyID != nil, historyResults.contains(where: { $0.requiresHistoryDecision || $0.status == .failed }) {
                    ScrollView { conflictActions.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                }
            } else {
                Text(L10n.text("尚未复制调整。请先从一张照片复制所需范围。"))
            }
        }
    }

    private var hasPendingApplication: Bool {
        guard !pasteResults.isEmpty else { return true }
        return pasteResults.contains { [.blocked, .failed, .conflict].contains($0.status) }
    }

    private func targetRow(_ url: URL) -> some View {
        let id = url.resolvingSymlinksInPath().standardizedFileURL.path
        let target = prepared?.targets.first { $0.id == id }
        let outcome = pasteResults.first { $0.targetID == id }
        let part = model.adjustmentSession?.transactions.first(where: { $0.id == prepared?.id })?.parts.first { $0.identity.path == id }
        let historyError = historyResults.first(where: { $0.targetID == id })?.error
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(url.lastPathComponent).fontWeight(.medium)
                PhotoLocationButton(url: url)
                Spacer()
                if let outcome { Text(part?.state == .undone ? L10n.text("已撤销") : outcome.status.title).foregroundStyle(.secondary) }
                Toggle(L10n.text("跳过"), isOn: Binding(get: { skipped.contains(id) }, set: {
                    if $0 { skipped.insert(id) } else { skipped.remove(id) }
                })).toggleStyle(.checkbox).fixedSize()
                    .disabled(outcome.map { [.applied, .unchanged, .skipped].contains($0.status) } == true)
            }
            if kind == .synchronize, let photo = model.batchSelectionPhotos.values.first(where: { $0.url.path == id }), model.collectionHasDraft(photo.id) {
                Text(L10n.text("此照片有尚未保存的调整。应用或放弃后，请重新检查目标。"))
                HStack {
                    Button(L10n.text("应用并保存")) { if model.resolveCollectionDraft(photo.id, apply: true) { invalidatePreparation() } }
                    Button(L10n.text("放弃草稿")) { if model.resolveCollectionDraft(photo.id, apply: false) { invalidatePreparation() } }
                }
            } else if model.file?.resolvingSymlinksInPath().standardizedFileURL.path == id, model.geometryDraft != nil {
                Text(L10n.text("此照片有未应用的几何或镜头草稿。")).font(.callout)
                HStack {
                    Button(L10n.text("应用草稿")) { if model.applyGeometryDraft() { invalidatePreparation() } }
                        .disabled(!model.geometryDraftCanApply)
                    Button(L10n.text("放弃草稿")) { model.cancelGeometryDraft(); invalidatePreparation() }
                }
            }
            if let error = historyError ?? outcome?.error ?? target?.error {
                Text(model.adjustmentErrorMessage(error)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var historyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("历史仅保留在本次会话；已保存的调整会在重新打开时恢复。"))
                    .font(.callout).foregroundStyle(.secondary)
                if let historyPhoto { Text(historyPhoto.lastPathComponent).fontWeight(.medium) }
                conflictActions
                if model.adjustmentSession?.transactions.isEmpty != false { Text(L10n.text("暂无编辑历史。")) }
                ForEach((model.adjustmentSession?.transactions ?? []).filter { focusedHistory == nil || $0.id == focusedHistory }.reversed(), id: \.id) { transaction in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(transaction.action.title).fontWeight(.medium)
                        Text(transaction.parts.map { URL(fileURLWithPath: $0.identity.path).lastPathComponent }.joined(separator: "、"))
                            .font(.callout).lineLimit(3)
                        HStack {
                            let applied = transaction.parts.filter { $0.state == .applied }.count
                            let undone = transaction.parts.filter { $0.state == .undone }.count
                            Button(L10n.format("撤销 %@ 张", String(applied))) { runHistory(transaction.id, undo: true) }
                                .disabled(applied == 0)
                            Button(L10n.format("重做 %@ 张", String(undone))) { runHistory(transaction.id, undo: false) }
                                .disabled(undone == 0)
                        }
                    }
                    Divider()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 270, maxHeight: 520)
    }

    @ViewBuilder private var conflictActions: some View {
        if historyID != nil, historyResults.contains(where: \.requiresHistoryDecision) {
            Text(L10n.text("以下目标尚未完成本次历史操作，请检查原因后重试。"))
            ForEach(historyResults.filter(\.requiresHistoryDecision), id: \.targetID) { result in
                Text(URL(fileURLWithPath: result.targetID).lastPathComponent + " · " + model.adjustmentErrorMessage(result.error))
                    .font(.callout).foregroundStyle(.secondary)
                if model.file?.resolvingSymlinksInPath().standardizedFileURL.path == result.targetID, model.geometryDraft != nil {
                    HStack {
                        Button(L10n.text("应用草稿")) {
                            if model.applyGeometryDraft(), let historyID { runHistory(historyID, undo: historyUndo, photo: historyPhoto) }
                        }.disabled(!model.geometryDraftCanApply)
                        Button(L10n.text("放弃草稿")) {
                            model.cancelGeometryDraft()
                            if let historyID { runHistory(historyID, undo: historyUndo, photo: historyPhoto) }
                        }
                    }
                }
            }
            if historyPhoto == nil {
                Button(L10n.text("跳过以上目标后重试")) {
                    guard let historyID else { return }
                    let conflicts = Set(historyResults.filter(\.requiresHistoryDecision).map(\.targetID))
                    model.changeAdjustmentTransaction(historyID, undo: historyUndo, skipping: conflicts)
                    historyResults = model.adjustmentOutcomes; updateResultMessage()
                }
            } else {
                Button(L10n.text("重试未完成项")) { if let historyID { runHistory(historyID, undo: historyUndo, photo: historyPhoto) } }
            }
        } else if historyID != nil, historyResults.contains(where: { $0.status == .failed }) {
            Button(L10n.text("重试未完成项")) { if let historyID { runHistory(historyID, undo: historyUndo, photo: historyPhoto) } }
        }
    }

    private func runHistory(_ id: UUID, undo: Bool, photo: URL? = nil) {
        historyID = id; historyUndo = undo; historyPhoto = photo
        model.performAdjustmentHistory(.init(transactionID: id, photo: photo, undo: undo))
        historyResults = model.adjustmentOutcomes; updateResultMessage()
    }
    private func updateResultMessage() {
        if historyID != nil {
            let applied = historyResults.filter { $0.status == .applied }.count
            let failed = historyResults.filter { [.failed, .blocked, .conflict].contains($0.status) }.count
            message = L10n.format(historyUndo ? "已撤销 %@ 张 · 未完成 %@ 张" : "已重做 %@ 张 · 未完成 %@ 张", String(applied), String(failed))
        } else {
            let parts = model.adjustmentSession?.transactions.first(where: { $0.id == prepared?.id })?.parts ?? []
            let undone = Set(parts.filter { $0.state == .undone }.map { $0.identity.path })
            let applied = pasteResults.filter { $0.status == .applied && !undone.contains($0.targetID) }.count
            let unchanged = pasteResults.filter { $0.status == .unchanged }.count
            let skipped = pasteResults.filter { $0.status == .skipped }.count
            let failed = pasteResults.filter { [.failed, .blocked, .conflict].contains($0.status) }.count
            message = L10n.format("已保存 %@ 张 · 未变化 %@ 张 · 已跳过 %@ 张 · 已撤销 %@ 张 · 未完成 %@ 张",
                String(applied), String(unchanged), String(skipped), String(undone.count), String(failed))
        }
    }
    private func chooseTargets() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = DirectoryContents.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            targets = panel.urls.filter { $0.resolvingSymlinksInPath().standardizedFileURL.path != excludedSource }
            skipped = []; prepare()
        }
    }
    private func invalidatePreparation() {
        operationGeneration = UUID(); preparing = false
        prepared = nil; pasteResults = []; historyResults = []; message = nil; historyID = nil; historyPhoto = nil
    }
    private func prepare() {
        invalidatePreparation()
        guard let payload, !targets.isEmpty else { return }
        let session: AdjustmentTransferSession
        do { session = try model.requireAdjustmentSession() }
        catch { message = model.adjustmentErrorMessage(error); return }
        let descriptors = model.adjustmentTransferTargets(targets, payload: payload, excludingSource: excludedSource,
            excludingIdentity: kind == .synchronize ? model.adjustmentSheetExcludedIdentity : nil, collection: kind == .synchronize)
        preparing = true
        let generation = UUID(), source = model.sourceRevision
        operationGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try session.prepare(payload: payload, targets: descriptors, action: kind == .synchronize ? .synchronize : preset == nil ? .paste : .preset) }
            DispatchQueue.main.async {
                guard generation == operationGeneration, source == model.sourceRevision else { return }
                preparing = false
                switch result {
                case .success(let value): prepared = value
                case .failure(let error): message = model.adjustmentErrorMessage(error)
                }
            }
        }
    }
    private func sourceName(_ payload: AdjustmentTransferPayload) -> String {
        if let preset { return preset.name }
        return payload.source.identifier.hasPrefix("/") ? URL(fileURLWithPath: payload.source.identifier).lastPathComponent : payload.source.identifier
    }
    private func close() {
        invalidatePreparation()
        if let onClose { onClose() } else { dismiss() }
    }

}
