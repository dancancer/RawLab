import Foundation

struct MacCollectionPhoto: Identifiable {
    let id: String
    let url: URL
    let original: OriginalFileIdentity

    init(_ url: URL) throws {
        self.url = url.resolvingSymlinksInPath().standardizedFileURL
        original = try OriginalFileIdentity(self.url)
        id = try BatchExportItem.resourceKey(self.url)
    }

    func validate() throws {
        guard FileManager.default.isReadableFile(atPath: url.path),
              try OriginalFileIdentity(url) == original,
              try BatchExportItem.resourceKey(url) == id else { throw BatchExportFailure.changedInput }
    }
}

struct MacCollectionSynchronization {
    let sourceIdentity: String
    let payload: AdjustmentTransferPayload
    let targets: [URL]
}

struct MacCollectionExportReview {
    struct Snapshot {
        let photo: MacCollectionPhoto
        let record: VersionedPhotoEdit
        let settings: Adjustments
        let look: URL?
        let lookSHA256: String?
        let lookName: String
        let editorRevision: UUID?
    }
    struct Row: Identifiable {
        let id: String
        let url: URL
        let hasDraft: Bool
        let skipped: Bool
        let snapshot: Snapshot?
        let error: Error?
    }
    let selection: [String]
    let skipped: Set<String>
    let rows: [Row]
    let format: ExportFormat
    let longEdge: Int?
    let directory: URL
    var snapshots: [Snapshot] { rows.compactMap(\.snapshot) }
    var ready: Bool { !snapshots.isEmpty && rows.allSatisfy { $0.skipped || $0.snapshot != nil } }
}

// 在主线程固化编辑器输入，后台检查只读取文件与这些值，不访问 SwiftUI 状态。
struct MacCollectionExportPreparation {
    let selection: [String]
    let photos: [String: MacCollectionPhoto]
    let drafts: Set<String>
    let activeFile: URL?
    let activeRecord: VersionedPhotoEdit?
    let activeRevision: UUID
    let activeAIBusy: Bool
    let store: EditPersistence
    let films: [Film]
    let skipped: Set<String>
    let format: ExportFormat
    let longEdge: Int?
    let directory: URL

    func prepare() throws -> MacCollectionExportReview {
        guard longEdge == nil || (1...65535).contains(longEdge!) else { throw BatchExportFailure.destination }
        let rows = selection.compactMap { id -> MacCollectionExportReview.Row? in
            guard let photo = photos[id] else { return nil }
            let draft = drafts.contains(id)
            if skipped.contains(id) {
                return .init(id: id, url: photo.url, hasDraft: draft, skipped: true, snapshot: nil, error: nil)
            }
            do {
                let value = try snapshot(photo)
                if format == .hdrJPEG && !value.settings.isHDREditing {
                    throw RenderError.failed(L10n.text("HDR JPEG 需要启用 HDR 编辑。"))
                }
                return .init(id: id, url: photo.url, hasDraft: false, skipped: false, snapshot: value, error: nil)
            } catch {
                return .init(id: id, url: photo.url, hasDraft: draft, skipped: false, snapshot: nil, error: error)
            }
        }
        return MacCollectionExportReview(selection: selection, skipped: skipped, rows: rows,
            format: format, longEdge: longEdge, directory: directory)
    }

    func snapshot(_ photo: MacCollectionPhoto) throws -> MacCollectionExportReview.Snapshot {
        try photo.validate()
        guard !drafts.contains(photo.id) else { throw AdjustmentTransferError.draftRequiresPreflight }
        let record = try store.versionedState(for: photo.url)
        guard record.identity == photo.original else { throw BatchExportFailure.changedInput }
        if activeFile == photo.url {
            guard activeRecord == record, !activeAIBusy else { throw EditPersistenceConflict.changed }
        }
        var defaults = Adjustments()
        defaults.exposureMode = RenderEngine.isRasterInput(photo.url) ? .sensor : .preview
        if record.state == nil, try HDRSourceInfo.probe(photo.url) != nil { defaults.hdr = HDRSettings() }
        let state = record.state ?? PhotoEditState(settings: defaults, filmID: "")
        if !state.settings.isHDREditing && state.settings.aiDenoiseEnabled { try RenderEngine.validateAIInput(photo.url) }
        let look: URL?, lookName: String
        if state.settings.isHDREditing { look = nil; lookName = "HDR" }
        else if let recipeID = state.settings.masterRecipeID {
            guard let recipe = MasterRecipe.allRecipes.first(where: { $0.id == recipeID }), let url = recipe.lutURL() else {
                throw BatchExportFailure.missingLook
            }
            look = url; lookName = recipe.title
        } else if !state.filmID.isEmpty {
            guard let film = Film.independentRecipe(state.filmID) ?? films.first(where: {
                $0.id == state.filmID || "builtin:\($0.url.lastPathComponent)" == state.filmID
            }) else { throw BatchExportFailure.missingLook }
            look = film.url; lookName = film.name
        } else { look = nil; lookName = "中性" }
        return .init(photo: photo, record: record, settings: state.settings, look: look,
            lookSHA256: try look.map(BatchFrozenSettings.checksum), lookName: lookName,
            editorRevision: activeFile == photo.url ? activeRevision : nil)
    }
}
