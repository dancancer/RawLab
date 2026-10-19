import Foundation
import Photos
import CoreGraphics
import ImageIO

@main
struct BatchPublicationTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "BatchPublicationRegression", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        print("PASS: \(message)")
    }

    static func writeRasterFixture(to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels: [UInt8] = [
            40, 80, 120, 255, 180, 100, 50, 255, 90, 160, 70, 255,
            210, 70, 110, 255, 70, 180, 190, 255, 200, 200, 220, 255
        ]
        let image = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(data: bytes.baseAddress, width: 3, height: 2,
                                           bitsPerComponent: 8, bytesPerRow: 12,
                                           space: colorSpace,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return context.makeImage()
        }
        guard let image,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw NSError(domain: "BatchPublicationRegression", code: 2) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "BatchPublicationRegression", code: 3)
        }
    }

    @MainActor static func waitForCompletion(_ model: BatchExportModel,
                                             timeout: TimeInterval = 90) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(!model.isRunning, "Batch model finishes before the \(Int(timeout)) second deadline")
    }

    @MainActor static func testRasterBatchRender(root: URL, journal: BatchJournalStore) async throws {
        let rasterURL = root.appendingPathComponent("batch-source.jpg")
        try writeRasterFixture(to: rasterURL)
        var settings = RawSettings.default
        settings.exposure = 0.25
        settings.hsl.set(.saturation, channel: 2, value: -20)
        settings.photoEffects.vignetteAmount = -25
        let source = BatchSourceSnapshot(identity: PhotoIdentity(resourceIdentifier: "raster-source"),
                                         sourceFile: .externallyManaged(rasterURL), displayName: "batch-source.jpg",
                                         sourceKind: .raster, settings: settings)
        let rasterTarget = BatchTarget(identity: PhotoIdentity(resourceIdentifier: "raster-target"),
                                       sourceURL: rasterURL, displayName: "batch-target.jpg",
                                       sourceKind: .raster)
        var targets = [rasterTarget]
        let rawURL = Bundle.main.url(forResource: "batch-raw-fixture", withExtension: "DNG")
            ?? ProcessInfo.processInfo.environment["RAWLAB_TEST_RAW"].map(URL.init(fileURLWithPath:))
        if let rawURL, FileManager.default.fileExists(atPath: rawURL.path) {
            targets.append(BatchTarget(identity: PhotoIdentity(resourceIdentifier: "raw-target"),
                                       sourceURL: rawURL, displayName: "raw-target.ARW",
                                       sourceKind: .raw))
        }
        try require(Set(targets.map(\.sourceKind)) == [.raster, .raw],
                    "Batch model receives both raster and RAW targets")
        let preview = try await BatchExportModel(job: BatchExportJob(source: source, targets: targets),
                                                  journalStore: journal).preview(target: rasterTarget)
        try require(preview.cgImage != nil, "Batch model previews a strict-loaded raster target")

        let jpegDirectory = root.appendingPathComponent("jpeg-output", isDirectory: true)
        try FileManager.default.createDirectory(at: jpegDirectory, withIntermediateDirectories: true)
        let jpegModel = BatchExportModel(
            job: BatchExportJob(source: source, targets: targets), journalStore: journal,
            jpegWriter: { data, name, _, checkpoint in
                let destination = jpegDirectory.appendingPathComponent(name)
                try data.write(to: destination)
                try checkpoint("file:\(destination.path)")
            })
        jpegModel.start()
        try await waitForCompletion(jpegModel)
        try require(jpegModel.job.status == .completed && jpegModel.job.targets.allSatisfy { $0.status == .succeeded },
                    "Batch model completes mixed raster/RAW JPEG rendering through the processor")
        let jpegOutputs = try FileManager.default.contentsOfDirectory(at: jpegDirectory, includingPropertiesForKeys: nil)
        try require(jpegOutputs.count == targets.count && jpegOutputs.allSatisfy {
            CGImageSourceCreateWithURL($0 as CFURL, nil) != nil
        }, "Batch model publishes readable JPEG output for every mixed target")

        let job = BatchExportJob(source: source, targets: targets, outputFormat: .renderedDNG)
        let model = BatchExportModel(job: job, journalStore: journal)
        model.start()
        try await waitForCompletion(model)
        try require(model.job.status == .completed && model.job.targets.allSatisfy { $0.status == .succeeded },
                    "Batch model completes mixed raster/RAW rendered DNG rendering")
        let outputs = model.fileExportURLs ?? []
        try require(outputs.count == targets.count && outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                    "Batch model publishes every raster/mixed DNG output")
        for output in outputs {
            try require(CGImageSourceCreateWithURL(output as CFURL, nil) != nil,
                        "Batch model DNG output is a readable TIFF container")
            try? FileManager.default.removeItem(at: output)
        }
        if let output = outputs.first { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
    }

    @MainActor static func main() async throws {
        try require(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied,
                    "test process has no Photos access")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-publication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try BatchJournalStore(directory: root.appendingPathComponent("journal"))
        try await testRasterBatchRender(root: root, journal: journal)
        let source = BatchSourceSnapshot(identity: PhotoIdentity(resourceIdentifier: "source"),
                                        sourceFile: .externallyManaged(root.appendingPathComponent("source.ARW")), displayName: "source.ARW", settings: .default)
        let output = root.appendingPathComponent("published.dng")
        let bytes = Data("already published DNG".utf8)
        try bytes.write(to: output)
        var job = BatchExportJob(source: source, targets: [BatchTarget(
            identity: PhotoIdentity(resourceIdentifier: "target"), sourceURL: source.sourceFile.withReadAccess({ $0 }),
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
