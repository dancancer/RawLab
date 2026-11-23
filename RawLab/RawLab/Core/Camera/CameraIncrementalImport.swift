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

    var kinds: [String] {
        switch self {
        case .raw: return ["RAW"]
        case .jpeg: return ["JPEG"]
        case .rawAndJPEG: return ["RAW", "JPEG"]
        }
    }

    func includes(_ asset: CameraAssetSnapshot) -> Bool { kinds.contains(asset.kind) }
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
    // Older manifests used one boundary for both formats.
    let boundary: CameraImportBoundary?
    var owner: UUID?
    var boundaries: [String: CameraImportBoundary]?
}

struct CameraImportBoundary: Codable {
    let date: Date
    let storage: Set<UInt32>
    let keys: Set<String>
    let anchors: Set<String>
    let owner: UUID

    static func latest(from assets: [CameraAssetSnapshot], storage: Set<UInt32>, owner: UUID) -> Self? {
        let dated = assets.compactMap { asset in asset.captureDate.map { (asset, $0) } }
        guard let date = dated.map(\.1).max() else { return nil }
        let tail = dated.filter { $0.1 == date }.map(\.0)
        return Self(date: date, storage: storage, keys: Set(tail.map(\.key)),
                    anchors: Set(tail.map(\.anchorKey)), owner: owner)
    }
}

struct CameraIncrementalScan {
    static let maximumAssets = 10_000

    let assets: [CameraRemoteAsset]
    let undatedCount: Int
    let start: Date
    let needsCutoffConfirmation: Bool
    let nextBoundaries: [String: CameraImportBoundary]

    init(assets: [CameraRemoteAsset], boundaries: [String: CameraImportBoundary], cutoff: Date, customCutoff: Date?,
         format: CameraImportFormat, includeUndated: Bool, savedKeys: Set<String> = [], skippedKeys: Set<String> = []) {
        let owner = assets.first?.owner
        let storage = Set(assets.map { $0.snapshot.storage })
        let listed = assets.map { ($0, $0.snapshot.captureDate) }
        let dated = listed.compactMap { asset, date in date.map { (asset, $0) } }
        let confirmed = boundaries.filter { kind, boundary in
            // 卡槽和照片元数据不足以确认重连后的存储卡。
            boundary.owner == owner && boundary.storage == storage && dated.contains {
                $0.0.snapshot.kind == kind && $0.1 == boundary.date && boundary.anchors.contains($0.0.snapshot.anchorKey)
            }
        }
        let starts = Dictionary(uniqueKeysWithValues: format.kinds.map { ($0, customCutoff ?? confirmed[$0]?.date ?? cutoff) })
        needsCutoffConfirmation = customCutoff == nil && format.kinds.contains { boundaries[$0] != nil && confirmed[$0] == nil }
        if needsCutoffConfirmation {
            start = format.kinds.compactMap { boundaries[$0]?.date }.min() ?? cutoff
        } else {
            start = starts.values.min() ?? cutoff
        }
        let undated = listed.compactMap { asset, date in
            date == nil && format.includes(asset.snapshot) && !savedKeys.contains(asset.snapshot.key) &&
                !skippedKeys.contains(asset.snapshot.key) ? asset : nil
        }
        undatedCount = undated.count

        if needsCutoffConfirmation {
            self.assets = []
            nextBoundaries = [:]
            return
        }

        func afterConfirmedBoundary(_ asset: CameraRemoteAsset, _ date: Date) -> Bool {
            guard customCutoff == nil, let boundary = confirmed[asset.snapshot.kind],
                  date == boundary.date, asset.owner == boundary.owner else { return true }
            return !boundary.keys.contains(asset.snapshot.key)
        }

        let eligible = dated.filter { asset, date in
            guard let start = starts[asset.snapshot.kind], date >= start,
                  !savedKeys.contains(asset.snapshot.key), !skippedKeys.contains(asset.snapshot.key) else { return false }
            return afterConfirmedBoundary(asset, date)
        }
        self.assets = eligible.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.snapshot.key < $1.0.snapshot.key
        }.map(\.0) + (includeUndated ? undated : [])

        let selectedByKind = Dictionary(grouping: eligible.map(\.0.snapshot), by: \.kind)
        var next: [String: CameraImportBoundary] = [:]
        if let owner {
            for (kind, selected) in selectedByKind where customCutoff == nil || confirmed[kind] == nil {
                let kindStart = starts[kind] ?? cutoff
                let skippedDate = dated.compactMap { asset, date -> Date? in
                    guard asset.snapshot.kind == kind, date >= kindStart,
                          skippedKeys.contains(asset.snapshot.key), afterConfirmedBoundary(asset, date) else { return nil }
                    return date
                }.min()
                if let skippedDate {
                    let selectedKeys = Set(selected.map(\.key))
                    let safe = dated.compactMap { asset, date -> CameraAssetSnapshot? in
                        let key = asset.snapshot.key
                        guard asset.snapshot.kind == kind, date >= kindStart, date <= skippedDate, !skippedKeys.contains(key),
                              selectedKeys.contains(key) || savedKeys.contains(key) ||
                                (customCutoff == nil && confirmed[kind]?.date == date && confirmed[kind]?.keys.contains(key) == true)
                        else { return nil }
                        return asset.snapshot
                    }
                    next[kind] = CameraImportBoundary.latest(from: safe, storage: storage, owner: owner) ?? confirmed[kind]
                } else {
                    next[kind] = CameraImportBoundary.latest(from: selected, storage: storage, owner: owner)
                }
            }
        }
        nextBoundaries = next
    }
}

extension CameraTransferJob {
    func bindToListing(_ assets: [CameraRemoteAsset]) -> [UUID: CameraRemoteAsset] {
        guard let owner = assets.first?.owner else { return [:] }
        if originalListingOwner == owner {
            let exact = Dictionary(grouping: assets, by: \.snapshot)
            return Dictionary(uniqueKeysWithValues: items.compactMap { item in
                guard let matches = exact[item.asset], matches.count == 1 else { return nil }
                return (item.id, matches[0])
            })
        }

        // 槽位和照片元数据只能定位候选。跨会话下载必须再核对已保存的源摘要。
        let stored = Dictionary(grouping: items, by: \.asset.withoutLocator)
        let listed = Dictionary(grouping: assets, by: \.snapshot.withoutLocator)
        return Dictionary(uniqueKeysWithValues: stored.compactMap { metadata, original in
            guard original.count == 1, original[0].sourceDigest != nil,
                  let matches = listed[metadata], matches.count == 1 else { return nil }
            return (original[0].id, matches[0])
        })
    }
}

extension CameraAssetSnapshot {
    var captureDate: Date? {
        if format == 0 && storage == 0 {
            guard let milliseconds = Int64(created), (946_684_800_000..<4_102_444_800_000).contains(milliseconds) else { return nil }
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
        // 旧协议按相机钟面时间比较，避免手机跨时区使已确认的日期边界移动。
        // 格式为 yyyyMMdd'T'HHmmss（15 字节 ASCII），GMT 公历有效日期且在 [2000-01-01, 2100-01-01)。
        let utf8 = Array(created.utf8.prefix(15))
        guard utf8.count == 15, utf8[8] == 0x54 else { return nil }
        @inline(__always) func digit(_ byte: UInt8) -> Int? {
            byte >= 0x30 && byte <= 0x39 ? Int(byte - 0x30) : nil
        }
        @inline(__always) func twoDigits(_ i: Int) -> Int? {
            guard let a = digit(utf8[i]), let b = digit(utf8[i + 1]) else { return nil }
            return a * 10 + b
        }
        guard let yHi = twoDigits(0), let yLo = twoDigits(2),
              let month = twoDigits(4), let day = twoDigits(6),
              let hour = twoDigits(9), let minute = twoDigits(11), let second = twoDigits(13) else { return nil }
        let year = yHi * 100 + yLo
        guard (2000...2099).contains(year),
              (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else { return nil }
        let maxDay: Int
        switch month {
        case 2:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            maxDay = isLeap ? 29 : 28
        case 4, 6, 9, 11:
            maxDay = 30
        default:
            maxDay = 31
        }
        guard (1...maxDay).contains(day) else { return nil }
        let y = year - (month <= 2 ? 1 : 0)
        let era = y / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = Int64(days) * 86_400 + Int64(hour) * 3_600 + Int64(minute) * 60 + Int64(second)
        guard (946_684_800..<4_102_444_800).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: Double(seconds))
    }

    var anchorKey: String {
        "\(storage):\(format):\(name):\(size):\(created):\(modified)"
    }

    var withoutLocator: CameraAssetSnapshot {
        CameraAssetSnapshot(content: 0, file: 0, storage: storage, format: format, name: name,
                            size: size, created: created, modified: modified)
    }
}
