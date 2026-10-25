import Foundation
import CryptoKit

struct UpdateStore {
    let directory: URL
    var stateURL: URL { directory.appendingPathComponent("state.json") }
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Updates", isDirectory: true)
    }
    init(directory: URL = defaultDirectory) { self.directory = directory }
    func load(automaticCheck: Bool) throws -> UpdatePreferences {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            var result = UpdatePreferences(); result.automaticCheck = automaticCheck; return result
        }
        try requireOrdinary(directory); try requireOrdinary(stateURL)
        let value = try JSONDecoder().decode(UpdatePreferences.self, from: Data(contentsOf: stateURL))
        guard value.channel == "stable", value.pendingUpdate.format == 1 else {
            throw UpdateAdapterError(code: "storage", detail: "Unsupported update state")
        }
        if let receipt = value.stateRepairReceipt {
            let archive = repairedStateArchive(receipt)
            try requireOrdinary(archive.deletingLastPathComponent().deletingLastPathComponent())
            try requireOrdinary(archive.deletingLastPathComponent()); try requireOrdinary(archive)
            guard digest(try Data(contentsOf: archive)) == receipt.sha256 else {
                throw UpdateAdapterError(code: "storage", detail: "State repair archive changed")
            }
        }
        return value
    }
    func repairedStateArchive(_ receipt: UpdateStateRepairReceipt) -> URL {
        directory.appendingPathComponent("StateRecoveries/\(receipt.id.uuidString)/state.json")
    }
    func repairableState() throws -> Data {
        try requireOrdinary(directory); try requireOrdinary(stateURL)
        let data = try Data(contentsOf: stateURL)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func knownString(_ value: Any?, _ accepts: (String) -> Bool) -> Bool {
                guard let value else { return true }
                guard let text = value as? String else { return false }
                return accepts(text)
            }
            let pending = object["pendingUpdate"] as? [String: Any]
            let failure = pending?["failure"] as? [String: Any]
            let installationPhases = ["installing", "pending_restart"]
            guard knownString(object["channel"], { $0 == "stable" }),
                  object["pendingUpdate"] == nil || pending != nil,
                  pending?["format"].map({ ($0 as? Int) == 1 }) ?? true,
                  knownString(pending?["phase"], { UpdatePhase(rawValue: $0) != nil }),
                  knownString(pending?["choice"], { UpdateInstallChoice(rawValue: $0) != nil }),
                  knownString(failure?["stage"], { UpdatePhase(rawValue: $0) != nil }),
                  object["stateRepairReceipt"] == nil || object["stateRepairReceipt"] is NSNull,
                  object["recoveryReceipt"] == nil || object["recoveryReceipt"] is NSNull,
                  pending?["backupPath"] == nil || pending?["backupPath"] is NSNull,
                  pending?["previousVersion"] == nil || pending?["previousVersion"] is NSNull,
                  pending?["previousBuild"] == nil || pending?["previousBuild"] is NSNull,
                  !installationPhases.contains(pending?["phase"] as? String ?? ""),
                  !installationPhases.contains(failure?["stage"] as? String ?? "") else {
                throw UpdateAdapterError(code: "storage", detail: "Unsupported update state cannot be rebuilt")
            }
        }
        guard (try? load(automaticCheck: false)) == nil else {
            throw UpdateAdapterError(code: "storage", detail: "Update state is readable; reopen the app")
        }
        for name in ["Backups", "Recoveries"] {
            let path = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                try requireOrdinary(path)
                guard try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty else {
                    throw UpdateAdapterError(code: "storage", detail: "Installation or data recovery status is unknown")
                }
            }
        }
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovery-in-progress.json").path) else {
            throw UpdateAdapterError(code: "storage", detail: "Data recovery is unfinished")
        }
        return data
    }
    func repairState(expected: Data) throws -> UpdatePreferences {
        guard try repairableState() == expected else {
            throw UpdateAdapterError(code: "storage", detail: "Update state changed; reopen the app")
        }
        let receipt = UpdateStateRepairReceipt(id: UUID(), sha256: digest(expected))
        let archive = repairedStateArchive(receipt)
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try requireOrdinary(archive.deletingLastPathComponent().deletingLastPathComponent())
        try requireOrdinary(archive.deletingLastPathComponent())
        // 先持久保存原始字节，再原子替换；中断不会留下缺失状态而绕过启动门禁。
        try expected.write(to: archive, options: .atomic)
        let file = try FileHandle(forWritingTo: archive); try file.synchronize(); try file.close()
        guard try repairableState() == expected else { throw UpdateAdapterError(code: "storage", detail: "Update state changed") }
        var next = UpdatePreferences(); next.automaticCheck = false; next.stateRepairReceipt = receipt
        try save(next)
        return next
    }
    private func requireOrdinary(_ path: URL) throws {
        let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
            throw UpdateAdapterError(code: "storage", detail: "Unsupported state entry")
        }
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func save(_ preferences: UpdatePreferences) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: stateURL, options: .atomic)
        let file = try FileHandle(forWritingTo: stateURL); defer { try? file.close() }; try file.synchronize()
    }
}

struct UpdateDataBackup {
    struct Manifest: Codable {
        let format: Int
        let created: Date
        let previousVersion: String
        var previousBuild: String?
        let targetVersion: String
        let files: [String: String]
    }
    static let dataDirectories = ["Edits", "Looks", "Presets", "Batch"]
    let dataRoot: URL
    let updateRoot: URL

    func create(previous: String, target: String, previousBuild: String? = nil) throws -> URL {
        let result = updateRoot.appendingPathComponent("Backups/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        var files: [String: String] = [:]
        do {
            let sourceRoot = dataRoot.resolvingSymlinksInPath()
            for name in Self.dataDirectories {
                let source = sourceRoot.appendingPathComponent(name, isDirectory: true)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try requireOrdinary(source)
                let target = result.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                var walkError: Error?
                guard let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], errorHandler: { _, error in walkError = error; return false }) else {
                    throw UpdateAdapterError(code: "backup", detail: name)
                }
                for case let file as URL in walker {
                    try requireOrdinary(file)
                    let resolved = file.resolvingSymlinksInPath().path
                    guard resolved.hasPrefix(sourceRoot.path + "/") else { throw UpdateAdapterError(code: "backup", detail: "Invalid source entry") }
                    let relative = String(resolved.dropFirst(sourceRoot.path.count + 1))
                    let destination = result.appendingPathComponent(relative)
                    if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    } else {
                        try FileManager.default.copyItem(at: file, to: destination)
                        let originalHash = try digest(file), copiedHash = try digest(destination)
                        guard originalHash == copiedHash else { throw UpdateAdapterError(code: "backup", detail: relative) }
                        files[relative] = copiedHash
                    }
                }
                if let walkError { throw walkError }
            }
            let manifest = Manifest(format: 1, created: Date(), previousVersion: previous, previousBuild: previousBuild, targetVersion: target, files: files)
            try JSONEncoder().encode(manifest).write(to: result.appendingPathComponent("manifest.json"), options: .atomic)
            return result
        } catch { try? FileManager.default.removeItem(at: result); throw error }
    }

    func verify(_ directory: URL) throws -> Manifest {
        let root = updateRoot.appendingPathComponent("Backups", isDirectory: true).standardizedFileURL
        guard directory.standardizedFileURL.deletingLastPathComponent() == root else {
            throw UpdateAdapterError(code: "backup", detail: "Invalid backup location")
        }
        try requireOrdinary(directory)
        try requireOrdinary(root)
        try requireOrdinary(directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.format == 1 else { throw UpdateAdapterError(code: "backup", detail: "Unsupported backup") }
        for (path, hash) in manifest.files {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard let first = parts.first, Self.dataDirectories.contains(String(first)), parts.count >= 2,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw UpdateAdapterError(code: "backup", detail: "Invalid backup entry")
            }
            let file = directory.appendingPathComponent(path)
            guard file.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath().appendingPathComponent(path) else {
                throw UpdateAdapterError(code: "backup", detail: "Linked backup entry")
            }
            try requireOrdinary(file)
            guard try digest(file) == hash else { throw UpdateAdapterError(code: "backup", detail: path) }
        }
        return manifest
    }

    private struct Recovery: Codable {
        let id: UUID
        let originals: [String]
        var restored: Bool
    }
    private var recoveryJournal: URL { updateRoot.appendingPathComponent("recovery-in-progress.json") }
    var hasPendingRecovery: Bool { FileManager.default.fileExists(atPath: recoveryJournal.path) }

    // 日志先于任何目录移动落盘；编辑入口必须在日志清除前保持关闭。
    func restore(_ directory: URL, afterMove: (String) throws -> Void = { _ in }) throws -> URL {
        let manifest = try verify(directory)
        try requireOrdinary(dataRoot); try requireOrdinary(updateRoot)
        if hasPendingRecovery { try rollback(try readRecovery()) }
        let recovery = Recovery(id: UUID(), originals: Self.dataDirectories.filter {
            FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent($0).path)
        }, restored: false)
        let root = recoveryRoot(recovery), staged = root.appendingPathComponent("staged")
        let parent = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try requireOrdinary(parent)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("original"), withIntermediateDirectories: true)
        for name in Self.dataDirectories {
            try FileManager.default.createDirectory(at: staged.appendingPathComponent(name), withIntermediateDirectories: true)
            if recovery.originals.contains(name) { try requireOrdinary(dataRoot.appendingPathComponent(name)) }
        }
        // 只复制清单内且重新校验过的文件；备份中额外的文件不会进入用户数据。
        for (name, hash) in manifest.files {
            let target = staged.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: directory.appendingPathComponent(name), to: target)
            guard try digest(target) == hash else { throw UpdateAdapterError(code: "recovery", detail: "Backup changed during recovery") }
            try synchronize(target)
        }
        try writeRecovery(recovery, to: recoveryJournal)
        do {
            for name in Self.dataDirectories {
                let current = dataRoot.appendingPathComponent(name)
                if recovery.originals.contains(name) {
                    try FileManager.default.moveItem(at: current, to: root.appendingPathComponent("original/\(name)"))
                }
                try afterMove(name)
                try FileManager.default.moveItem(at: staged.appendingPathComponent(name), to: current)
            }
            var completed = recovery; completed.restored = true
            try writeRecovery(completed, to: root.appendingPathComponent("receipt.json"))
            try writeRecovery(completed, to: recoveryJournal)
            return root
        } catch {
            // 回滚本身失败时保留日志与所有目录，下次明确重试继续回滚。
            try rollback(recovery)
            throw error
        }
    }

    func finishRecovery(_ receipt: String) throws {
        guard hasPendingRecovery else { return }
        let recovery = try readRecovery()
        let root = recoveryRoot(recovery)
        guard recovery.restored, root.standardizedFileURL == URL(fileURLWithPath: receipt).standardizedFileURL else {
            throw UpdateAdapterError(code: "recovery", detail: "Recovery has not completed")
        }
        try requireOrdinary(root.appendingPathComponent("receipt.json"))
        let saved = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: root.appendingPathComponent("receipt.json")))
        guard saved.id == recovery.id, saved.restored else { throw UpdateAdapterError(code: "recovery", detail: "Invalid recovery receipt") }
        try FileManager.default.removeItem(at: recoveryJournal)
    }

    private func recoveryRoot(_ value: Recovery) -> URL { updateRoot.appendingPathComponent("Recoveries/\(value.id.uuidString)") }
    private func readRecovery() throws -> Recovery {
        try requireOrdinary(recoveryJournal)
        let value = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: recoveryJournal))
        guard Set(value.originals).count == value.originals.count, value.originals.allSatisfy(Self.dataDirectories.contains) else {
            throw UpdateAdapterError(code: "recovery", detail: "Invalid recovery journal")
        }
        let root = recoveryRoot(value)
        try requireOrdinary(root.deletingLastPathComponent()); try requireOrdinary(root)
        try requireOrdinary(root.appendingPathComponent("original"))
        return value
    }
    private func rollback(_ recovery: Recovery) throws {
        let root = recoveryRoot(recovery)
        for name in Self.dataDirectories {
            let current = dataRoot.appendingPathComponent(name), original = root.appendingPathComponent("original/\(name)")
            let hasOriginal = FileManager.default.fileExists(atPath: original.path)
            if hasOriginal || !recovery.originals.contains(name) {
                if FileManager.default.fileExists(atPath: current.path) {
                    let discarded = root.appendingPathComponent("discarded/\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: discarded, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: current, to: discarded.appendingPathComponent(name))
                }
                if hasOriginal { try requireOrdinary(original); try FileManager.default.moveItem(at: original, to: current) }
            } else if !FileManager.default.fileExists(atPath: current.path) {
                throw UpdateAdapterError(code: "recovery", detail: "Missing original directory: \(name)")
            }
        }
        try FileManager.default.removeItem(at: recoveryJournal)
    }
    private func writeRecovery(_ value: Recovery, to path: URL) throws {
        try JSONEncoder().encode(value).write(to: path, options: .atomic); try synchronize(path)
    }
    private func synchronize(_ path: URL) throws {
        let handle = try FileHandle(forWritingTo: path); defer { try? handle.close() }; try handle.synchronize()
    }

    private func requireOrdinary(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
            throw UpdateAdapterError(code: "backup", detail: "Unsupported data entry")
        }
    }
    private func digest(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
