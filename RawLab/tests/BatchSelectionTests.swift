import Foundation

func checkBatchSelection(_ root: URL) throws {
    func check(_ value: Bool, _ message: String) throws { try BatchExportTests.require(value, message) }
    func rejected(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    let store = try EditPersistence(directory: root.appendingPathComponent("collection-edits"))
    let collection = IOSBatchSelection()
    let journal = try BatchJournalStore(directory: root.appendingPathComponent("collection-jobs"))
    var identities: [PhotoIdentity] = []
    for index in 0..<3 {
        let file = root.appendingPathComponent("collection-\(index).png")
        try Data([UInt8(index), 2, 3]).write(to: file)
        let identity = PhotoIdentity(resourceIdentifier: "collection-\(index)")
        identities.append(identity)
        let photo = IOSAdjustmentPhoto(identity: identity, displayName: "same.png", file: .externallyManaged(file), isRaw: false)
        collection.append(photo)
        collection.append(photo)
        var settings = RawSettings.default
        settings.exposure = Double(index + 1) / 2
        settings.contrast = Double(index) * 0.1
        try store.save(identity, state: PhotoEditState(settings: settings))
    }
    try check(collection.selection.ordered == identities.map(\.key), "collection deduplicates stable identities while keeping same-named photos in order")
    try check(collection.selection.targets(excluding: identities[0].key) == identities.dropFirst().map(\.key), "synchronization excludes the selected source identity")
    collection.selection.select(identities[2].key, false)
    _ = collection.selection.beginEditing(identities[1].key)
    collection.selection.returnToCollection()
    try check(collection.selection.returnPosition == identities[1].key && collection.selection.selected.count == 2,
              "micro-edit return preserves position and selection")
    collection.selection.selectAll(true)
    var drafts: Set<String> = [identities[1].key]
    let active: (String) throws -> Void = { key in if drafts.contains(key) { throw CocoaError(.userCancelled) } }
    let look: (RawSettings) throws -> (URL?, String?) = { _ in (nil, nil) }
    let blocked = collection.prepareExport(store: store, skipping: [], format: .jpeg, longEdge: 2048, probeHDR: { _ in false }, validateActive: active, resolveLook: look)
    try check(!blocked.ready && blocked.rows[1].error != nil, "export preflight includes the active dirty target")
    let skipped = collection.prepareExport(store: store, skipping: drafts, format: .jpeg, longEdge: 2048, probeHDR: { _ in false }, validateActive: active, resolveLook: look)
    try check(skipped.ready && skipped.rows.map(\.id) == [identities[0].key, identities[2].key] && collection.selection.selected.count == 3,
              "operation skips leave collection selection and the draft untouched")
    let allSkipped = collection.prepareExport(store: store, skipping: Set(identities.map(\.key)), format: .jpeg, longEdge: nil, probeHDR: { _ in false }, validateActive: active, resolveLook: look)
    try check(!allSkipped.ready && rejected { _ = try collection.freeze(allSkipped, store: store, journal: journal, validateActive: active) }, "all skipped cannot create an empty task")
    drafts = []
    let review = collection.prepareExport(store: store, skipping: [], format: .jpeg, longEdge: 2048, probeHDR: { _ in false }, validateActive: active, resolveLook: look)
    try check(review.ready && review.rows.map { $0.settings?.exposure } == [0.5, 1, 1.5], "confirmation displays each photo's final committed settings")
    var changed = store.state(for: identities[1])!.settings
    changed.exposure = 1.2
    try store.save(identities[1], state: PhotoEditState(settings: changed))
    try check(rejected { _ = try collection.freeze(review, store: store, journal: journal, validateActive: active) }, "late saved edits invalidate a prior confirmation")
    let fresh = collection.prepareExport(store: store, skipping: [], format: .jpeg, longEdge: 2048, probeHDR: { _ in false }, validateActive: active, resolveLook: look)
    drafts.insert(identities[2].key)
    try check(rejected { _ = try collection.freeze(fresh, store: store, journal: journal, validateActive: active) }, "late unsaved drafts block freezing")
    drafts = []
    collection.selection.select(identities[2].key, false)
    try check(rejected { _ = try collection.freeze(fresh, store: store, journal: journal, validateActive: active) }, "selection changes invalidate the confirmed count")
    collection.selection.selectAll(true)
    let job = try collection.freeze(fresh, store: store, journal: journal, validateActive: active)
    try check(job.settingsMode == .perTargetFrozen && job.targets.map { $0.frozen?.settings.exposure } == [0.5, 1.2, 1.5], "confirmed export freezes each target's own snapshot")
    try check(job.targets.allSatisfy { $0.sourceURL.path.hasPrefix(journal.directory.path) } && job.targets.map { $0.frozen?.ordinal } == [0, 1, 2], "task owns input copies and freezes order")
    changed.exposure = -0.3
    try store.save(identities[1], state: PhotoEditState(settings: changed))
    let loaded = try journal.load(id: job.id)!
    try check(loaded.targets[1].frozen?.settings.exposure == 1.2, "later micro-edit cannot mutate a persisted task")
    let syncID = UUID()
    collection.selection.recordSynchronization(syncID, changed: true)
    collection.selection.recordSynchronization(UUID(), changed: false)
    try check(collection.selection.lastSynchronization == syncID, "no-change synchronization preserves the prior successful history entry")
    let lookFile = root.appendingPathComponent("collection-look.cube")
    try Data("look-one".utf8).write(to: lookFile)
    changed.lutID = "custom-look"
    try store.save(identities[1], state: PhotoEditState(settings: changed))
    let withLook: (RawSettings) throws -> (URL?, String?) = { ($0.hasLook ? lookFile : nil, "Own look") }
    let lookReview = collection.prepareExport(store: store, skipping: [], format: .renderedDNG, longEdge: nil, probeHDR: { _ in false }, validateActive: active, resolveLook: withLook)
    try Data("look-two".utf8).write(to: lookFile)
    try check(rejected { _ = try collection.freeze(lookReview, store: store, journal: journal, validateActive: active) }, "changed look invalidates export confirmation")
    let stableLook = collection.prepareExport(store: store, skipping: [], format: .renderedDNG, longEdge: nil, probeHDR: { _ in false }, validateActive: active, resolveLook: withLook)
    let looked = try collection.freeze(stableLook, store: store, journal: journal, validateActive: active)
    try FileManager.default.removeItem(at: lookFile)
    try looked.targets[1].frozen!.verifyFiles(input: looked.targets[1].sourceURL)
    try check(looked.targets[1].frozen?.lookURL != lookFile && looked.outputFormat == .renderedDNG, "task-owned look survives library deletion and retains output settings")
    let lost = collection.photos[identities[0].key]!.photo.file!
    try lost.withReadAccess { try FileManager.default.removeItem(at: $0) }
    let missing = collection.prepareExport(store: store, skipping: [], format: .jpeg, longEdge: nil, probeHDR: { _ in false }, validateActive: active, resolveLook: withLook)
    try check(missing.rows[0].error != nil && collection.selection.ordered.count == 3, "missing source is marked per photo without substitution or collection loss")
    collection.refreshValidation()
    let deadline = Date().addingTimeInterval(5)
    while collection.failures[identities[0].key] == nil && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    try check(collection.failures[identities[0].key] != nil, "collection publishes a per-photo missing-file marker after returning")

    for target in job.targets { try target.frozen!.verifyFiles(input: target.sourceURL) }
    try check(true, "original file deletion does not invalidate task-owned frozen inputs")
}
