import Foundation

public struct EditorGeometryDraftState: Codable, Equatable, Sendable {
    public var preset: String
    public var lockedRatio: Double?
    public var swapped: Bool
    public var grid: Bool
    public var includesLens: Bool

    public init(preset: String = "free", lockedRatio: Double? = nil, swapped: Bool = false, grid: Bool = true, includesLens: Bool = false) {
        self.preset = preset
        self.lockedRatio = lockedRatio
        self.swapped = swapped
        self.grid = grid
        self.includesLens = includesLens
    }
}

public struct EditorToolDraftStep: Codable, Equatable {
    public var value: RawSettings
    public var geometry: EditorGeometryDraftState

    public init(value: RawSettings, geometry: EditorGeometryDraftState = EditorGeometryDraftState()) {
        self.value = value
        self.geometry = geometry
    }
}

public struct EditorToolDraft: Codable, Equatable {
    public let tool: EditorToolSelection
    public let original: RawSettings
    public private(set) var step: EditorToolDraftStep
    public private(set) var undoSteps: [EditorToolDraftStep] = []
    public private(set) var redoSteps: [EditorToolDraftStep] = []
    public private(set) var interacting = false

    public init(tool: EditorToolSelection, original: RawSettings) {
        self.tool = tool; self.original = original; step = EditorToolDraftStep(value: original)
    }
    public var value: RawSettings { step.value }
    public var changed: Bool { projecting(on: original) != original }
    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }

    public func projecting(on settings: RawSettings) -> RawSettings {
        guard value != original else { return settings }
        var result = tool.project(value, original: original, onto: settings)
        if step.geometry.includesLens {
            result.setGeometrySettings(value.geometrySettings)
            result.lensCorrection = value.lensCorrection
        }
        return result
    }

    public mutating func update(_ requested: RawSettings, geometry: EditorGeometryDraftState? = nil, interactive: Bool = false) {
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

    public mutating func undo() {
        guard let previous = undoSteps.popLast() else { return }
        redoSteps.append(step); step = previous; interacting = false
    }
    public mutating func redo() {
        guard let next = redoSteps.popLast() else { return }
        undoSteps.append(step); step = next; interacting = false
    }
    public mutating func finishInteraction() { interacting = false }
}

public extension EditorToolSelection {
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
                else { result.denoise = value.denoise; result.displayChromaDenoise = value.displayChromaDenoise }
            case .vignette, .grain:
                for parameter in PhotoEffectParameter.allCases where parameter.isVignette == (kind == .vignette) {
                    result.setExactEditingEffect(parameter, to: value.editingEffectValue(parameter))
                }
            default:
                kind.setValue(kind.value(from: value), in: &result)
                if kind == .exposure { result.exposureMode = value.exposureMode }
            }
        case .hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation:
            if result.isHDREditing, let keyPath = hdrRenditionKeyPath {
                result.hdr?.renditionSettings[keyPath: keyPath] = value.hdr?.renditionSettings[keyPath: keyPath] ?? 0
            }
        }
        return result
    }
}

public struct EditorToolDraftStore {
    public struct Record: Codable {
        public var version = 1
        public let identity: PhotoIdentity
        public let draft: EditorToolDraft

        public init(version: Int = 1, identity: PhotoIdentity, draft: EditorToolDraft) {
            self.version = version
            self.identity = identity
            self.draft = draft
        }
    }
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("active.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public static func appStore() throws -> Self {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return Self(directory: root.appendingPathComponent("RawLab/EditorDraft", isDirectory: true))
    }

    public func save(identity: PhotoIdentity, draft: EditorToolDraft) throws {
        guard identity.contentIdentifier != nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Record(identity: identity, draft: draft)).write(to: file, options: .atomic)
    }

    public func load(identity: PhotoIdentity, committed: RawSettings) throws -> EditorToolDraft? {
        guard let record = try read(), record.identity == identity, record.draft.original == committed else { return nil }
        return record.draft
    }

    public func clear(identity: PhotoIdentity) throws {
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
