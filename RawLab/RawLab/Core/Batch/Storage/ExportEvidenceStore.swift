import Foundation

// Q6（B1 判据）：相机原件的「已导出」= 真实外部出口成功后的持久登记，这里是唯一账本。
public final class ExportEvidenceStore: @unchecked Sendable {
    public static let shared = ExportEvidenceStore()

    private struct Index: Codable { var identifiers: [String] }
    private let url: URL?
    private let queue = DispatchQueue(label: "com.rawlab.exportevidence")
    private var cache: Set<String>?

    private init() {
        url = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: true)
            .appendingPathComponent("RawLab/ExportEvidence.json")
    }
    // 模型测试注入临时目录；app 用 shared。
    public init(url: URL) { self.url = url }

    public func record(contentIdentifier: String?) {
        guard let contentIdentifier, !contentIdentifier.isEmpty else { return }
        record(contentIdentifiers: [contentIdentifier])
    }

    // 登记失败（磁盘写失败）不抛出：内存账本保留，下一次登记再落盘。
    public func record(contentIdentifiers: [String]) {
        let additions = contentIdentifiers.filter { !$0.isEmpty }
        guard !additions.isEmpty else { return }
        queue.sync {
            var set = cache ?? readUnlocked()
            guard !Set(additions).isSubset(of: set) else { cache = set; return }
            set.formUnion(additions)
            cache = set
            writeUnlocked(set)
        }
    }

    public func exportedContentIdentifiers() -> Set<String> {
        queue.sync {
            if let cache { return cache }
            let set = readUnlocked()
            cache = set
            return set
        }
    }

    public struct EvidenceCandidate: Sendable {
        public let contentIdentifier: String?
        public let succeeded: Bool
        public let outputFileURL: URL?
        public let inPicker: Bool

        public init(contentIdentifier: String?, succeeded: Bool, outputFileURL: URL?, inPicker: Bool) {
            self.contentIdentifier = contentIdentifier
            self.succeeded = succeeded
            self.outputFileURL = outputFileURL
            self.inPicker = inPicker
        }
    }

    public static func renderedDNGEvidenceIdentifiers(exported: Bool, candidates: [EvidenceCandidate]) -> [String] {
        guard exported else { return [] }
        return candidates.compactMap { candidate in
            guard candidate.succeeded, candidate.inPicker else { return nil }
            return candidate.contentIdentifier
        }
    }

    private func readUnlocked() -> Set<String> {
        guard let url, let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return [] }
        return Set(index.identifiers)
    }

    private func writeUnlocked(_ set: Set<String>) {
        guard let url else { return }
        let directory = url.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: directory,
                withIntermediateDirectories: true)) != nil else { return }
        let data = try? JSONEncoder().encode(Index(identifiers: set.sorted()))
        guard let data, (try? data.write(to: url, options: .atomic)) != nil else { return }
    }
}
