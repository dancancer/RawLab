import Foundation
import Photos

@main
struct BatchPublicationTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "BatchPublicationRegression", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        print("PASS: \(message)")
    }

    @MainActor static func main() async throws {
        try require(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied,
                    "test process has no Photos access")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-publication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try BatchJournalStore(directory: root.appendingPathComponent("journal"))
        let source = BatchSourceSnapshot(identity: PhotoIdentity(resourceIdentifier: "source"),
                                        sourceURL: root.appendingPathComponent("source.ARW"),
                                        displayName: "source.ARW", settings: .default)
        let output = root.appendingPathComponent("published.dng")
        let bytes = Data("already published DNG".utf8)
        try bytes.write(to: output)
        var job = BatchExportJob(source: source, targets: [BatchTarget(
            identity: PhotoIdentity(resourceIdentifier: "target"), sourceURL: source.sourceURL,
            displayName: "target.ARW", status: .needsConfirmation, outputFileURL: output)],
            outputFormat: .renderedDNG, status: .interrupted)
        job.globalError = "DNG 已生成，但任务记录未更新，请先核对保存结果。"
        job.targets[0].errorMessage = job.globalError
        let model = BatchExportModel(job: job, journalStore: journal)
        try require(model.job.status == .completed && model.fileExportURLs == [output],
                    "DNG recovery exposes the published file")
        try require(model.validationMessage == nil && model.job.globalError == nil,
                    "verified DNG publication clears its obsolete checkpoint warning")

        await model.reconcilePublication()
        try require(model.validationMessage == nil && model.job.targets[0].status == .succeeded,
                    "DNG reconciliation does not request or require Photos authorization")
        try require(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied &&
                    (try? Data(contentsOf: output)) == bytes,
                    "DNG reconciliation preserves permissions and published bytes")
        model.confirmPublication(id: job.targets[0].id, saved: false)
        try require(model.job.targets[0].status == .succeeded,
                    "obsolete manual Photos confirmation cannot reset a completed DNG")

        let manualDNG = BatchExportModel(job: job, journalStore: journal)
        try FileManager.default.removeItem(at: output)
        manualDNG.confirmPublication(id: job.targets[0].id, saved: true)
        try require(manualDNG.job.targets[0].status == .pending && manualDNG.fileExportURLs == nil,
                    "DNG manual confirmation checks files instead of trusting a Photos decision")
        await model.reconcilePublication()
        try require(model.job.status == .interrupted && model.job.targets[0].status == .pending,
                    "DNG reconciliation detects a file removed after opening the task")
        try require(model.fileExportURLs == nil && model.fileExportStatus == .none,
                    "DNG reconciliation removes stale file export actions")
        let saved = try journal.load(id: job.id)
        try require(saved?.targets[0].status == .pending && saved?.targets[0].outputFileURL == nil,
                    "DNG reconciliation persists the checked file state")

        job.outputFormat = .jpeg
        job.targets[0].outputFileURL = nil
        job.targets[0].outputAssetIdentifier = "unreadable-asset"
        job.globalError = nil
        job.targets[0].errorMessage = nil
        let jpegSaved = BatchExportModel(job: job, journalStore: journal)
        try require(jpegSaved.job.targets[0].status == .needsConfirmation,
                    "JPEG still requires manual confirmation without Photos access")
        await jpegSaved.reconcilePublication()
        try require(jpegSaved.validationMessage != nil && jpegSaved.job.targets[0].status == .needsConfirmation,
                    "JPEG reconciliation still reports denied Photos access")
        jpegSaved.confirmPublication(id: job.targets[0].id, saved: true)
        try require(jpegSaved.job.targets[0].status == .succeeded,
                    "JPEG manual saved confirmation remains available")
        let jpegUnsaved = BatchExportModel(job: job, journalStore: journal)
        jpegUnsaved.confirmPublication(id: job.targets[0].id, saved: false)
        try require(jpegUnsaved.job.targets[0].status == .pending &&
                    jpegUnsaved.job.targets[0].outputAssetIdentifier == nil,
                    "JPEG manual unsaved confirmation allows a deliberate retry")
        print("PASS: batch publication model regressions")
    }
}
