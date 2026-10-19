import CryptoKit
import Foundation
import UIKit

private enum Failure: Error { case message(String) }

// ============================================================================
// Hold actual completed work; the main thread controls only its publication.
// ============================================================================
private final class Deliveries {
    private let condition = NSCondition()
    private var values: [() -> Void] = []

    func append(_ value: @escaping () -> Void) {
        condition.lock(); defer { condition.unlock() }
        values.append(value)
        condition.broadcast()
    }

    func take() throws -> [() -> Void] {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(60)
        while values.isEmpty {
            guard condition.wait(until: deadline) else { throw Failure.message("RAW publication timed out") }
        }
        defer { values.removeAll() }
        return values
    }
}

private struct Content: Equatable {
    let source: URL?
    let identity: PhotoIdentity?
    let restored: RawSettings?
    let preview: Data?
    let comparison: Data?
    let size: CGSize?
    let geometry: GeometrySettings
    let histogram: [CGFloat]
    let baseHistogram: [CGFloat]

    init(_ model: RawEditorViewModel) {
        source = model.sourceFile?.withReadAccess({ $0 })
        identity = model.sourceIdentity
        restored = model.restoredSettings
        preview = model.previewImage?.pngData()
        comparison = model.basePreviewImage?.pngData()
        size = model.nativeImageSize
        geometry = model.basePreviewGeometry
        histogram = model.histogram
        baseHistogram = model.baseHistogram
    }
}

@main
struct RawImportHistoryTests {
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.message(message) }
        assertions += 1
        print("PASS: \(message)")
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func render(_ model: RawEditorViewModel, settings: RawSettings,
                               deliveries: Deliveries) throws -> [() -> Void] {
        model.updatePreview(settings: settings, includeHistogram: true, quality: .final, histogramDelay: 0)
        model.renderQueue.sync {}
        model.renderQueue.sync {}
        return try deliveries.take()
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw Failure.message("Pass RAW and isolated output directory") }
        let raw = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let originalHash = try hash(Data(contentsOf: raw))
        let a = PhotoIdentity(resourceIdentifier: "raw-history-a-\(UUID().uuidString)")
        let b = PhotoIdentity(resourceIdentifier: "raw-history-b-\(UUID().uuidString)")
        var aSettings = RawSettings.default
        aSettings.exposure = 0.2
        var bSettings = RawSettings.default
        bSettings.exposure = -0.4
        bSettings.geometry.perspectiveHorizontal = 0.3
        bSettings.geometry.cropWidth = 0.7
        let storeURL = output.appendingPathComponent("edits")
        let store = try EditPersistence(directory: storeURL)
        try store.save(a, state: PhotoEditState(settings: aSettings))
        try store.save(b, state: PhotoEditState(settings: bSettings))
        let deliveries = Deliveries()
        let model = RawEditorViewModel(editPersistence: store, resultDelivery: { deliveries.append($0) })
        var ownedCacheURLs: Set<URL> = []
        defer { ownedCacheURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
        print("Simulator process home: \(NSHomeDirectory())")
        try check(Thread.isMainThread, "real RAW model publications run on the main thread")

        var aCallbacks: [RawSettings] = [], bCallbacks: [RawSettings] = []
        var aImported = 0, bImported = 0
        model.importImage(from: .raw(raw), identity: a, onImported: { aImported += 1 },
                          onSettingsRestored: { aCallbacks.append($0) })
        let lateA = try deliveries.take()
        model.importImage(from: .raw(raw), identity: b, onImported: { bImported += 1 },
                          onSettingsRestored: { bCallbacks.append($0) })
        let currentB = try deliveries.take()
        try check(model.isBusy && !model.hasImage, "completed but held RAW A cannot publish while B is pending")
        currentB.forEach { $0() }
        if let url = model.sourceFile?.withReadAccess({ $0 }) { ownedCacheURLs.insert(url) }
        let publishedB = Content(model)
        try check(model.hasImage && !model.isBusy && model.sourceKind == .raw && model.sourceIdentity == b,
                  "actual RAW B owns the editor after import")
        try check(bCallbacks == [bSettings] && model.restoredSettings == bSettings && model.editSaveState == .restored,
                  "RAW B restores its own exposure, perspective and saved notice")
        try check(publishedB.preview != nil && publishedB.comparison != nil && publishedB.size != nil &&
                  !publishedB.histogram.isEmpty && !publishedB.baseHistogram.isEmpty && publishedB.geometry == bSettings.geometry,
                  "RAW B publishes pixels, geometry and both histograms")
        let bRevision = model.sourceRevision
        lateA.forEach { $0() }
        try check(Content(model) == publishedB && model.sourceRevision == bRevision && !model.isBusy,
                  "late decoded RAW A cannot replace B source, pixels, geometry or history")
        try check(aCallbacks.isEmpty && bCallbacks == [bSettings], "late RAW A cannot invoke its restore callback")
        try check(aImported == 0 && bImported == 1,
                  "only accepted RAW B invokes the import success callback used by analytics")

        model.importImage(from: .raw(raw), identity: a)
        try deliveries.take().forEach { $0() }
        if let url = model.sourceFile?.withReadAccess({ $0 }) { ownedCacheURLs.insert(url) }
        var aEdit = aSettings
        aEdit.exposure = 0.7
        let oldPreview = try render(model, settings: aEdit, deliveries: deliveries)
        model.importImage(from: .raw(raw), identity: b)
        try deliveries.take().forEach { $0() }
        let beforeBEdit = Content(model)
        var edited = bSettings
        edited.exposure = 0.8
        edited.geometry.perspectiveVertical = -0.25
        let newPreview = try render(model, settings: edited, deliveries: deliveries)
        oldPreview.forEach { $0() }
        try check(Content(model) == beforeBEdit && model.previewRendering,
                  "late RAW A preview cannot replace B or finish B's active preview")
        newPreview.forEach { $0() }
        try check(!model.previewRendering && model.previewImage?.pngData() != beforeBEdit.preview &&
                  model.basePreviewGeometry == edited.geometry && model.sourceIdentity == b,
                  "current RAW B preview applies exposure and both perspective axes")

        model.queueSettingsSave(edited)
        try check(model.saveCurrentSettings(edited) && model.editSaveState == .saved && model.pendingSettings == nil,
                  "RAW committed edits persist and produce the saved notice")
        let reopened = try EditPersistence(directory: storeURL)
        try check(reopened.state(for: b)?.settings == edited && reopened.state(for: a)?.settings == aSettings,
                  "reopened history retains complete B edits and separate A settings")
        let restoredDeliveries = Deliveries()
        let restored = RawEditorViewModel(editPersistence: reopened, resultDelivery: { restoredDeliveries.append($0) })
        restored.importImage(from: .raw(raw), identity: b)
        try restoredDeliveries.take().forEach { $0() }
        try check(restored.restoredSettings == edited && restored.editSaveState == .restored &&
                  restored.previewImage?.pngData() == model.previewImage?.pngData() && restored.nativeImageSize == model.nativeImageSize,
                  "new RAW model restores the committed preview and perspective canvas exactly")
        let referenceProcessor = Sony2FujiProcessor()
        let reference = try referenceProcessor.processRaw(url: raw, settings: edited, previewLongEdge: 1280,
                                                          lutURL: nil, viewportPreview: true)
        let referenceImage = referenceProcessor.makeUIImage(from: reference.buffer,
                                                             orientation: reference.orientation ?? restored.sourceOrientation)
        try check(referenceImage?.pngData() == restored.previewImage?.pngData() && reference.buffer.nativeSize == restored.nativeImageSize,
                  "restored RAW preview matches independent fresh processing of the saved settings")
        let finalHash = try hash(Data(contentsOf: raw))
        try check(finalHash == originalHash, "RAW fixture bytes remain unchanged")
        let summary: [String: Any] = ["assertions": assertions, "rawSHA256": originalHash,
                                      "previewSHA256": hash(restored.previewImage!.pngData()!),
                                      "nativeWidth": restored.nativeImageSize!.width,
                                      "nativeHeight": restored.nativeImageSize!.height]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("summary.json"))
        print("PASS: real RAW import/history suite (\(assertions) assertions)")
    }
}
