import Foundation

final class ProcessingMigrationCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct ProcessingMigrationQuality: Codable, Equatable {
    let rgbRMSE: Double
    let p99Error: Double
    let worstTileRMSE: Double
    let detailRMSE: Double
    let evaluations: Int

    var isValid: Bool {
        evaluations >= 0 && [rgbRMSE, p99Error, worstTileRMSE, detailRMSE]
            .allSatisfy { $0.isFinite && $0 >= 0 }
    }
    var passes: Bool {
        isValid && rgbRMSE <= 2.0 / 255 && p99Error <= 6.0 / 255 &&
            worstTileRMSE <= 4.0 / 255 && detailRMSE <= 2.0 / 255
    }
}

// 与编辑记录一同原子保存；备份是原始设置，不由新版参数反推。
struct ProcessingMigrationReceipt<Snapshot: Codable & Equatable>: Codable, Equatable {
    enum Status: String, Codable { case migrated, kept, rolledBack }
    let policyVersion: Int
    let targetVersion: Int
    var status: Status
    let original: Snapshot
    let quality: ProcessingMigrationQuality?

    init(status: Status, original: Snapshot, quality: ProcessingMigrationQuality? = nil) {
        policyVersion = 1
        targetVersion = 3
        self.status = status
        self.original = original
        self.quality = quality
    }

    func shouldAttempt(current: Snapshot, sourceVersion: Int) -> Bool {
        sourceVersion < targetVersion && status == .kept && original != current
    }

    private enum CodingKeys: String, CodingKey { case policyVersion, targetVersion, status, original, quality }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        policyVersion = try values.decode(Int.self, forKey: .policyVersion)
        targetVersion = try values.decode(Int.self, forKey: .targetVersion)
        status = try values.decode(Status.self, forKey: .status)
        original = try values.decode(Snapshot.self, forKey: .original)
        quality = try values.decodeIfPresent(ProcessingMigrationQuality.self, forKey: .quality)
        guard policyVersion == 1, targetVersion == 3, quality?.isValid != false else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unsupported processing migration receipt"))
        }
    }
}
