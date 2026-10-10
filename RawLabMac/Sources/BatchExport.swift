import Foundation

enum BatchItemStatus: String, Codable {
    case waiting, running, publishing, succeeded, failed
    var title: String {
        switch self {
        case .waiting: return "等待导出"
        case .running, .publishing: return "正在导出"
        case .succeeded: return "已导出"
        case .failed: return "导出失败"
        }
    }
}

struct BatchExportItem: Codable, Identifiable {
    let id: UUID
    let input: URL
    let identity: OriginalFileIdentity
    var selected = false
    var status = BatchItemStatus.waiting
    var output: URL?
    var completedIdentity: OriginalFileIdentity?
    var error: String?
    var validationError: String?

    init(url: URL) throws {
        id = UUID()
        input = url.resolvingSymlinksInPath().standardizedFileURL
        identity = try OriginalFileIdentity(input)
    }
}

struct BatchExportJob: Codable {
    var version = 1
    let id: UUID
    let source: URL
    let settings: Adjustments
    var look: URL?
    let lookName: String
    var items: [BatchExportItem] = []
    var outputDirectory: URL?
    var png = false
    var longEdge: Int?
    var started = false
    var interrupted = false
    var cancelled = false
    var failure: String?

    init(source: URL, settings: Adjustments, look: URL?, lookName: String) {
        id = UUID()
        self.source = source
        self.settings = settings
        self.look = look
        self.lookName = lookName
    }

    var selectedCount: Int { items.filter(\.selected).count }
    var succeededCount: Int { items.filter { $0.selected && $0.status == .succeeded }.count }
    var failedCount: Int { items.filter { $0.selected && $0.status == .failed }.count }
    var remainingCount: Int { selectedCount - succeededCount - failedCount }
    var suffix: String { png ? "png" : "jpg" }
}

final class BatchJournal {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Batch", isDirectory: true)
    }
    let directory: URL
    private var url: URL { directory.appendingPathComponent("job.json") }

    init(directory: URL = BatchJournal.defaultDirectory) { self.directory = directory }

    func save(_ job: BatchExportJob) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
    }

    func snapshotLook(_ original: URL?, for id: UUID) throws -> URL? {
        guard let original else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("\(id.uuidString).\(original.pathExtension)")
        try FileManager.default.copyItem(at: original, to: copy)
        return copy
    }

    func load() throws -> BatchExportJob? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var job = try JSONDecoder().decode(BatchExportJob.self, from: Data(contentsOf: url))
        guard job.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        for index in job.items.indices where [.running, .publishing].contains(job.items[index].status) {
            let item = job.items[index]
            if item.status == .publishing, let output = item.output, let expected = item.completedIdentity,
               let actual = try? OriginalFileIdentity(output), expected.matchesContent(actual) {
                job.items[index].status = .succeeded
            } else {
                job.items[index].status = .waiting
                job.items[index].error = nil
            }
            job.interrupted = true
            cleanup(job, item: item)
        }
        if job.started && job.remainingCount > 0 { job.interrupted = true }
        return job
    }

    func discard(_ job: BatchExportJob) throws {
        for item in job.items { cleanup(job, item: item) }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        if let look = job.look, look.deletingLastPathComponent() == directory,
           look.deletingPathExtension().lastPathComponent == job.id.uuidString {
            try? FileManager.default.removeItem(at: look)
        }
    }

    private func cleanup(_ job: BatchExportJob, item: BatchExportItem) {
        guard let directory = job.outputDirectory else { return }
        let temp = directory.appendingPathComponent(".rawlab-\(job.id)-\(item.id).\(job.suffix)")
        try? FileManager.default.removeItem(at: temp)
    }
}

extension OriginalFileIdentity {
    func matchesContent(_ other: OriginalFileIdentity) -> Bool {
        size == other.size && modified == other.modified && fileNumber == other.fileNumber
    }
}

enum BatchRunScope { case unfinished, failed }

enum BatchExportFailure: LocalizedError {
    case destination, changedInput, missingLook, noSelection
    var errorDescription: String? {
        switch self {
        case .destination: return "无法写入输出目录，请检查访问权限和剩余空间。"
        case .changedInput: return "原始文件已被替换，请重新选择照片。"
        case .missingLook: return "任务使用的外观文件不可用，请重新创建任务。"
        case .noSelection: return "请至少选择一张 RAW 照片。"
        }
    }
}

enum BatchExportRunner {
    typealias Render = (URL, Adjustments, URL?, URL) throws -> Void

    static func run(job: inout BatchExportJob, journal: BatchJournal, scope: BatchRunScope,
                    shouldCancel: () -> Bool, didUpdate: (BatchExportJob) -> Void = { _ in },
                    render: Render) throws {
        guard let directory = job.outputDirectory else { throw BatchExportFailure.destination }
        guard job.selectedCount > 0 else { throw BatchExportFailure.noSelection }
        if let look = job.look, !FileManager.default.isReadableFile(atPath: look.path) {
            throw BatchExportFailure.missingLook
        }
        try verifyDestination(directory)
        job.started = true; job.interrupted = false; job.cancelled = false; job.failure = nil
        try journal.save(job)
        do {
            for index in job.items.indices {
                let item = job.items[index]
                guard item.selected, item.status != .succeeded,
                      scope != .failed || item.status == .failed else { continue }
                if shouldCancel() { job.cancelled = true; break }
                try verifyDestination(directory)
                job.items[index].status = .running
                job.items[index].error = nil
                try journal.save(job)
                didUpdate(job)
                try export(index, job: &job, journal: journal, directory: directory, render: render)
                didUpdate(job)
            }
        } catch {
            job.interrupted = true; job.failure = error.localizedDescription
            try? journal.save(job)
            didUpdate(job)
            throw error
        }
        try journal.save(job)
        didUpdate(job)
    }

    private static func export(_ index: Int, job: inout BatchExportJob, journal: BatchJournal,
                               directory: URL, render: Render) throws {
        let item = job.items[index]
        let temp = directory.appendingPathComponent(".rawlab-\(job.id)-\(item.id).\(job.suffix)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            guard try OriginalFileIdentity(item.input) == item.identity else { throw BatchExportFailure.changedInput }
            try render(item.input, job.settings, job.look, temp)
        } catch {
            job.items[index].status = .failed
            job.items[index].error = error.localizedDescription
            try journal.save(job)
            if isStorageFailure(error) { throw error }
            try verifyDestination(directory)
            return
        }
        let name = item.input.deletingPathExtension().lastPathComponent + "-" + safeName(job.lookName)
        let output = uniqueOutput(directory: directory, name: name, suffix: job.suffix)
        // 在发布前记录 inode；重启能识别已发布但尚未来得及记成功的成片。
        job.items[index].output = output
        job.items[index].completedIdentity = try OriginalFileIdentity(temp)
        job.items[index].status = .publishing
        try journal.save(job)
        do {
            try FileManager.default.moveItem(at: temp, to: output)
        } catch {
            job.items[index].status = .failed
            job.items[index].error = error.localizedDescription
            try journal.save(job)
            if isStorageFailure(error) { throw error }
            return
        }
        job.items[index].status = .succeeded
        job.items[index].error = nil
        try journal.save(job)
    }

    static func uniqueOutput(directory: URL, name: String, suffix: String) -> URL {
        var number = 0
        while true {
            let label = name + (number == 0 ? "" : "-\(number)") + "." + suffix
            let url = directory.appendingPathComponent(label)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }

    private static func safeName(_ name: String) -> String {
        let text = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(separator: "-")
        return String(text.prefix(80))
    }

    private static func verifyDestination(_ directory: URL) throws {
        let probe = directory.appendingPathComponent(".rawlab-write-\(UUID().uuidString)")
        do {
            try Data([0]).write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
        } catch { throw BatchExportFailure.destination }
    }

    private static func isStorageFailure(_ error: Error) -> Bool {
        if case RenderError.outputIO = error { return true }
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError,
            NSFileWriteVolumeReadOnlyError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && [28, 13, 30].contains(error.code))
    }
}
