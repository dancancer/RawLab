import Foundation
import CryptoKit

final class BatchJournalStore {
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func appStore() throws -> BatchJournalStore {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
        return try BatchJournalStore(directory: root.appendingPathComponent("RawLab/BatchJobs", isDirectory: true))
    }

    func save(_ job: BatchExportJob) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let destination = directory.appendingPathComponent("\(job.id.uuidString).json")
        try encoder.encode(job).write(to: destination, options: .atomic)
    }

    func load(id: UUID) throws -> BatchExportJob? {
        let file = directory.appendingPathComponent("\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return relocateOwnedFiles(try JSONDecoder().decode(BatchExportJob.self, from: Data(contentsOf: file)))
    }

    func pendingJobs() throws -> [BatchExportJob] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.compactMap { url -> BatchExportJob? in
            let original = try JSONDecoder().decode(BatchExportJob.self, from: Data(contentsOf: url))
            let recovered = relocateOwnedFiles(original).recovered()
            // Photos owns completed JPEGs. Keep the completed DNG journal until dismissal;
            // exported files in Documents/Exports persist independently of the journal.
            if recovered.status == .completed && recovered.outputFormat == .jpeg {
                try discard(id: recovered.id)
                return nil
            }
            if recovered != original { try save(recovered) }
            return recovered
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func relocateOwnedFiles(_ original: BatchExportJob) -> BatchExportJob {
        let root = directory.appendingPathComponent(original.id.uuidString, isDirectory: true)
        func relocate(_ url: URL) -> URL {
            let parent = url.deletingLastPathComponent()
            if parent.lastPathComponent == "inputs" && parent.deletingLastPathComponent().lastPathComponent == original.id.uuidString {
                return root.appendingPathComponent("inputs", isDirectory: true).appendingPathComponent(url.lastPathComponent)
            }
            if parent.lastPathComponent == original.id.uuidString { return root.appendingPathComponent(url.lastPathComponent) }
            return url
        }
        var job = original
        job.source.sourceURL = relocate(job.source.sourceURL)
        job.source.lookURL = job.source.lookURL.map(relocate)
        for index in job.targets.indices { job.targets[index].sourceURL = relocate(job.targets[index].sourceURL) }
        return job
    }

    func discard(id: UUID) throws {
        let record = directory.appendingPathComponent("\(id.uuidString).json")
        let inputs = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: inputs.path) { try FileManager.default.removeItem(at: inputs) }
        if FileManager.default.fileExists(atPath: record.path) { try FileManager.default.removeItem(at: record) }
    }
}

enum BatchInputStore {
    static func directory(for jobID: UUID, root: URL? = nil) throws -> URL {
        let base: URL
        if let root {
            base = root
        } else {
            base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
                .appendingPathComponent("RawLab/BatchJobs", isDirectory: true)
        }
        let directory = base.appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func copy(_ sourceURL: URL, identity: PhotoIdentity, jobID: UUID, root: URL? = nil) throws -> URL {
        let directory = try directory(for: jobID, root: root)
        let ext = sourceURL.pathExtension.isEmpty ? "raw" : sourceURL.pathExtension
        let destination = directory.appendingPathComponent(safeFileName(identity.key) + "." + ext)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        let temporary = directory.appendingPathComponent(".copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: sourceURL, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func safeFileName(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func prepare(_ job: inout BatchExportJob, look: URL?, root: URL? = nil) throws {
        job.source.sourceURL = try copy(job.source.sourceURL, identity: job.source.identity, jobID: job.id, root: root)
        if job.source.settings.hasLook {
            guard let look, FileManager.default.isReadableFile(atPath: look.path) else {
                throw BatchExportError.global(L10n.text("所选外观不可用，请重新选择外观。"))
            }
            let folder = try directory(for: job.id, root: root).deletingLastPathComponent()
            let destination = folder.appendingPathComponent("look.\(look.pathExtension)")
            if look != destination && !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: look, to: destination)
            }
            job.source.lookURL = destination
        }
    }
}

enum BatchFileOutputStore {
    static func root() -> URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Exports", isDirectory: true)
    }

    static func directory(for jobID: UUID) throws -> URL {
        let directory = root().appendingPathComponent(jobID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BatchExportError.global(error.localizedDescription)
        }
        return directory
    }

    static func destination(jobID: UUID, outputName: String) -> URL {
        root().appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent(outputName)
    }

    static func temporaryURL(for jobID: UUID, outputName: String) -> URL {
        root().appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent(".rawlab-\(UUID().uuidString)-\(outputName)")
    }
}

enum BatchFileWriter {
    static func write(file: URL, outputName: String, jobID: UUID,
                      checkpoint: @escaping (String) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw BatchExportError.target(L10n.text("渲染型 DNG 未生成。"))
        }
        let directory = try BatchFileOutputStore.directory(for: jobID)
        let destination = directory.appendingPathComponent(outputName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: file,
                                                          backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: file, to: destination)
            }
        } catch {
            throw BatchExportError.global(error.localizedDescription)
        }
        do {
            try checkpoint("file:\(destination.path)")
        } catch {
            throw BatchExportError.uncertain(L10n.text("DNG 已生成，但任务记录未更新，请先核对保存结果。"))
        }
    }
}

enum OutputNameAllocator {
    static func baseName(for displayName: String, suffix: String = "jpg") -> String {
        let base = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        return (base.isEmpty ? "RawLab" : base) + "." + suffix
    }

    static func assignUniqueNames(_ targets: [BatchTarget], suffix: String = "jpg") -> [BatchTarget] {
        var used = Set<String>()
        return targets.map { target in
            let original = URL(fileURLWithPath: target.outputName).deletingPathExtension().lastPathComponent
            let base = original.isEmpty ? URL(fileURLWithPath: target.displayName).deletingPathExtension().lastPathComponent : original
            var candidate = (base.isEmpty ? "RawLab" : base) + "." + suffix
            var number = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base)-\(number).\(suffix)"
                number += 1
            }
            used.insert(candidate.lowercased())
            var copy = target
            copy.outputName = candidate
            return copy
        }
    }
}
