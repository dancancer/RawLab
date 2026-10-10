import AppKit
import Combine

final class AIWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

final class AIColorWorker {
    private let queue = DispatchQueue(label: "rawlab.ai.color", qos: .userInitiated)
    private var engine: RenderEngine?

    func perform<T>(cancellation: AIWorkCancellation = AIWorkCancellation(), _ operation: @escaping () throws -> T) async throws -> T {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try cancellation.check()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async(execute: DispatchWorkItem {
                    do {
                        try cancellation.check()
                        let value = try operation()
                        try cancellation.check()
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: error) }
                })
            }
        } onCancel: { cancellation.cancel() }
    }

    func render(file: URL, settings: Adjustments, look: URL?, cancellation: AIWorkCancellation = AIWorkCancellation()) async throws -> RenderedImage {
        try await perform(cancellation: cancellation) {
            if self.engine == nil { self.engine = try RenderEngine() }
            guard let frame = try self.engine!.render(file, settings: settings, lut: look, edge: 1600, interactive: false) else {
                throw AIError.message("AI 候选预览为空。")
            }
            return frame
        }
    }
}

@MainActor final class AIColorMatchModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case idle, preparing, loadingReferences, requesting, compiling, rendering, applying, closed
        var title: String {
            switch self {
            case .idle, .closed: return ""
            case .preparing: return "准备中性预览…"
            case .loadingReferences: return "读取参考图…"
            case .requesting: return "分析参考风格…"
            case .compiling: return "生成并校验 CUBE…"
            case .rendering: return "显影候选外观…"
            case .applying: return "应用并保存调整…"
            }
        }
    }

    let id = UUID()
    let snapshot: EditorModel.AISnapshot
    let original: RenderedImage
    @Published private(set) var phase = Phase.idle
    @Published private(set) var baseline: RenderedImage?
    @Published private(set) var source: AIImage?
    @Published private(set) var references: [AIImage] = []
    @Published private(set) var candidate: AIColorLook?
    @Published private(set) var preview: RenderedImage?
    @Published private(set) var fixedCandidate: AIColorLook?
    @Published private(set) var fixedPreview: RenderedImage?
    @Published private(set) var regions = AIToneRegions.standard
    @Published private(set) var strength = 1.0
    @Published private(set) var previewStrength = 1.0
    @Published private(set) var isPreviewing = false
    @Published private(set) var error: String?
    @Published var instruction = ""
    private weak var editor: EditorModel?
    private let worker = AIColorWorker()
    private let service: AIService
    private var operationID = UUID()
    private var previewID = UUID()
    private var generationTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var localCancellation: AIWorkCancellation?

    var isBusy: Bool { phase != .idle && phase != .closed }
    var isCurrent: Bool { phase != .closed && editor?.isCurrentAIEdit(snapshot) == true }
    private var previewMatches: Bool { candidate?.regions == regions && preview != nil && previewStrength == strength }
    var canGenerate: Bool { !isBusy && !isPreviewing && source != nil && !references.isEmpty && isCurrent && (candidate == nil || previewMatches) }
    var canApply: Bool { !isBusy && !isPreviewing && previewMatches && isCurrent }
    var canExport: Bool { canApply }
    var protectedSources: [URL] { [snapshot.file] + references.compactMap(\.sourceURL) + (editor?.films.map(\.url) ?? []) }

    init(editor: EditorModel, service: AIService = AIService()) throws {
        snapshot = try editor.freezeAIEdit()
        guard let original = editor.result else { throw AIError.message("当前照片还没有精确预览。") }
        self.editor = editor; self.original = original; self.service = service
    }

    func prepare() async {
        guard !isBusy, phase != .closed, source == nil else { return }
        let token = UUID(); operationID = token
        let cancellation = AIWorkCancellation(); localCancellation = cancellation
        phase = .preparing; error = nil
        do {
            try requireCurrent()
            let frame = try await worker.render(file: snapshot.file, settings: snapshot.state.settings.aiBaseline,
                look: nil, cancellation: cancellation)
            let image = try await worker.perform(cancellation: cancellation) { try AIImage.prepare(frame.image, name: "Source") }
            guard accepts(token) else { return }
            try requireCurrent()
            baseline = frame; source = image; phase = .idle
        } catch {
            guard accepts(token) else { return }
            phase = .idle
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    func addReferences(_ urls: [URL]) async {
        guard !isBusy, phase != .closed else { return }
        let available = 6-references.count
        guard available > 0 else { error = "最多添加 6 张参考图。"; return }
        let token = UUID(); operationID = token
        let cancellation = AIWorkCancellation(); localCancellation = cancellation
        phase = .loadingReferences; error = nil
        var failures: [String] = []
        if urls.count > available { failures.append("最多 6 张参考图，其余 \(urls.count-available) 张未添加。") }
        for url in urls.prefix(available) {
            do {
                let image = try await worker.perform(cancellation: cancellation) { try AIImage.load(url) }
                guard accepts(token) else { return }
                references.append(image)
            } catch {
                guard accepts(token) else { return }
                if error is CancellationError { break }
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        guard accepts(token) else { return }
        phase = .idle
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func removeReference(_ id: UUID) {
        guard !isBusy, phase != .closed else { return }
        references.removeAll { $0.id == id }
    }

    func generate(configuration: AIConfiguration, key: String) {
        guard canGenerate, let source else {
            error = isCurrent ? "请等待预览完成并添加参考图。" : "照片或调整已变化，请关闭面板后重新开始。"
            return
        }
        let token = UUID(); operationID = token
        generationTask?.cancel()
        let references = self.references, intent = instruction, previous = candidate?.recipe
        let priorImage = preview?.image, priorStrength = previewStrength
        let priorRegions = candidate?.regions ?? .standard
        phase = .requesting; error = nil
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                var images = [source]
                if let priorImage, previous != nil {
                    let image = try await self.worker.perform { try AIImage.prepare(priorImage, name: "Candidate") }
                    images.append(image)
                }
                images += references
                guard self.accepts(token) else { return }
                try self.requireCurrent()
                let recipe = try await self.service.generate(configuration: configuration, key: key, images: images,
                    instruction: intent, previous: previous, previousStrength: priorStrength, previousRegions: priorRegions)
                guard self.accepts(token) else { return }
                try self.requireCurrent()
                self.phase = .compiling
                let look = try await self.worker.perform { try AIColorLook.compile(recipe: recipe, model: configuration.model) }
                guard self.accepts(token) else { return }
                try self.requireCurrent()
                self.phase = .rendering
                let frame = try await self.worker.render(file: self.snapshot.file, settings: self.snapshot.state.settings.aiBaseline, look: look.url)
                guard self.accepts(token) else { return }
                try self.requireCurrent()
                self.candidate = look; self.preview = frame
                self.fixedCandidate = look; self.fixedPreview = frame; self.regions = .standard
                self.strength = 1; self.previewStrength = 1; self.phase = .idle
            } catch {
                guard self.accepts(token) else { return }
                self.phase = .idle
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func updateStrength(_ value: Double) {
        guard !isBusy, isCurrent, candidate != nil, value.isFinite, (0...2).contains(value) else { return }
        strength = value
        refreshPreview()
    }

    func updateRegions(_ value: AIToneRegions) {
        guard !isBusy, isCurrent, candidate != nil else { return }
        do { regions = try value.validated() }
        catch { self.error = error.localizedDescription; return }
        refreshPreview()
    }

    private func refreshPreview() {
        guard let candidate, let fixedCandidate else { return }
        let value = strength, regions = regions
        let token = UUID(); previewID = token
        previewTask?.cancel(); isPreviewing = true
        var settings = snapshot.state.settings.aiBaseline; settings.strength = value
        let file = snapshot.file
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                let look: AIColorLook
                if regions == .standard { look = fixedCandidate }
                else if regions == candidate.regions { look = candidate }
                else {
                    look = try await self.worker.perform {
                        try AIColorLook.compile(recipe: fixedCandidate.recipe, model: fixedCandidate.model, regions: regions)
                    }
                }
                try Task.checkCancellation()
                let frame = try await self.worker.render(file: file, settings: settings, look: look.url)
                let fixedFrame = regions == .standard ? frame : try await self.worker.render(file: file, settings: settings, look: fixedCandidate.url)
                guard self.previewID == token, self.phase != .closed else { return }
                try self.requireCurrent()
                self.candidate = look; self.preview = frame; self.fixedPreview = fixedFrame
                self.previewStrength = value; self.isPreviewing = false
                self.error = nil
            } catch {
                guard self.previewID == token, self.phase != .closed else { return }
                self.isPreviewing = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func apply() async -> Bool {
        guard canApply, let candidate, let editor else { error = "当前候选还不能应用。"; return false }
        phase = .applying; error = nil
        do {
            try await editor.applyAILook(candidate.url, name: candidate.recipe.name, strength: strength, snapshot: snapshot)
            phase = .closed
            return true
        } catch { self.error = error.localizedDescription; phase = .idle; return false }
    }

    func cancelGeneration() {
        guard phase != .applying, phase != .closed else { return }
        operationID = UUID(); previewID = UUID()
        generationTask?.cancel(); previewTask?.cancel()
        localCancellation?.cancel(); localCancellation = nil
        generationTask = nil; previewTask = nil
        isPreviewing = false; strength = previewStrength; phase = .idle
        regions = candidate?.regions ?? .standard
    }

    func close() {
        guard phase != .applying else { return }
        cancelGeneration(); phase = .closed
    }

    func clearError() { error = nil }
    private func accepts(_ token: UUID) -> Bool { operationID == token && phase != .closed }
    private func requireCurrent() throws {
        guard isCurrent else { throw AIError.message("照片或调整已变化，未应用 AI 结果。请关闭面板后重新开始。") }
    }
}
