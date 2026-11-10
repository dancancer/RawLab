import Foundation

struct EditorGeometryDraftState: Codable, Equatable {
    var preset = "free"
    var lockedRatio: Double?
    var swapped = false
    var grid = true
    var includesLens = false
}

struct EditorToolDraftStep: Codable, Equatable {
    var value: RawSettings
    var geometry = EditorGeometryDraftState()
}

struct EditorToolDraft: Codable, Equatable {
    let tool: EditorToolSelection
    let original: RawSettings
    private(set) var step: EditorToolDraftStep
    private(set) var undoSteps: [EditorToolDraftStep] = []
    private(set) var redoSteps: [EditorToolDraftStep] = []
    private(set) var interacting = false

    init(tool: EditorToolSelection, original: RawSettings) {
        self.tool = tool; self.original = original; step = EditorToolDraftStep(value: original)
    }
    var value: RawSettings { step.value }
    var changed: Bool { projecting(on: original) != original }
    var canUndo: Bool { !undoSteps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }

    func projecting(on settings: RawSettings) -> RawSettings {
        guard value != original else { return settings }
        var result = tool.project(value, original: original, onto: settings)
        if step.geometry.includesLens {
            result.setGeometrySettings(value.geometrySettings)
            result.lensCorrection = value.lensCorrection
        }
        return result
    }

    mutating func update(_ requested: RawSettings, geometry: EditorGeometryDraftState? = nil, interactive: Bool = false) {
        var next = EditorToolDraftStep(value: tool.project(requested, original: original, onto: value),
                                      geometry: geometry ?? step.geometry)
        if next.geometry.includesLens {
            next.value.lensCorrection = requested.lensCorrection
            next.value.setGeometrySettings(requested.geometrySettings)
        }
        if next != step {
            if !interacting { undoSteps.append(step); undoSteps = Array(undoSteps.suffix(100)) }
            redoSteps.removeAll()
        }
        if !interactive && interacting && undoSteps.last == next { undoSteps.removeLast() }
        step = next; interacting = interactive
    }

    mutating func undo() {
        guard let previous = undoSteps.popLast() else { return }
        redoSteps.append(step); step = previous; interacting = false
    }
    mutating func redo() {
        guard let next = redoSteps.popLast() else { return }
        undoSteps.append(step); step = next; interacting = false
    }
    mutating func finishInteraction() { interacting = false }
}

extension EditorToolSelection {
    func project(_ value: RawSettings, original: RawSettings, onto current: RawSettings) -> RawSettings {
        var result = current
        switch self {
        case .geometry: result.setGeometrySettings(value.geometrySettings)
        case .lens: result.lensCorrection = value.lensCorrection
        case .film, .recipe:
            result.lutID = value.lutID; result.masterRecipeID = value.masterRecipeID
            result.lutStrength = value.lutStrength; result.masterRecipeSettingsVersion = value.masterRecipeSettingsVersion
            // 配方独立化会换算这些依赖；没有变化的字段仍属于其他工具。
            func copyChanged<T: Equatable>(_ key: WritableKeyPath<RawSettings, T>) {
                if original[keyPath: key] != value[keyPath: key] { result[keyPath: key] = value[keyPath: key] }
            }
            copyChanged(\.exposure); copyChanged(\.highlights); copyChanged(\.shadows)
            copyChanged(\.contrast); copyChanged(\.saturation); copyChanged(\.toneCurve)
            copyChanged(\.whiteBalanceMode); copyChanged(\.temperature); copyChanged(\.tint)
            copyChanged(\.hsl); copyChanged(\.toneControls); copyChanged(\.atmosphere)
            copyChanged(\.colorGrading); copyChanged(\.toneCurveConfig)
            if result.isHDREditing, let before = original.hdr, let after = value.hdr, before != after {
                result.hdr?.lookSettings = after.lookSettings
                if before.toneSettings != after.toneSettings { result.hdr?.toneSettings = after.toneSettings }
                if before.colorSettings != after.colorSettings { result.hdr?.colorSettings = after.colorSettings }
                if before.effectsSettings != after.effectsSettings { result.hdr?.effectsSettings = after.effectsSettings }
                if before.detailSettings != after.detailSettings { result.hdr?.detailSettings = after.detailSettings }
                if before.exposure != after.exposure { result.hdr?.exposure = after.exposure }
                if before.contrast != after.contrast { result.hdr?.contrast = after.contrast }
                if before.highlights != after.highlights { result.hdr?.highlights = after.highlights }
                if before.shadows != after.shadows { result.hdr?.shadows = after.shadows }
                if before.saturation != after.saturation { result.hdr?.saturation = after.saturation }
                if before.temperature != after.temperature { result.hdr?.temperature = after.temperature }
                if before.tint != after.tint { result.hdr?.tint = after.tint }
            }
        case .adjustment(let kind):
            switch kind {
            case .temperature, .tint:
                result.whiteBalanceMode = value.whiteBalanceMode
                AdjustmentKind.temperature.setValue(AdjustmentKind.temperature.value(from: value), in: &result)
                AdjustmentKind.tint.setValue(AdjustmentKind.tint.value(from: value), in: &result)
            case .hsl: result.editingHSLSettings = value.editingHSLSettings
            case .colorGrading: result.editingGradingSettings = value.editingGradingSettings
            case .toneCurve:
                result.editingCurveSettings = value.editingCurveSettings
                kind.setValue(kind.value(from: value), in: &result)
            case .noiseReduction:
                if result.isHDREditing { kind.setValue(kind.value(from: value), in: &result) }
                else { result.noiseReduction = value.noiseReduction; result.denoise = value.denoise; result.displayChromaDenoise = value.displayChromaDenoise }
            case .vignette, .grain:
                for parameter in PhotoEffectParameter.allCases where parameter.isVignette == (kind == .vignette) {
                    result.setEditingEffect(parameter, to: value.editingEffectValue(parameter))
                }
            default:
                kind.setValue(kind.value(from: value), in: &result)
                if kind == .exposure { result.exposureMode = value.exposureMode }
            }
        }
        return result
    }
}

struct EditorToolDraftStore {
    struct Record: Codable {
        var version = 1
        let identity: PhotoIdentity
        let draft: EditorToolDraft
    }
    let directory: URL
    private var file: URL { directory.appendingPathComponent("active.json") }

    static func appStore() throws -> Self {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return Self(directory: root.appendingPathComponent("RawLab/EditorDraft", isDirectory: true))
    }

    func save(identity: PhotoIdentity, draft: EditorToolDraft) throws {
        guard identity.contentIdentifier != nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Record(identity: identity, draft: draft)).write(to: file, options: .atomic)
    }

    func load(identity: PhotoIdentity, committed: RawSettings) throws -> EditorToolDraft? {
        guard let record = try read(), record.identity == identity, record.draft.original == committed else { return nil }
        return record.draft
    }

    func clear(identity: PhotoIdentity) throws {
        if try read()?.identity == identity { try FileManager.default.removeItem(at: file) }
    }

    private func read() throws -> Record? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
        let states = [record.draft.original, record.draft.value] + record.draft.undoSteps.map(\.value) + record.draft.redoSteps.map(\.value)
        guard record.version == 1, record.draft.undoSteps.count <= 100, record.draft.redoSteps.count <= 100,
              states.allSatisfy({ EditorAdjustmentRules.valid($0) && ($0.hdr?.isValid ?? true) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }
}
