import Foundation

public final class ProcessingMigrationCancellation {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public struct ProcessingMigrationQuality: Codable, Equatable {
    public let rgbRMSE: Double
    public let p99Error: Double
    public let worstTileRMSE: Double
    public let detailRMSE: Double
    public let evaluations: Int

    public init(rgbRMSE: Double, p99Error: Double, worstTileRMSE: Double, detailRMSE: Double, evaluations: Int) {
        self.rgbRMSE = rgbRMSE
        self.p99Error = p99Error
        self.worstTileRMSE = worstTileRMSE
        self.detailRMSE = detailRMSE
        self.evaluations = evaluations
    }

    public var isValid: Bool {
        evaluations >= 0 && [rgbRMSE, p99Error, worstTileRMSE, detailRMSE]
            .allSatisfy { $0.isFinite && $0 >= 0 }
    }
    public var passes: Bool {
        isValid && rgbRMSE <= 2.0 / 255 && p99Error <= 6.0 / 255 &&
            worstTileRMSE <= 4.0 / 255 && detailRMSE <= 2.0 / 255
    }
}

// 与编辑记录一同原子保存；备份是原始设置，不由新版参数反推。
public struct ProcessingMigrationReceipt<Snapshot: Codable & Equatable>: Codable, Equatable {
    public enum Status: String, Codable { case migrated, kept, rolledBack }
    public let policyVersion: Int
    public let targetVersion: Int
    public var status: Status
    public let original: Snapshot
    public let quality: ProcessingMigrationQuality?

    public init(status: Status, original: Snapshot, quality: ProcessingMigrationQuality? = nil) {
        policyVersion = 1
        targetVersion = 3
        self.status = status
        self.original = original
        self.quality = quality
    }

    public func shouldAttempt(current: Snapshot, sourceVersion: Int) -> Bool {
        sourceVersion < targetVersion && status == .kept && original != current
    }

    private enum CodingKeys: String, CodingKey { case policyVersion, targetVersion, status, original, quality }
    public init(from decoder: Decoder) throws {
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
