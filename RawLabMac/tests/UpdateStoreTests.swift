import Foundation

@main struct UpdateStoreTests {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { fatalError(message) }; print("PASS: \(message)")
    }
    static func rejected(_ work: () throws -> Void) -> Bool { do { try work(); return false } catch { return true } }
    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--crash-recovery" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            _ = try UpdateDataBackup(dataRoot: root, updateRoot: root.appendingPathComponent("Updates"))
                .restore(URL(fileURLWithPath: CommandLine.arguments[3]), afterMove: { if $0 == "Edits" { exit(71) } })
            fatalError("Crash injection was not reached")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-update-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateStore(directory: root.appendingPathComponent("Updates"))
        var preferences = try store.load(automaticCheck: false)
        try check(!preferences.automaticCheck && !preferences.automaticInstall, "Legacy opt-out is preserved on first migration")
        preferences.skippedVersion = "0.9.1"; preferences.remindAfter = Date(timeIntervalSince1970: 12345)
        let token = preferences.pendingUpdate.beginCheck(); _ = preferences.pendingUpdate.fail("network", detail: "offline", token: token)
        try store.save(preferences)
        let restored = try store.load(automaticCheck: true)
        try check(restored.pendingUpdate.failure?.code == "network" && restored.skippedVersion == "0.9.1" && restored.remindAfter == preferences.remindAfter,
            "Preferences and failure survive reopening")
        let corrupt = Data("{\"channel\":\"future\"}".utf8); try corrupt.write(to: store.stateURL)
        try check(rejected { _ = try store.load(automaticCheck: true) } && Data(contentsOf: store.stateURL) == corrupt, "Unknown state is rejected without overwriting it")
        let edits = root.appendingPathComponent("Edits"); try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        let source = edits.appendingPathComponent("photo.json"); try Data("precise edit".utf8).write(to: source)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)
        let backups = UpdateDataBackup(dataRoot: root, updateRoot: store.directory)
        let backup = try backups.create(previous: "0.8.2", target: "0.9.1")
        try check(try backups.verify(backup).files.count == 1, "Backup verifies copied edit data")
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        try check(Data(contentsOf: source) == Data("precise edit".utf8) && before[.modificationDate] as? Date == after[.modificationDate] as? Date,
            "Backup leaves source data and modification times unchanged")
        try Data("new format".utf8).write(to: source)
        let newRecord = edits.appendingPathComponent("new.json")
        try Data("new photo".utf8).write(to: newRecord)
        let receipt = try backups.restore(backup)
        try check(Data(contentsOf: source) == Data("precise edit".utf8) && !FileManager.default.fileExists(atPath: newRecord.path),
            "Explicit recovery restores only the verified previous records")
        try check(Data(contentsOf: receipt.appendingPathComponent("original/Edits/photo.json")) == Data("new format".utf8) &&
            Data(contentsOf: receipt.appendingPathComponent("original/Edits/new.json")) == Data("new photo".utf8),
            "Recovery preserves every newer record in its quarantine")
        try check(backups.hasPendingRecovery, "Recovery stays blocked until its completion is persisted")
        try backups.finishRecovery(receipt.path)
        try check(!backups.hasPendingRecovery, "Persisted recovery can be finalized before reopening editing")
        try Data("latest format".utf8).write(to: source)
        try check(rejected { _ = try backups.restore(backup, afterMove: { name in
            if name == "Edits" { throw UpdateAdapterError(code: "test", detail: "Injected failure") }
        }) }, "A mid-recovery filesystem failure is reported")
        try check(Data(contentsOf: source) == Data("latest format".utf8) && !backups.hasPendingRecovery,
            "Failed recovery rolls back all moved directories without losing new data")
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--crash-recovery", root.path, backup.path]; try child.run(); child.waitUntilExit()
        try check(child.terminationStatus == 71 && backups.hasPendingRecovery && !FileManager.default.fileExists(atPath: source.path),
            "A process crash between directory moves leaves a durable recovery journal")
        let resumed = try backups.restore(backup)
        try check(Data(contentsOf: source) == Data("precise edit".utf8) && Data(contentsOf: resumed.appendingPathComponent("original/Edits/photo.json")) == Data("latest format".utf8),
            "A new process can roll back the interrupted move and safely repeat recovery")
        try backups.finishRecovery(resumed.path)
        try FileManager.default.removeItem(at: backup.appendingPathComponent("Edits"))
        try FileManager.default.createSymbolicLink(at: backup.appendingPathComponent("Edits"), withDestinationURL: edits)
        try check(rejected { _ = try backups.verify(backup) }, "Backup verification rejects a symlinked parent directory")
        let outside = root.appendingPathComponent("external.json"); try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: edits.appendingPathComponent("link.json"), withDestinationURL: outside)
        try check(rejected { _ = try backups.create(previous: "0.8.2", target: "0.9.1") }, "Backup refuses linked source records")
    }
}
