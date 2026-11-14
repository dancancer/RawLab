import Foundation
import CryptoKit
import Darwin

enum CameraTransferPhase: String, Codable { case queued, downloading, prepared, saved, interrupted, failed }
enum CameraOriginalAvailability: String, Codable { case prepared, available, missing, changed, unavailable }
struct CameraTransferItem: Codable, Identifiable {
    let id: UUID
    let asset: CameraAssetSnapshot
    var phase: CameraTransferPhase = .queued
    var sourceID: UUID?
    var digest: String?
    var sourceDigest: String?
    var failure: String?
    var reused: Bool?
}
struct CameraTransferJob: Codable, Identifiable {
    typealias BoundItem = (item: CameraTransferItem, asset: CameraRemoteAsset)
    let id: UUID
    let camera: CameraDeviceIdentity
    let connectionKey: String
    let createdAt: Date
    var items: [CameraTransferItem]
    var incremental: CameraIncrementalPlan?
    var dismissed: Bool?
    var listingOwner: UUID?
    var originalListingOwner: UUID? { listingOwner ?? incremental?.owner }
    var complete: Bool { items.allSatisfy { $0.phase == .saved } }
    var savedCount: Int { items.filter { $0.phase == .saved }.count }
    var failedItems: [CameraTransferItem] { items.filter { $0.phase == .failed } }
    var pendingItems: [CameraTransferItem] { items.filter { $0.phase != .saved && $0.phase != .failed } }
    var itemLimit: Int { incremental == nil ? 64 : CameraIncrementalScan.maximumAssets }

    func matches(camera device: CameraDeviceIdentity, connectionKey: String, allowAlternateConnection: Bool = true) -> Bool {
        let serial = camera.serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifiedSerial = !serial.isEmpty && serial.contains { $0 != "0" }
        return camera.manufacturer == device.manufacturer && camera.model == device.model &&
            serial == device.serial.trimmingCharacters(in: .whitespacesAndNewlines) &&
            (self.connectionKey == connectionKey || (allowAlternateConnection && verifiedSerial))
    }

    func pendingAssets(device: CameraDeviceIdentity, connectionKey: String, assets: [CameraRemoteAsset],
                       allowAlternateConnection: Bool) throws -> [BoundItem] {
        let recoveryError: CameraProtocolError = allowAlternateConnection ? .importRecoveryRequired : .tetherRecoveryRequired
        guard matches(camera: device, connectionKey: connectionKey, allowAlternateConnection: allowAlternateConnection)
        else { throw recoveryError }
        let bound = bindToListing(assets)
        return try pendingItems.map { item in
            guard let asset = bound[item.id] else { throw recoveryError }
            return (item, asset)
        }
    }
}
struct CameraStoredOriginal: Codable, Identifiable {
    let id: UUID
    let name: String
    let size: UInt64
    let digest: String
    let savedAt: Date
    var availability: CameraOriginalAvailability = .prepared
    var jpegSource: CameraJPEGSource?
}
struct CameraTetherRecord: Codable, Identifiable {
    static let maximumFilesPerTransfer = 64
    static let maximumBytesPerTransfer: UInt64 = 2 << 30

    let id: UUID
    let camera: CameraDeviceIdentity
    let connectionKey: String
    var baseline: Set<String>
    // 重连后的句柄可能变化，保留其与旧任务条目的对应关系。没有摘要的离线文件不记录对应项。
    var reboundItems: [String: UUID]?
    var jobIDs: [UUID] = []
    var shutterRequestedAt: Date?
    var shutterOwner: UUID?
    var shutterAcknowledged = false
    var shutterJobs: [UUID] = []
}
struct CameraOriginalManifest: Codable {
    var version = 1
    var jobs: [CameraTransferJob] = []
    var originals: [CameraStoredOriginal] = []
    var tether: CameraTetherRecord?
    var canResumeTether: Bool { tetherRecoveryInputs != nil }

    // 首页和恢复使用同一份本地证据。卡内清单及原件字节仍须重连后核对。
    fileprivate var tetherRecoveryInputs: (record: CameraTetherRecord, jobs: [CameraTransferJob], digests: [UUID: String])? {
        guard let tether, tether.camera.supportsMobileContents || tether.camera.supportsLegacyContents,
              !tether.camera.serial.isEmpty || tether.connectionKey.hasPrefix("BLE:") || tether.connectionKey.hasPrefix("SSID:"),
              !tether.baseline.isEmpty, !tether.jobIDs.isEmpty,
              tether.jobIDs.count <= CameraTetherRecord.maximumFilesPerTransfer else { return nil }

        let ids = Set(tether.jobIDs)
        guard ids.count == tether.jobIDs.count else { return nil }
        let byID = Dictionary(grouping: jobs.lazy.filter { ids.contains($0.id) }, by: \.id)
        var registeredJobs: [CameraTransferJob] = []
        for id in tether.jobIDs {
            guard let matches = byID[id], matches.count == 1, let job = matches.first,
                  job.incremental == nil, !job.items.isEmpty,
                  job.matches(camera: tether.camera, connectionKey: tether.connectionKey, allowAlternateConnection: false)
            else { return nil }
            registeredJobs.append(job)
        }
        let items = registeredJobs.flatMap(\.items)
        guard items.count <= CameraTetherRecord.maximumFilesPerTransfer,
              items.allSatisfy({ $0.asset.transferable }),
              items.reduce(0, { $0 + $1.asset.size }) <= CameraTetherRecord.maximumBytesPerTransfer,
              Set(items.map(\.asset.withoutLocator)).count == items.count
        else { return nil }

        var digests: [UUID: String] = [:]
        for item in items {
            // 旧联机任务保存的是原件，其已保存摘要也可用于校验源字节。
            guard let digest = item.sourceDigest ?? (item.phase == .saved ? item.digest : nil),
                  CameraOriginalStore.validDigest(digest), digests.updateValue(digest, forKey: item.id) == nil
            else { return nil }
        }
        let registered = Dictionary(grouping: items, by: \.asset.key)
        var covered = Set<UUID>()
        for key in tether.baseline {
            let original = registered[key]
            guard let id = tether.reboundItems?[key] ?? (original?.count == 1 ? original?.first?.id : nil),
                  digests[id] != nil, covered.insert(id).inserted else { return nil }
        }
        return (tether, registeredJobs, digests)
    }

    func pendingIncrementalJob(device: CameraDeviceIdentity, connectionKey: String) -> CameraTransferJob? {
        jobs.last {
            $0.incremental != nil && !$0.complete && $0.dismissed != true &&
                $0.matches(camera: device, connectionKey: connectionKey)
        }
    }

    func savedIncrementalKeys(owner: UUID, jpeg: CameraJPEGOptions) -> Set<String> {
        Set(jobs.lazy.filter { $0.incremental != nil && $0.originalListingOwner == owner }.flatMap { job in
            job.items.compactMap { item in
                guard item.phase == .saved, item.asset.kind == "RAW" || job.incremental?.jpeg == jpeg
                else { return nil }
                return item.asset.key
            }
        })
    }

    func incrementalBoundaries(device: CameraDeviceIdentity, connectionKey: String) -> [String: CameraImportBoundary] {
        var result: [String: CameraImportBoundary] = [:]
        for job in jobs.reversed() where job.complete && job.matches(camera: device, connectionKey: connectionKey) {
            guard let plan = job.incremental else { continue }
            if let boundaries = plan.boundaries {
                for (kind, boundary) in boundaries where result[kind] == nil {
                    result[kind] = boundary
                }
            } else if let legacy = plan.boundary {
                // 旧起点可能来自未导入的格式，只用实际保存的条目重建。
                let saved = job.items.filter { $0.phase == .saved && $0.sourceID != nil }.map(\.asset)
                for (kind, assets) in Dictionary(grouping: saved, by: \.kind) where result[kind] == nil {
                    result[kind] = CameraImportBoundary.latest(from: assets, storage: legacy.storage, owner: legacy.owner)
                }
            }
            if result.count == CameraImportFormat.rawAndJPEG.kinds.count { break }
        }
        return result
    }
}

/// 唯一持久原件 owner。下载临时文件与最终原件在同一文件系统，编辑器只取得再次校验后的 URL。
final class CameraOriginalStore {
    let directory: URL
    private let originalsDirectory: URL, partialDirectory: URL, manifestURL: URL
    private let directoryLock: FileHandle
    private let lock = NSRecursiveLock()
    private var state: CameraOriginalManifest
    var snapshot: CameraOriginalManifest { locked { state } }

    static func applicationDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("RawLab/CameraOriginals", isDirectory: true)
    }
    init(directory: URL) throws {
        self.directory = directory
        originalsDirectory = directory.appendingPathComponent("originals", isDirectory: true)
        partialDirectory = directory.appendingPathComponent("partial", isDirectory: true)
        manifestURL = directory.appendingPathComponent("manifest.json")
        for path in [directory, originalsDirectory, partialDirectory] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let file = directory.appendingPathComponent(".lock")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: Data()) }
        directoryLock = try FileHandle(forUpdating: file)
        guard flock(directoryLock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw CameraProtocolError.invalid("Camera storage is already in use") }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 << 20 else { throw CameraProtocolError.invalid("Camera manifest exceeds budget") }
            state = try JSONDecoder().decode(CameraOriginalManifest.self, from: Data(contentsOf: manifestURL))
            guard state.version == 1,
                  Set(state.jobs.map(\.id)).count == state.jobs.count,
                  Set(state.originals.map(\.id)).count == state.originals.count,
                  state.originals.allSatisfy({ CameraWire.validName($0.name) && CameraWire.photoName($0.name) && $0.size > 0 && $0.size <= 1 << 30 && Self.validDigest($0.digest) }),
                  state.jobs.allSatisfy({ $0.items.count <= $0.itemLimit && $0.incremental?.jpeg.isValid != false &&
                    Set($0.items.map(\.id)).count == $0.items.count &&
                    $0.items.allSatisfy { CameraWire.validName($0.asset.name) && CameraWire.photoName($0.asset.name) && $0.asset.transferable } }) else {
                throw CameraProtocolError.invalid("Invalid camera storage manifest")
            }
        } else { state = CameraOriginalManifest() }
        try recover()
    }
    deinit { _ = flock(directoryLock.fileDescriptor, LOCK_UN); try? directoryLock.close() }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    fileprivate static func validDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func change<T>(_ body: () throws -> T) throws -> T {
        try locked {
            let previous = state
            do { let result = try body(); try persist(); return result }
            catch { state = previous; throw error }
        }
    }
    private func persist() throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= 32 << 20 else { throw CameraProtocolError.invalid("Camera task history exceeds storage budget") }
        let temporary = directory.appendingPathComponent(".manifest-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, manifestURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        syncDirectory(directory)
    }
    private func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        if descriptor >= 0 { _ = fsync(descriptor); _ = Darwin.close(descriptor) }
    }
    private func indices(job: UUID, item: UUID) throws -> (Int, Int) {
        guard let j = state.jobs.firstIndex(where: { $0.id == job }),
              let i = state.jobs[j].items.firstIndex(where: { $0.id == item }) else { throw CameraProtocolError.invalid("Camera transfer item is missing") }
        return (j, i)
    }
    func originalURL(_ source: CameraStoredOriginal) -> URL {
        originalsDirectory.appendingPathComponent(source.id.uuidString.lowercased(), isDirectory: true).appendingPathComponent(source.name)
    }
    private func partialURL(_ item: UUID) -> URL { partialDirectory.appendingPathComponent(item.uuidString.lowercased() + ".partial") }
    private func adjustedURL(_ item: UUID) -> URL { partialURL(item).deletingPathExtension().appendingPathExtension("jpeg-partial") }
    static let sampleSegmentBytes = 64 << 10
    static func sampleOffsets(forSize size: UInt64) -> [UInt64]? {
        let chunk = UInt64(sampleSegmentBytes)
        guard size >= chunk * 3 else { return nil }
        return [0, (size - chunk) / 2, size - chunk]
    }
    static func hash(_ url: URL) throws -> (size: UInt64, digest: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256(), size: UInt64 = 0
        while let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty {
            digest.update(data: bytes); size += UInt64(bytes.count)
            guard size <= 1 << 30 else { throw CameraProtocolError.invalid("Camera original exceeds budget") }
        }
        return (size, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private func availability(_ source: CameraStoredOriginal) -> CameraOriginalAvailability {
        let url = originalURL(source)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return .changed }
            let actual = try Self.hash(url)
            return actual.size == source.size && actual.digest == source.digest ? .available : .changed
        } catch {
            let code = (error as NSError).code
            return code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError ? .missing : .unavailable
        }
    }
    func verifiedURL(_ sourceID: UUID) throws -> URL {
        try locked {
            guard let index = state.originals.firstIndex(where: { $0.id == sourceID }),
                  state.originals[index].availability != .prepared else { throw CameraProtocolError.invalid("Original is not published") }
            let status = availability(state.originals[index])
            if status != state.originals[index].availability { try change { state.originals[index].availability = status } }
            guard status == .available else { throw CameraProtocolError.invalid("Saved camera original is missing or changed") }
            return originalURL(state.originals[index])
        }
    }
    func enqueue(device: CameraDeviceIdentity, connectionKey: String, assets: [CameraAssetSnapshot],
                 listingOwner: UUID? = nil, incremental: CameraIncrementalPlan? = nil) throws -> CameraTransferJob {
        try change {
            try appendJob(device: device, connectionKey: connectionKey, assets: assets,
                          listingOwner: listingOwner, incremental: incremental)
        }
    }
    func dismissIncrementalJob(_ id: UUID) throws {
        try change {
            guard let index = state.jobs.firstIndex(where: { $0.id == id && $0.incremental != nil && !$0.complete })
            else { throw CameraProtocolError.invalid("Pending incremental import is missing") }
            state.jobs[index].dismissed = true
        }
    }
    // Q6：相机原件不自动删，这里是唯一的手动清理入口。「已导出」以真实外部出口在场为准：
    // exportedContentIdentifiers 传入最近打开记录的私有副本内容标识（RecentPhotoStore 会在
    // 用户打开原件时把 RAW 完整副本存进自己的目录，打开是导出到相册/Files 的必经步骤）；
    // 没有该证据的完整任务宁漏删不误删，绝不动用户尚未导出的原件。
    // 其余保护：最新任务保留（历史与重复导入检测锚点）；联机记录（tether.jobIDs /
    // shutterJobs）引用的任务保留（断点恢复证据）；每台相机每个增量格式保留最近一条完整
    // 增量任务（incrementalBoundaries 按机身+连接回溯检查点，savedIncrementalKeys 的旧
    // owner 去重键被检查点边界门控，跨连接后旧 owner 不再命中）。
    // 原件文件仅在其余任务不再以 sourceID 引用时删除（跨任务共享的原件保留）；
    // 最近打开的照片由 RecentPhotoStore 另存副本，清理不影响其继续打开。
    func pruneExportedOriginals(exportedContentIdentifiers: Set<String> = []) throws
        -> (originals: Int, freedBytes: UInt64) {
        try change {
            guard let newestJob = state.jobs.max(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) })?.id
            else { return (0, 0) }
            var tetherReferenced = Set(state.tether?.jobIDs ?? [])
            tetherReferenced.formUnion(state.tether?.shutterJobs ?? [])
            // 与 incrementalBoundaries 同构的逆序扫描：每台相机首次供给某格式的完整任务
            // 是该格式的检查点锚点。锚点按机身归组比按连接更保守——多保留、不误删。
            var anchorIDs = Set<UUID>()
            var coveredKinds: [String: Set<String>] = [:]
            for job in state.jobs.reversed() where job.complete {
                guard let plan = job.incremental else { continue }
                let kinds: Set<String>
                if let boundaries = plan.boundaries { kinds = Set(boundaries.keys) }
                else if plan.boundary != nil {
                    kinds = Set(job.items.filter { $0.phase == .saved && $0.sourceID != nil }.map(\.asset.kind))
                } else { kinds = [] }
                var covered = coveredKinds[job.camera.stableKey] ?? []
                if !kinds.isSubset(of: covered) { anchorIDs.insert(job.id) }
                covered.formUnion(kinds)
                coveredKinds[job.camera.stableKey] = covered
            }
            let digestByID = Dictionary(state.originals.map { ($0.id, $0.digest) }, uniquingKeysWith: { first, _ in first })
            func fullyExported(_ job: CameraTransferJob) -> Bool {
                job.items.allSatisfy { item in
                    guard let source = item.sourceID else { return true }
                    guard let digest = digestByID[source] else { return false }  // 原件条目缺失：拿不准→不删
                    return exportedContentIdentifiers.contains(digest)
                }
            }
            let prunable = state.jobs.filter { job in
                job.complete && job.id != newestJob && !tetherReferenced.contains(job.id) &&
                    !anchorIDs.contains(job.id) && fullyExported(job)
            }
            guard !prunable.isEmpty else { return (0, 0) }
            let prunableIDs = Set(prunable.map(\.id))
            let remainingSourceIDs = Set(state.jobs.filter { !prunableIDs.contains($0.id) }
                .flatMap { $0.items.compactMap(\.sourceID) })
            let prunedSourceIDs = Set(prunable.flatMap { $0.items.compactMap(\.sourceID) })
            let orphans = state.originals.filter { prunedSourceIDs.contains($0.id) && !remainingSourceIDs.contains($0.id) }
            for original in orphans {
                let file = originalURL(original)
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            }
            let orphanIDs = Set(orphans.map(\.id))
            state.jobs.removeAll { prunableIDs.contains($0.id) }
            state.originals.removeAll { orphanIDs.contains($0.id) }
            return (orphans.count, orphans.reduce(UInt64(0)) { $0 + $1.size })
        }
    }
    private func appendJob(device: CameraDeviceIdentity, connectionKey: String, assets: [CameraAssetSnapshot],
                           listingOwner: UUID?, incremental: CameraIncrementalPlan? = nil) throws -> CameraTransferJob {
        let limit = incremental == nil ? 64 : CameraIncrementalScan.maximumAssets
        guard !assets.isEmpty, assets.count <= limit, Set(assets.map(\.key)).count == assets.count,
              assets.allSatisfy({ $0.transferable && CameraWire.validName($0.name) && CameraWire.photoName($0.name) })
        else { throw CameraProtocolError.invalid("Camera import queue contains invalid or excessive files") }
        if let incremental {
            guard incremental.jpeg.isValid, assets.allSatisfy(incremental.format.includes) else {
                throw CameraProtocolError.invalid("Incremental import options do not match the queue")
            }
        } else if assets.reduce(UInt64(0), { $0 + $1.size }) > 2 << 30 {
            throw CameraProtocolError.invalid("Transfer exceeds 64 originals or 2 GiB")
        }
        let job = CameraTransferJob(id: UUID(), camera: device, connectionKey: connectionKey, createdAt: Date(),
            items: assets.map { CameraTransferItem(id: UUID(), asset: $0) }, incremental: incremental, listingOwner: listingOwner)
        state.jobs.append(job); return job
    }
    func begin(job: UUID, item: UUID) throws -> (url: URL, handle: FileHandle) {
        try locked {
            let (j, i) = try indices(job: job, item: item)
            guard state.jobs[j].items[i].phase != .saved && state.jobs[j].items[i].phase != .prepared else {
                throw CameraProtocolError.invalid("Published original cannot restart downloading")
            }
            let url = partialURL(item)
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { throw CameraProtocolError.invalid("Cannot create camera partial file") }
            do {
                try change { state.jobs[j].items[i].phase = .downloading; state.jobs[j].items[i].failure = nil }
                return (url, try FileHandle(forWritingTo: url))
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        }
    }
    func complete(job: UUID, item: UUID, digest: String) throws -> CameraStoredOriginal {
        try locked {
            let (j, i) = try indices(job: job, item: item)
            let transfer = state.jobs[j].items[i], partial = partialURL(item)
            guard transfer.phase == .downloading, Self.validDigest(digest) else { throw CameraProtocolError.invalid("Original transfer is not complete") }
            let actual = try Self.hash(partial)
            guard actual.size == transfer.asset.size, actual.digest == digest else { throw CameraProtocolError.invalid("Original size or checksum mismatch") }
            let reader = try FileHandle(forReadingFrom: partial)
            let prefix = try reader.read(upToCount: 4) ?? Data(); try reader.close()
            try CameraWire.validateHeader(name: transfer.asset.name, data: prefix)
            if let expected = transfer.sourceDigest {
                guard expected == digest else { throw CameraProtocolError.importRecoveryRequired }
            } else {
                // 保存相机源字节的摘要，JPEG 调整或落盘失败后仍可核对重传来源。
                try change { state.jobs[j].items[i].sourceDigest = digest }
            }
            let jpegSource = state.jobs[j].incremental.flatMap { plan in
                plan.jpeg.adjust && transfer.asset.kind == "JPEG" ? CameraJPEGSource(digest: digest, options: plan.jpeg) : nil
            }
            let adjustableSource = try jpegSource.map { _ in try CameraJPEGProcessing.adjustableSource(partial) }
            if let existing = state.originals.first(where: { source in
                guard source.availability != .prepared, source.jpegSource == jpegSource else { return false }
                return (jpegSource != nil || (source.digest == digest && source.size == actual.size)) && availability(source) == .available
            }) {
                try change {
                    state.jobs[j].items[i].sourceID = existing.id
                    state.jobs[j].items[i].digest = existing.digest
                    state.jobs[j].items[i].phase = .saved
                    state.jobs[j].items[i].reused = true
                }
                try? FileManager.default.removeItem(at: partial)
                return existing
            }
            let staged = jpegSource == nil ? partial : adjustedURL(item)
            defer { if staged != partial { try? FileManager.default.removeItem(at: staged) } }
            let output: (size: UInt64, digest: String)
            if let jpegSource, let adjustableSource {
                try CameraJPEGProcessing.encode(source: adjustableSource, destinationURL: staged, options: jpegSource.options)
                output = try Self.hash(staged)
                guard output.size > 0 else { throw CameraProtocolError.jpegProcessing }
                let handle = try FileHandle(forUpdating: staged)
                defer { try? handle.close() }
                try handle.synchronize()
            } else { output = actual }
            let source = CameraStoredOriginal(id: UUID(), name: transfer.asset.name, size: output.size, digest: output.digest,
                                              savedAt: Date(), jpegSource: jpegSource)
            try change {
                state.originals.append(source); state.jobs[j].items[i].sourceID = source.id
                state.jobs[j].items[i].digest = output.digest; state.jobs[j].items[i].phase = .prepared
            }
            try FileManager.default.createDirectory(at: originalURL(source).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staged, to: originalURL(source))
            syncDirectory(originalURL(source).deletingLastPathComponent())
            syncDirectory(originalsDirectory)
            try change {
                state.originals[state.originals.count - 1].availability = .available
                state.jobs[j].items[i].phase = .saved
            }
            if staged != partial { try? FileManager.default.removeItem(at: partial) }
            return state.originals.last!
        }
    }
    func samplingCandidate(job: UUID, item: UUID) -> (source: CameraStoredOriginal, url: URL)? {
        locked {
            guard let (j, i) = try? indices(job: job, item: item) else { return nil }
            let currentJob = state.jobs[j], transfer = currentJob.items[i]
            guard transfer.phase != .saved, transfer.phase != .prepared else { return nil }
            if currentJob.incremental?.jpeg.adjust == true && transfer.asset.kind == "JPEG" { return nil }
            let target = transfer.asset
            guard Self.sampleOffsets(forSize: target.size) != nil, let captureDate = target.captureDate else { return nil }
            var matchedIDs = Set<UUID>()
            for pastJob in state.jobs {
                for pastItem in pastJob.items where pastItem.phase == .saved {
                    guard let sourceID = pastItem.sourceID,
                          pastItem.asset.kind == target.kind,
                          pastItem.asset.name == target.name,
                          pastItem.asset.size == target.size,
                          pastItem.asset.captureDate == captureDate else { continue }
                    matchedIDs.insert(sourceID)
                }
            }
            guard !matchedIDs.isEmpty else { return nil }
            var validSources: [CameraStoredOriginal] = []
            for index in state.originals.indices where matchedIDs.contains(state.originals[index].id) {
                let source = state.originals[index]
                guard source.jpegSource == nil, source.availability == .available, source.size == target.size,
                      transfer.sourceDigest == nil || transfer.sourceDigest == source.digest else { continue }
                let status = availability(source)
                if status != source.availability {
                    try? change { state.originals[index].availability = status }
                }
                if status == .available {
                    validSources.append(state.originals[index])
                }
            }
            guard Set(validSources.map(\.digest)).count == 1, let chosen = validSources.last else { return nil }
            return (chosen, originalURL(chosen))
        }
    }
    func reuseSampledOriginal(job: UUID, item: UUID, sourceID: UUID) throws -> CameraStoredOriginal {
        try locked {
            let (j, i) = try indices(job: job, item: item)
            let transfer = state.jobs[j].items[i]
            guard transfer.phase != .saved, transfer.phase != .prepared else {
                throw CameraProtocolError.invalid("Published original cannot be reused again")
            }
            guard !(state.jobs[j].incremental?.jpeg.adjust == true && transfer.asset.kind == "JPEG"),
                  let sourceIndex = state.originals.firstIndex(where: { $0.id == sourceID }) else {
                throw CameraProtocolError.invalid("Sampled original is unavailable")
            }
            let existing = state.originals[sourceIndex]
            guard existing.jpegSource == nil, existing.availability == .available,
                  existing.size == transfer.asset.size,
                  transfer.sourceDigest == nil || transfer.sourceDigest == existing.digest else {
                throw CameraProtocolError.invalid("Sampled original metadata mismatch")
            }
            let status = availability(existing)
            if status != existing.availability {
                try change { state.originals[sourceIndex].availability = status }
            }
            guard status == .available else {
                throw CameraProtocolError.invalid("Sampled original is missing or changed")
            }
            try change {
                state.jobs[j].items[i].sourceDigest = existing.digest
                state.jobs[j].items[i].sourceID = existing.id
                state.jobs[j].items[i].digest = existing.digest
                state.jobs[j].items[i].failure = nil
                state.jobs[j].items[i].phase = .saved
                state.jobs[j].items[i].reused = true
            }
            return state.originals[sourceIndex]
        }
    }
    func interrupt(job: UUID, item: UUID, error: String?, cancelled: Bool) throws {
        try locked {
            let (j, i) = try indices(job: job, item: item)
            guard state.jobs[j].items[i].phase != .saved, state.jobs[j].items[i].phase != .prepared else { return }
            try change {
                state.jobs[j].items[i].phase = cancelled ? .interrupted : .failed
                state.jobs[j].items[i].failure = error
            }
            try? FileManager.default.removeItem(at: partialURL(item))
        }
    }
    func recover() throws {
        try change {
            var discardSources: Set<UUID> = []
            for j in state.jobs.indices {
                for i in state.jobs[j].items.indices {
                    let item = state.jobs[j].items[i]
                    if item.phase == .prepared, let id = item.sourceID,
                       let source = state.originals.firstIndex(where: { $0.id == id }) {
                        if item.sourceDigest == nil {
                            let original = state.originals[source]
                            state.jobs[j].items[i].sourceDigest = original.jpegSource?.digest ?? original.digest
                        }
                        let status = availability(state.originals[source])
                        if status == .available {
                            state.originals[source].availability = .available; state.jobs[j].items[i].phase = .saved
                        } else if status == .missing {
                            discardSources.insert(id); state.jobs[j].items[i].phase = .interrupted
                            state.jobs[j].items[i].sourceID = nil
                        } else {
                            state.originals[source].availability = status; state.jobs[j].items[i].phase = .failed
                            state.jobs[j].items[i].failure = "Saved original checksum changed"
                        }
                    } else if item.phase == .downloading { state.jobs[j].items[i].phase = .interrupted }
                }
            }
            state.originals.removeAll { discardSources.contains($0.id) }
            // 仅清理该 Store 命名的未发布文件；最终原件及未知文件不属于垃圾。
            for file in try FileManager.default.contentsOfDirectory(at: partialDirectory, includingPropertiesForKeys: nil) {
                if ["partial", "jpeg-partial"].contains(file.pathExtension),
                   UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func beginTether(device: CameraDeviceIdentity, connectionKey: String, baseline: [CameraRemoteAsset]) throws {
        try change { state.tether = CameraTetherRecord(id: UUID(), camera: device, connectionKey: connectionKey, baseline: Set(baseline.map { $0.snapshot.key })) }
    }
    func resumeTether(device: CameraDeviceIdentity, connectionKey: String, assets: [CameraRemoteAsset],
                      verifySaved: (CameraTransferJob.BoundItem) throws -> String,
                      receivePending: (UUID, [CameraTransferJob.BoundItem]) throws -> Void,
                      checkCurrent: () throws -> Void = {}) throws {
        let (previous, jobs, matches) = try locked {
            try tetherRecoveryPlan(device: device, connectionKey: connectionKey, assets: assets)
        }
        do {
            // 核对已保存的原件后才开始发布待传项，避免混入换卡后的内容。
            for job in jobs {
                for item in job.items where item.phase == .saved {
                    try checkCurrent()
                    guard let match = matches[item.id], try verifySaved((item, match.asset)) == match.digest
                    else { throw CameraProtocolError.tetherRecoveryRequired }
                }
            }
            for job in jobs where !job.complete {
                try checkCurrent()
                let pending: [CameraTransferJob.BoundItem] = try job.pendingItems.map {
                    guard let match = matches[$0.id] else { throw CameraProtocolError.tetherRecoveryRequired }
                    return ($0, match.asset)
                }
                // 正常落盘流程比对待传项记录的源摘要。
                try receivePending(job.id, pending)
            }
        } catch CameraProtocolError.response(_, 0x2009) {
            // PTP InvalidObjectHandle：清单里的原件已不可读取，须由用户重新选片。
            throw CameraProtocolError.tetherRecoveryRequired
        }
        try checkCurrent()
        try change {
            guard state.tether?.id == previous.id, state.tether?.baseline == previous.baseline,
                  state.tether?.jobIDs == previous.jobIDs,
                  state.jobs.filter({ previous.jobIDs.contains($0.id) && $0.complete }).count == jobs.count
            else { throw CameraProtocolError.tetherRecoveryRequired }
            // 无可靠卡片 UUID 时，离线新增对象不能自动归因；只恢复已登记任务。
            state.tether?.baseline = Set(assets.map { $0.snapshot.key })
            state.tether?.reboundItems = Dictionary(uniqueKeysWithValues: matches.map { ($0.value.asset.snapshot.key, $0.key) })
        }
    }
    private typealias TetherMatch = (asset: CameraRemoteAsset, digest: String)

    private func tetherRecoveryPlan(device: CameraDeviceIdentity, connectionKey: String, assets: [CameraRemoteAsset]) throws
        -> (CameraTetherRecord, [CameraTransferJob], [UUID: TetherMatch]) {
        let unavailable = CameraProtocolError.tetherRecoveryRequired
        guard device.supportsMobileContents || device.supportsLegacyContents,
              let (tether, jobs, digests) = state.tetherRecoveryInputs,
              tether.camera.stableKey == device.stableKey, tether.connectionKey == connectionKey,
              let owner = assets.first?.owner, assets.allSatisfy({ $0.owner == owner }),
              Set(assets.map { $0.snapshot.key }).count == assets.count
        else { throw unavailable }

        let listed = Dictionary(grouping: assets, by: \.snapshot.withoutLocator)
        var matches: [UUID: TetherMatch] = [:]
        var keys = Set<String>()
        for item in jobs.flatMap(\.items) {
            guard let digest = digests[item.id],
                  let candidates = listed[item.asset.withoutLocator], candidates.count == 1,
                  keys.insert(candidates[0].snapshot.key).inserted
            else { throw unavailable }
            matches[item.id] = (candidates[0], digest)
        }
        return (tether, jobs, matches)
    }
    func registerTetherAssets(_ assets: [CameraAssetSnapshot], listingOwner: UUID) throws -> CameraTransferJob {
        try change {
            guard let tether = state.tether else { throw CameraProtocolError.invalid("Tether session is missing") }
            let job = try appendJob(device: tether.camera, connectionKey: tether.connectionKey, assets: assets,
                                    listingOwner: listingOwner)
            state.tether?.baseline.formUnion(assets.map(\.key)); state.tether?.jobIDs.append(job.id)
            if state.tether?.shutterRequestedAt != nil { state.tether?.shutterJobs.append(job.id) }
            return job
        }
    }
    func markShutterRequested(owner: UUID) throws {
        try change {
            guard state.tether != nil, state.tether?.shutterRequestedAt == nil else { throw CameraProtocolError.captureUnknown }
            state.tether?.shutterRequestedAt = Date(); state.tether?.shutterOwner = owner
            state.tether?.shutterAcknowledged = false; state.tether?.shutterJobs = []
        }
    }
    func acknowledgeShutter(owner: UUID) throws {
        try change {
            guard state.tether?.shutterOwner == owner else { return }
            state.tether?.shutterAcknowledged = true
        }
    }
    func clearUnsentShutter(owner: UUID) throws {
        try change {
            guard state.tether?.shutterOwner == owner, state.tether?.shutterAcknowledged == false else { return }
            state.tether?.shutterRequestedAt = nil; state.tether?.shutterOwner = nil; state.tether?.shutterJobs = []
        }
    }
    func finishConfirmedShutter(owner: UUID) throws {
        try change {
            guard let tether = state.tether, tether.shutterOwner == owner, tether.shutterAcknowledged,
                  !tether.shutterJobs.isEmpty, tether.shutterJobs.allSatisfy({ id in state.jobs.first { $0.id == id }?.complete == true }) else { return }
            state.tether?.shutterRequestedAt = nil; state.tether?.shutterOwner = nil
            state.tether?.shutterAcknowledged = false; state.tether?.shutterJobs = []
        }
    }
}
