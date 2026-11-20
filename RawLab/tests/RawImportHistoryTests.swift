import RawLabKit
import CryptoKit
import Foundation
import UIKit

@_silgen_name("rawlab_import_counter_reset")
func rawlabImportCounterReset()
@_silgen_name("rawlab_import_counter_process_calls")
func rawlabImportCounterProcessCalls() -> Int32
@_silgen_name("rawlab_import_counter_core_decode")
func rawlabImportCounterCoreDecode() -> Int32
@_silgen_name("rawlab_import_counter_cancelled_status")
func rawlabImportCounterCancelledStatus() -> Int32
@_silgen_name("rawlab_import_counter_set_on_process")
func rawlabImportCounterSetOnProcess(_ callback: (@convention(c) () -> Void)?)

private final class CancelTriggerBox {
    static let lock = NSLock()
    static var model: RawEditorViewModel?
    static var request: UUID?
    static func trigger() {
        lock.lock()
        let m = model
        let r = request
        model = nil
        request = nil
        lock.unlock()
        guard let m, let r else { return }
        DispatchQueue.main.async {
            m.cancelImageImport(r)
        }
    }
}

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
    let histogram: Sony2FujiProcessor.RGBHistogram?
    let baseHistogram: Sony2FujiProcessor.RGBHistogram?

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

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.message(message) }
        assertions += 1
        print("PASS: \(message)")
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func render(_ model: RawEditorViewModel, settings: RawSettings,
                               deliveries: Deliveries) throws -> [() -> Void] {
        // 与 ContentView 的已提交参数观察器同步，草稿参考不走这个入口。
        model.committedPreviewSettings = settings
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
        let c = PhotoIdentity(resourceIdentifier: "raw-history-unseen-\(UUID().uuidString)")
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
                  publishedB.histogram != nil && publishedB.baseHistogram != nil && publishedB.geometry == bSettings.geometry,
                  "RAW B publishes pixels, geometry and both histograms")
        let bRevision = model.sourceRevision
        lateA.forEach { $0() }
        try check(Content(model) == publishedB && model.sourceRevision == bRevision && !model.isBusy,
                  "late decoded RAW A cannot replace B source, pixels, geometry or history")
        try check(aCallbacks.isEmpty && bCallbacks == [bSettings], "late RAW A cannot invoke its restore callback")
        try check(aImported == 0 && bImported == 1,
                  "only accepted RAW B invokes the import success callback used by analytics")

        var cCallbacks: [RawSettings] = []
        model.importImage(from: .raw(raw), identity: c,
                          onSettingsRestored: { cCallbacks.append($0) })
        let currentC = try deliveries.take()
        currentC.forEach { $0() }
        if let url = model.sourceFile?.withReadAccess({ $0 }) { ownedCacheURLs.insert(url) }
        let neutralProcessor = Sony2FujiProcessor()
        let neutralReference = try neutralProcessor.processRaw(
            url: raw, settings: .default, previewLongEdge: 1280, lutURL: nil, viewportPreview: true)
        let neutralReferenceImage = neutralProcessor.makeUIImage(
            from: neutralReference.buffer, orientation: neutralReference.orientation)
        try check(model.sourceIdentity == c && cCallbacks == [.default] &&
                  model.restoredSettings == .default && model.editSaveState == .idle &&
                  neutralReferenceImage?.pngData() == model.previewImage?.pngData(),
                  "unseen RAW import renders the neutral default without a film or recipe")

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
        // Imported metadata is part of the record even when settings carry a LUT identity.
        let metadataID = PhotoIdentity(resourceIdentifier: "raw-history-metadata")
        var metadataSettings = RawSettings.default
        metadataSettings.lutID = "missing-look-for-metadata-test"
        let metadataRecord = PhotoEditState(settings: metadataSettings, updatedAt: Date(timeIntervalSince1970: 123))
            .replacing(settings: metadataSettings, preservingFilmID: nil)
        try store.save(metadataID, state: metadataRecord)
        model.importImage(from: .raw(raw), identity: metadataID)
        try deliveries.take().forEach { $0() }
        if let url = model.sourceFile?.withReadAccess({ $0 }) { ownedCacheURLs.insert(url) }
        metadataSettings.exposure = 0.3
        model.queueSettingsSave(metadataSettings)
        try check(model.saveCurrentSettings(metadataSettings), "metadata record edit saves")
        try check(store.state(for: metadataID)?.filmID == nil &&
                  store.state(for: metadataID)?.settings.lutID == "missing-look-for-metadata-test",
                  "ordinary edit retains an imported explicit nil film identity")
        try check(store.state(for: metadataID)!.updatedAt > metadataRecord.updatedAt,
                  "successful persistence refreshes the existing timestamp semantics")
        let editRevision = UUID()
        let noDraft = EditorDraftSnapshot(geometry: nil, lens: nil, tool: .film)
        guard case .prepared(let reset) = model.prepareReset(.group(.light), settings: metadataSettings,
                                                            revision: editRevision, draft: noDraft) else {
            throw Failure.message("light reset should prepare from the complete current record")
        }
        let savedMetadata = try store.state(for: metadataID)!
        try check(reset.candidate.settings.exposure == 0 && reset.candidate.filmID == nil &&
                  reset.candidate.settings.lutID == metadataSettings.lutID &&
                  reset.candidate.updatedAt == savedMetadata.updatedAt,
                  "prepared reset retains explicit nil film, unrelated LUT and candidate timestamp")
        let renderBeforeReset = model.latestRenderID
        let bytesBeforeReset = try Data(contentsOf: storeURL.appendingPathComponent("edits.json"))
        let rejectsReset: () -> Bool = {
            model.commitReset(reset, settings: metadataSettings, revision: editRevision, draft: noDraft) == nil
        }
        try check(model.commitReset(reset, settings: metadataSettings, revision: UUID(), draft: noDraft) == nil,
                  "edit revision changes reject a prepared reset")
        var changedSnapshot = metadataSettings
        changedSnapshot.saturation = 0.7
        try check(model.commitReset(reset, settings: changedSnapshot, revision: editRevision, draft: noDraft) == nil,
                  "same-revision committed value changes reject a prepared reset")
        let originalSourceRevision = model.sourceRevision
        model.sourceRevision = UUID()
        try check(rejectsReset(), "source revision changes reject a prepared reset")
        model.sourceRevision = originalSourceRevision
        let originalSource = model.sourceFile
        model.sourceFile = .externallyManaged(output.appendingPathComponent("other-source.ARW"))
        try check(rejectsReset(), "actual source path changes reject a prepared reset")
        model.sourceFile = originalSource
        model.sourceIdentity = a
        try check(rejectsReset(), "source identity changes reject a prepared reset")
        model.sourceIdentity = metadataID
        let originalWB = model.rawWhiteBalance
        model.rawWhiteBalance = .init(temperature: 5100, tint: 9, isCalibrated: true)
        try check(rejectsReset(), "same-revision white balance metadata changes reject a prepared reset")
        if let originalWB {
            model.rawWhiteBalance = .init(temperature: originalWB.temperature, tint: originalWB.tint,
                                         isCalibrated: !originalWB.isCalibrated)
            try check(rejectsReset(), "white balance calibration status is part of the prepared context")
        }
        model.rawWhiteBalance = originalWB
        model.retainEditMetadata(savedMetadata.replacing(settings: metadataSettings, preservingFilmID: "changed-film"))
        try check(rejectsReset(), "same-revision external film identity changes reject a prepared reset")
        model.retainEditMetadata(savedMetadata)
        var changedDraft = noDraft
        changedDraft.geometry = GeometrySettings()
        try check(model.commitReset(reset, settings: metadataSettings, revision: editRevision, draft: changedDraft) == nil,
                  "draft state changes reject a prepared reset")
        let bytesAfterRejectedReset = try Data(contentsOf: storeURL.appendingPathComponent("edits.json"))
        try check(model.latestRenderID == renderBeforeReset && model.pendingSettings == nil &&
                  bytesAfterRejectedReset == bytesBeforeReset,
                  "rejected tokens cause no render or persistence request")
        guard let accepted = model.commitReset(reset, settings: metadataSettings, revision: editRevision, draft: noDraft) else {
            throw Failure.message("current reset token was rejected")
        }
        try check(accepted.settings.exposure == 0 && model.pendingSettings == nil && model.latestRenderID == renderBeforeReset,
                  "ordinary reset returns one replacement without saving ahead of the UI owner")
        model.queueSettingsSave(accepted.settings)
        try check(model.saveCurrentSettings(accepted.settings), "ordinary reset follows the original queued save entry")
        if case .unchanged = model.prepareReset(.group(.light), settings: accepted.settings,
                                               revision: UUID(), draft: noDraft) {
            try check(model.pendingSettings == nil, "unchanged reset creates no save request")
        } else { throw Failure.message("default light reset should be unchanged") }

        var paired = accepted.settings
        paired.geometry.cropWidth = 0.8
        paired.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: false)
        let pairDraft = EditorDraftSnapshot(geometry: paired.geometry, lens: paired, tool: .geometry)
        if case .blocked = model.prepareReset(.all, settings: accepted.settings, revision: editRevision, draft: pairDraft) {
            try check(true, "full reset blocks until the draft is resolved")
        } else { throw Failure.message("full reset bypassed the active draft") }
        guard let draftCommit = model.prepareDraft(settings: accepted.settings, revision: editRevision, draft: pairDraft) else {
            throw Failure.message("changed draft should prepare")
        }
        var stalePair = pairDraft
        stalePair.lens?.lensCorrection = nil
        try check(!model.saveDraft(draftCommit, settings: accepted.settings, revision: editRevision, draft: stalePair),
                  "changed lens half makes a prepared geometry draft stale")
        model.queueSettingsSave(accepted.settings)
        let oldSave = model.editSaveWork
        try check(model.saveDraft(draftCommit, settings: accepted.settings, revision: editRevision, draft: pairDraft),
                  "changed geometry and lens persist as one candidate")
        oldSave?.perform()
        try check(store.state(for: metadataID)?.settings == paired && model.pendingSettings == nil,
                  "a previously queued old autosave cannot overwrite the saved draft")
        try check(model.consumePersistedEditorSettings(paired) && !model.consumePersistedEditorSettings(paired),
                  "saved candidate observer suppression is exact and consumes once")
        guard let secondDraft = model.prepareDraft(settings: accepted.settings, revision: editRevision, draft: pairDraft),
              model.saveDraft(secondDraft, settings: accepted.settings, revision: editRevision, draft: pairDraft) else {
            throw Failure.message("second candidate should save")
        }
        model.sourceRevision = UUID()
        try check(!model.consumePersistedEditorSettings(paired),
                  "saved-candidate suppression cannot consume settings from another source revision")
        model.sourceRevision = originalSourceRevision
        guard let thirdDraft = model.prepareDraft(settings: accepted.settings, revision: editRevision, draft: pairDraft),
              model.saveDraft(thirdDraft, settings: accepted.settings, revision: editRevision, draft: pairDraft) else {
            throw Failure.message("candidate after stale-source consumption should save")
        }
        var followingEdit = paired
        followingEdit.exposure = 0.4
        try check(!model.consumePersistedEditorSettings(followingEdit) && !model.consumePersistedEditorSettings(paired),
                  "a following ordinary edit is never swallowed by saved-candidate suppression")
        var changedLook = followingEdit
        changedLook.lutID = "explicitly-selected-look"
        model.queueSettingsSave(changedLook)
        try check(model.saveCurrentSettings(changedLook) && store.state(for: metadataID)?.filmID == "explicitly-selected-look",
                  "a real look identity change synchronizes film metadata with its selected LUT")
        let finalHash = try hash(Data(contentsOf: raw))
        try check(finalHash == originalHash, "RAW fixture bytes remain unchanged")
        try verifySingleDecodeAndCancellation(raw: raw, output: output)
        let summary: [String: Any] = ["assertions": assertions, "rawSHA256": originalHash,
                                      "previewSHA256": hash(restored.previewImage!.pngData()!),
                                      "nativeWidth": restored.nativeImageSize!.width,
                                      "nativeHeight": restored.nativeImageSize!.height]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("summary.json"))
        print("PASS: real RAW import/history suite (\(assertions) assertions)")
    }

    private static func verifySingleDecodeAndCancellation(raw: URL, output: URL) throws {
        let store = try EditPersistence(directory: output.appendingPathComponent("decode-count-edits"))
        let queue = DispatchQueue(label: "com.rawlab.tests.raw-import-decode-count")
        let model = RawEditorViewModel(editPersistence: store, importQueue: queue)

        func waitImport(_ identity: PhotoIdentity, settings: RawSettings? = nil) throws {
            if let settings {
                try store.save(identity, state: PhotoEditState(settings: settings))
            }
            let doneLock = NSCondition()
            var finished = false
            queue.async {
                doneLock.lock()
                finished = true
                doneLock.broadcast()
                doneLock.unlock()
            }
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                doneLock.lock()
                let isDone = finished
                doneLock.unlock()
                if isDone && !model.isBusy && !model.previewRendering { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }

        // (a) Default settings -> 1 processRaw call, 1 core RAW decode.
        let defaultID = PhotoIdentity(resourceIdentifier: "decode-default-\(UUID().uuidString)")
        rawlabImportCounterReset()
        model.importImage(from: .raw(raw), identity: defaultID)
        try waitImport(defaultID)
        if let url = model.sourceFile?.withReadAccess({ $0 }) { try? FileManager.default.removeItem(at: url) }
        try check(model.hasImage && rawlabImportCounterProcessCalls() == 1 && rawlabImportCounterCoreDecode() == 1,
                  "default RAW import runs 1 processRaw and 1 core RAW decode (calls=\(rawlabImportCounterProcessCalls()) decode=\(rawlabImportCounterCoreDecode()))")

        // (b) Geometry + lens correction enabled -> 1 processRaw call, 1 core RAW decode.
        let geomLensID = PhotoIdentity(resourceIdentifier: "decode-geom-lens-\(UUID().uuidString)")
        var geomLens = RawSettings.default
        geomLens.geometry.cropWidth = 0.75
        geomLens.geometry.perspectiveHorizontal = 0.2
        geomLens.lensCorrection = LensCorrectionSettings(distortion: true, tca: true)
        try store.save(geomLensID, state: PhotoEditState(settings: geomLens))
        rawlabImportCounterReset()
        model.importImage(from: .raw(raw), identity: geomLensID)
        try waitImport(geomLensID)
        if let url = model.sourceFile?.withReadAccess({ $0 }) { try? FileManager.default.removeItem(at: url) }
        try check(model.hasImage && rawlabImportCounterProcessCalls() == 1 && rawlabImportCounterCoreDecode() == 1,
                  "geometry+lens RAW import runs 1 processRaw and 1 core RAW decode (calls=\(rawlabImportCounterProcessCalls()) decode=\(rawlabImportCounterCoreDecode()))")

        // (c) Custom WB + geometry -> <=2 core RAW decodes (neutral base + custom WB).
        let customWBID = PhotoIdentity(resourceIdentifier: "decode-custom-wb-\(UUID().uuidString)")
        var customWB = RawSettings.default
        customWB.whiteBalanceMode = .custom
        customWB.temperature = 6200
        customWB.tint = 12
        customWB.geometry.cropWidth = 0.8
        try store.save(customWBID, state: PhotoEditState(settings: customWB))
        rawlabImportCounterReset()
        model.importImage(from: .raw(raw), identity: customWBID)
        try waitImport(customWBID)
        if let url = model.sourceFile?.withReadAccess({ $0 }) { try? FileManager.default.removeItem(at: url) }
        try check(model.hasImage && rawlabImportCounterProcessCalls() == 2 && rawlabImportCounterCoreDecode() <= 2,
                  "custom WB RAW import runs 2 processRaw and <=2 core RAW decodes (calls=\(rawlabImportCounterProcessCalls()) decode=\(rawlabImportCounterCoreDecode()))")

        // (d) Cooperative cancellation stops < 1.0s via SONY2FUJI_STATUS_CANCELLED without error leak, and subsequent import succeeds.
        let cancelID = PhotoIdentity(resourceIdentifier: "decode-cancel-\(UUID().uuidString)")
        rawlabImportCounterReset()
        CancelTriggerBox.lock.lock()
        CancelTriggerBox.model = model
        CancelTriggerBox.request = nil
        CancelTriggerBox.lock.unlock()
        rawlabImportCounterSetOnProcess {
            CancelTriggerBox.trigger()
        }
        queue.suspend()
        let start = CFAbsoluteTimeGetCurrent()
        let req = model.importImage(from: .raw(raw), identity: cancelID)
        CancelTriggerBox.lock.lock()
        CancelTriggerBox.request = req
        CancelTriggerBox.lock.unlock()
        queue.resume()
        let queueDone = NSCondition()
        var queueFinished = false
        queue.async {
            queueDone.lock()
            queueFinished = true
            queueDone.broadcast()
            queueDone.unlock()
        }
        let cancelDeadline = Date().addingTimeInterval(15)
        while Date() < cancelDeadline {
            queueDone.lock()
            let done = queueFinished
            queueDone.unlock()
            if done { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try check(elapsed < 1.0 && rawlabImportCounterCancelledStatus() >= 1 && !model.isBusy && model.statusMessage == nil,
                  "cooperative RAW import cancellation aborted in \(String(format: "%.3f", elapsed))s (cancelledStatus=\(rawlabImportCounterCancelledStatus())) with no error leak")

        let followUpID = PhotoIdentity(resourceIdentifier: "decode-followup-\(UUID().uuidString)")
        rawlabImportCounterReset()
        model.importImage(from: .raw(raw), identity: followUpID)
        try waitImport(followUpID)
        if let url = model.sourceFile?.withReadAccess({ $0 }) { try? FileManager.default.removeItem(at: url) }
        try check(model.hasImage && model.sourceIdentity == followUpID && model.statusMessage == nil,
                  "follow-up RAW import succeeds cleanly after cooperative cancellation")
    }
}
