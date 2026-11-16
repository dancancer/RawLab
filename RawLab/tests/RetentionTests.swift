import Foundation

// Q6 保留策略（批量产物 30 天/100 条，双条件先到先清）的独立模型测试。
// 运行：bash RawLab/tests/retention.sh
@main struct RetentionTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "RetentionTests", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS: \(message)")
    }
    static func main() throws {
        try batchArtifactAgeBoundary()
        try batchArtifactCountBoundary()
        try batchArtifactGroupedEntry()
        try batchArtifactBothConditions()
        try batchArtifactReclaimsPopulatedStandaloneExport()
        try batchArtifactSkipsRecoveredJobDuringSweep()
        try exportEvidenceRegistry()
    }

    // Q6（B1）：导出证据账本——只有真实外部出口成功后登记；持久、幂等；
    // 「打开过」（不登记）不构成证据；账本读不出来时返回空集（宁漏删）。
    private static func exportEvidenceRegistry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/ExportEvidence.json")
        let store = ExportEvidenceStore(url: file)
        try check(store.exportedContentIdentifiers().isEmpty,
                  "Opening photos in the editor registers nothing: an empty ledger exports nothing")
        store.record(contentIdentifier: String(repeating: "a", count: 64))
        store.record(contentIdentifier: nil)
        store.record(contentIdentifier: "")
        try check(store.exportedContentIdentifiers() == [String(repeating: "a", count: 64)],
                  "A successful external export registers its content identifier once")
        let reopened = ExportEvidenceStore(url: file)
        try check(reopened.exportedContentIdentifiers() == [String(repeating: "a", count: 64)],
                  "Export evidence survives app restarts (persisted outside any LRU)")
        reopened.record(contentIdentifiers: [String(repeating: "b", count: 64), String(repeating: "a", count: 64)])
        try check(ExportEvidenceStore(url: file).exportedContentIdentifiers()
                      == [String(repeating: "a", count: 64), String(repeating: "b", count: 64)],
                  "Later exports append without dropping or duplicating earlier evidence")
        // 账本目录不可建：登记留在内存（宁漏登记），下一次成功落盘继续携带。
        let blockedParent = root.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blockedParent)
        let blocked = ExportEvidenceStore(url: blockedParent.appendingPathComponent("ExportEvidence.json"))
        blocked.record(contentIdentifier: String(repeating: "c", count: 64))
        try check(blocked.exportedContentIdentifiers() == [String(repeating: "c", count: 64)],
                  "A failed ledger write keeps the evidence in memory instead of losing it")
        try Data("{ hal".utf8).write(to: file, options: .atomic)
        try check(ExportEvidenceStore(url: file).exportedContentIdentifiers().isEmpty,
                  "An unreadable ledger yields no evidence, so cleanup only under-deletes")
        // 渲染型 DNG：渲染落沙盒不算导出，picker 确认后才按行记账（红锚：saveJournal
        // 无条件登记时，取消另存的行也已入账）。
        let pickerURL = URL(fileURLWithPath: "/tmp/rendered.dng")
        let candidates = [
            ExportEvidenceStore.EvidenceCandidate(contentIdentifier: String(repeating: "d", count: 64),
                                                  succeeded: true, outputFileURL: pickerURL, inPicker: true),
            ExportEvidenceStore.EvidenceCandidate(contentIdentifier: String(repeating: "e", count: 64),
                                                  succeeded: false, outputFileURL: nil, inPicker: false),
            ExportEvidenceStore.EvidenceCandidate(contentIdentifier: nil,
                                                  succeeded: true, outputFileURL: nil, inPicker: false),
        ]
        try check(ExportEvidenceStore.renderedDNGEvidenceIdentifiers(exported: false, candidates: candidates).isEmpty,
                  "Rendered DNG rows stay out of the ledger until the picker confirms the save")
        try check(ExportEvidenceStore.renderedDNGEvidenceIdentifiers(exported: true, candidates: candidates)
                      == [String(repeating: "d", count: 64)],
                  "A confirmed save registers exactly the succeeded rows present in the picker, one per row")
    }

    private static let day: TimeInterval = 24 * 60 * 60

    private struct Fixture {
        let root: URL
        let exports: URL
        let journals: URL
        init(_ name: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-retention-\(name)-\(UUID().uuidString)")
            exports = root.appendingPathComponent("Exports", isDirectory: true)
            journals = root.appendingPathComponent("BatchJobs", isDirectory: true)
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        }
        func exportDirectory(age: TimeInterval, now: Date, id: UUID = UUID()) throws -> URL {
            let url = exports.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([0]).write(to: url.appendingPathComponent("rendered.dng"))
            let createdAt = now.addingTimeInterval(-age)
            let modifiedAt = createdAt.addingTimeInterval(1)
            try FileManager.default.setAttributes([.creationDate: createdAt, .modificationDate: modifiedAt], ofItemAtPath: url.path)
            return url
        }
        func journalRecord(age: TimeInterval, now: Date, id: UUID = UUID()) throws -> URL {
            let url = journals.appendingPathComponent("\(id.uuidString).json")
            try Data("{}".utf8).write(to: url)
            let date = now.addingTimeInterval(-age)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        func fileCount(_ directory: URL) throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: directory.path).count
        }
    }

    // 31 天删、30 天留：双条件之一按天数，恰好 30 天（边界内）保留。
    private static func batchArtifactAgeBoundary() throws {
        let fixture = try Fixture("age")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = try fixture.exportDirectory(age: 31 * day, now: now)
        let boundary = try fixture.exportDirectory(age: 30 * day, now: now)
        let oldJournal = try fixture.journalRecord(age: 31 * day, now: now)
        let freshJournal = try fixture.journalRecord(age: 29 * day, now: now)
        let reclaimed = BatchArtifactRetention.reclaim(exportsRoot: fixture.exports, journalRoot: fixture.journals, now: now)
        try check(reclaimed == 2, "Age condition reclaims the two 31-day entries and nothing else")
        try check(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: boundary.path),
                  "A 31-day-old artifact is removed while a 30-day-old one is retained")
        try check(!FileManager.default.fileExists(atPath: oldJournal.path) && FileManager.default.fileExists(atPath: freshJournal.path),
                  "Journal records follow the same 30-day line with a one-day margin")
    }

    // 101 条时最旧删、100 条不动：双条件之二按条数，按时间排序保留最近 100 条。
    private static func batchArtifactCountBoundary() throws {
        let fixture = try Fixture("count")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var ids = [UUID]()
        for index in 0..<101 {
            ids.append(UUID())
            _ = try fixture.journalRecord(age: TimeInterval(101 - index), now: now, id: ids[index])
        }
        var reclaimed = BatchArtifactRetention.reclaim(exportsRoot: fixture.exports, journalRoot: fixture.journals, now: now)
        let remainingAfterCap = try fixture.fileCount(fixture.journals)
        try check(reclaimed == 1 && remainingAfterCap == 100,
                  "The 101st oldest entry is reclaimed down to exactly 100 entries")
        try check(!FileManager.default.fileExists(atPath: fixture.journals.appendingPathComponent("\(ids[0].uuidString).json").path),
                  "Entry count reclaims the oldest entry, not an arbitrary one")
        reclaimed = BatchArtifactRetention.reclaim(exportsRoot: fixture.exports, journalRoot: fixture.journals, now: now)
        try check(reclaimed == 0, "Exactly 100 entries remain untouched")
    }

    // 一个任务条目 = Exports/<uuid> 目录 + journal <uuid>.json（含 <uuid>/inputs 输入副本）。
    // 同一 id 同进同退；已关闭任务留下的独立产物目录也能被独立清退。
    private static func batchArtifactGroupedEntry() throws {
        let fixture = try Fixture("group")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()
        let directory = try fixture.exportDirectory(age: 40 * day, now: now, id: id)
        let record = try fixture.journalRecord(age: 40 * day, now: now, id: id)
        let inputs = fixture.journals.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try Data([1]).write(to: inputs.appendingPathComponent("photo.raw"))
        let orphan = try fixture.exportDirectory(age: 40 * day, now: now)
        let sidecar = fixture.journals.appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: sidecar)
        let reclaimed = BatchArtifactRetention.reclaim(exportsRoot: fixture.exports, journalRoot: fixture.journals, now: now)
        try check(reclaimed == 2, "The grouped entry and the journal-less artifact directory are reclaimed as two entries")
        try check(!FileManager.default.fileExists(atPath: directory.path) && !FileManager.default.fileExists(atPath: record.path)
                      && !FileManager.default.fileExists(atPath: inputs.deletingLastPathComponent().path),
                  "Deleting one entry removes its artifact directory, journal record and input copies together")
        try check(!FileManager.default.fileExists(atPath: orphan.path), "A completed job's standalone export directory is reclaimed")
        try check(FileManager.default.fileExists(atPath: sidecar.path), "Non-UUID files in the journal root are never swept")
    }

    // 先到先清：条目数未满 100 时天数条件独立生效；两条件互不等待。
    private static func batchArtifactBothConditions() throws {
        let fixture = try Fixture("both")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<95 { _ = try fixture.exportDirectory(age: TimeInterval(index), now: now) }
        for _ in 0..<10 { _ = try fixture.exportDirectory(age: 35 * day, now: now) }
        let reclaimed = BatchArtifactRetention.reclaim(exportsRoot: fixture.exports, journalRoot: fixture.journals, now: now)
        let remainingFresh = try fixture.fileCount(fixture.exports)
        try check(reclaimed == 10 && remainingFresh == 95,
                  "Ten 35-day-old artifacts are reclaimed below the count cap while fresh entries stay")
    }

    // 回归：真实渲染型 DNG 导出先建 Exports/<uuid>/（定格 creationDate），随后写入 .dng 推进目录 modificationDate > creationDate，
    // discard 删除 journal 后仅留独立产物目录；超过 30 天后仍能被回收（撤掉按 part 快照 mtime 复核必红）。
    private static func batchArtifactReclaimsPopulatedStandaloneExport() throws {
        let fixture = try Fixture("populated-export")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exportDir = fixture.exports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let createdAt = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.creationDate: createdAt, .modificationDate: createdAt], ofItemAtPath: exportDir.path)
        let renderedFile = exportDir.appendingPathComponent("IMG_0001.dng")
        try Data([0x49, 0x49, 0x2A, 0x00]).write(to: renderedFile)
        let values = try exportDir.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        try check((values.contentModificationDate ?? .distantPast) > (values.creationDate ?? .distantFuture),
                  "Writing a rendered child file advances export directory modificationDate past creationDate")
        let reclaimed = BatchArtifactRetention.reclaim(
            exportsRoot: fixture.exports,
            journalRoot: fixture.journals,
            now: createdAt.addingTimeInterval(31 * day)
        )
        try check(reclaimed == 1 && !FileManager.default.fileExists(atPath: exportDir.path),
                  "A populated standalone export directory with mtime > ctime is reclaimed after 30 days")
    }

    // 竞态回归：后台清扫尚未结束时，首屏恢复同 ID 任务（原子重写 journal + 写入 inputs，或标记为活跃保护），
    // 清扫结束后该任务的 journal 与 inputs 仍存在（撤掉删除前复核必红）。
    private static func batchArtifactSkipsRecoveredJobDuringSweep() throws {
        let fixture = try Fixture("race")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expiredID = UUID()
        let resumedID = UUID()
        let protectedID = UUID()
        defer { BatchArtifactRetention.unprotectJob(protectedID) }

        _ = try fixture.exportDirectory(age: 35 * day, now: now, id: expiredID)
        _ = try fixture.journalRecord(age: 35 * day, now: now, id: expiredID)

        let resumedExport = try fixture.exportDirectory(age: 31 * day, now: now, id: resumedID)
        let resumedJournal = try fixture.journalRecord(age: 31 * day, now: now, id: resumedID)
        let resumedInputs = fixture.journals.appendingPathComponent(resumedID.uuidString, isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: resumedInputs, withIntermediateDirectories: true)
        let resumedInputFile = resumedInputs.appendingPathComponent("photo.raw")
        try Data([1]).write(to: resumedInputFile)

        let protectedExport = try fixture.exportDirectory(age: 31 * day, now: now, id: protectedID)
        let protectedJournal = try fixture.journalRecord(age: 31 * day, now: now, id: protectedID)
        let protectedInputs = fixture.journals.appendingPathComponent(protectedID.uuidString, isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedInputs, withIntermediateDirectories: true)
        let protectedInputFile = protectedInputs.appendingPathComponent("photo.raw")
        try Data([2]).write(to: protectedInputFile)

        let enteredRace = DispatchSemaphore(value: 0)
        let recoveryDone = DispatchSemaphore(value: 0)
        let sweepDone = DispatchSemaphore(value: 0)
        var didTriggerRace = false
        var reclaimed = -1

        DispatchQueue.global(qos: .utility).async {
            reclaimed = BatchArtifactRetention.reclaim(
                exportsRoot: fixture.exports,
                journalRoot: fixture.journals,
                now: now
            ) { candidateID in
                guard !didTriggerRace, candidateID == resumedID || candidateID == protectedID else { return }
                didTriggerRace = true
                enteredRace.signal()
                recoveryDone.wait()
            }
            sweepDone.signal()
        }

        enteredRace.wait()
        // 模拟清扫期间恢复同 ID 任务：resumedID 原子重写 journal 并写入新 input；
        // protectedID 走未重写 journal 的直接恢复路径并登记活跃保护。
        try Data("{\"resumed\":true}".utf8).write(to: resumedJournal, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: resumedJournal.path)
        let newInputFile = resumedInputs.appendingPathComponent("resumed.raw")
        try Data([3]).write(to: newInputFile)
        BatchArtifactRetention.protectJob(protectedID)
        recoveryDone.signal()

        sweepDone.wait()

        try check(reclaimed == 1, "Only the unrecovered expired job is reclaimed while in-flight recovered jobs survive")
        try check(FileManager.default.fileExists(atPath: resumedJournal.path)
                      && FileManager.default.fileExists(atPath: resumedInputFile.path)
                      && FileManager.default.fileExists(atPath: newInputFile.path)
                      && FileManager.default.fileExists(atPath: resumedExport.path),
                  "A job whose journal and inputs are rewritten mid-sweep retains its journal, inputs, and exports")
        try check(FileManager.default.fileExists(atPath: protectedJournal.path)
                      && FileManager.default.fileExists(atPath: protectedInputFile.path)
                      && FileManager.default.fileExists(atPath: protectedExport.path),
                  "A recovered job protected without rewriting its journal retains its journal, inputs, and exports")
    }
}
