import Combine
import Foundation
import RawLabKit

public struct IOSAdjustmentPhoto: Identifiable {
    public let identity: PhotoIdentity
    public let displayName: String
    public let file: PhotoSourceFile?
    public let isRaw: Bool
    public var error: Error?
    public var validateSource: (() throws -> Void)?
    public var id: String { identity.key }
    public var isX3f: Bool {
        isRaw && (file?.withReadAccess { $0.pathExtension.lowercased() == "x3f" } == true ||
                  URL(fileURLWithPath: displayName).pathExtension.lowercased() == "x3f")
    }

    public init(identity: PhotoIdentity,
                displayName: String,
                file: PhotoSourceFile?,
                isRaw: Bool,
                error: Error? = nil,
                validateSource: (() throws -> Void)? = nil) {
        self.identity = identity
        self.displayName = displayName
        self.file = file
        self.isRaw = isRaw
        self.error = error
        self.validateSource = validateSource
    }
}

public struct IOSCollectionPhoto: Identifiable {
    public let photo: IOSAdjustmentPhoto
    public let inputSHA256: String?
    public let error: Error?
    public var id: String { photo.id }

    public init(_ photo: IOSAdjustmentPhoto) {
        self.photo = photo
        do {
            if let error = photo.error { throw error }
            guard let file = photo.file else { throw CocoaError(.fileReadNoSuchFile) }
            inputSHA256 = try file.withReadAccess { try PhotoIdentity.cachedFallback(for: $0).contentIdentifier }
            error = nil
        } catch { inputSHA256 = nil; self.error = error }
    }

    public func validate() throws {
        if let error { throw error }
        guard let file = photo.file, let inputSHA256,
              try file.withReadAccess({ try PhotoIdentity.cachedFallback(for: $0).contentIdentifier }) == inputSHA256 else {
            throw BatchExportError.target(L10n.text("原始文件已被替换，请重新选择照片。"))
        }
    }
}

public struct IOSCollectionExportReview {
    public struct Row: Identifiable {
        public let photo: IOSCollectionPhoto
        public let record: PhotoEditRecord?
        public let settings: RawSettings?
        public let look: URL?
        public let lookSHA256: String?
        public let lookName: String?
        public let error: Error?
        public let editGeneration: UInt64
        public var id: String { photo.id }

        public init(photo: IOSCollectionPhoto, record: PhotoEditRecord?, settings: RawSettings?,
                    look: URL?, lookSHA256: String?, lookName: String?, error: Error?, editGeneration: UInt64) {
            self.photo = photo
            self.record = record
            self.settings = settings
            self.look = look
            self.lookSHA256 = lookSHA256
            self.lookName = lookName
            self.error = error
            self.editGeneration = editGeneration
        }
    }
    public let selection: [String]
    public let rows: [Row]
    public let format: BatchOutputFormat
    public let longEdge: Int?
    public let outputSharpening: OutputSharpening
    public var ready: Bool { !rows.isEmpty && rows.allSatisfy { $0.error == nil && $0.record != nil && $0.settings != nil } }

    public init(selection: [String], rows: [Row], format: BatchOutputFormat, longEdge: Int?,
                outputSharpening: OutputSharpening = .off) {
        self.selection = selection
        self.rows = rows
        self.format = format
        self.longEdge = longEdge
        self.outputSharpening = outputSharpening
    }
}

public final class IOSBatchSelection: ObservableObject {
    @Published public var selection = BatchSelectionSession<String>()
    @Published public private(set) var photos: [String: IOSCollectionPhoto] = [:]
    @Published public private(set) var failures: [String: String] = [:]

    public init() {}

    public func append(_ photo: IOSAdjustmentPhoto) {
        guard photos[photo.id] == nil else { return }
        photos[photo.id] = IOSCollectionPhoto(photo)
        selection.append([photo.id])
    }

    public func remove(_ id: String) { photos.removeValue(forKey: id); failures.removeValue(forKey: id); selection.remove(id) }

    public func refreshValidation() {
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

    public var exportInput: IOSCollectionExportInput {
        .init(selection: selection.targets(), photos: photos)
    }

    public func prepareExport(store: EditPersistence, skipping: Set<String>, format: BatchOutputFormat, longEdge: Int?,
                              outputSharpening: OutputSharpening = .off,
                              x3fDefaultMode: (URL) throws -> X3fMode, probeHDR: (URL) throws -> Bool, validateActive: (String) throws -> Void,
                              resolveLook: (RawSettings) throws -> (URL?, String?),
                              validateCameraProfile: (HDRCameraProfile) throws -> Void = { _ in },
                              editGeneration: (String) -> UInt64 = { _ in 0 }) -> IOSCollectionExportReview {
        exportInput.prepareExport(store: store, skipping: skipping, format: format, longEdge: longEdge,
            outputSharpening: outputSharpening,
            x3fDefaultMode: x3fDefaultMode, probeHDR: probeHDR, validateActive: validateActive,
            resolveLook: resolveLook, validateCameraProfile: validateCameraProfile, editGeneration: editGeneration)
    }

    public func freeze(_ review: IOSCollectionExportReview, store: EditPersistence, journal: BatchJournalStore,
                       validateActive: (String) throws -> Void,
                       editGeneration: (String) -> UInt64 = { _ in 0 }) throws -> BatchExportJob {
        try exportInput.freeze(review, store: store, journal: journal, validateActive: { key in
            guard selection.targets() == review.selection,
                  photos[key]?.photo.file == review.rows.first(where: { $0.id == key })?.photo.photo.file else {
                throw AdjustmentCommitError.expired
            }
            try validateActive(key)
        }, editGeneration: editGeneration)
    }
}

// 预检与复制使用主线程固化的集合值，后台不直接读取 ObservableObject 的可变字典。
public struct IOSCollectionExportInput {
    public let selection: [String]
    public let photos: [String: IOSCollectionPhoto]

    public init(selection: [String], photos: [String: IOSCollectionPhoto]) {
        self.selection = selection
        self.photos = photos
    }

    public func prepareExport(store: EditPersistence, skipping: Set<String>, format: BatchOutputFormat, longEdge: Int?,
                              outputSharpening: OutputSharpening = .off,
                              x3fDefaultMode: (URL) throws -> X3fMode, probeHDR: (URL) throws -> Bool,
                              validateActive: (String) throws -> Void,
                              resolveLook: (RawSettings) throws -> (URL?, String?),
                              validateHDRSource: (URL, Int?) throws -> Void = { _, _ in
                                  throw HDRSettings.ModeError.unsupportedSource
                              },
                              validateCameraProfile: (HDRCameraProfile) throws -> Void = { _ in },
                              editGeneration: (String) -> UInt64 = { _ in 0 }) -> IOSCollectionExportReview {
        let selected = selection
        let rows = selected.filter { !skipping.contains($0) }.compactMap { id -> IOSCollectionExportReview.Row? in
            guard let photo = photos[id] else { return nil }
            do {
                try photo.validate()
                try validateActive(id)
                let generation = editGeneration(id)
                guard ExportSize.isValid(longEdge) else { throw BatchExportError.global(L10n.text("导出尺寸无效。")) }
                let record = try store.readState(for: photo.photo.identity, requiringLegacyDecision: true, isX3f: photo.photo.isX3f)
                let settings: RawSettings
                if let saved = record.state { settings = saved.settings }
                else {
                    guard let file = photo.photo.file else { throw CocoaError(.fileReadNoSuchFile) }
                    settings = try file.withReadAccess { url in
                        try RawSettings.sourceDefaults(for: url, isRaw: photo.photo.isRaw,
                            sourceIsHDR: probeHDR(url), x3fDefaultMode: x3fDefaultMode)
                    }
                }
                if format.requiresHDR && !settings.isHDREditing { throw BatchExportError.target(format.hdrRequiredMessage) }
                if settings.isHDREditing {
                    guard let file = photo.photo.file else { throw CocoaError(.fileReadNoSuchFile) }
                    try file.withReadAccess { try validateHDRSource($0, settings.proRAWDecodeVersion) }
                    if let profile = settings.hdr?.cameraDevelopmentSettings.cameraProfile {
                        try validateCameraProfile(profile)
                    }
                    let look = settings.hdr!.lookSettings
                    guard look.assetIsAvailable() else {
                        throw BatchExportError.target(L10n.text("目标所需的外观不可用，请先导入外观。"))
                    }
                }
                let (look, name) = try settings.isHDREditing ? (nil, nil) : resolveLook(settings)
                if settings.hasLook && look == nil {
                    throw BatchExportError.target(L10n.text("目标所需的外观不可用，请先导入外观。"))
                }
                let hash = try look.map { try PhotoIdentity.cachedFallback(for: $0).contentIdentifier! }
                return .init(photo: photo, record: record, settings: settings, look: look, lookSHA256: hash,
                    lookName: name, error: nil, editGeneration: generation)
            } catch {
                return .init(photo: photo, record: nil, settings: nil, look: nil, lookSHA256: nil,
                    lookName: nil, error: error, editGeneration: editGeneration(id))
            }
        }
        return .init(selection: selected, rows: rows, format: format, longEdge: longEdge,
                     outputSharpening: format == .renderedDNG ? .off : outputSharpening)
    }

    public func freeze(_ review: IOSCollectionExportReview, store: EditPersistence, journal: BatchJournalStore,
                       validateActive: (String) throws -> Void,
                       editGeneration: (String) -> UInt64 = { _ in 0 }) throws -> BatchExportJob {
        func validateReview() throws {
            guard review.ready, selection == review.selection else { throw AdjustmentCommitError.expired }
            for row in review.rows {
                guard photos[row.id]?.photo.file == row.photo.photo.file,
                      editGeneration(row.id) == row.editGeneration else { throw AdjustmentCommitError.expired }
                try row.photo.validate()
                try validateActive(row.id)
                if row.record?.state == nil {
                    _ = try store.readState(for: row.photo.photo.identity, requiringLegacyDecision: true, isX3f: row.photo.photo.isX3f)
                }
                if let look = row.look, try PhotoIdentity.cachedFallback(for: look).contentIdentifier != row.lookSHA256 {
                    throw AdjustmentCommitError.expired
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
                    let destination = folder.appendingPathComponent("look-\(row.lookSHA256 ?? UUID().uuidString).\(original.pathExtension)")
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.copyItem(at: original, to: destination)
                    }
                    look = destination
                }
                var target = BatchTarget(identity: photo.identity, sourceURL: input, displayName: photo.displayName,
                    sourceKind: photo.isRaw ? .raw : .raster)
                let effectiveSharpening: OutputSharpening? = review.format == .renderedDNG || review.outputSharpening == .off
                    ? nil : review.outputSharpening
                target.frozen = .init(ordinal: ordinal, settings: row.settings!, inputSHA256: row.photo.inputSHA256!,
                    lookURL: look, lookSHA256: row.lookSHA256, lookName: row.lookName, outputFormat: review.format,
                    longEdge: review.longEdge, outputSharpening: effectiveSharpening)
                try target.frozen!.verifyFiles(input: input)
                targets.append(target)
            }
            let first = targets[0]
            let source = BatchSourceSnapshot(identity: first.identity, sourceFile: .externallyManaged(first.sourceURL),
                displayName: first.displayName, sourceKind: first.sourceKind, settings: first.frozen!.settings)
            let effectiveSharpening: OutputSharpening? = review.format == .renderedDNG || review.outputSharpening == .off
                ? nil : review.outputSharpening
            var job = BatchExportJob(id: jobID, source: source, targets: targets, outputFormat: review.format,
                longEdge: review.longEdge, outputSharpening: effectiveSharpening)
            job.version = 2; job.settingsMode = .perTargetFrozen
            try validateReview()
            try journal.save(job)
            return job
        } catch { try? journal.discard(id: jobID); throw error }
    }
}
