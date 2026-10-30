import Combine
import Foundation

struct IOSAdjustmentPhoto: Identifiable {
    let identity: PhotoIdentity
    let displayName: String
    let file: PhotoSourceFile?
    let isRaw: Bool
    var error: Error? = nil
    var validateSource: (() throws -> Void)? = nil
    var id: String { identity.key }
}

struct IOSCollectionPhoto: Identifiable {
    let photo: IOSAdjustmentPhoto
    let inputSHA256: String?
    let error: Error?
    var id: String { photo.id }

    init(_ photo: IOSAdjustmentPhoto) {
        self.photo = photo
        do {
            if let error = photo.error { throw error }
            guard let file = photo.file else { throw CocoaError(.fileReadNoSuchFile) }
            inputSHA256 = try file.withReadAccess { try PhotoIdentity.fallback(for: $0).contentIdentifier }
            error = nil
        } catch { inputSHA256 = nil; self.error = error }
    }

    func validate() throws {
        if let error { throw error }
        guard let file = photo.file, let inputSHA256,
              try file.withReadAccess({ try PhotoIdentity.fallback(for: $0).contentIdentifier }) == inputSHA256 else {
            throw BatchExportError.target(L10n.text("原始文件已被替换，请重新选择照片。"))
        }
    }
}

struct IOSCollectionExportReview {
    struct Row: Identifiable {
        let photo: IOSCollectionPhoto
        let record: VersionedPhotoEdit?
        let settings: RawSettings?
        let look: URL?
        let lookSHA256: String?
        let lookName: String?
        let error: Error?
        var id: String { photo.id }
    }
    let selection: [String]
    let rows: [Row]
    let format: BatchOutputFormat
    let longEdge: Int?
    var ready: Bool { !rows.isEmpty && rows.allSatisfy { $0.error == nil && $0.record != nil && $0.settings != nil } }
}

final class IOSBatchSelection: ObservableObject {
    @Published var selection = BatchSelectionSession<String>()
    @Published private(set) var photos: [String: IOSCollectionPhoto] = [:]
    @Published private(set) var failures: [String: String] = [:]

    func append(_ photo: IOSAdjustmentPhoto) {
        guard photos[photo.id] == nil else { return }
        photos[photo.id] = IOSCollectionPhoto(photo)
        selection.append([photo.id])
    }

    func remove(_ id: String) { photos.removeValue(forKey: id); failures.removeValue(forKey: id); selection.remove(id) }

    func refreshValidation() {
        let snapshot = photos
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var errors: [String: String] = [:]
            for (id, photo) in snapshot {
                do { try photo.validate() } catch { errors[id] = error.localizedDescription }
            }
            let result = errors
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (id, photo) in snapshot where self.photos[id]?.photo.file == photo.photo.file {
                    self.failures[id] = result[id]
                }
            }
        }
    }

    var exportInput: IOSCollectionExportInput {
        .init(selection: selection.targets(), photos: photos)
    }

    func prepareExport(store: EditPersistence, skipping: Set<String>, format: BatchOutputFormat, longEdge: Int?,
                       probeHDR: (URL) throws -> Bool, validateActive: (String) throws -> Void,
                       resolveLook: (RawSettings) throws -> (URL?, String?)) -> IOSCollectionExportReview {
        exportInput.prepareExport(store: store, skipping: skipping, format: format, longEdge: longEdge,
            probeHDR: probeHDR, validateActive: validateActive, resolveLook: resolveLook)
    }

    func freeze(_ review: IOSCollectionExportReview, store: EditPersistence, journal: BatchJournalStore,
                validateActive: (String) throws -> Void) throws -> BatchExportJob {
        try exportInput.freeze(review, store: store, journal: journal, validateActive: { key in
            guard selection.targets() == review.selection,
                  photos[key]?.photo.file == review.rows.first(where: { $0.id == key })?.photo.photo.file else {
                throw EditPersistenceConflict.changed
            }
            try validateActive(key)
        })
    }
}

// 预检与复制使用主线程固化的集合值，后台不直接读取 ObservableObject 的可变字典。
struct IOSCollectionExportInput {
    let selection: [String]
    let photos: [String: IOSCollectionPhoto]

    func prepareExport(store: EditPersistence, skipping: Set<String>, format: BatchOutputFormat, longEdge: Int?,
                       probeHDR: (URL) throws -> Bool,
                       validateActive: (String) throws -> Void,
                       resolveLook: (RawSettings) throws -> (URL?, String?)) -> IOSCollectionExportReview {
        let selected = selection
        let rows = selected.filter { !skipping.contains($0) }.compactMap { id -> IOSCollectionExportReview.Row? in
            guard let photo = photos[id] else { return nil }
            do {
                try photo.validate()
                try validateActive(id)
                guard ExportSize.isValid(longEdge) else { throw BatchExportError.global(L10n.text("导出尺寸无效。")) }
                let record = try store.versionedState(for: photo.photo.identity)
                var settings = record.state?.settings ?? .default
                if record.state==nil,let file=photo.photo.file,try file.withReadAccess(probeHDR) { settings.hdr=HDRSettings() }
                if format == .hdrJPEG && !settings.isHDREditing { throw BatchExportError.target(L10n.text("HDR JPEG 需要启用 HDR 编辑。")) }
                let (look, name) = try settings.isHDREditing ? (nil,nil) : resolveLook(settings)
                if settings.hasLook && look == nil {
                    throw BatchExportError.target(L10n.text("目标所需的外观不可用，请先导入外观。"))
                }
                let hash = try look.map { try PhotoIdentity.fallback(for: $0).contentIdentifier! }
                return .init(photo: photo, record: record, settings: settings, look: look, lookSHA256: hash, lookName: name, error: nil)
            } catch {
                return .init(photo: photo, record: nil, settings: nil, look: nil, lookSHA256: nil, lookName: nil, error: error)
            }
        }
        return .init(selection: selected, rows: rows, format: format, longEdge: longEdge)
    }

    func freeze(_ review: IOSCollectionExportReview, store: EditPersistence, journal: BatchJournalStore,
                validateActive: (String) throws -> Void) throws -> BatchExportJob {
        func validateReview() throws {
            guard review.ready, selection == review.selection else { throw EditPersistenceConflict.changed }
            for row in review.rows {
                guard photos[row.id]?.photo.file == row.photo.photo.file,
                      try store.versionedState(for: row.photo.photo.identity) == row.record else { throw EditPersistenceConflict.changed }
                try row.photo.validate()
                try validateActive(row.id)
                if let look = row.look, try PhotoIdentity.fallback(for: look).contentIdentifier != row.lookSHA256 {
                    throw EditPersistenceConflict.changed
                }
            }
        }
        try validateReview()
        let jobID = UUID()
        do {
            var targets: [BatchTarget] = []
            for (ordinal, row) in review.rows.enumerated() {
                let photo = row.photo.photo
                let input = try photo.file!.withReadAccess {
                    try BatchInputStore.copy($0, identity: photo.identity, jobID: jobID, root: journal.directory)
                }
                var look: URL?
                if let original = row.look {
                    let folder = try BatchInputStore.directory(for: jobID, root: journal.directory).deletingLastPathComponent()
                    let destination = folder.appendingPathComponent("look-\(ordinal).\(original.pathExtension)")
                    try FileManager.default.copyItem(at: original, to: destination)
                    look = destination
                }
                var target = BatchTarget(identity: photo.identity, sourceURL: input, displayName: photo.displayName,
                    sourceKind: photo.isRaw ? .raw : .raster)
                target.frozen = .init(ordinal: ordinal, settings: row.settings!, inputSHA256: row.photo.inputSHA256!,
                    lookURL: look, lookSHA256: row.lookSHA256, lookName: row.lookName, outputFormat: review.format, longEdge: review.longEdge)
                try target.frozen!.verifyFiles(input: input)
                targets.append(target)
            }
            let first = targets[0]
            let source = BatchSourceSnapshot(identity: first.identity, sourceFile: .externallyManaged(first.sourceURL),
                displayName: first.displayName, sourceKind: first.sourceKind, settings: first.frozen!.settings)
            var job = BatchExportJob(id: jobID, source: source, targets: targets, outputFormat: review.format, longEdge: review.longEdge)
            job.version = 2; job.settingsMode = .perTargetFrozen
            // 文件复制期间也可能产生新编辑；最后一次核对必须在发布 journal 前。
            try validateReview()
            try journal.save(job)
            return job
        } catch { try? journal.discard(id: jobID); throw error }
    }
}
