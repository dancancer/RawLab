import Foundation

struct EditorEditSource: Equatable {
    let file: PhotoSourceFile
    let identity: PhotoIdentity
    let revision: UUID
}

struct EditorDraftSnapshot: Equatable {
    var geometry: GeometrySettings?
    var lens: RawSettings?
    var tool: EditorToolSelection
    var destination: EditorToolSelection? = nil

    var isActive: Bool { tool == .geometry || tool == .lens }

    func projecting(on settings: RawSettings) -> RawSettings {
        var result = settings
        if let lens { result.lensCorrection = lens.lensCorrection }
        if let geometry { result.geometry = geometry }
        return result
    }

    func isChanged(from settings: RawSettings) -> Bool {
        let projected = projecting(on: settings)
        return projected.geometry != settings.geometry || projected.lensSettings != settings.lensSettings
    }
}

struct EditorEditSnapshot: Equatable {
    let source: EditorEditSource
    let editRevision: UUID
    let committed: PhotoEditState
    let draft: EditorDraftSnapshot
    let context: EditorAdjustmentContext
    let whiteBalance: Sony2FujiProcessor.RawWhiteBalance?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.editRevision == rhs.editRevision &&
        lhs.committed == rhs.committed && lhs.draft == rhs.draft && lhs.whiteBalance == rhs.whiteBalance &&
        lhs.context.isRaw == rhs.context.isRaw &&
        lhs.context.defaultExposureMode == rhs.context.defaultExposureMode &&
        lhs.context.cameraTemperature == rhs.context.cameraTemperature &&
        lhs.context.cameraTint == rhs.context.cameraTint
    }
}

struct PreparedEditorReset {
    let original: EditorEditSnapshot
    let candidate: PhotoEditState
    let updatesDraft: Bool
    let requiresConfirmation: Bool
}

enum EditorResetPreparation {
    case unchanged
    case blocked(EditorAdjustmentResetBlock?)
    case prepared(PreparedEditorReset)
}

struct PreparedEditorDraft {
    let original: EditorEditSnapshot
    let candidate: PhotoEditState
}

// 只保留原记录的附加信息；当前参数始终来自 ContentView。
struct EditorRecordMetadata {
    let source: EditorEditSource
    let filmID: String?
    let updatedAt: Date
    let lutID: String?
    let recipeID: String?

    init(source: EditorEditSource, record: PhotoEditState) {
        self.source = source
        filmID = record.filmID
        updatedAt = record.updatedAt
        lutID = record.settings.lutID
        recipeID = record.settings.masterRecipeID
    }

    func state(settings: RawSettings) -> PhotoEditState {
        let sameLook = settings.lutID == lutID && settings.masterRecipeID == recipeID
        return PhotoEditState(settings: settings, updatedAt: updatedAt)
            .replacing(settings: settings, preservingFilmID: sameLook ? filmID : settings.lutID)
    }
}

struct PersistedEditorSettings {
    let source: EditorEditSource
    let settings: RawSettings
}

extension RawEditorViewModel {
    var editorEditSource: EditorEditSource? {
        guard let sourceFile, let sourceIdentity, sourceKind != nil, activeImportRevision == nil else { return nil }
        return EditorEditSource(file: sourceFile, identity: sourceIdentity, revision: sourceRevision)
    }

    func retainEditMetadata(_ record: PhotoEditState) {
        guard let source = editorEditSource else { return }
        editRecordMetadata = EditorRecordMetadata(source: source, record: record)
    }

    func currentEditState(settings: RawSettings) -> PhotoEditState {
        guard let metadata = editRecordMetadata, metadata.source == editorEditSource else {
            return PhotoEditState(settings: settings, updatedAt: Date(timeIntervalSince1970: 0))
        }
        return metadata.state(settings: settings)
    }

    func editSnapshot(settings: RawSettings, revision: UUID, draft: EditorDraftSnapshot) -> EditorEditSnapshot? {
        guard !isBusy, hasImage, let source = editorEditSource else { return nil }
        let context = EditorAdjustmentContext(isRaw: sourceKind == .raw,
                                             defaultExposureMode: RawSettings.default.exposureMode,
                                             cameraTemperature: rawWhiteBalance?.isCalibrated == true ? rawWhiteBalance?.temperature : nil,
                                             cameraTint: rawWhiteBalance?.isCalibrated == true ? rawWhiteBalance?.tint : nil)
        return EditorEditSnapshot(source: source, editRevision: revision,
                                  committed: currentEditState(settings: settings), draft: draft,
                                  context: context, whiteBalance: rawWhiteBalance)
    }

    func prepareReset(_ scope: EditorAdjustmentScope, settings: RawSettings, revision: UUID,
                      draft: EditorDraftSnapshot) -> EditorResetPreparation {
        guard let original = editSnapshot(settings: settings, revision: revision, draft: draft) else { return .blocked(nil) }
        let geometryScope: Bool
        if case .group(.geometry) = scope { geometryScope = true } else { geometryScope = false }
        guard geometryScope == draft.isActive else { return .blocked(nil) }
        let snapshot = geometryScope
            ? original.committed.replacing(settings: draft.projecting(on: settings), preservingFilmID: original.committed.filmID)
            : original.committed
        switch EditorAdjustmentRules.prepareReset(scope, snapshot: snapshot, context: original.context) {
        case .unchanged: return .unchanged
        case .blocked(let reason): return .blocked(reason)
        case .candidate(let candidate, let confirmation):
            return .prepared(PreparedEditorReset(original: original, candidate: candidate,
                                                 updatesDraft: geometryScope, requiresConfirmation: confirmation))
        }
    }

    func commitReset(_ prepared: PreparedEditorReset, settings: RawSettings, revision: UUID,
                     draft: EditorDraftSnapshot) -> PhotoEditState? {
        guard prepared.original == editSnapshot(settings: settings, revision: revision, draft: draft) else { return nil }
        if !prepared.updatesDraft { retainEditMetadata(prepared.candidate) }
        return prepared.candidate
    }

    func prepareDraft(settings: RawSettings, revision: UUID, draft: EditorDraftSnapshot) -> PreparedEditorDraft? {
        guard draft.isActive, draft.isChanged(from: settings),
              let original = editSnapshot(settings: settings, revision: revision, draft: draft) else { return nil }
        return PreparedEditorDraft(original: original,
            candidate: original.committed.replacing(settings: draft.projecting(on: settings),
                                                     preservingFilmID: original.committed.filmID))
    }

    func saveDraft(_ prepared: PreparedEditorDraft, settings: RawSettings, revision: UUID,
                   draft: EditorDraftSnapshot) -> Bool {
        guard prepared.original == editSnapshot(settings: settings, revision: revision, draft: draft) else { return false }
        let source = prepared.original.source
        cancelQueuedSettingsSave()
        guard persistEditCandidate(prepared.candidate, source: source) else {
            failedDraftSource = source
            return false
        }
        failedDraftSource = nil
        persistedEditorSettings = PersistedEditorSettings(source: source, settings: prepared.candidate.settings)
        return true
    }

    func consumePersistedEditorSettings(_ settings: RawSettings) -> Bool {
        let saved = persistedEditorSettings
        persistedEditorSettings = nil
        return saved?.source == editorEditSource && saved?.settings == settings
    }

    var hasFailedDraftSave: Bool { failedDraftSource != nil && failedDraftSource == editorEditSource }

    func discardDraftSaveFailure(settings: RawSettings) {
        guard hasFailedDraftSave else { return }
        failedDraftSource = nil
        editSaveState = .idle
        if pendingSettings != nil { queueSettingsSave(settings) }
    }
}
