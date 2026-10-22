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
                  model.rawLUTID == nil && !model.rawLUTApplied &&
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
        let savedMetadata = store.state(for: metadataID)!
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
        let summary: [String: Any] = ["assertions": assertions, "rawSHA256": originalHash,
                                      "previewSHA256": hash(restored.previewImage!.pngData()!),
                                      "nativeWidth": restored.nativeImageSize!.width,
                                      "nativeHeight": restored.nativeImageSize!.height]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("summary.json"))
        print("PASS: real RAW import/history suite (\(assertions) assertions)")
    }
}
