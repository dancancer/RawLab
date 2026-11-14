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
            let date = now.addingTimeInterval(-age)
            try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
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
            try fixture.journalRecord(age: TimeInterval(101 - index), now: now, id: ids[index])
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
        for index in 0..<95 { try fixture.exportDirectory(age: TimeInterval(index), now: now) }
        for _ in 0..<10 { try fixture.exportDirectory(age: 35 * day, now: now) }
        let reclaimed = BatchArtifactRetention.reclaim(exportsRoot: fixture.exports, journalRoot: fixture.journals, now: now)
        let remainingFresh = try fixture.fileCount(fixture.exports)
        try check(reclaimed == 10 && remainingFresh == 95,
                  "Ten 35-day-old artifacts are reclaimed below the count cap while fresh entries stay")
    }
}
