import Foundation

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}

private func perTargetSnapshots(root: URL, inputs: [URL], output: URL) throws {
    var job = BatchExportJob(source: inputs[0], settings: Adjustments(), look: nil, lookName: "Neutral")
    job.outputDirectory = output
    job.items = try inputs.map { try BatchExportItem(url: $0) }
    for index in job.items.indices { job.items[index].selected = true }
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
    object["settings_mode"] = "per_target_frozen"
    let malformed = try JSONDecoder().decode(BatchExportJob.self, from: JSONSerialization.data(withJSONObject: object))
    let invalidJournal = BatchJournal(directory: root.appendingPathComponent("invalid-mode"))
    var rejected = false
    do { try invalidJournal.save(malformed) } catch { rejected = true }
    try check(rejected, "per-target mode must not silently resume as a uniform legacy job")
    object["version"] = 3
    var items = object["items"] as! [[String: Any]]
    for index in items.indices {
        var settings = Adjustments(); settings.exposure = Double(index + 1) / 2
        settings.vibrance = Double(index * 10)
        items[index]["frozen"] = ["version": 1, "settingsVersion": 1, "ordinal": index,
            "settings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)),
            "lookName": "Photo\(index)", "outputFormat": "png", "longEdge": 1024]
    }
    object["items"] = items
    var frozen = try JSONDecoder().decode(BatchExportJob.self, from: JSONSerialization.data(withJSONObject: object))
    let journal = BatchJournal(directory: root.appendingPathComponent("per-target-journal"))
    try journal.save(frozen)
    var captured: [Double] = []
    try BatchExportRunner.run(job: &frozen, journal: journal, scope: .unfinished,
                             shouldCancel: { captured.count == 1 }) { _, settings, _, destination in
        captured.append(settings.exposure)
        try check(destination.pathExtension == "png", "each item freezes its output format")
        try Data("frozen".utf8).write(to: destination)
    }
    try check(captured == [0.5], "first frozen item renders independently")
    var resumed = try journal.load()!
    try BatchExportRunner.run(job: &resumed, journal: journal, scope: .unfinished,
                             shouldCancel: { false }) { input, settings, _, destination in
        captured.append(settings.exposure)
        if input == inputs[1] { throw Failure(message: "retry me") }
        try Data("resumed".utf8).write(to: destination)
    }
    try check(captured == [0.5, 1, 1.5], "resume preserves order and skips successful items")
    resumed = try journal.load()!
    try BatchExportRunner.run(job: &resumed, journal: journal, scope: .failed,
                             shouldCancel: { false }) { _, settings, _, destination in
        captured.append(settings.exposure)
        try Data("retried".utf8).write(to: destination)
    }
    try check(captured == [0.5, 1, 1.5, 1] && resumed.succeededCount == 3,
              "retry uses the same per-target snapshot without rerunning successful photos")
    try check(resumed.items.allSatisfy { $0.output?.pathExtension == "png" }, "published items use frozen format")
    for mode in ["uniform_frozen", ""] {
        var downgraded = object
        if mode.isEmpty { downgraded.removeValue(forKey: "settings_mode") } else { downgraded["settings_mode"] = mode }
        var failed = false
        do { try journal.save(JSONDecoder().decode(BatchExportJob.self, from: JSONSerialization.data(withJSONObject: downgraded))) }
        catch { failed = true }
        try check(failed, "per-target snapshots cannot silently downgrade to a global snapshot")
    }
    var duplicate = object
    var duplicatedRows = items
    duplicatedRows[1]["input"] = duplicatedRows[0]["input"]
    duplicatedRows[1]["identity"] = duplicatedRows[0]["identity"]
    duplicatedRows[1]["resourceIdentifier"] = duplicatedRows[0]["resourceIdentifier"]
    duplicate["items"] = duplicatedRows
    var duplicateRejected = false
    do { try journal.save(JSONDecoder().decode(BatchExportJob.self, from: JSONSerialization.data(withJSONObject: duplicate))) }
    catch { duplicateRejected = true }
    try check(duplicateRejected, "frozen target identities cannot be duplicated with a new row UUID")
    var missingLook = object
    var missingLookRows = items
    var missingLookSnapshot = missingLookRows[0]["frozen"] as! [String: Any]
    var recipeSettings = Adjustments(); recipeSettings.applyMasterRecipe(.hamadaDaylightV2)
    missingLookSnapshot["settings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipeSettings))
    missingLookRows[0]["frozen"] = missingLookSnapshot; missingLook["items"] = missingLookRows
    var lookRejected = false
    do { try journal.save(JSONDecoder().decode(BatchExportJob.self, from: JSONSerialization.data(withJSONObject: missingLook))) }
    catch { lookRejected = true }
    try check(lookRejected, "a recipe snapshot cannot omit its frozen look")
    var foreign = resumed
    foreign.items[0].resourceIdentifier = "0:0"
    foreign.items[0].status = .waiting
    var touched = false
    try BatchExportRunner.run(job: &foreign, journal: journal, scope: .unfinished, shouldCancel: { false }) { _, _, _, output in
        touched = true; try Data("unexpected".utf8).write(to: output)
    }
    try check(foreign.items[0].status == .failed && !touched, "per-photo export rechecks the frozen device and inode identity")
    for invalid in ["unknown", "per_target_frozen"] {
        var bad = object; bad["settings_mode"] = invalid
        var rows = items; rows[0].removeValue(forKey: "frozen"); bad["items"] = rows
        var failed = false
        do {
            let decoded = try JSONDecoder().decode(BatchExportJob.self, from: JSONSerialization.data(withJSONObject: bad))
            try journal.save(decoded)
        } catch { failed = true }
        try check(failed, "unknown mode and missing item snapshot are rejected")
    }
}

private func journalIsolation(root: URL, inputs: [URL], output: URL) throws {
    let isolationRoot = root.appendingPathComponent("journal-isolation")
    let corruptJournal = BatchJournal(directory: isolationRoot.appendingPathComponent("corrupt"))
    try FileManager.default.createDirectory(at: corruptJournal.directory, withIntermediateDirectories: true)
    let corruptURL = corruptJournal.directory.appendingPathComponent("job.json")
    let corruptBytes = Data("{corrupt-batch-journal".utf8)
    try corruptBytes.write(to: corruptURL)

    try check(try corruptJournal.load() == nil, "corrupt job.json isolates to empty state without throwing")
    try check(!FileManager.default.fileExists(atPath: corruptURL.path), "corrupt job.json is moved out of active path")
    guard let firstArchive = corruptJournal.lastQuarantinedURL else {
        throw Failure(message: "corrupt job.json must record its archive URL")
    }
    try check(firstArchive.deletingLastPathComponent().standardizedFileURL == corruptJournal.directory.standardizedFileURL &&
              firstArchive.lastPathComponent.hasPrefix("job.json.corrupt-"),
              "corrupt job.json is renamed under job.json.corrupt-<timestamp>")
    try check(try Data(contentsOf: firstArchive) == corruptBytes, "archived corrupt job.json preserves original bytes")
    guard let loadNotice = corruptJournal.consumeQuarantinedError() else {
        throw Failure(message: "corrupt job.json must surface an isolation error for user notice")
    }
    try check(corruptJournal.consumeQuarantinedError() == nil, "quarantined error is consumed once")
    try check(L10n.format("无法读取上次批量任务：%@", String(describing: loadNotice.localizedDescription))
        .contains(loadNotice.localizedDescription), "existing localized batch recovery notice formats quarantined error")

    var recoveredJob = BatchExportJob(source: inputs[0], settings: Adjustments(), look: nil, lookName: "Recovered")
    recoveredJob.outputDirectory = output
    recoveredJob.items = [try BatchExportItem(url: inputs[0])]
    recoveredJob.items[0].selected = true
    try corruptJournal.save(recoveredJob)
    try check(try corruptJournal.load()?.id == recoveredJob.id, "save creates a new batch job after corrupt journal isolation")
    try check(try Data(contentsOf: firstArchive) == corruptBytes, "saving a new job retains the archived corrupt file on disk")

    var semanticBadObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recoveredJob)) as! [String: Any]
    semanticBadObject["settings_mode"] = "per_target_frozen"
    let semanticJobBytes = try JSONSerialization.data(withJSONObject: semanticBadObject)
    try semanticJobBytes.write(to: corruptURL)
    let replacementJob = BatchExportJob(source: inputs[1], settings: Adjustments(), look: nil, lookName: "Replacement")
    try corruptJournal.save(replacementJob)
    guard let secondArchive = corruptJournal.lastQuarantinedURL else {
        throw Failure(message: "semantically unusable job.json must be archived on save")
    }
    try check(secondArchive != firstArchive && (try Data(contentsOf: secondArchive)) == semanticJobBytes &&
              (try Data(contentsOf: firstArchive)) == corruptBytes,
              "direct save archives semantically unusable job.json without colliding with prior corrupt archives")
    try check(corruptJournal.consumeQuarantinedError() != nil && (try corruptJournal.load()?.id) == replacementJob.id,
              "direct save records quarantine error and persists replacement job")

    var badParamObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(replacementJob)) as! [String: Any]
    var badSettings = badParamObject["settings"] as! [String: Any]
    badSettings["toneControls"] = ["blackPoint": 999, "whitePoint": 0, "vibrance": 0]
    badParamObject["settings"] = badSettings
    let badParamBytes = try JSONSerialization.data(withJSONObject: badParamObject)
    try badParamBytes.write(to: corruptURL)
    try corruptJournal.discard(replacementJob)
    guard let thirdArchive = corruptJournal.lastQuarantinedURL else {
        throw Failure(message: "discard must quarantine rather than delete a damaged job.json")
    }
    try check(thirdArchive != firstArchive && thirdArchive != secondArchive &&
              (try Data(contentsOf: thirdArchive)) == badParamBytes &&
              !FileManager.default.fileExists(atPath: corruptURL.path),
              "discard preserves damaged job.json bytes on disk while clearing active journal state")
    try check(corruptJournal.consumeQuarantinedError() != nil, "discard records quarantined error for caller consumption")

    // Unconsumed quarantinedError must be cleared on entry to the next read/save/discard rather than leaking.
    let unconsumedBytes = Data("{unconsumed-quarantine".utf8)
    try unconsumedBytes.write(to: corruptURL)
    try corruptJournal.discard(replacementJob)
    try check(try corruptJournal.load() == nil && corruptJournal.consumeQuarantinedError() == nil,
              "next healthy load clears any unconsumed quarantinedError")
    try unconsumedBytes.write(to: corruptURL)
    _ = try corruptJournal.load()
    try corruptJournal.save(recoveredJob)
    try check(corruptJournal.consumeQuarantinedError() == nil,
              "next healthy save clears any unconsumed quarantinedError")

    // Runner checkpoint saves forward mid-session quarantine error once without leaving stale state.
    let runnerCorruptBytes = Data("{corrupt-before-runner".utf8)
    try runnerCorruptBytes.write(to: corruptURL)
    var runnerJob = recoveredJob
    var runnerQuarantineCount = 0
    try BatchExportRunner.run(job: &runnerJob, journal: corruptJournal, scope: .unfinished,
                              shouldCancel: { false }, onQuarantine: { _ in runnerQuarantineCount += 1 }) { _, _, _, destination in
        try Data("runner-ok".utf8).write(to: destination)
    }
    try check(runnerQuarantineCount == 1 && corruptJournal.consumeQuarantinedError() == nil &&
              (try Data(contentsOf: corruptJournal.lastQuarantinedURL!)) == runnerCorruptBytes,
              "runner forwards quarantine notice once across checkpoint saves and leaves no residual error")

    // Semantic validation coverage: uniform longEdge, scalars, photoEffects, denoise, and unknown masterRecipeID.
    let baseUniformObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recoveredJob)) as! [String: Any]
    let baseSettingsObject = baseUniformObject["settings"] as! [String: Any]
    let semanticCases: [(String, (inout [String: Any], inout [String: Any]) -> Void)] = [
        ("uniform longEdge zero", { jobObj, _ in jobObj["longEdge"] = 0 }),
        ("uniform longEdge above ceiling", { jobObj, _ in jobObj["longEdge"] = 70000 }),
        ("out-of-range scalar exposure", { _, settingsObj in settingsObj["exposure"] = 99.0 }),
        ("out-of-range photoEffects", { _, settingsObj in
            settingsObj["photoEffects"] = [
                "vignetteAmount": 999.0, "vignetteMidpoint": 50.0, "vignetteRoundness": 0.0,
                "vignetteFeather": 50.0, "vignetteHighlights": 0.0,
                "grainAmount": 0.0, "grainSize": 25.0, "grainRoughness": 50.0
            ]
        }),
        ("out-of-range rawNoiseReduction", { _, settingsObj in settingsObj["rawNoiseReduction"] = 99.0 }),
        ("out-of-range chromaNoiseReduction", { _, settingsObj in settingsObj["chromaNoiseReduction"] = 5.0 }),
        ("out-of-range waveletNoiseReduction", { _, settingsObj in
            settingsObj["waveletNoiseReduction"] = [
                "enabled": true, "preset": "custom", "luma": 999.0, "chroma": 50.0, "coarse": 50.0
            ]
        }),
        ("unknown masterRecipeID", { _, settingsObj in
            settingsObj["masterRecipeID"] = "nonexistent-master-recipe"
            settingsObj["masterRecipeSettingsVersion"] = 4
        })
    ]
    let semanticJournal = BatchJournal(directory: isolationRoot.appendingPathComponent("semantic-fields"))
    try FileManager.default.createDirectory(at: semanticJournal.directory, withIntermediateDirectories: true)
    let semanticURL = semanticJournal.directory.appendingPathComponent("job.json")
    for (label, mutate) in semanticCases {
        var jobObj = baseUniformObject
        var settingsObj = baseSettingsObject
        mutate(&jobObj, &settingsObj)
        jobObj["settings"] = settingsObj
        let badData = try JSONSerialization.data(withJSONObject: jobObj)
        let decodedUniform = try JSONDecoder().decode(BatchExportJob.self, from: badData)
        var saveRejected = false
        do { try semanticJournal.save(decodedUniform) } catch { saveRejected = true }
        try check(saveRejected, "\(label): uniform job save rejects semantically unusable value")
        try badData.write(to: semanticURL)
        try check(try semanticJournal.load() == nil, "\(label): uniform job load isolates semantically unusable value")
        guard let archived = semanticJournal.lastQuarantinedURL, semanticJournal.consumeQuarantinedError() != nil else {
            throw Failure(message: "\(label): uniform job load must archive and record quarantine error")
        }
        try check((try Data(contentsOf: archived)) == badData && !FileManager.default.fileExists(atPath: semanticURL.path),
                  "\(label): uniform job load preserves archived bytes")
    }

    // Per-target frozen settings also enforce Adjustmens.validateResetValues() (scalars, effects, denoise, unknown recipe).
    let dummyLook = isolationRoot.appendingPathComponent("dummy.cube")
    try Data("LUT_3D_SIZE 2\n".utf8).write(to: dummyLook)
    let dummyChecksum = try BatchFrozenSettings.checksum(dummyLook)
    for (label, mutate) in semanticCases where !label.hasPrefix("uniform longEdge") {
        var perTargetObj = baseUniformObject
        perTargetObj["version"] = 3
        perTargetObj["settings_mode"] = "per_target_frozen"
        var itemRows = perTargetObj["items"] as! [[String: Any]]
        var frozenSettingsObj = baseSettingsObject
        var ignoredJobObj = perTargetObj
        mutate(&ignoredJobObj, &frozenSettingsObj)
        var frozenObj: [String: Any] = [
            "version": 1, "settingsVersion": 1, "ordinal": 0,
            "settings": frozenSettingsObj,
            "lookName": "Frozen", "outputFormat": "png", "longEdge": 1024
        ]
        if frozenSettingsObj["masterRecipeID"] != nil {
            frozenObj["look"] = dummyLook.absoluteString
            frozenObj["lookSHA256"] = dummyChecksum
        }
        itemRows[0]["frozen"] = frozenObj
        perTargetObj["items"] = itemRows
        let badFrozenData = try JSONSerialization.data(withJSONObject: perTargetObj)
        let decodedFrozen = try JSONDecoder().decode(BatchExportJob.self, from: badFrozenData)
        var frozenRejected = false
        do { try semanticJournal.save(decodedFrozen) } catch { frozenRejected = true }
        try check(frozenRejected, "\(label): per-target frozen job save rejects semantically unusable value")
        try badFrozenData.write(to: semanticURL)
        try check(try semanticJournal.load() == nil && semanticJournal.consumeQuarantinedError() != nil,
                  "\(label): per-target frozen job load isolates semantically unusable value")
        try check((try Data(contentsOf: semanticJournal.lastQuarantinedURL!)) == badFrozenData,
                  "\(label): per-target frozen job load preserves archived bytes")
    }

    let dirAtJobJournal = BatchJournal(directory: isolationRoot.appendingPathComponent("dir-at-job"))
    let dirJobURL = dirAtJobJournal.directory.appendingPathComponent("job.json")
    try FileManager.default.createDirectory(at: dirJobURL, withIntermediateDirectories: true)
    do { _ = try dirAtJobJournal.load(); throw Failure(message: "directory at job.json must fail-closed on load") }
    catch is CocoaError { }
    do { try dirAtJobJournal.save(recoveredJob); throw Failure(message: "directory at job.json must fail-closed on save") }
    catch is CocoaError { }
    do { try dirAtJobJournal.discard(recoveredJob); throw Failure(message: "directory at job.json must fail-closed on discard") }
    catch is CocoaError { }
    try check((try FileManager.default.attributesOfItem(atPath: dirJobURL.path)[.type] as? FileAttributeType) == .typeDirectory,
              "directory at job.json remains untouched")

    let symlinkJournal = BatchJournal(directory: isolationRoot.appendingPathComponent("symlink-at-job"))
    try FileManager.default.createDirectory(at: symlinkJournal.directory, withIntermediateDirectories: true)
    let symlinkURL = symlinkJournal.directory.appendingPathComponent("job.json")
    try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "missing-target.json")
    do { _ = try symlinkJournal.load(); throw Failure(message: "symlink at job.json must fail-closed on load") }
    catch is CocoaError { }
    do { try symlinkJournal.save(recoveredJob); throw Failure(message: "symlink at job.json must fail-closed on save") }
    catch is CocoaError { }
    try check((try FileManager.default.attributesOfItem(atPath: symlinkURL.path)[.type] as? FileAttributeType) == .typeSymbolicLink,
              "symlink at job.json remains untouched")

    let fileBatchPath = isolationRoot.appendingPathComponent("file-as-batch-dir")
    let fileBatchBytes = Data("not-a-directory".utf8)
    try fileBatchBytes.write(to: fileBatchPath)
    let fileDirJournal = BatchJournal(directory: fileBatchPath)
    do { _ = try fileDirJournal.load(); throw Failure(message: "non-directory batch container must fail-closed on load") }
    catch is CocoaError { }
    do { try fileDirJournal.save(recoveredJob); throw Failure(message: "non-directory batch container must fail-closed on save") }
    catch is CocoaError { }
    try check(try Data(contentsOf: fileBatchPath) == fileBatchBytes, "non-directory batch container remains untouched")

    let futureSchemaJournal = BatchJournal(directory: isolationRoot.appendingPathComponent("future-schema"))
    try FileManager.default.createDirectory(at: futureSchemaJournal.directory, withIntermediateDirectories: true)
    var futureSchemaObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recoveredJob)) as! [String: Any]
    futureSchemaObject["version"] = 99
    let futureSchemaBytes = try JSONSerialization.data(withJSONObject: futureSchemaObject)
    let futureSchemaURL = futureSchemaJournal.directory.appendingPathComponent("job.json")
    try futureSchemaBytes.write(to: futureSchemaURL)
    do { _ = try futureSchemaJournal.load(); throw Failure(message: "future journal schema must fail-closed on load") }
    catch is CocoaError { }
    do { try futureSchemaJournal.save(recoveredJob); throw Failure(message: "future journal schema must fail-closed on save") }
    catch is CocoaError { }
    try check(try Data(contentsOf: futureSchemaURL) == futureSchemaBytes,
              "future schema batch journal remains intact in place")
    print("PASS: batch journal isolation, quarantine notice lifecycle and semantic validation")
}

@main struct BatchExportTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputs = ["one.ARW", "bad.ARW", "three.ARW"].map { root.appendingPathComponent($0) }
        for url in inputs { try Data(url.lastPathComponent.utf8).write(to: url) }
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try perTargetSnapshots(root: root, inputs: inputs, output: output)
        try journalIsolation(root: root, inputs: inputs, output: output)
        let existing = output.appendingPathComponent("one-Velvia.jpg")
        try Data("existing".utf8).write(to: existing)
        var settings = Adjustments(); settings.exposure = 0.75
        settings.blackPoint = -32.75; settings.whitePoint = 46.5; settings.vibrance = 21.25
        settings.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 10, chroma: 72, coarse: 100)
        settings.exposureMode = .sensor
        var hsl = HSLSettings()
        hsl.set(.saturation, channel: 5, value: -65)
        settings.hsl = hsl
        settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true)
        settings.setGeometry(.cropWidth, to: 0.6)
        settings.setGeometry(.cropX, to: 0.2)
        settings.setGeometry(.cropHeight, to: 0.75)
        settings.rotateGeometry(clockwise: true)
        settings.flipGeometry(horizontal: true)
        settings.setGeometry(.straightenDegrees, to: 4.5)
        let frozenGeometry = settings.geometrySettings
        var job = BatchExportJob(source: inputs[0], settings: settings, look: nil, lookName: "Velvia")
        job.longEdge = 2048
        let encodedJob = try JSONEncoder().encode(job)
        let protectedJournal = BatchJournal(directory: root.appendingPathComponent("future-journal"))
        try FileManager.default.createDirectory(at: protectedJournal.directory, withIntermediateDirectories: true)
        var futureJob = try JSONSerialization.jsonObject(with: encodedJob) as! [String: Any]
        var futureSettings = futureJob["settings"] as! [String: Any]
        futureSettings["processing"] = ["family": "rawlab", "version": 99, "quality": "standard"]
        futureJob["settings"] = futureSettings
        let protectedBytes = try JSONSerialization.data(withJSONObject: futureJob)
        let protectedURL = protectedJournal.directory.appendingPathComponent("job.json")
        try protectedBytes.write(to: protectedURL)
        do {
            _ = try protectedJournal.load()
            throw Failure(message: "unknown processing cannot resume")
        } catch is DecodingError { }
        do {
            try protectedJournal.save(job)
            throw Failure(message: "new batch must not overwrite an unsupported journal")
        } catch is DecodingError { }
        try check(try Data(contentsOf: protectedURL) == protectedBytes, "unsupported batch journal remains intact")
        try check(try JSONDecoder().decode(BatchExportJob.self, from: encodedJob).settings.geometrySettings == frozenGeometry,
                  "batch journal round-trip preserves geometry")
        try check(try JSONDecoder().decode(BatchExportJob.self, from: encodedJob).settings.toneSettings == settings.toneSettings,
                  "batch journal round-trip preserves independent tone controls")
        var dngRecord = try JSONSerialization.jsonObject(with: encodedJob) as! [String: Any]
        dngRecord["outputFormat"] = "dng"
        dngRecord["version"] = 2
        let restoredDNG = try JSONDecoder().decode(BatchExportJob.self,
            from: JSONSerialization.data(withJSONObject: dngRecord))
        try check(restoredDNG.suffix == "dng", "rendered DNG journals retain their file format")
        try check(try JSONDecoder().decode(BatchExportJob.self, from: encodedJob).suffix == "jpg",
                  "legacy JPEG journals retain their original format")
        var legacyPNG = try JSONSerialization.jsonObject(with: encodedJob) as! [String: Any]
        legacyPNG["png"] = true
        try check(try JSONDecoder().decode(BatchExportJob.self,
                  from: JSONSerialization.data(withJSONObject: legacyPNG)).suffix == "png",
                  "legacy PNG journals retain their original format")
        var legacyRecipeJob = try JSONSerialization.jsonObject(with: encodedJob) as! [String: Any]
        var legacyRecipeSettings = legacyRecipeJob["settings"] as! [String: Any]
        legacyRecipeSettings["masterRecipeID"] = MasterRecipe.hamadaDaylightV2.id
        legacyRecipeSettings["exposure"] = 0
        legacyRecipeSettings.removeValue(forKey: "masterRecipeSettingsVersion")
        legacyRecipeJob["settings"] = legacyRecipeSettings
        let legacyRecipeJournal = BatchJournal(directory: root.appendingPathComponent("legacy-recipe-journal"))
        try FileManager.default.createDirectory(at: legacyRecipeJournal.directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacyRecipeJob).write(to: legacyRecipeJournal.directory.appendingPathComponent("job.json"))
        let restoredRecipeJob = try legacyRecipeJournal.load()!
        try check(restoredRecipeJob.settings.exposure == 0.4 && restoredRecipeJob.settings.shadows == 20 &&
                  restoredRecipeJob.settings.tint == 5,
                  "unfinished legacy recipe jobs migrate their frozen controls")
        try legacyRecipeJournal.save(restoredRecipeJob)
        try check(try legacyRecipeJournal.load()?.settings == restoredRecipeJob.settings,
                  "reloaded migrated jobs do not apply recipe defaults twice")
        var recipeSettings = Adjustments()
        recipeSettings.applyMasterRecipe(.hamadaDaylightV2)
        recipeSettings.setHSL(.hue, channel: 0, value: 37)
        recipeSettings.strength = 0.5
        let hslJob = BatchExportJob(source: inputs[0], settings: recipeSettings, look: nil, lookName: "Hamada")
        let hslJournal = BatchJournal(directory: root.appendingPathComponent("hsl-journal"))
        try hslJournal.save(hslJob)
        recipeSettings.applyMasterRecipe(.jungraphyNeon)
        let frozenHSLJob = try hslJournal.load()!
        try check(frozenHSLJob.settings.hslSettings.value(.hue, channel: 0) == 37 &&
                  frozenHSLJob.settings.renderHSLSettings.value(.hue, channel: 0) == 18.5,
                  "new recipe jobs freeze visible HSL and its strength semantics, not static defaults")
        let rasterSource = root.appendingPathComponent("source.png")
        try Data("raster source identity".utf8).write(to: rasterSource)
        var dormant = frozenHSLJob.settings
        dormant.whiteBalanceMode = .custom
        dormant.temperature = 4200
        dormant.tint = 35
        dormant.exposureMode = .sensor
        dormant.rawNoiseReduction = 2
        dormant.lensCorrection = LensCorrectionSettings(distortion: true, tca: true)
        var rasterJob = BatchExportJob(source: rasterSource, settings: dormant, look: nil, lookName: "Mixed")
        rasterJob.outputDirectory = output
        var rawTarget = try BatchExportItem(url: inputs[0])
        rawTarget.selected = true
        rasterJob.items = [rawTarget]
        var resolved: Adjustments?
        try BatchExportRunner.run(job: &rasterJob, journal: hslJournal, scope: .unfinished,
                                 shouldCancel: { false }) { _, snapshot, _, destination in
            resolved = snapshot
            try Data("mixed".utf8).write(to: destination)
        }
        try check(resolved?.whiteBalanceMode == .asShot && resolved?.temperature == 6500 &&
                  resolved?.tint == dormant.tint && resolved?.exposureMode == .preview &&
                  resolved?.rawNoiseReduction == 0 && resolved?.lensSettings == LensCorrectionSettings(),
                  "raster-source batch cannot apply dormant camera controls to a RAW target")
        try check(resolved?.masterRecipeID == dormant.masterRecipeID && resolved?.strength == dormant.strength &&
                  resolved?.exposure == dormant.exposure && resolved?.renderHSLSettings == dormant.renderHSLSettings &&
                  rasterJob.settings == dormant,
                  "mixed batch preserves common style and the immutable source snapshot")
        var independentSettings = dormant
        independentSettings.masterRecipeID = nil
        let independentRasterJob = BatchExportJob(source: rasterSource, settings: independentSettings,
                                                  look: nil, lookName: "Independent")
        try check(independentRasterJob.settings(for: inputs[0]).tint == 0,
                  "mixed batch drops dormant camera tint when no master recipe is active")
        var v2Job = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hslJob)) as! [String: Any]
        var v2Settings = v2Job["settings"] as! [String: Any]
        v2Settings["masterRecipeSettingsVersion"] = 2
        v2Job["settings"] = v2Settings
        try JSONSerialization.data(withJSONObject: v2Job).write(to: hslJournal.directory.appendingPathComponent("job.json"))
        let oldHSLJob = try hslJournal.load()!
        try check(oldHSLJob.settings.renderHSLSettings.value(.hue, channel: 0) == 37,
                  "unfinished version two jobs retain formerly independent HSL")
        try hslJournal.save(oldHSLJob)
        try check(try hslJournal.load()?.settings == oldHSLJob.settings,
                  "legacy HSL job behavior survives another journal round-trip")
        try check(try JSONDecoder().decode(BatchExportJob.self, from: encodedJob).longEdge == 2048,
                  "batch keeps the chosen export size")
        var legacyJob = try JSONSerialization.jsonObject(with: encodedJob) as! [String: Any]
        legacyJob.removeValue(forKey: "longEdge")
        try check(try JSONDecoder().decode(BatchExportJob.self, from: JSONSerialization.data(withJSONObject: legacyJob)).longEdge == nil,
                  "older batch tasks retain original export size")
        job.outputDirectory = output
        job.items = try inputs.map { try BatchExportItem(url: $0) }
        try check(job.items.allSatisfy { !$0.selected }, "candidates start unselected")
        try check(!BatchExportFailure.noSelection.localizedDescription.contains("RAW"),
                  "empty selection guidance applies to RAW and ordinary photos")
        for index in job.items.indices { job.items[index].selected = true }
        settings.exposure = -1
        settings.reset(.geometry)
        settings.hsl = nil
        settings.exposureMode = .scene
        settings.lensCorrection = LensCorrectionSettings(distortion: true, mode: .manual, profileID: "live-profile")
        let journal = BatchJournal(directory: root.appendingPathComponent("journal"))
        var dngJob = job
        dngJob.format = .renderedDNG
        try journal.save(dngJob)
        try check(try journal.load()?.format == .renderedDNG && journal.load()?.version == 2,
                  "new DNG format survives durable journal recovery")
        try check(ExportFormat.forOutput(URL(fileURLWithPath: "/tmp/IMAGE.DNG")) == .renderedDNG &&
                  ExportFormat.renderedDNG.nativeFormat == SONY2FUJI_OUTPUT_DNG,
                  "DNG extension maps to native DNG, not JPEG")
        var dngCalls = 0
        try BatchExportRunner.run(job: &dngJob, journal: journal, scope: .unfinished,
                                 shouldCancel: { false }) { _, snapshot, _, destination in
            try check(destination.pathExtension == "dng" && snapshot == job.settings,
                      "DNG batch uses frozen adjustments and DNG temporary filenames")
            dngCalls += 1
            try Data("DNG".utf8).write(to: destination)
        }
        try check(dngCalls == inputs.count && dngJob.items.allSatisfy { $0.output?.pathExtension == "dng" },
                  "DNG batch publishes DNG names for every selected item")
        var calls: [String] = []
        try BatchExportRunner.run(job: &job, journal: journal, scope: .unfinished, shouldCancel: { false }) { input, snapshot, _, destination in
            calls.append(input.lastPathComponent)
            try check(snapshot.exposure == 0.75, "snapshot must not follow live edits")
            try check(snapshot.geometrySettings == frozenGeometry, "batch freezes crop, rotation, flips and straightening")
            try check(snapshot.lensSettings == LensCorrectionSettings(distortion: true, tca: true) && snapshot.lensSettings.coreProfileID.isEmpty,
                      "batch freezes automatic mode, not a resolved source lens")
            try check(snapshot.waveletSettings == WaveletDenoiseSettings(enabled: true, luma: 10, chroma: 72, coarse: 100), "batch keeps frozen denoise settings")
            try check(snapshot.hslSettings == hsl && snapshot.exposureMode == .sensor, "batch keeps frozen HSL and exposure baseline")
            if input == inputs[1] { throw Failure(message: "invalid RAW") }
            try Data("rendered".utf8).write(to: destination)
        }
        try check(calls.count == 3, "one failure does not stop subsequent targets")
        try check(job.items.filter { $0.status == .succeeded }.count == 2, "two successful rows")
        try check(job.items[1].status == .failed, "failed row is explicit")
        try check(try String(contentsOf: existing, encoding: .utf8) == "existing", "never overwrite existing output")
        try check(job.items[0].output != existing, "collision gets another name")
        try check(try String(contentsOf: inputs[0], encoding: .utf8) == "one.ARW", "RAW remains untouched")
        calls.removeAll()
        try BatchExportRunner.run(job: &job, journal: journal, scope: .failed, shouldCancel: { false }) { input, _, _, destination in
            calls.append(input.lastPathComponent)
            try Data("retry".utf8).write(to: destination)
        }
        try check(calls == ["bad.ARW"], "retry must never repeat successful targets")
        try check(try journal.load()?.items.allSatisfy { $0.status == .succeeded } == true, "completion is journaled")
        try check(try journal.load()?.settings.hslSettings == hsl && journal.load()?.settings.exposureMode == .sensor,
                  "journal preserves HSL and exposure baseline")
        var cancelled = BatchExportJob(source: inputs[0], settings: settings, look: nil, lookName: "Neutral")
        cancelled.outputDirectory = output
        cancelled.items = try inputs.map { try BatchExportItem(url: $0) }
        for index in cancelled.items.indices { cancelled.items[index].selected = true }
        var stop = false
        try BatchExportRunner.run(job: &cancelled, journal: journal, scope: .unfinished, shouldCancel: { stop }) { _, _, _, destination in
            try Data("first".utf8).write(to: destination)
            stop = true
        }
        try check(cancelled.items[0].status == .succeeded && cancelled.items[1].status == .waiting,
                  "cancel retains completed output and leaves remaining inputs unprocessed")
        var duringPreparation = BatchExportJob(source: inputs[0], settings: settings, look: nil, lookName: "Neutral")
        duringPreparation.outputDirectory = output
        duringPreparation.items = try inputs.map { try BatchExportItem(url: $0) }
        for index in duringPreparation.items.indices { duringPreparation.items[index].selected = true }
        stop = false
        var preparedCount = 0
        try BatchExportRunner.run(job: &duringPreparation, journal: journal, scope: .unfinished, shouldCancel: { stop }) { _, _, _, destination in
            preparedCount += 1
            if preparedCount == 2 { stop = true; throw RenderError.aiCancelled }
            try Data("completed".utf8).write(to: destination)
        }
        try check(duringPreparation.cancelled && duringPreparation.failedCount == 0 &&
                  duringPreparation.items[0].status == .succeeded && duringPreparation.items[1].status == .waiting,
                  "AI preparation cancellation keeps the active item retryable and preserves completed output")
        try check(try journal.load()?.items[1].status == .waiting, "AI cancellation saves a retryable journal")
        var interrupted = cancelled
        interrupted.items[1].status = .running
        try journal.save(interrupted)
        let restored = try journal.load()!
        try check(restored.settings.waveletSettings == settings.waveletSettings, "journal preserves denoise settings")
        try check(restored.interrupted && restored.items[1].status == .waiting, "running work restores as interrupted, never successful")
        try check(restored.items[0].status == .succeeded, "recovery preserves successful rows")
        var publishing = cancelled
        let published = output.appendingPathComponent("published.jpg")
        try Data("published".utf8).write(to: published)
        publishing.items[1].output = published
        publishing.items[1].completedIdentity = try OriginalFileIdentity(published)
        publishing.items[1].status = .publishing
        try journal.save(publishing)
        try check(try journal.load()?.items[1].status == .succeeded, "published-before-checkpoint output must not be duplicated")
        var brokenOutput = BatchExportJob(source: inputs[0], settings: settings, look: nil, lookName: "Neutral")
        brokenOutput.outputDirectory = output
        brokenOutput.items = try inputs.map { try BatchExportItem(url: $0) }
        for index in brokenOutput.items.indices { brokenOutput.items[index].selected = true }
        var storageCalls = 0
        do {
            try BatchExportRunner.run(job: &brokenOutput, journal: journal, scope: .unfinished, shouldCancel: { false }) { _, _, _, _ in
                storageCalls += 1
                throw RenderError.outputIO
            }
            throw Failure(message: "output I/O failure must stop the batch")
        } catch RenderError.outputIO { }
        try check(storageCalls == 1, "global storage failure must not attempt remaining photos")
        try check(try journal.load()?.interrupted == true, "global failure persists interrupted state")
        var abandoned = cancelled
        abandoned.items[1].status = .running
        let temporary = output.appendingPathComponent(".rawlab-\(abandoned.id)-\(abandoned.items[1].id).\(abandoned.suffix)")
        try Data("partial output".utf8).write(to: temporary)
        try journal.save(abandoned)
        _ = try journal.load()
        try check(!FileManager.default.fileExists(atPath: temporary.path), "recovery removes abandoned partial output")
        try BatchExportX3fTargetTests.run(root: root)
        print("PASS: snapshot, collisions, failure continuation, retry, cancel and durable recovery")
    }
}
