import RawLabKit
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
        let record: PhotoEditRecord
        let settings: Adjustments
        let look: URL?
        let lookSHA256: String?
        let lookName: String
        let editorRevision: UUID?
        var editGeneration: UInt64 = 0
        var noticeKey: String? = nil
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
    var adaptiveJPEG = false
    var snapshots: [Snapshot] { rows.compactMap(\.snapshot) }
    var ready: Bool { !snapshots.isEmpty && rows.allSatisfy { $0.skipped || $0.snapshot != nil } }
}

// 在主线程固化编辑器输入，后台检查只读取文件与这些值，不访问 SwiftUI 状态。
struct MacCollectionExportPreparation {
    let selection: [String]
    let photos: [String: MacCollectionPhoto]
    let drafts: Set<String>
    let activeFile: URL?
    let activeRecord: PhotoEditRecord?
    let activeRevision: UUID
    let activeAIBusy: Bool
    let store: EditPersistence
    let films: [Film]
    let skipped: Set<String>
    let format: ExportFormat
    let longEdge: Int?
    let directory: URL
    var adaptiveJPEG = false
    var probeHDRSource: HDRSourceInfo.Probe = { try HDRSourceInfo.probe($0, onSDRFallback: $1) }
    var editGeneration: (URL) -> UInt64 = { _ in 0 }

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
                if !adaptiveJPEG && format.requiresHDR && !value.settings.isHDREditing {
                    throw RenderError.failed(format.hdrRequiredMessage)
                }
                return .init(id: id, url: photo.url, hasDraft: false, skipped: false, snapshot: value, error: nil)
            } catch {
                return .init(id: id, url: photo.url, hasDraft: draft, skipped: false, snapshot: nil, error: error)
            }
        }
        return MacCollectionExportReview(selection: selection, skipped: skipped, rows: rows,
            format: format, longEdge: longEdge, directory: directory, adaptiveJPEG: adaptiveJPEG)
    }

    func snapshot(_ photo: MacCollectionPhoto) throws -> MacCollectionExportReview.Snapshot {
        try photo.validate()
        guard !drafts.contains(photo.id) else { throw AdjustmentTransferError.draftRequiresPreflight }
        let generation = editGeneration(photo.url)
        let record: PhotoEditRecord
        if activeFile == photo.url {
            guard let activeRecord, !activeAIBusy else { throw AdjustmentTransferError.draftRequiresPreflight }
            record = activeRecord
        } else { record = try store.readState(for: photo.url) }
        guard record.identity == photo.original else { throw BatchExportFailure.changedInput }
        var sdrFallback = false
        let info = try probeHDRSource(photo.url, { sdrFallback = true })
        var state = try record.state ?? PhotoEditState(settings: RenderEngine.defaultSettings(for: photo.url, sourceIsHDR: info != nil), filmID: "")
        if sdrFallback { state.settings.hdr?.mode = .sdr }
        if state.settings.isHDREditing {
            guard let source = try info ?? HDRSourceInfo.probeRAW(photo.url) else { throw HDRSettings.ModeError.unsupportedSource }
            try source.validateEditDecodeVersion(state.settings.proRAWDecodeVersion)
            if let profile = state.settings.hdr?.cameraDevelopmentSettings.cameraProfile {
                try HDRCameraProfileAssetStore.url(for: profile)
            }
            let look = state.settings.hdr!.lookSettings
            guard look.assetIsAvailable() else { throw AdjustmentTransferError.missingLook(look.name ?? "HDR LUT") }
        }
        if !state.settings.isHDREditing && state.settings.aiDenoiseEnabled {
            try RenderEngine.validateAIInput(photo.url, settings: state.settings)
        }
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
            editorRevision: activeFile == photo.url ? activeRevision : nil, editGeneration: generation,
            noticeKey: sdrFallback ? "此照片的 HDR 需 macOS 15 才能编辑，将按 SDR 导出。" : nil)
    }
}

/// 冻结产物：任务与已写进日志目录的 look 副本（未落盘前由调用方负责释放）。
struct MacFrozenCollectionExport {
    let job: BatchExportJob
    var ownedLooks: [URL] = []
}

/// 冻结核心：前后双遍全集重验 + 每目标 look 副本拷贝。只读取文件、会话代次与入口固化的
/// 主线程值（同 MacCollectionExportPreparation 不变量），可在集合导出后台队列执行；
/// 与 UI 状态的原子性（选择、草稿、修订、批次状态）由主线程在 attachBatch 前复核。
struct MacCollectionExportFreeze {
    let session: AdjustmentTransferSession
    let drafts: Set<String>
    let activeFile: URL?
    let activeRevision: UUID
    let journal: BatchJournal
    var observeStage: ((String, Bool) -> Void)?

    func freeze(_ review: MacCollectionExportReview) throws -> MacFrozenCollectionExport {
        func validate() throws {
            observeStage?("revalidate", Thread.isMainThread)
            for snapshot in review.snapshots {
                try snapshot.photo.validate()
                guard !drafts.contains(snapshot.photo.id),
                      session.editGeneration(for: snapshot.photo.url) == snapshot.editGeneration,
                      snapshot.editorRevision == nil
                        || (activeFile == snapshot.photo.url && activeRevision == snapshot.editorRevision) else {
                    throw AdjustmentCommitError.expired
                }
                guard try snapshot.look.map(BatchFrozenSettings.checksum) == snapshot.lookSHA256 else {
                    throw BatchExportFailure.missingLook
                }
            }
        }
        try validate()
        let first = review.snapshots[0]
        var job = BatchExportJob(source: first.photo.url, settings: first.settings, look: nil, lookName: first.lookName)
        job.settingsMode = .perTargetFrozen; job.version = 3
        job.format = review.adaptiveJPEG ? .jpeg : review.format
        job.longEdge = review.longEdge; job.outputDirectory = review.directory
        var ownedLooks = [URL]()
        do {
            observeStage?("copy", Thread.isMainThread)
            for (ordinal, snapshot) in review.snapshots.enumerated() {
                var item = try BatchExportItem(url: snapshot.photo.url)
                guard item.identity == snapshot.record.identity, item.resourceIdentifier == snapshot.photo.id else {
                    throw BatchExportFailure.changedInput
                }
                let look = try journal.snapshotLook(snapshot.look, jobID: job.id, contentIdentifier: snapshot.lookSHA256)
                if let look { ownedLooks.append(look) }
                item.selected = true
                item.noticeKey = snapshot.noticeKey
                item.frozen = BatchFrozenSettings(ordinal: ordinal, settings: snapshot.settings, look: look,
                    lookSHA256: snapshot.lookSHA256, lookName: snapshot.lookName,
                    outputFormat: review.adaptiveJPEG ? (snapshot.settings.isHDREditing ? .hdrJPEG : .jpeg) : review.format,
                    longEdge: review.longEdge)
                try item.frozen!.verifyLook(); job.items.append(item)
            }
            try validate()
        } catch {
            for look in ownedLooks { try? FileManager.default.removeItem(at: look) }
            throw error
        }
        return MacFrozenCollectionExport(job: job, ownedLooks: ownedLooks)
    }
}
