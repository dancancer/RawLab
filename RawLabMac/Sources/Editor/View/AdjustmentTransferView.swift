import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AdjustmentTransferView: View {
    @ObservedObject var model: EditorModel
    let kind: AdjustmentSheetKind
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
    @State private var excludedSource: String?

    private var title: String { L10n.text(kind == .copy ? "复制调整" : kind == .paste ? "粘贴调整" : "本次会话历史") }
    private var selectedScope: AdjustmentTransferScope {
        scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields)
    }
    private var remainingTargets: Int { prepared?.targets.filter { !skipped.contains($0.id) }.count ?? 0 }
    private var ready: Bool {
        !preparing && remainingTargets > 0 && prepared?.targets.allSatisfy { $0.error == nil || skipped.contains($0.id) } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("adjustment.transfer.close")
            }
            if kind == .copy { copyContent }
            else if kind == .paste { pasteContent }
            else { historyContent }
            if let message { Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("adjustment.transfer.message") }
        }
        .padding(24).frame(width: 600).frame(minHeight: 380, maxHeight: 680).tint(.yellow)
        .onAppear {
            if kind == .paste {
                payload = model.adjustmentSheetPayload ?? model.adjustmentClipboard
                targets = model.adjustmentSheetTargets ?? model.file.map { [$0] } ?? []
                excludedSource = model.adjustmentSheetExcludedSource
            } else if kind == .history, let request = model.pendingAdjustmentHistory {
                historyID = request.transactionID; historyUndo = request.undo; historyPhoto = request.photo
                historyResults = model.adjustmentOutcomes
                updateResultMessage()
            }
        }
        .onDisappear {
            operationGeneration = UUID(); model.adjustmentSheetPayload = nil; model.adjustmentSheetTargets = nil
            model.adjustmentSheetExcludedSource = nil; model.pendingAdjustmentHistory = nil
        }
    }

    private var copyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.file?.lastPathComponent ?? "").font(.headline)
            Text(model.file?.deletingLastPathComponent().path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Picker(L10n.text("复制范围"), selection: $scope) {
                Text(L10n.text("全部")).tag("all")
                Text(L10n.text("仅已修改")).tag("modified")
                Text(L10n.text("自定义")).tag("custom")
            }.pickerStyle(.segmented).accessibilityIdentifier("adjustment.copy.scope")
            Text(L10n.text("几何与镜头仅在“全部”或显式选择时包含。")).font(.callout).foregroundStyle(.secondary)
            if scope == "custom" {
                HStack {
                    Text(L10n.format("已选 %@ 项", String(fields.count))).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("清空选择")) { fields.removeAll() }.disabled(fields.isEmpty)
                        .accessibilityIdentifier("adjustment.copy.clear")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(["looks", "light", "color", "effects", "detail", "geometry"], id: \.self) { group in
                            DisclosureGroup {
                                let members = AdjustmentTransferField.allCases.filter { $0.group == group }
                                Toggle(L10n.text("选择此组"), isOn: groupBinding(members)).fontWeight(.medium)
                                ForEach(members.filter { $0.hslLocation == nil }, id: \.rawValue) { field in fieldToggle(field) }
                                if group == "color" {
                                    ForEach(HSLAxis.allCases) { axis in
                                        DisclosureGroup("HSL · \(axis.title)") {
                                            let items = members.filter { $0.hslLocation?.axis == axis.rawValue }
                                            Toggle(L10n.text("选择此组"), isOn: groupBinding(items))
                                            ForEach(items, id: \.rawValue) { field in fieldToggle(field) }
                                        }.padding(.leading, 12)
                                    }
                                }
                            } label: {
                                let members = AdjustmentTransferField.allCases.filter { $0.group == group }
                                Text(AdjustmentTransferField.groupTitle(group) + " · \(members.filter { fields.contains($0) }.count)/\(members.count)")
                                    .fontWeight(.medium)
                            }
                        }
                    }.padding(.trailing, 8)
                }.frame(minHeight: 220, maxHeight: 400)
            }
            HStack {
                Spacer()
                Button(L10n.text("复制调整")) {
                    do { _ = try model.copyAdjustments(scope: selectedScope); dismiss() }
                    catch { message = model.adjustmentErrorMessage(error) }
                }.buttonStyle(.borderedProminent).disabled(scope == "custom" && fields.isEmpty)
                    .accessibilityIdentifier("adjustment.copy.confirm")
            }
        }
    }

    private var pasteContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let payload {
                Text(L10n.format("来源：%@ · %@ 项调整", sourceName(payload), String(payload.fields.count)))
                if payload.source.identifier.hasPrefix("/") {
                    Text(URL(fileURLWithPath: payload.source.identifier).deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if payload.source.recipe != nil {
                    Text(L10n.text("按实际生效值应用，已包含配方强度。")).font(.callout).foregroundStyle(.secondary)
                }
                DisclosureGroup(L10n.text("查看调整范围")) {
                    Text(payload.fields.sorted { $0.rawValue < $1.rawValue }.map(\.displayTitle).joined(separator: "、"))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(L10n.format("目标：%@ 张照片", String(targets.count))).fontWeight(.medium)
                    Spacer()
                    Button(L10n.text("选择照片…"), action: chooseTargets).disabled(preparing)
                        .accessibilityIdentifier("adjustment.paste.chooseTargets")
                    Button(L10n.text("检查目标"), action: prepare).disabled(preparing || targets.isEmpty)
                        .accessibilityIdentifier("adjustment.paste.preflight")
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
                        Button(L10n.text("完成")) { dismiss() }.buttonStyle(.borderedProminent)
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
                Spacer()
                if let outcome { Text(part?.state == .undone ? L10n.text("已撤销") : outcome.status.title).foregroundStyle(.secondary) }
                Toggle(L10n.text("跳过"), isOn: Binding(get: { skipped.contains(id) }, set: {
                    if $0 { skipped.insert(id) } else { skipped.remove(id) }
                })).toggleStyle(.checkbox).fixedSize()
                    .disabled(outcome.map { [.applied, .unchanged, .skipped].contains($0.status) } == true)
            }
            Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if model.file?.resolvingSymlinksInPath().standardizedFileURL.path == id, model.geometryDraft != nil {
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
                ForEach((model.adjustmentSession?.transactions ?? []).reversed(), id: \.id) { transaction in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text(transaction.action == .paste ? "粘贴调整" : "调整照片")).fontWeight(.medium)
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
            skipped = []; invalidatePreparation()
        }
    }
    private func invalidatePreparation() { prepared = nil; pasteResults = []; historyResults = []; message = nil; historyID = nil; historyPhoto = nil }
    private func prepare() {
        guard let payload else { return }
        invalidatePreparation()
        guard let session = try? model.requireAdjustmentSession() else { return }
        let descriptors = model.adjustmentTransferTargets(targets, payload: payload, excludingSource: excludedSource)
        preparing = true
        let generation = UUID(); operationGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try session.prepare(payload: payload, targets: descriptors) }
            DispatchQueue.main.async {
                guard generation == operationGeneration else { return }
                preparing = false
                switch result {
                case .success(let value): prepared = value
                case .failure(let error): message = model.adjustmentErrorMessage(error)
                }
            }
        }
    }
    private func groupBinding(_ members: [AdjustmentTransferField]) -> Binding<Bool> {
        Binding(get: { Set(members).isSubset(of: fields) }, set: { if $0 { fields.formUnion(members) } else { fields.subtract(members) } })
    }
    private func fieldToggle(_ field: AdjustmentTransferField) -> some View {
        Toggle(field.displayTitle, isOn: Binding(get: { fields.contains(field) }, set: {
            if $0 { fields.insert(field) } else { fields.remove(field) }
        })).padding(.leading, 12).accessibilityIdentifier("adjustment.copy.\(field.rawValue)")
    }

    private func sourceName(_ payload: AdjustmentTransferPayload) -> String {
        payload.source.identifier.hasPrefix("/") ? URL(fileURLWithPath: payload.source.identifier).lastPathComponent : payload.source.identifier
    }
}
