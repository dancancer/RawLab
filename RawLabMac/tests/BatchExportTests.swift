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
        print("PASS: snapshot, collisions, failure continuation, retry, cancel and durable recovery")
    }
}
