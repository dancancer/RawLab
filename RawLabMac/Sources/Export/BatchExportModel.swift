import RawLabKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class BatchCancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    private var progress: AIPreparation?
    func attach(_ progress: AIPreparation?) {
        lock.lock(); self.progress = progress; let cancelled = value; lock.unlock()
        if cancelled { progress?.cancel() }
    }
    func cancel() { lock.lock(); value = true; let progress = progress; lock.unlock(); progress?.cancel() }
}

final class MacHDRBatchPreparation {
    private let source: URL
    private let settings: Adjustments
    private let store: MacEditPersistence
    private let films: [Film]
    private let probeHDRSource: HDRSourceInfo.Probe
    init(source: URL,settings: Adjustments,store: MacEditPersistence,films: [Film],
         probeHDRSource: @escaping HDRSourceInfo.Probe = { try HDRSourceInfo.probe($0, onSDRFallback: $1) }) {
        self.source=source; self.settings=settings; self.store=store; self.films=films
        self.probeHDRSource=probeHDRSource
    }
    func prepare(_ item: MacBatchExportItem,ordinal: Int,format: ExportFormat,longEdge: Int?,outputSharpening: OutputSharpening? = nil,sourceIsHDR: Bool? = nil,sdrFallback: Bool = false) throws -> MacBatchFrozenSettings {
        guard try OriginalFileIdentity(item.input)==item.identity else { throw BatchExportFailure.changedInput }
        let record=try store.readState(for:item.input)
        let raster=RenderEngine.isRasterInput(item.input)
        var fallback=sdrFallback
        let sourceIsHDR=try sourceIsHDR ?? (probeHDRSource(item.input,{ fallback=true }) != nil)
        var target=try record.state ?? MacPhotoEditState(settings:RenderEngine.defaultSettings(for:item.input,sourceIsHDR:sourceIsHDR),filmID:"")
        if fallback { target.settings.hdr?.mode = .sdr }
        let rawInfo = !raster && target.settings.isHDREditing ? try HDRSourceInfo.probeRAW(item.input) : nil
        if target.settings.isHDREditing {
            guard sourceIsHDR || rawInfo != nil else { throw HDRSettings.ModeError.unsupportedSource }
            if let rawInfo { try rawInfo.validateEditDecodeVersion(target.settings.proRAWDecodeVersion) }
            else if target.settings.proRAWDecodeVersion != nil { throw HDRSettings.ModeError.invalidSettings }
        }
        let payload=try HDRAdjustmentTransfer.batchPayload(settings:settings.hdr!,identifier:source.path,
            processingVersion:settings.processing.version,targetIsHDR:target.settings.isHDREditing)
        let context=MacAdjustmentTransferContext(identifier:item.identity.path,isRaw:!raster,
            sourceIsHDR:sourceIsHDR, sourceSupportsCameraHDR: rawInfo != nil, sourceIsBayerHDR: rawInfo?.isCameraRAW == true)
        let prepared=try MacAdjustmentTransfer.prepare(payload:payload,target:target,context:context)
        if format.requiresHDR && !prepared.settings.isHDREditing {
            throw RenderError.failed(format.hdrRequiredMessage)
        }
        let look: URL?,name: String
        if prepared.settings.isHDREditing { look=nil; name="HDR" }
        else if let recipe=prepared.settings.masterRecipe { look=recipe.lutURL(); name=recipe.title }
        else if let filmID = prepared.filmID, !filmID.isEmpty {
            guard let film=Film.independentRecipe(filmID) ?? films.first(where:{ $0.id==filmID || "builtin:\($0.url.lastPathComponent)"==filmID }) else {
                throw BatchExportFailure.missingLook
            }
            look=film.url; name=film.name
        } else { look=nil; name="neutral" }
        if !prepared.settings.isHDREditing && prepared.settings.masterRecipeID != nil && look==nil {
            throw BatchExportFailure.missingLook
        }
        return MacBatchFrozenSettings(ordinal:ordinal,settings:prepared.settings,look:look,
            lookSHA256:try look.map(MacBatchFrozenSettings.checksum),lookName:name,outputFormat:format,longEdge:longEdge,
            outputSharpening:format == .renderedDNG ? nil : outputSharpening)
    }
}

final class BatchExportModel: ObservableObject {
    @Published private(set) var job: MacBatchExportJob
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published var error: String?
    @Published private(set) var preview: RenderedImage?
    @Published private(set) var previewing = false
    @Published private(set) var validating = false
    @Published private(set) var aiProgress: (phase: Int, done: UInt64, total: UInt64)?
    var aiProgressTitle: String {
        switch aiProgress?.phase {
        case 2: return L10n.text("正在处理 RAW 噪声")
        case 3: return L10n.text("正在处理颜色噪声")
        case 4: return L10n.text("正在保存 AI 结果")
        default: return L10n.text("正在准备 AI 降噪")
        }
    }
    private(set) var updateJournalFailed = false
    @Published var previewFile: URL?
    @Published var sourceEditingGeometry = false
    var onActivity: (Bool) -> Void = { _ in }
    var onDiscard: () -> Void = { }
    var onQuarantineOnDiscard: (String) -> Void = { _ in }
    private let journal: MacBatchJournal
    private let queue = DispatchQueue(label: "rawlab.batch", qos: .userInitiated)
    private let validationQueue = DispatchQueue(label: "rawlab.batch-validation", qos: .userInitiated)
    private var engine: RenderEngine?
    private var cancellation = BatchCancellation()
    private var previewCancellation = BatchCancellation()
    private var previewRevision = UUID()
    private final class ProbeToken: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    enum X3fProbeState: Equatable {
        case pending
        case resolved(X3fMode)
        case failed(String)
    }

    private let prepareAIOperation: (RenderEngine, URL, Adjustments, AIPreparation) throws -> Void
    private let onUsage: (UsageEvent) -> Void
    private let hdrPreparation: MacHDRBatchPreparation?
    private let probeHDRSource: HDRSourceInfo.Probe
    private let resolveX3fMode: MacBatchExportJob.X3fModeResolver
    @Published private(set) var x3fProbeStates: [UUID: X3fProbeState] = [:]
    private var activeProbeToken: ProbeToken?
    var isProbingX3fNotices: Bool { x3fProbeStates.values.contains(.pending) }

    init(job: MacBatchExportJob, journal: MacBatchJournal,hdrPreparation: MacHDRBatchPreparation? = nil,
         probeHDRSource: @escaping HDRSourceInfo.Probe = { try HDRSourceInfo.probe($0, onSDRFallback: $1) },
         resolveX3fMode: @escaping MacBatchExportJob.X3fModeResolver = {
             try MacBatchExportJob.x3fModeResolver(defaultMode: RenderEngine.x3fDefaultMode(for:))($0)
         },
         prepareAI: @escaping (RenderEngine, URL, Adjustments, AIPreparation) throws -> Void = {
             try $0.prepareAI($1, settings: $2, progress: $3)
         },
         onUsage: @escaping (UsageEvent) -> Void = { _ in }) {
        self.job = job
        self.journal = journal
        self.onUsage = onUsage
        self.hdrPreparation=hdrPreparation
        self.probeHDRSource = probeHDRSource
        self.resolveX3fMode = resolveX3fMode
        self.prepareAIOperation = prepareAI
        error = job.failure
        probePendingX3fNotices()
    }

    deinit {
        activeProbeToken?.cancel()
    }

    var canRun: Bool { !running && !validating && (job.mode == .perTargetFrozen || !sourceEditingGeometry) && job.selectedCount > 0 && job.outputDirectory != nil }
    var title: String {
        if stopping { return L10n.text("正在停止…") }
        if running { return L10n.text("正在导出") }
        if job.interrupted { return L10n.text("导出已中断") }
        if job.cancelled { return L10n.text("导出已取消") }
        return job.started ? L10n.text("导出完成") : L10n.text("批量导出")
    }
    var summary: String {
        if !job.started { return L10n.format("已选 %@ 张", String(describing: job.selectedCount)) }
        return L10n.format("成功 %@ 张 · 失败 %@ 张 · 未处理 %@ 张", String(describing: job.succeededCount), String(describing: job.failedCount), String(describing: job.remainingCount))
    }

    func hasX3fProbeFailure(for item: MacBatchExportItem) -> Bool {
        guard job.mode == .uniformFrozen, !job.settings.isHDREditing, job.settings.aiDenoiseEnabled,
              RenderEngine.isX3fInput(item.input), item.validationError == nil,
              case .failed = noticeX3fProbeState(for: item) else { return false }
        return true
    }

    func notice(for item: MacBatchExportItem) -> String? {
        var messages = item.noticeKey.map { [L10n.text($0)] } ?? []
        if job.mode == .uniformFrozen, !job.settings.isHDREditing, job.settings.aiDenoiseEnabled {
            if RenderEngine.isRasterInput(item.input) {
                messages.append(L10n.text("普通图片未使用 AI 降噪"))
            } else if RenderEngine.isX3fInput(item.input), item.validationError == nil {
                switch noticeX3fProbeState(for: item) {
                case .resolved(.normal):
                    messages.append(L10n.text("此 X3F 显影模式不支持 AI 降噪。"))
                case .failed(let detail):
                    messages.append(L10n.format("无法读取 X3F 显影模式：%@", detail))
                case .pending, .resolved(.legacy), nil:
                    break
                }
            }
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func noticeX3fProbeState(for item: MacBatchExportItem) -> X3fProbeState? {
        if let resolved = item.resolvedX3fMode { return .resolved(resolved) }
        return x3fProbeStates[item.id]
    }

    private func cancelPendingX3fProbes() {
        activeProbeToken?.cancel()
        activeProbeToken = nil
        for (id, state) in x3fProbeStates where state == .pending {
            x3fProbeStates.removeValue(forKey: id)
        }
    }

    private func probePendingX3fNotices() {
        guard job.mode == .uniformFrozen, !job.settings.isHDREditing, job.settings.aiDenoiseEnabled else { return }
        let candidates = job.items.filter { item in
            RenderEngine.isX3fInput(item.input) &&
            item.resolvedX3fMode == nil &&
            item.validationError == nil &&
            x3fProbeStates[item.id] == nil
        }
        guard !candidates.isEmpty else { return }
        cancelPendingX3fProbes()
        let token = ProbeToken()
        activeProbeToken = token
        for item in candidates {
            x3fProbeStates[item.id] = .pending
        }
        let resolver = resolveX3fMode
        validationQueue.async { [weak self] in
            for item in candidates {
                guard !token.cancelled else { break }
                let outcome = Result { try resolver(item.input) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeProbeToken === token, !token.cancelled else { return }
                    guard let index = self.job.items.firstIndex(where: {
                        $0.id == item.id && $0.input == item.input && $0.identity == item.identity
                    }) else {
                        self.x3fProbeStates.removeValue(forKey: item.id)
                        return
                    }
                    switch outcome {
                    case .success(let mode):
                        self.x3fProbeStates[item.id] = .resolved(mode)
                        self.job.items[index].resolvedX3fMode = mode
                    case .failure(let failure):
                        self.x3fProbeStates[item.id] = .failed(failure.localizedDescription)
                    }
                }
            }
        }
    }

    func addFiles() {
        guard job.mode == .uniformFrozen, !running, !job.started, !validating else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择待导出的照片")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DirectoryContents.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        guard job.mode == .uniformFrozen, !running, !job.started, !validating else { return }
        var failures: [String] = []
        var added: [MacBatchExportItem] = []
        for url in urls {
            do {
                guard DirectoryContents.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                    throw RenderError.failed(L10n.text("不是支持的图像文件"))
                }
                var item = try MacBatchExportItem(url: url)
                item.selected = true
                if let index = job.items.firstIndex(where: { $0.input == item.input }) {
                    job.items[index].selected = true
                    x3fProbeStates.removeValue(forKey: job.items[index].id)
                } else { job.items.append(item) }
                added.append(item)
            } catch { failures.append(L10n.format("%@：%@", url.lastPathComponent, error.localizedDescription)) }
        }
        saveDraft()
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
        guard !added.isEmpty else { return }
        validating = true
        let candidates = added
        let validationJob = job
        validationQueue.async { [self] in
            var engine: RenderEngine?
            for item in candidates {
                var failure: String?
                var sdrFallback = false
                var resolvedX3fMode: X3fMode?
                do {
                    let info = try probeHDRSource(item.input, { sdrFallback = true })
                    let snapshot = try hdrPreparation?.prepare(item,ordinal:0,format:validationJob.format,longEdge:validationJob.longEdge,sourceIsHDR:info != nil,sdrFallback:sdrFallback) ?? validationJob.snapshot(for:item, resolveX3fMode: resolveX3fMode)
                    if validationJob.mode == .uniformFrozen, RenderEngine.isX3fInput(item.input) {
                        resolvedX3fMode = snapshot.settings.x3fMode
                    }
                    if snapshot.settings.activeAIDenoise {
                        try RenderEngine.validateAIInput(item.input, settings: snapshot.settings)
                    } else {
                        if engine == nil { engine = try RenderEngine() }
                        _ = try engine!.render(item.input, settings: snapshot.settings, lut: snapshot.look, edge: 180, interactive: true)
                    }
                } catch { failure = error.localizedDescription }
                let message = failure
                let x3fMode = failure == nil ? resolvedX3fMode : nil
                let noticeKey = failure == nil && sdrFallback ? "此照片的 HDR 需 macOS 15 才能编辑，将按 SDR 导出。" : nil
                DispatchQueue.main.async {
                    if let index = self.job.items.firstIndex(where: { $0.input == item.input }) {
                        self.job.items[index].noticeKey = noticeKey
                        self.job.items[index].resolvedX3fMode = x3fMode
                        if let x3fMode {
                            self.x3fProbeStates[self.job.items[index].id] = .resolved(x3fMode)
                        }
                        if let message {
                            self.job.items[index].validationError = message
                            self.job.items[index].selected = false
                        }
                    }
                }
            }
            DispatchQueue.main.async { self.validating = false; self.saveDraft(preserveNotice: true) }
        }
    }

    func select(_ id: UUID, _ value: Bool) {
        guard job.mode == .uniformFrozen, !running, !job.started, let index = job.items.firstIndex(where: { $0.id == id }) else { return }
        guard !validating, job.items[index].validationError == nil else { return }
        job.items[index].selected = value
        saveDraft()
    }

    func selectAll(_ selected: Bool) {
        guard job.mode == .uniformFrozen, !running, !job.started, !validating else { return }
        for index in job.items.indices { job.items[index].selected = selected && job.items[index].validationError == nil }
        saveDraft()
    }

    func remove(_ id: UUID) {
        guard job.mode == .uniformFrozen, !running, !job.started else { return }
        job.items.removeAll { $0.id == id }
        x3fProbeStates.removeValue(forKey: id)
        saveDraft()
    }

    func chooseDirectory() {
        guard job.mode == .uniformFrozen, !running else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择输出文件夹")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = job.outputDirectory
        if panel.runModal() == .OK { job.outputDirectory = panel.url; saveDraft() }
    }

    func setFormat(_ value: ExportFormat) {
        guard job.mode == .uniformFrozen, !running, !job.started else { return }
        job.format = value
        if value == .renderedDNG { job.outputSharpening = nil }
        saveDraft()
    }

    func setLongEdge(_ value: Int?) {
        guard job.mode == .uniformFrozen, !running, !job.started, value == nil || (1...65535).contains(value!) else { return }
        job.longEdge = value; saveDraft()
    }

    func setOutputSharpening(_ value: OutputSharpening) {
        guard job.mode == .uniformFrozen, !running, !job.started else { return }
        job.outputSharpening = value == .off ? nil : value; saveDraft()
    }

    private static func quarantineNotice(for error: Error) -> String {
        L10n.format("无法读取上次批量任务：%@", String(describing: error.localizedDescription))
    }

    private func consumeQuarantinedNotice() -> String? {
        journal.consumeQuarantinedError().map(Self.quarantineNotice(for:))
    }

    private func saveDraft(preserveNotice: Bool = false) {
        do {
            try journal.save(job)
            if let notice = consumeQuarantinedNotice() {
                error = notice
            } else if !preserveNotice {
                error = nil
            }
            updateJournalFailed = false
        } catch {
            _ = journal.consumeQuarantinedError()
            updateJournalFailed = true
            self.error = L10n.format("任务未保存：%@", String(describing: error.localizedDescription))
        }
    }

    func prepareForUpdate() -> Bool {
        guard !running, !stopping, !validating, !previewing else { return false }
        saveDraft()
        return !updateJournalFailed
    }

    @discardableResult func start(_ scope: BatchRunScope = .unfinished) -> Bool {
        guard !running else { return false }
        guard !validating else { error = L10n.text("正在检查照片…"); return false }
        guard job.mode == .perTargetFrozen || !sourceEditingGeometry else {
            error = L10n.text("来源有未完成的调整，请先应用或放弃。")
            return false
        }
        guard job.selectedCount > 0 else { error = L10n.text("尚未选择照片"); return false }
        guard job.outputDirectory != nil else { error = L10n.text("选择输出文件夹"); return false }
        // 渲染队列先排空已取消的预览，避免同一引擎并发使用或 AI 预览挡住导出。
        closePreview()
        cancelPendingX3fProbes()
        let cancellation = BatchCancellation()
        self.cancellation = cancellation
        error = nil; running = true; stopping = false
        onActivity(true)
        let snapshot = job
        queue.async { [self] in
            var work = snapshot
            var failure: String?
            var quarantineNotice: String?
            let recordQuarantine: (Error) -> Void = { quarantined in
                if quarantineNotice == nil { quarantineNotice = Self.quarantineNotice(for: quarantined) }
            }
            var attempted = Set<UUID>()
            do {
                let runSnapshot=try freezeHDRJob(snapshot,shouldCancel:{ cancellation.cancelled },onQuarantine:recordQuarantine)
                work=runSnapshot
                try MacBatchExportRunner.runSnapshots(job: &work, journal: journal, scope: scope,
                                                   resolveX3fMode: resolveX3fMode,
                                                   shouldCancel: { cancellation.cancelled }, didUpdate: { updated in
                    attempted.formUnion(updated.items.filter { $0.status == .running }.map(\.id))
                    DispatchQueue.main.async { self.job = updated }
                }, onQuarantine: recordQuarantine) { input, frozen, output in
                    let settings = frozen.settings
                    let look = frozen.look
                    if self.engine == nil { self.engine = try RenderEngine() }
                    if settings.activeAIDenoise {
                        let progress = AIPreparation { phase, done, total in
                            DispatchQueue.main.async { self.aiProgress = (phase, done, total) }
                        }
                        cancellation.attach(progress)
                        defer {
                            cancellation.attach(nil)
                            DispatchQueue.main.async { self.aiProgress = nil }
                        }
                        try self.prepareAIOperation(self.engine!, input, settings, progress)
                    }
                    if cancellation.cancelled { throw RenderError.aiCancelled }
                    _ = try self.engine!.render(input, settings: settings, lut: look, edge: 32)
                    _ = try self.engine!.render(input, settings: settings, lut: look, edge: nil, output: output,
                        stageOutput: false,
                        exportLongEdge:frozen.longEdge,exportFormat:frozen.outputFormat,
                        outputSharpening: frozen.outputFormat == .renderedDNG ? .off : frozen.effectiveOutputSharpening)
                }
            } catch {
                failure = error.localizedDescription
                work.interrupted = true; work.failure = failure
                do {
                    try journal.save(work)
                    if let quarantined = journal.consumeQuarantinedError() { recordQuarantine(quarantined) }
                } catch {
                    if let quarantined = journal.consumeQuarantinedError() { recordQuarantine(quarantined) }
                    failure = L10n.format("任务未保存：%@", error.localizedDescription) + "\n" + (work.failure ?? "")
                }
            }
            let final = work
            let message: String?
            if let quarantineNotice, let failure { message = quarantineNotice + "\n" + failure }
            else { message = failure ?? quarantineNotice }
            let succeeded = max(0, final.succeededCount - snapshot.succeededCount)
            let failed = final.items.filter { attempted.contains($0.id) && $0.status == .failed }.count
            let outcome: UsageBatchOutcome = final.interrupted ? .interrupted : final.cancelled ? .cancelled : failed > 0 ? .partial : .completed
            DispatchQueue.main.async {
                self.job = final; self.error = message
                self.running = false; self.stopping = false; self.aiProgress = nil
                self.onActivity(false)
                self.onUsage(.batchExportCompleted(succeeded: succeeded, failed: failed, outcome: outcome))
            }
        }
        return true
    }

    private func freezeHDRJob(_ draft: MacBatchExportJob,shouldCancel: () -> Bool,
                              onQuarantine: (Error) -> Void = { _ in }) throws -> MacBatchExportJob {
        guard draft.mode == .uniformFrozen,draft.settings.isHDREditing else { return draft }
        guard let hdrPreparation else { throw RenderError.failed(L10n.text("当前照片的设置尚不可用。")) }
        var result=draft; result.items=draft.items.filter(\.selected)
        var owned=[URL](),published=false
        defer { if !published { for url in owned { try? FileManager.default.removeItem(at:url) } } }
        for index in result.items.indices {
            if shouldCancel() { throw RenderError.aiCancelled }
            let draftSharpening = draft.format == .renderedDNG ? nil : draft.outputSharpening
            let prepared=try hdrPreparation.prepare(result.items[index],ordinal:index,format:draft.format,longEdge:draft.longEdge,outputSharpening:draftSharpening)
            let look=try journal.snapshotLook(prepared.look,jobID:result.id,contentIdentifier:prepared.lookSHA256)
            if let look { owned.append(look) }
            result.items[index].frozen=MacBatchFrozenSettings(ordinal:index,settings:prepared.settings,look:look,
                lookSHA256:prepared.lookSHA256,lookName:prepared.lookName,outputFormat:prepared.outputFormat,longEdge:prepared.longEdge,
                outputSharpening:prepared.outputSharpening)
        }
        result.settingsMode = .perTargetFrozen; result.version=3
        try result.validate()
        do {
            try journal.save(result)
            if let quarantined = journal.consumeQuarantinedError() { onQuarantine(quarantined) }
        } catch {
            if let quarantined = journal.consumeQuarantinedError() { onQuarantine(quarantined) }
            throw error
        }
        published=true
        return result
    }

    func cancel() {
        closePreview()
        cancelPendingX3fProbes()
        guard running else { return }
        stopping = true; cancellation.cancel()
    }

    func discardDraft() -> Bool {
        guard !job.started else { return false }
        return discardTask()
    }

    func close() -> Bool {
        guard !running, !validating, !previewing else { return false }
        return job.started || job.mode == .perTargetFrozen || discardDraft()
    }

    func discardTask() -> Bool {
        guard !running, !validating, !previewing else { return false }
        cancelPendingX3fProbes()
        do {
            try journal.discard(job)
            let notice = consumeQuarantinedNotice()
            self.error = notice
            onDiscard()
            if let notice { onQuarantineOnDiscard(notice) }
            return true
        } catch {
            _ = journal.consumeQuarantinedError()
            self.error = error.localizedDescription
            return false
        }
    }

    func inspect(_ item: MacBatchExportItem) {
        guard !running else { return }
        closePreview()
        let cancellation = BatchCancellation()
        previewCancellation = cancellation
        let revision = UUID()
        previewRevision = revision; previewFile = item.input; preview = nil; previewing = true; error = nil
        let frozenJob = job
        queue.async { [self] in
            guard !cancellation.cancelled else { return }
            let result = Result { () -> RenderedImage? in
                try frozenJob.validate()
                guard try OriginalFileIdentity(item.input) == item.identity else { throw BatchExportFailure.changedInput }
                if frozenJob.mode == .perTargetFrozen {
                    guard try MacBatchExportItem.resourceKey(item.input) == item.resourceIdentifier else { throw BatchExportFailure.changedInput }
                }
                let snapshot: MacBatchFrozenSettings
                if frozenJob.mode == .uniformFrozen,let hdrPreparation {
                    snapshot=try hdrPreparation.prepare(item,ordinal:0,format:frozenJob.format,longEdge:frozenJob.longEdge)
                } else { snapshot=try frozenJob.snapshot(for:item, resolveX3fMode: resolveX3fMode) }
                if frozenJob.mode == .perTargetFrozen {
                    try snapshot.verifyLook()
                }
                if cancellation.cancelled { throw RenderError.aiCancelled }
                if engine == nil { engine = try RenderEngine() }
                if snapshot.settings.activeAIDenoise {
                    let progress = AIPreparation { _, _, _ in }
                    cancellation.attach(progress)
                    defer { cancellation.attach(nil) }
                    try prepareAIOperation(engine!, item.input, snapshot.settings, progress)
                }
                if cancellation.cancelled { throw RenderError.aiCancelled }
                return try engine!.render(item.input, settings: snapshot.settings, lut: snapshot.look, edge: 1600)
            }
            DispatchQueue.main.async {
                guard self.previewRevision == revision, !cancellation.cancelled else { return }
                self.previewing = false
                switch result {
                case .success(let image): self.preview = image
                case .failure(let failure): self.error = failure.localizedDescription
                }
            }
        }
    }

    func closePreview() {
        previewCancellation.cancel()
        previewRevision=UUID(); previewing=false; preview=nil; previewFile=nil
    }

    func reveal(_ output: URL? = nil) {
        if let output { NSWorkspace.shared.activateFileViewerSelecting([output]) }
        else if let directory = job.outputDirectory { NSWorkspace.shared.open(directory) }
    }
}
