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
    var failure: String?
}
struct CameraTransferJob: Codable, Identifiable {
    let id: UUID
    let camera: CameraDeviceIdentity
    let connectionKey: String
    let createdAt: Date
    var items: [CameraTransferItem]
    var complete: Bool { items.allSatisfy { $0.phase == .saved } }

    func pendingAssets(device: CameraDeviceIdentity, connectionKey: String, assets: [CameraRemoteAsset],
                       allowAlternateConnection: Bool) throws -> [(CameraTransferItem, CameraRemoteAsset)] {
        let serial = camera.serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifiedSerial = !serial.isEmpty && serial.contains { $0 != "0" }
        guard camera.manufacturer == device.manufacturer, camera.model == device.model,
              serial == device.serial.trimmingCharacters(in: .whitespacesAndNewlines),
              self.connectionKey == connectionKey || (allowAlternateConnection && verifiedSerial) else {
            throw CameraProtocolError.invalid("Transfer belongs to a different camera")
        }
        let assetsBySnapshot = Dictionary(grouping: assets, by: \.snapshot)
        return try items.filter { $0.phase != .saved }.map { item in
            guard let matches = assetsBySnapshot[item.asset], matches.count == 1 else {
                throw CameraProtocolError.invalid("Camera original changed; select it again")
            }
            return (item, matches[0])
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
}
struct CameraTetherRecord: Codable, Identifiable {
    let id: UUID
    let camera: CameraDeviceIdentity
    let connectionKey: String
    var baseline: Set<String>
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
                  state.jobs.allSatisfy({ $0.items.count <= 64 && Set($0.items.map(\.id)).count == $0.items.count &&
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
    private static func validDigest(_ digest: String) -> Bool {
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
    func enqueue(device: CameraDeviceIdentity, connectionKey: String, assets: [CameraAssetSnapshot]) throws -> CameraTransferJob {
        try change { try appendJob(device: device, connectionKey: connectionKey, assets: assets) }
    }
    private func appendJob(device: CameraDeviceIdentity, connectionKey: String, assets: [CameraAssetSnapshot]) throws -> CameraTransferJob {
        guard !assets.isEmpty, assets.count <= 64, assets.allSatisfy({ $0.transferable && CameraWire.validName($0.name) && CameraWire.photoName($0.name) }),
              assets.reduce(UInt64(0), { $0 + $1.size }) <= 2 << 30,
              Set(assets.map(\.key)).count == assets.count else { throw CameraProtocolError.invalid("Transfer exceeds 64 originals or 2 GiB") }
        let job = CameraTransferJob(id: UUID(), camera: device, connectionKey: connectionKey, createdAt: Date(),
            items: assets.map { CameraTransferItem(id: UUID(), asset: $0) })
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
            for existing in state.originals where existing.digest == digest && existing.size == actual.size && existing.availability != .prepared {
                if availability(existing) == .available {
                    try change { state.jobs[j].items[i].sourceID = existing.id; state.jobs[j].items[i].digest = digest; state.jobs[j].items[i].phase = .saved }
                    try? FileManager.default.removeItem(at: partial)
                    return existing
                }
            }
            let source = CameraStoredOriginal(id: UUID(), name: transfer.asset.name, size: actual.size, digest: digest, savedAt: Date())
            try change {
                state.originals.append(source); state.jobs[j].items[i].sourceID = source.id
                state.jobs[j].items[i].digest = digest; state.jobs[j].items[i].phase = .prepared
            }
            try FileManager.default.createDirectory(at: originalURL(source).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: partial, to: originalURL(source))
            syncDirectory(originalURL(source).deletingLastPathComponent())
            syncDirectory(originalsDirectory)
            try change {
                state.originals[state.originals.count - 1].availability = .available
                state.jobs[j].items[i].phase = .saved
            }
            return state.originals.last!
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
                if file.pathExtension == "partial", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func beginTether(device: CameraDeviceIdentity, connectionKey: String, baseline: [CameraRemoteAsset]) throws {
        try change { state.tether = CameraTetherRecord(id: UUID(), camera: device, connectionKey: connectionKey, baseline: Set(baseline.map { $0.snapshot.key })) }
    }
    func validateTetherResume(device: CameraDeviceIdentity, connectionKey: String, assets: [CameraRemoteAsset]) throws {
        try locked {
            guard let tether = state.tether, tether.camera.stableKey == device.stableKey, tether.connectionKey == connectionKey,
                  !device.serial.isEmpty || connectionKey.hasPrefix("BLE:") || connectionKey.hasPrefix("SSID:"),
                  !tether.baseline.isEmpty, tether.baseline.isSubset(of: Set(assets.map { $0.snapshot.key })) else {
                throw CameraProtocolError.tetherRecoveryRequired
            }
        }
    }
    func rebaseResumedTether(_ assets: [CameraRemoteAsset]) throws {
        try change {
            guard state.tether != nil else { throw CameraProtocolError.invalid("Tether session is missing") }
            // 无可靠卡片 UUID 时，离线新增对象不能自动归因；只恢复已登记任务。
            state.tether?.baseline = Set(assets.map { $0.snapshot.key })
        }
    }
    func registerTetherAssets(_ assets: [CameraAssetSnapshot]) throws -> CameraTransferJob {
        try change {
            guard let tether = state.tether else { throw CameraProtocolError.invalid("Tether session is missing") }
            let job = try appendJob(device: tether.camera, connectionKey: tether.connectionKey, assets: assets)
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
