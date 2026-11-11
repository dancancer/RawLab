import Foundation

enum CameraImportFormat: String, Codable, CaseIterable, Identifiable {
    case raw, jpeg, rawAndJPEG

    var id: Self { self }
    var title: String {
        switch self {
        case .raw: return "RAW"
        case .jpeg: return "JPEG"
        case .rawAndJPEG: return "RAW + JPEG"
        }
    }

    func includes(_ asset: CameraAssetSnapshot) -> Bool {
        self == .rawAndJPEG || (self == .raw) == (asset.kind == "RAW")
    }
}

struct CameraJPEGOptions: Codable, Equatable {
    var adjust = false
    var longEdge: Int?
    var quality = 90

    var isValid: Bool {
        (1...100).contains(quality) && longEdge.map { (1...65535).contains($0) } != false
    }
}

struct CameraIncrementalPlan: Codable {
    let format: CameraImportFormat
    let jpeg: CameraJPEGOptions
    let boundary: CameraImportBoundary?
    var owner: UUID?
}

struct CameraImportBoundary: Codable {
    let date: Date
    let storage: Set<UInt32>
    let keys: Set<String>
    let anchors: Set<String>
    let owner: UUID
}

struct CameraIncrementalScan {
    static let maximumAssets = 10_000

    let assets: [CameraRemoteAsset]
    let undatedCount: Int
    let start: Date
    let needsCutoffConfirmation: Bool
    let nextBoundary: CameraImportBoundary?

    init(assets: [CameraRemoteAsset], boundary: CameraImportBoundary?, cutoff: Date, customCutoff: Date?,
         format: CameraImportFormat, includeUndated: Bool, savedKeys: Set<String> = []) {
        let storage = Set(assets.map { $0.snapshot.storage })
        let listed = assets.map { ($0, $0.snapshot.captureDate) }
        let dated = listed.compactMap { asset, date in date.map { (asset, $0) } }
        let confirmed = boundary.flatMap { boundary -> CameraImportBoundary? in
            guard storage == boundary.storage,
                  dated.contains(where: { $0.1 == boundary.date && boundary.anchors.contains($0.0.snapshot.anchorKey) })
            else { return nil }
            return boundary
        }
        let start = customCutoff ?? confirmed?.date ?? cutoff
        self.start = start
        needsCutoffConfirmation = boundary != nil && confirmed == nil && customCutoff == nil
        let undated = listed.compactMap { asset, date in
            date == nil && format.includes(asset.snapshot) && !savedKeys.contains(asset.snapshot.key) ? asset : nil
        }
        undatedCount = undated.count

        if needsCutoffConfirmation {
            self.assets = []
            nextBoundary = nil
            return
        }

        let inRange = dated.filter { $0.1 >= start }
        let eligible = inRange.filter { asset, date in
            guard format.includes(asset.snapshot), !savedKeys.contains(asset.snapshot.key) else { return false }
            // 跨会话的对象句柄可能变化。边界同刻的文件重新校验字节后再去重。
            guard customCutoff == nil, let confirmed, date == confirmed.date, asset.owner == confirmed.owner else { return true }
            return !confirmed.keys.contains(asset.snapshot.key)
        }
        self.assets = eligible.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.snapshot.key < $1.0.snapshot.key
        }.map(\.0) + (includeUndated ? undated : [])

        if (customCutoff == nil || confirmed == nil), !self.assets.isEmpty,
           let latest = inRange.map(\.1).max(), let owner = assets.first?.owner {
            let tail = inRange.filter { $0.1 == latest }.map { $0.0.snapshot }
            nextBoundary = CameraImportBoundary(date: latest, storage: storage, keys: Set(tail.map(\.key)),
                anchors: Set(tail.map(\.anchorKey)), owner: owner)
        } else { nextBoundary = nil }
    }
}

extension CameraAssetSnapshot {
    private static let legacyDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()

    var captureDate: Date? {
        if format == 0 && storage == 0 {
            guard let milliseconds = Int64(created), (946_684_800_000..<4_102_444_800_000).contains(milliseconds) else { return nil }
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
        // 旧协议按相机钟面时间比较，避免手机跨时区使已确认的日期边界移动。
        let datePart = String(created.prefix(15))
        guard datePart.count == 15, let date = Self.legacyDateFormat.date(from: datePart),
              Self.legacyDateFormat.string(from: date) == datePart,
              (946_684_800.0..<4_102_444_800.0).contains(date.timeIntervalSince1970) else { return nil }
        return date
    }

    var anchorKey: String {
        "\(storage):\(format):\(name):\(size):\(created):\(modified)"
    }
}
