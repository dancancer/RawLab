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
