import Foundation

// Q6（B1 判据）：相机原件的「已导出」= 真实外部出口成功后的持久登记，这里是唯一账本。
// 登记时机：保存照片图库成功、Files 另存（含渲染型 DNG）成功、批量导出每行进入 succeeded。
// 「在编辑器打开过」不算证据——RecentPhotoStore 是 100 张 / 2 GiB 的有界 LRU，removeLast
// 会物理删除副本、记录也能被手动移除，用它当判据会把从未导出的原件删掉。账本只增不删：
// 登记写失败只会在内存里保留、下次落盘（宁漏登记）；读取失败返回空集（宁漏删）。
// key 用源文件内容标识（SHA-256 十六进制小写），与 CameraStoredOriginal.digest 同格式。
final class ExportEvidenceStore {
    static let shared = ExportEvidenceStore()

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
    init(url: URL) { self.url = url }

    func record(contentIdentifier: String?) {
        guard let contentIdentifier, !contentIdentifier.isEmpty else { return }
        record(contentIdentifiers: [contentIdentifier])
    }

    // 登记失败（磁盘写失败）不抛出：内存账本保留，下一次登记再落盘。
    func record(contentIdentifiers: [String]) {
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

    func exportedContentIdentifiers() -> Set<String> {
        queue.sync {
            if let cache { return cache }
            let set = readUnlocked()
            cache = set
            return set
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
