import Foundation
import ImageIO
import UIKit

enum TestFailure: Error { case message(String) }

/// Captures work after decoding/rendering. Only the test's main thread releases
/// its publications, so lateness is controlled without delaying production IO.
final class ResultCollector {
    private let condition = NSCondition()
    private var deliveries: [() -> Void] = []

    func append(_ delivery: @escaping () -> Void) {
        condition.lock()
        deliveries.append(delivery)
        condition.broadcast()
        condition.unlock()
    }

    func take(minimum: Int = 1) throws -> [() -> Void] {
        let deadline = Date().addingTimeInterval(15)
        condition.lock()
        defer { condition.unlock() }
        while deliveries.count < minimum {
            guard condition.wait(until: deadline) else {
                throw TestFailure.message("Timed out waiting for \(minimum) completed results; got \(deliveries.count)")
            }
        }
        let completed = deliveries
        deliveries.removeAll()
        return completed
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return deliveries.count
    }
}

/// These are externally visible source/pixel/settings values, not request IDs.
struct PublishedContent: Equatable {
    let url: URL?
    let identity: PhotoIdentity?
    let kind: String?
    let name: String?
    let preview: Data?
    let comparison: Data?
    let nativeSize: CGSize?
    let histogram: Sony2FujiProcessor.RGBHistogram?
    let baseHistogram: Sony2FujiProcessor.RGBHistogram?
    let geometry: GeometrySettings
    let restored: RawSettings?
    let hasImage: Bool

    init(_ model: RawEditorViewModel) {
        url = model.sourceFile?.withReadAccess({ $0 })
        identity = model.sourceIdentity
        switch model.sourceKind {
        case .raw?: kind = "raw"
        case .raster?: kind = "raster"
        case nil: kind = nil
        }
        name = model.sourceDisplayName
        preview = model.previewImage?.pngData()
        comparison = model.basePreviewImage?.pngData()
        nativeSize = model.nativeImageSize
        histogram = model.histogram
        baseHistogram = model.baseHistogram
        geometry = model.basePreviewGeometry
        restored = model.restoredSettings
        hasImage = model.hasImage
    }
}

struct Fixture {
    let collector = ResultCollector()
    let model: RawEditorViewModel
    let aURL: URL, bURL: URL, missingURL: URL
    let aIdentity: PhotoIdentity, bIdentity: PhotoIdentity
    let aSettings: RawSettings, bSettings: RawSettings

    init(directory: URL, exportQueue: DispatchQueue = .global(qos: .userInitiated),
         importQueue: DispatchQueue = .global(qos: .userInitiated)) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        aURL = directory.appendingPathComponent("source-a.png")
        bURL = directory.appendingPathComponent("source-b.png")
        missingURL = directory.appendingPathComponent("missing-source.png")
        aIdentity = PhotoIdentity(resourceIdentifier: "import-state-a-\(UUID().uuidString)")
        bIdentity = PhotoIdentity(resourceIdentifier: "import-state-b-\(UUID().uuidString)")
        var a = RawSettings.default
        a.exposure = 0.25
        a.geometry.cropX = 0.1; a.geometry.cropY = 0.1
        a.geometry.cropWidth = 0.8; a.geometry.cropHeight = 0.8
        aSettings = a
        var b = RawSettings.default
        b.exposure = -0.35
        b.geometry.cropX = 0.2; b.geometry.cropY = 0.125
        b.geometry.cropWidth = 0.6; b.geometry.cropHeight = 0.75
        bSettings = b
        let persistence = try EditPersistence(directory: directory.appendingPathComponent("edits"))
        try persistence.save(aIdentity, state: PhotoEditState(settings: a))
        try persistence.save(bIdentity, state: PhotoEditState(settings: b))
        let collector = self.collector
        model = RawEditorViewModel(editPersistence: persistence, exportQueue: exportQueue, importQueue: importQueue,
                                  resultDelivery: { collector.append($0) })
        try Self.writeImage(aURL, size: CGSize(width: 80, height: 60),
                            colors: [UIColor(red: 0.45, green: 0.15, blue: 0.1, alpha: 1), UIColor(white: 0.25, alpha: 1)])
        try Self.writeImage(bURL, size: CGSize(width: 96, height: 64),
                            colors: [UIColor(red: 0.1, green: 0.3, blue: 0.5, alpha: 1), UIColor(red: 0.1, green: 0.45, blue: 0.2, alpha: 1)])
    }

    private static func writeImage(_ url: URL, size: CGSize, colors: [UIColor]) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            colors[0].setFill()
            context.fill(CGRect(origin: .zero, size: size))
            colors[1].setFill()
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
        guard let bytes = image.pngData() else { throw TestFailure.message("Generated image has no PNG bytes") }
        try bytes.write(to: url)
    }
}

/// The condition is used only by detached test tasks; it never blocks the main
/// thread while awaiting work that itself needs the main queue.
final class AsyncLoaderProbe {
    private let condition = NSCondition()
    private var continuation: CheckedContinuation<PhotoImportSource, Error>?
    private var completion: Result<PhotoImportSource, Error>?
    private var gateOpen = false
    private(set) var calls = 0

    func awaitGate() {
        condition.lock()
        while !gateOpen { condition.wait() }
        condition.unlock()
    }
    func openGate() {
        condition.lock(); gateOpen = true; condition.broadcast(); condition.unlock()
    }
    func load() async throws -> PhotoImportSource {
        try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            calls += 1
            self.continuation = continuation
            condition.broadcast()
            condition.unlock()
        }
    }
    func waitForRequest() throws {
        let deadline = Date().addingTimeInterval(15)
        condition.lock()
        defer { condition.unlock() }
        while continuation == nil {
            guard condition.wait(until: deadline) else { throw TestFailure.message("Async loader was not requested") }
        }
    }
    func resume(with source: PhotoImportSource) throws {
        condition.lock()
        let pending = continuation
        continuation = nil
        condition.unlock()
        guard let pending else { throw TestFailure.message("No pending async source load") }
        pending.resume(returning: source)
    }
    func finish(_ result: Result<PhotoImportSource, Error>) {
        condition.lock(); completion = result; condition.broadcast(); condition.unlock()
    }
    func waitForResult() throws -> Result<PhotoImportSource, Error> {
        let deadline = Date().addingTimeInterval(15)
        condition.lock()
        defer { condition.unlock() }
        while completion == nil {
            guard condition.wait(until: deadline) else { throw TestFailure.message("Async source load did not finish") }
        }
        return completion!
    }
    var numberOfCalls: Int {
        condition.lock(); defer { condition.unlock() }; return calls
    }
}
