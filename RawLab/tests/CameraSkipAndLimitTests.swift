import Foundation
import CryptoKit
import ImageIO
import CoreGraphics
import SwiftUI

#if os(macOS)
struct UIImage {
    let cgImage: CGImage?
    init(cgImage: CGImage) { self.cgImage = cgImage }
}

struct IOSCameraEndpoint: Equatable {
    let host: String
    let connectionKey: String
    let label: String
}
#endif

#if os(iOS)
struct ZoomablePhoto: View {
    init(image: UIImage, referenceImage: UIImage?, label: String,
         viewing: Binding<PhotoViewingState>, viewport: Binding<PhotoViewport>,
         nativePixelSize: CGSize? = nil) {}
    var body: some View { EmptyView() }
}
#endif

final class FakeSonyCameraEntry {
    let content: UInt32
    let file: UInt32
    let name: String
    let createdMillis: UInt64
    let legacyCreated: String
    var bytes: Data
    var downloadResponseCode: UInt16?
    var dropConnectionOnDownload = false

    init(content: UInt32, file: UInt32 = 1, name: String, createdMillis: UInt64, bytes: Data,
         legacyCreated: String = "20261113T100000",
         downloadResponseCode: UInt16? = nil, dropConnectionOnDownload: Bool = false) {
        self.content = content
        self.file = file
        self.name = name
        self.createdMillis = createdMillis
        self.legacyCreated = legacyCreated
        self.bytes = bytes
        self.downloadResponseCode = downloadResponseCode
        self.dropConnectionOnDownload = dropConnectionOnDownload
    }
}

final class FakeSonyCameraChannel: CameraByteChannel {
    enum Mode { case mobile, legacy }
    private let lock = NSLock()
    private var buffered = Data()
    private(set) var closed = false
    let mode: Mode
    var entries: [FakeSonyCameraEntry]
    var legacyHandleCountOverride: Int?
    private(set) var downloadAttempts: [String: Int] = [:]
    private(set) var mobileRangeReads: [String: [Range<Int>]] = [:]
    private(set) var legacyFullReads: [String: Int] = [:]
    private(set) var bytesReadByName: [String: Int] = [:]
    private(set) var objectInfoCalls = 0
    private var dropNextRead = false

    init(mode: Mode = .mobile, entries: [FakeSonyCameraEntry]) {
        self.mode = mode
        self.entries = entries
    }

    func resetTransferStats() {
        lock.lock()
        downloadAttempts = [:]
        mobileRangeReads = [:]
        legacyFullReads = [:]
        bytesReadByName = [:]
        objectInfoCalls = 0
        lock.unlock()
    }

    func read(_ count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if closed || dropNextRead {
            closed = true
            throw CameraProtocolError.disconnected
        }
        guard count <= buffered.count else {
            closed = true
            throw CameraProtocolError.disconnected
        }
        let slice = Data(buffered.prefix(count))
        buffered.removeFirst(count)
        if buffered.isEmpty { buffered = Data() }
        return slice
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw CameraProtocolError.disconnected }
        var reader = CameraDataReader(data)
        let length = Int(try reader.u32())
        let packetType = try reader.u32()
        guard length == data.count else { throw CameraProtocolError.invalid("Invalid test packet length") }
        if packetType == 14 { return }
        guard packetType == 6 else { throw CameraProtocolError.invalid("Unexpected test request packet \(packetType)") }
        _ = try reader.u32()
        let op = try reader.u16()
        let tid = try reader.u32()
        var params: [UInt32] = []
        while reader.remaining >= 4 { params.append(try reader.u32()) }
        try respond(op: op, tid: tid, params: params)
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    private func appendResponse(_ tid: UInt32, code: UInt16 = 0x2001, data: Data? = nil) {
        if let data {
            var start = Data(); start.appendLE(tid); start.appendLE(UInt64(data.count))
            var end = Data(); end.appendLE(tid); end.append(data)
            buffered.append(CameraWire.packet(9, start))
            buffered.append(CameraWire.packet(12, end))
        }
        var status = Data(); status.appendLE(code); status.appendLE(tid)
        buffered.append(CameraWire.packet(7, status))
    }

    private static func ptpString(_ string: String) -> Data {
        var bytes = Data([UInt8(string.utf16.count + 1)])
        bytes.append((string + "\0").data(using: .utf16LittleEndian)!)
        return bytes
    }

    private func deviceDataset() -> Data {
        var device = Data()
        device.appendLE(UInt16(100)); device.appendLE(UInt32(17)); device.appendLE(UInt16(100))
        device.append(Self.ptpString("Sony")); device.appendLE(UInt16(0))
        let operations: [UInt16] = mode == .mobile
            ? [0x1001, 0x1002, 0x923c, 0x923d]
            : [0x1001, 0x1002, 0x9201, 0x9202, 0x9209, 0x9212, 0x1004, 0x1007, 0x1008, 0x1009]
        device.appendLE(UInt32(operations.count))
        operations.forEach { device.appendLE($0) }
        for _ in 0..<4 { device.appendLE(UInt32(0)) }
        for value in ["Sony Corporation", "ILCE-6700", "2.00", "FAKE-SERIAL-01"] {
            device.append(Self.ptpString(value))
        }
        return device
    }

    private func mobilePage(after cursor: UInt64, maxItems: Int) -> Data {
        let remaining = entries.filter { $0.createdMillis > cursor }
        let slice = Array(remaining.prefix(maxItems))
        var out = Data(repeating: 0, count: 144)
        out.appendLE(UInt32(slice.count))
        for (index, item) in slice.enumerated() {
            out.appendLE(UInt32(index + 1))
            out.appendLE(item.content)
            out.append(Data(repeating: 0, count: 20))
            out.appendLE(item.createdMillis)
            out.append(Data(repeating: 0, count: 36))
            out.appendLE(UInt32(0))
            out.appendLE(UInt32(1))
            out.appendLE(item.file)
            let path = Data(("A:/DCIM/100MSDCF/" + item.name).utf8) + Data([0])
            out.appendLE(UInt32(path.count))
            out.append(path)
            out.appendLE(UInt32(0xb101))
            out.appendLE(UInt64(item.bytes.count))
            out.append(Data(repeating: 0, count: 32))
            out.appendLE(UInt32(0))
            out.appendLE(UInt32(0))
            out.appendLE(UInt32(0))
        }
        return out
    }

    private func legacyObjectInfo(_ item: FakeSonyCameraEntry) -> Data {
        var out = Data()
        out.appendLE(UInt32(0x10001))
        out.appendLE(UInt16(item.name.lowercased().hasSuffix(".arw") ? 0xb101 : 0x3801))
        out.appendLE(UInt16(0))
        out.appendLE(UInt32(item.bytes.count))
        out.append(Data(repeating: 0, count: 40))
        out.append(Self.ptpString(item.name))
        out.append(Self.ptpString(item.legacyCreated))
        out.append(Self.ptpString(""))
        out.append(Self.ptpString(""))
        return out
    }

    private func respond(op: UInt16, tid: UInt32, params: [UInt32]) throws {
        switch op {
        case 0x1001:
            appendResponse(tid, data: deviceDataset())
        case 0x1002, 0x9201, 0x9212:
            appendResponse(tid)
        case 0x9202:
            var descriptor = Data()
            descriptor.appendLE(UInt16(0x12c))
            descriptor.appendLE(UInt32(1)); descriptor.appendLE(UInt16(0x5013))
            descriptor.appendLE(UInt32(0))
            appendResponse(tid, data: descriptor)
        case 0x9209:
            var props = Data(); props.appendLE(UInt64(0))
            appendResponse(tid, data: props)
        case 0x1004:
            var storages = Data(); storages.appendLE(UInt32(1)); storages.appendLE(UInt32(0x10001))
            appendResponse(tid, data: storages)
        case 0x1007:
            let total = legacyHandleCountOverride ?? entries.count
            var handles = Data(); handles.appendLE(UInt32(total))
            if let overrideCount = legacyHandleCountOverride {
                for index in 0..<overrideCount { handles.appendLE(UInt32(index + 1)) }
            } else {
                for entry in entries { handles.appendLE(entry.content) }
            }
            appendResponse(tid, data: handles)
        case 0x1008:
            objectInfoCalls += 1
            guard let handle = params.first, let entry = entries.first(where: { $0.content == handle }) else {
                appendResponse(tid, code: 0x2009)
                return
            }
            appendResponse(tid, data: legacyObjectInfo(entry))
        case 0x923c:
            let low = UInt64(params.count > 0 ? params[0] : 0)
            let high = UInt64(params.count > 1 ? params[1] : 0)
            let maxCount = Int(params.count > 2 ? params[2] : 100)
            appendResponse(tid, data: mobilePage(after: low | (high << 32), maxItems: maxCount))
        case 0x923d, 0x1009:
            let content = params[0]
            let file = op == 0x923d ? (params[1] & 0xffff) : 1
            guard let entry = entries.first(where: { $0.content == content && (op == 0x1009 || $0.file == file) }) else {
                appendResponse(tid, code: 0x2009)
                return
            }
            downloadAttempts[entry.name, default: 0] += 1
            if entry.dropConnectionOnDownload {
                dropNextRead = true
                return
            }
            if let code = entry.downloadResponseCode {
                appendResponse(tid, code: code)
                return
            }
            if op == 0x923d {
                let offset = Int(UInt64(params[2]) | (UInt64(params[3]) << 32))
                let length = Int(params[4])
                let end = min(entry.bytes.count, offset + length)
                let slice = entry.bytes.subdata(in: offset..<end)
                mobileRangeReads[entry.name, default: []].append(offset..<end)
                bytesReadByName[entry.name, default: 0] += slice.count
                appendResponse(tid, data: slice)
            } else {
                legacyFullReads[entry.name, default: 0] += 1
                bytesReadByName[entry.name, default: 0] += entry.bytes.count
                appendResponse(tid, data: entry.bytes)
            }
        default:
            appendResponse(tid, code: 0x2005)
        }
    }
}

@main struct CameraSkipAndLimitTests {
    static let fakeCameraPrefsKey = "camera.incremental.preferences.Sony Corporation|ILCE-6700|FAKE-SERIAL-01"

    static func check(_ condition: Bool, _ message: String, line: Int = #line) throws {
        guard condition else {
            throw CameraProtocolError.invalid("Line \(line): \(message)")
        }
        print("PASS: \(message)")
    }

    @MainActor static func waitUntil(timeout: TimeInterval = 5, line: Int = #line, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CameraProtocolError.invalid("Line \(line): Timed out waiting for condition")
    }

    static func validRAWBytes(_ tag: UInt8) -> Data {
        Data([0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, tag])
    }

    static func makeLargeRAW(size: Int, seed: UInt8) -> Data {
        precondition(size >= 16)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ptr[0] = 0x49; ptr[1] = 0x49; ptr[2] = 0x2a; ptr[3] = 0x00
            ptr[4] = 0x08; ptr[5] = 0x00; ptr[6] = 0x00; ptr[7] = seed
            for index in stride(from: 8, to: size, by: 4096) {
                let block = UInt32(index / 4096) ^ (UInt32(seed) << 16)
                ptr[index] = UInt8(truncatingIfNeeded: block)
                if index + 1 < size { ptr[index + 1] = UInt8(truncatingIfNeeded: block >> 8) }
                if index + 2 < size { ptr[index + 2] = UInt8(truncatingIfNeeded: block >> 16) }
                if index + 3 < size { ptr[index + 3] = UInt8(truncatingIfNeeded: block ^ 0xa5) }
            }
            ptr[size - 1] = seed ^ 0x5a
        }
        return data
    }

    static func makeLargeJPEG(targetSize: Int, seed: UInt8) throws -> Data {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = UInt8(truncatingIfNeeded: i &+ Int(seed))
            pixels[i * 4 + 1] = UInt8(truncatingIfNeeded: (i * 3) ^ Int(seed))
            pixels[i * 4 + 2] = UInt8(truncatingIfNeeded: (i * 7) &+ 19)
            pixels[i * 4 + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = ctx.makeImage() else {
            throw CameraProtocolError.invalid("Failed to build test CGImage")
        }
        let encoded = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else {
            throw CameraProtocolError.invalid("Failed to build test JPEG destination")
        }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CameraProtocolError.invalid("Failed to finalize test JPEG")
        }
        let base = encoded as Data
        guard base.count < targetSize else { return base }
        // Insert valid JPEG COM (0xFFFE) segments immediately after SOI (0xFFD8) to reach exact targetSize.
        var out = Data(capacity: targetSize)
        out.append(base.prefix(2))
        var remaining = targetSize - base.count
        while remaining >= 4 {
            let maxPayload = remaining - 4 == 1 || remaining - 4 == 2 || remaining - 4 == 3
                ? remaining - 8 : min(32_768, remaining - 4)
            let payloadCount = max(0, maxPayload)
            let segLen = UInt16(payloadCount + 2)
            out.append(contentsOf: [0xff, 0xfe, UInt8(segLen >> 8), UInt8(segLen & 0xff)])
            if payloadCount > 0 {
                out.append(Data(repeating: seed ^ 0x33, count: payloadCount))
            }
            remaining -= (4 + payloadCount)
            if remaining > 0 && remaining < 4 { break }
        }
        out.append(base.dropFirst(2))
        if out.count < targetSize {
            out.append(Data(repeating: 0, count: targetSize - out.count))
        }
        return out
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func invalidRAWBytes() -> Data {
        // PNG signature inside an .ARW file: PTP packet size matches, header validation fails.
        Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    }

    static func main() async {
        do {
            try await runAll()
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    @MainActor static func runAll() async throws {
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        try await testI13BadHeaderContinuesAndSkipsWithoutAdvancingCheckpointPastBadItem()
        try await testI13PerObjectPTPErrorContinuesWhileConnectionErrorsAbort()
        try await testI15PhotoLimitExceededOnMobileAndLegacyKeepsConnectionUsable()
        try await testI14ReconnectDefaultCutoffAndOneTapSamplingSkipsFullDownload()
        try await testI14SamplingNegativeSafetyMiddleAndTailSingleByteTamperFallsBack()
        try await testI14SamplingFallbackWhenMissingChangedAdjustedJPEGOrLegacy()
        try await testI14SameSessionRAWToRAWIncrementalBehaviorUnchanged()
    }

    @MainActor static func testI13BadHeaderContinuesAndSkipsWithoutAdvancingCheckpointPastBadItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i13-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let baseMillis = UInt64(Date().timeIntervalSince1970 * 1000) + 10_000
        let entries = [
            FakeSonyCameraEntry(content: 1, name: "DSC00001.ARW", createdMillis: baseMillis + 1_000, bytes: validRAWBytes(1)),
            FakeSonyCameraEntry(content: 2, name: "DSC00002.ARW", createdMillis: baseMillis + 2_000, bytes: invalidRAWBytes()),
            FakeSonyCameraEntry(content: 3, name: "DSC00003.ARW", createdMillis: baseMillis + 3_000, bytes: validRAWBytes(3)),
            FakeSonyCameraEntry(content: 4, name: "DSC00004.ARW", createdMillis: baseMillis + 4_000, bytes: validRAWBytes(4))
        ]
        let channel = FakeSonyCameraChannel(entries: entries)
        var openedSession: SonyCameraSession?
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
            let session = try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            openedSession = session
            return session
        }
        let controller = IOSCameraController(backend: backend)
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FAKE", label: "Fake")
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 4 }

        let cutoff = Date(timeIntervalSince1970: Double(baseMillis) / 1000)
        let scan1 = controller.incrementalScan(customCutoff: cutoff, includeUndated: false)
        try check(scan1.assets.count == 4, "Initial incremental scan queues all 4 card files")

        controller.startIncremental(scan1)
        try await waitUntil {
            controller.phase == .browsing || (controller.phase == .paused && controller.notice != nil)
        }

        let session = try openedSession ?? { throw CameraProtocolError.invalid("Missing session") }()
        let job = try store.snapshot.jobs.first ?? { throw CameraProtocolError.invalid("Missing incremental job") }()

        // I13 assertions: k=2 failed header check, k+1..N (3, 4) still saved, 1 failed, connection alive.
        try check(job.savedCount == 3 && Set(store.snapshot.originals.map(\.name)) == ["DSC00001.ARW", "DSC00003.ARW", "DSC00004.ARW"],
                  "I13: Subsequent files after the bad 2nd file are persisted and verified")
        try check(job.failedItems.count == 1 && job.pendingItems.isEmpty && !job.complete,
                  "I13: Job saves items 1, 3, 4 and records exactly 1 failed item")
        try check(!session.stopped && !channel.closed && controller.connected && controller.phase == .browsing,
                  "I13: Single bad file keeps camera session and controller connected")
        for original in store.snapshot.originals {
            _ = try store.verifiedURL(original.id)
        }
        try check(controller.notice == "保存 DSC00002.ARW 失败。",
                  "I13: Notice identifies the failed file instead of claiming disconnection")

        // Calling resume again must NOT re-download the failed 2nd file or loop.
        let attemptsBeforeResume = channel.downloadAttempts["DSC00002.ARW"] ?? 0
        try check(attemptsBeforeResume == 1, "I13: Bad file was attempted once during initial import")
        controller.resumeImport(job)
        try await waitUntil { controller.phase == .browsing }
        try check((channel.downloadAttempts["DSC00002.ARW"] ?? 0) == 1 && controller.connected,
                  "I13: Resuming again does not retry the failed file or disconnect")

        // Skip the failed file and verify checkpoint never crosses over item 2.
        controller.skipFailedIncrementalItems(job)
        try await waitUntil { !controller.scanning && controller.displayedIncrementalJob == nil }
        let scanAfterSkip = controller.incrementalScan(customCutoff: nil, includeUndated: false)
        try check(scanAfterSkip.assets.isEmpty, "I13: Skipping bad file excludes it while retaining saved items")

        // Add a newer 5th photo and import it; checkpoint must stay at item 1 (before skipped item 2).
        channel.entries.append(FakeSonyCameraEntry(content: 5, name: "DSC00005.ARW", createdMillis: baseMillis + 5_000, bytes: validRAWBytes(5)))
        controller.refreshImport()
        try await waitUntil { !controller.scanning && controller.assets.count == 5 }
        let scanNew = controller.incrementalScan(customCutoff: nil, includeUndated: false)
        try check(scanNew.assets.map(\.snapshot.name) == ["DSC00005.ARW"],
                  "I13: Subsequent scan picks up only the new 5th file without re-queuing skipped item 2")
        controller.startIncremental(scanNew)
        try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 4 }
        let boundaries = store.snapshot.incrementalBoundaries(device: session.device, connectionKey: endpoint.connectionKey)
        let expectedCheckpoint = Date(timeIntervalSince1970: Double(baseMillis + 1_000) / 1000)
        try check(boundaries["RAW"]?.date == expectedCheckpoint,
                  "I13: Incremental checkpoint stops at item 1 before skipped item 2 rather than jumping to item 5")
        controller.stop()
    }

    @MainActor static func testI13PerObjectPTPErrorContinuesWhileConnectionErrorsAbort() async throws {
        // 1) Per-object PTP error (0x2009 on item 2) continues to item 3 and stays connected.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i13-ptp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let now = UInt64(Date().timeIntervalSince1970 * 1000) + 1_000
            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC00011.ARW", createdMillis: now + 1_000, bytes: validRAWBytes(11)),
                FakeSonyCameraEntry(content: 2, name: "DSC00012.ARW", createdMillis: now + 2_000, bytes: validRAWBytes(12), downloadResponseCode: 0x2009),
                FakeSonyCameraEntry(content: 3, name: "DSC00013.ARW", createdMillis: now + 3_000, bytes: validRAWBytes(13))
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FAKE", label: "Fake"),
                               mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }
            controller.selection = Set(controller.assets.map(\.id))
            controller.importSelected()
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }
            let job = store.snapshot.jobs[0]
            try check(controller.connected && !channel.closed && job.savedCount == 2 && job.failedItems.count == 1,
                      "I13: Per-object PTP response error marks item failed and continues remaining files")
            controller.stop()
        }

        // 2) Connection-level error (TCP disconnect on item 2) MUST abort immediately and disconnect.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i13-drop-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let now = UInt64(Date().timeIntervalSince1970 * 1000) + 1_000
            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC00021.ARW", createdMillis: now + 1_000, bytes: validRAWBytes(21)),
                FakeSonyCameraEntry(content: 2, name: "DSC00022.ARW", createdMillis: now + 2_000, bytes: validRAWBytes(22), dropConnectionOnDownload: true),
                FakeSonyCameraEntry(content: 3, name: "DSC00023.ARW", createdMillis: now + 3_000, bytes: validRAWBytes(23))
            ])
            var openedSession: SonyCameraSession?
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                let s = try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
                openedSession = s
                return s
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FAKE", label: "Fake"),
                               mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }
            controller.selection = Set(controller.assets.map(\.id))
            controller.importSelected()
            try await waitUntil { controller.phase == .paused }
            let job = store.snapshot.jobs[0]
            try check(openedSession?.stopped == true && channel.closed && !controller.connected && controller.phase == .paused,
                      "I13 control: Connection drop interrupts transfer and disconnects session")
            try check((channel.downloadAttempts["DSC00023.ARW"] ?? 0) == 0,
                      "I13 control: Connection drop stops immediately before attempting item k+1")
            try check(job.savedCount == 1 && job.failedItems.isEmpty && job.pendingItems.count == 2 &&
                      job.items[1].phase == .interrupted && job.items[2].phase == .queued,
                      "I13 control: Interrupted connection preserves unfinished items as retryable pending items")
            controller.stop()
        }

        // 3) Session-gone PTP error (0x2003 SessionNotOpen) MUST also abort and disconnect.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i13-sess-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let now = UInt64(Date().timeIntervalSince1970 * 1000) + 1_000
            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC00031.ARW", createdMillis: now + 1_000, bytes: validRAWBytes(31)),
                FakeSonyCameraEntry(content: 2, name: "DSC00032.ARW", createdMillis: now + 2_000, bytes: validRAWBytes(32), downloadResponseCode: 0x2003),
                FakeSonyCameraEntry(content: 3, name: "DSC00033.ARW", createdMillis: now + 3_000, bytes: validRAWBytes(33))
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FAKE", label: "Fake"),
                               mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }
            controller.selection = Set(controller.assets.map(\.id))
            controller.importSelected()
            try await waitUntil { controller.phase == .paused }
            try check(!controller.connected && (channel.downloadAttempts["DSC00033.ARW"] ?? 0) == 0,
                      "I13 control: SessionNotOpen (0x2003) aborts transfer and pauses session")
            controller.stop()
        }
    }

    @MainActor static func testI15PhotoLimitExceededOnMobileAndLegacyKeepsConnectionUsable() async throws {
        // 1) Mobile protocol (0x923c) with 12,000 items: dedicated prompt, NOT "校验未通过", connection stays usable.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i15-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let baseMillis: UInt64 = 1_700_000_000_000
        let sampleBytes = validRAWBytes(99)
        let twelveThousand = (1...12_000).map { index in
            FakeSonyCameraEntry(content: UInt32(index), name: String(format: "DSC%05d.ARW", index),
                                createdMillis: baseMillis + UInt64(index), bytes: sampleBytes)
        }
        let mobileChannel = FakeSonyCameraChannel(mode: .mobile, entries: twelveThousand)
        var mobileSession: SonyCameraSession?
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
            let s = try SonyCameraSession(client: CameraPTPClient(command: mobileChannel, event: nil), purpose: purpose)
            mobileSession = s
            return s
        }
        let controller = IOSCameraController(backend: backend)
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
        controller.connect(endpoint: IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FAKE", label: "Fake"),
                           mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil {
            (controller.phase == .browsing || controller.phase == .paused) && controller.notice != nil
        }

        try check(controller.notice != "相机数据或原件校验未通过，已暂停。" && controller.notice == "照片 · 已到上限",
                  "I15 (mobile): Notice gives dedicated photo-limit message instead of verification failure")
        try check(mobileSession?.stopped == false && !mobileChannel.closed && controller.connected && controller.phase == .browsing,
                  "I15 (mobile): 12,000 card items keeps session open and controller connected in browsing phase")
        try check(controller.listingLimitExceeded,
                  "I15 (mobile): Controller marks listingLimitExceeded when card exceeds 10,000 photos")

        // Verify English localization as well.
        UserDefaults.standard.set("en", forKey: L10n.preferenceKey)
        controller.refreshImport()
        try await waitUntil { !controller.scanning && controller.notice != nil }
        try check(controller.notice == "Photo · Maximum Reached" && controller.connected,
                  "I15 (mobile): English localization resolves dedicated limit prompt and keeps session alive")
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)

        // Prove the existing connection is genuinely usable without reconnecting: trim card to 3 items and refresh.
        mobileChannel.entries = Array(twelveThousand.prefix(3))
        controller.refreshImport()
        try await waitUntil { !controller.scanning && controller.assets.count == 3 }
        try check(!controller.listingLimitExceeded && controller.connected && controller.assets.count == 3,
                  "I15 (mobile): Same open connection lists photos after card count drops below limit")
        controller.selection = [controller.assets[0].id]
        controller.importSelected()
        try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 1 }
        try check(store.snapshot.originals.count == 1,
                  "I15 (mobile): Same open connection imports original after 12,000-item limit recovery")
        controller.stop()

        // 2) Legacy protocol (0x1007) with 12,000 handles: does not break 40,004-byte PTP packet budget or close client.
        let legacyEntries = Array(twelveThousand.prefix(2))
        let legacyChannel = FakeSonyCameraChannel(mode: .legacy, entries: legacyEntries)
        legacyChannel.legacyHandleCountOverride = 12_000
        let legacySession = try SonyCameraSession(client: CameraPTPClient(command: legacyChannel, event: nil), purpose: .importing)
        var hitPhotoLimit = false
        do {
            _ = try legacySession.listAssets()
        } catch CameraProtocolError.photoLimitExceeded {
            hitPhotoLimit = true
        }
        try check(hitPhotoLimit && !legacySession.stopped && !legacyChannel.closed && legacyChannel.objectInfoCalls == 0,
                  "I15 (legacy): 12,000 handles throws photoLimitExceeded before 0x1008 calls and keeps PTP channel aligned")
        legacyChannel.legacyHandleCountOverride = nil
        let recoveredLegacy = try legacySession.listAssets()
        try check(recoveredLegacy.count == 2 && !legacySession.stopped,
                  "I15 (legacy): Same legacy session remains usable after 12,000-handle limit error")
    }

    @MainActor static func testI14ReconnectDefaultCutoffAndOneTapSamplingSkipsFullDownload() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-main-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)

        let midnight = Calendar.current.startOfDay(for: Date())
        let morningMillis = UInt64((midnight.timeIntervalSince1970 + 10 * 3600 + 15 * 60 + 0.125) * 1000)
        // 14:37:48.678 local time — non-midnight with sub-second (.678s) precision.
        let boundaryMillis = UInt64((midnight.timeIntervalSince1970 + 14 * 3600 + 37 * 60 + 48.678) * 1000)
        let afterBoundaryMillis = boundaryMillis + 250 // +250 ms in the exact same second!
        let exactBoundaryDate = Date(timeIntervalSince1970: Double(boundaryMillis) / 1000)

        let raw50MB_A = makeLargeRAW(size: 50_000_000, seed: 0x11)
        let raw50MB_B = makeLargeRAW(size: 50_000_000, seed: 0x22)
        let rawNew1MB = makeLargeRAW(size: 1_048_576, seed: 0x33)
        let fullDigestA = sha256Hex(raw50MB_A)
        let fullDigestB = sha256Hex(raw50MB_B)
        let fullDigestNew = sha256Hex(rawNew1MB)

        // Session 1: import two 50 MB RAWs up to 14:37:48.678.
        var activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
            FakeSonyCameraEntry(content: 1, name: "DSC01001.ARW", createdMillis: morningMillis, bytes: raw50MB_A),
            FakeSonyCameraEntry(content: 2, name: "DSC01002.ARW", createdMillis: boundaryMillis, bytes: raw50MB_B)
        ])
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
            try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
        }
        let controller = IOSCameraController(backend: backend)
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-MAIN", label: "Fake")
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 2 }

        let initialScan = controller.incrementalScan(customCutoff: midnight, includeUndated: false)
        try check(initialScan.assets.count == 2, "I14: Session 1 queues both 50 MB RAW files")
        controller.startIncremental(initialScan)
        try await waitUntil(timeout: 15) { controller.phase == .browsing && store.snapshot.originals.count == 2 }
        try check(activeChannel.bytesReadByName["DSC01002.ARW"] == 50_000_000 &&
                  (activeChannel.downloadAttempts["DSC01002.ARW"] ?? 0) == 16,
                  "I14: Session 1 performs full 50,000,000-byte download (16 x 3 MiB chunks)")
        controller.stop()

        // Session 2: Disconnect & reconnect (new SonyCameraSession UUID + reassigned PTP content handles + new +250ms shot).
        activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
            FakeSonyCameraEntry(content: 101, name: "DSC01001.ARW", createdMillis: morningMillis, bytes: raw50MB_A),
            FakeSonyCameraEntry(content: 102, name: "DSC01002.ARW", createdMillis: boundaryMillis, bytes: raw50MB_B),
            FakeSonyCameraEntry(content: 103, name: "DSC01003.ARW", createdMillis: afterBoundaryMillis, bytes: rawNew1MB)
        ])
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }

        // Requirement 1: Default cutoff after reconnect equals exact previous boundary timestamp (NOT midnight) and still requires confirmation.
        let unconfirmedScan = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: controller.includeUndated)
        try check(unconfirmedScan.needsCutoffConfirmation && unconfirmedScan.assets.isEmpty,
                  "I14 (1): Reconnect preserves security gate requiring user confirmation before queuing files")
        try check(unconfirmedScan.start == exactBoundaryDate && unconfirmedScan.start != midnight,
                  "I14 (1): Reconnect default start equals exact previous boundary timestamp (including .678 ms), not midnight")

        // Requirement 2: One-tap confirmSuggestedCutoff() preserves millisecond precision and 3-segment samples already-saved 50 MB RAW.
        controller.confirmSuggestedCutoff()
        try check(controller.customCutoff == exactBoundaryDate,
                  "I14 (2): One-tap confirmSuggestedCutoff() applies exact millisecond boundary Date")
        let confirmedScan = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: controller.includeUndated)
        try check(!confirmedScan.needsCutoffConfirmation &&
                  confirmedScan.assets.map(\.snapshot.name) == ["DSC01002.ARW", "DSC01003.ARW"],
                  "I14 (2): Confirmed scan excludes earlier DSC01001.ARW and includes boundary DSC01002.ARW + +250ms DSC01003.ARW")

        controller.startIncremental(confirmedScan)
        try await waitUntil(timeout: 15) { controller.phase == .browsing && store.snapshot.originals.count == 3 }

        let expectedRanges: [Range<Int>] = [
            0..<65_536,
            24_967_232..<25_032_768,
            49_934_464..<50_000_000
        ]
        try check((activeChannel.downloadAttempts["DSC01001.ARW"] ?? 0) == 0 &&
                  (activeChannel.bytesReadByName["DSC01001.ARW"] ?? 0) == 0,
                  "I14 (2): Photo before confirmed boundary timestamp incurs 0 PTP reads and 0 bytes")
        try check(activeChannel.downloadAttempts["DSC01002.ARW"] == 3 &&
                  activeChannel.mobileRangeReads["DSC01002.ARW"] == expectedRanges &&
                  activeChannel.bytesReadByName["DSC01002.ARW"] == 196_608,
                  "I14 (2): Already-imported 50 MB RAW reads only head/middle/tail 3 x 64 KiB (196,608 B, skipping 49,803,392 B)")
        try check(activeChannel.bytesReadByName["DSC01003.ARW"] == 1_048_576,
                  "I14 (2): Newly shot +250ms RAW is downloaded in full")

        let job2 = try store.snapshot.jobs.last ?? { throw CameraProtocolError.invalid("Missing Session 2 job") }()
        let sampledItem = try job2.items.first(where: { $0.asset.name == "DSC01002.ARW" })
            ?? { throw CameraProtocolError.invalid("Missing sampled item") }()
        try check(sampledItem.phase == .saved && sampledItem.reused == true && sampledItem.digest == fullDigestB,
                  "I14 (2): Sampled item is marked saved+reused and retains full-file SHA-256 (never sample hash)")
        try check(store.snapshot.originals.count == 3 &&
                  Set(store.snapshot.originals.map(\.digest)) == [fullDigestA, fullDigestB, fullDigestNew],
                  "I14 (2): Originals manifest retains exact 3 verified full-file entries without duplication")
        try check(controller.customCutoff == nil,
                  "I14 (2): Controller resets customCutoff after incremental job completes")
        controller.stop()

        // Also verify manual earlier cutoff selection (e.g. midnight) still works and 3-segment samples all 3 existing RAWs.
        activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
            FakeSonyCameraEntry(content: 201, name: "DSC01001.ARW", createdMillis: morningMillis, bytes: raw50MB_A),
            FakeSonyCameraEntry(content: 202, name: "DSC01002.ARW", createdMillis: boundaryMillis, bytes: raw50MB_B),
            FakeSonyCameraEntry(content: 203, name: "DSC01003.ARW", createdMillis: afterBoundaryMillis, bytes: rawNew1MB)
        ])
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }
        controller.customCutoff = midnight
        let manualScan = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
        try check(!manualScan.needsCutoffConfirmation && manualScan.assets.count == 3,
                  "I14 (2): Manual cutoff selection remains functional after reconnect")
        controller.startIncremental(manualScan)
        try await waitUntil(timeout: 10) { controller.phase == .browsing && store.snapshot.jobs.count == 3 && store.snapshot.jobs.last?.complete == true }
        try check(activeChannel.bytesReadByName["DSC01001.ARW"] == 196_608 &&
                  activeChannel.bytesReadByName["DSC01002.ARW"] == 196_608 &&
                  activeChannel.bytesReadByName["DSC01003.ARW"] == 196_608 &&
                  store.snapshot.originals.count == 3,
                  "I14 (2): Manual midnight cutoff samples all three previously imported RAWs (196,608 B each, 0 full downloads)")
        controller.stop()
    }

    @MainActor static func testI14SamplingNegativeSafetyMiddleAndTailSingleByteTamperFallsBack() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let size = 1_048_576 // 1 MiB (>= 3 * 64 KiB)
        let middleOffset = (size - 65_536) / 2 + 1_234
        let tailOffset = size - 1

        for (label, tamperOffset, expectedSampleReadsBeforeMismatch) in [
            ("middle", middleOffset, 2),
            ("tail", tailOffset, 3)
        ] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-tamper-\(label)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let captureMillis = UInt64(Date().timeIntervalSince1970 * 1000) - 60_000
            let originalBytes = makeLargeRAW(size: size, seed: 0x44)
            var tamperedBytes = originalBytes
            tamperedBytes[tamperOffset] ^= 0xff
            let originalDigest = sha256Hex(originalBytes)
            let tamperedDigest = sha256Hex(tamperedBytes)

            var activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC02001.ARW", createdMillis: captureMillis, bytes: originalBytes)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-TAMPER-\(label)", label: "Fake")
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            let scan1 = controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: Double(captureMillis) / 1000 - 1), includeUndated: false)
            controller.startIncremental(scan1)
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 1 }
            controller.stop()

            // Reconnect with same (kind, name, size, captureDate), but 1 byte tampered in middle or tail!
            activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 9, name: "DSC02001.ARW", createdMillis: captureMillis, bytes: tamperedBytes)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.confirmSuggestedCutoff()
            let scan2 = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
            controller.startIncremental(scan2)
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }

            let job2 = store.snapshot.jobs[1]
            let item2 = job2.items[0]
            try check(activeChannel.downloadAttempts["DSC02001.ARW"] == expectedSampleReadsBeforeMismatch + 1 &&
                      activeChannel.bytesReadByName["DSC02001.ARW"] == expectedSampleReadsBeforeMismatch * 65_536 + size,
                      "I14 (3-\(label)): 1-byte \(label) tamper aborts sampling at segment \(expectedSampleReadsBeforeMismatch) and falls back to full download")
            try check(item2.phase == .saved && item2.reused != true && item2.digest == tamperedDigest,
                      "I14 (3-\(label)): Tampered file is never mis-skipped; saves new original with full SHA-256")
            try check(Set(store.snapshot.originals.map(\.digest)) == [originalDigest, tamperedDigest],
                      "I14 (3-\(label)): Both original and newly downloaded tampered version exist intact in store")
            for orig in store.snapshot.originals {
                _ = try store.verifiedURL(orig.id)
            }
            controller.stop()
        }
    }

    @MainActor static func testI14SamplingFallbackWhenMissingChangedAdjustedJPEGOrLegacy() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let rawBytes = makeLargeRAW(size: 524_288, seed: 0x55)
        let captureMillis = UInt64(Date().timeIntervalSince1970 * 1000) - 120_000

        // 4a) Local original missing on disk -> falls back to full download.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-missing-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            var activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC03001.ARW", createdMillis: captureMillis, bytes: rawBytes)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-MISSING", label: "Fake")
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: 0), includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 1 }
            let savedURL = try store.verifiedURL(store.snapshot.originals[0].id)
            try FileManager.default.removeItem(at: savedURL)
            controller.stop()

            activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 2, name: "DSC03001.ARW", createdMillis: captureMillis, bytes: rawBytes)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.confirmSuggestedCutoff()
            controller.startIncremental(controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }
            try check(activeChannel.mobileRangeReads["DSC03001.ARW"] == [0..<524_288] &&
                      activeChannel.bytesReadByName["DSC03001.ARW"] == 524_288,
                      "I14 (4a): Missing local original skips sampling and performs full download")
            _ = try store.verifiedURL(store.snapshot.originals.last!.id)
            controller.stop()
        }

        // 4b) Local original corrupted/unavailable on disk (outside the 3 sample windows!) -> falls back to full download.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-changed-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            var activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC03002.ARW", createdMillis: captureMillis, bytes: rawBytes)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-CHANGED", label: "Fake")
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: 0), includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 1 }
            let savedURL = try store.verifiedURL(store.snapshot.originals[0].id)
            var corruptedLocal = try Data(contentsOf: savedURL)
            corruptedLocal[100_000] ^= 0xff // Outside [0..<65536], [229376..<294912], [458752..<524288]!
            try corruptedLocal.write(to: savedURL)
            controller.stop()

            activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 2, name: "DSC03002.ARW", createdMillis: captureMillis, bytes: rawBytes)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.confirmSuggestedCutoff()
            controller.startIncremental(controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }
            try check(activeChannel.mobileRangeReads["DSC03002.ARW"] == [0..<524_288] &&
                      activeChannel.bytesReadByName["DSC03002.ARW"] == 524_288 &&
                      store.snapshot.originals[0].availability == .changed,
                      "I14 (4b): Corrupted local original (availability != .available) skips sampling and re-downloads full file")
            _ = try store.verifiedURL(store.snapshot.originals.last!.id)
            controller.stop()
        }

        // 4c) Re-encoded JPEG (jpegSource != nil) -> falls back to full download both with adjust=true and adjust=false.
        do {
            defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-jpeg-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let jpegBytes = try makeLargeJPEG(targetSize: 300_000, seed: 0x66)
            var activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC03003.JPG", createdMillis: captureMillis, bytes: jpegBytes)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-JPEG", label: "Fake")
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.setJPEGOptions(CameraJPEGOptions(adjust: true, longEdge: 1600, quality: 80))
            controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: 0), includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 1 }
            try check(store.snapshot.originals[0].jpegSource != nil,
                      "I14 (4c): Initial adjusted JPEG import stores re-encoded copy with jpegSource != nil")
            controller.stop()

            // Reconnect with adjust == true: must NOT sample re-encoded JPEG bytes; must download full 300,000 B.
            activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 2, name: "DSC03003.JPG", createdMillis: captureMillis, bytes: jpegBytes)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.confirmSuggestedCutoff()
            controller.startIncremental(controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.jobs.count == 2 && store.snapshot.jobs.last?.complete == true }
            try check(activeChannel.mobileRangeReads["DSC03003.JPG"] == [0..<300_000] &&
                      activeChannel.bytesReadByName["DSC03003.JPG"] == 300_000,
                      "I14 (4c): Adjusted JPEG (adjust=true, jpegSource != nil) falls back to full download")
            controller.stop()

            // Reconnect and switch adjust = false while local copy has jpegSource != nil: must ALSO download full 300,000 B.
            activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 3, name: "DSC03003.JPG", createdMillis: captureMillis, bytes: jpegBytes)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.setJPEGOptions(CameraJPEGOptions(adjust: false))
            controller.confirmSuggestedCutoff()
            controller.startIncremental(controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }
            try check(activeChannel.mobileRangeReads["DSC03003.JPG"] == [0..<300_000] &&
                      store.snapshot.originals.last?.jpegSource == nil,
                      "I14 (4c): Switching to unadjusted JPEG when only jpegSource != nil exists downloads full camera JPEG")
            controller.stop()
        }

        // 4d) .legacy session (0x1009 stream only) -> default cutoff uses exact timestamp, download uses full 0x1009 stream (0 sampling).
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-legacy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let legacyCreated = "20261113T142345"
            let expectedLegacyDate = try CameraAssetSnapshot(
                content: 1, file: 0, storage: 0x10001, format: 0xb101,
                name: "DSC03004.ARW", size: UInt64(rawBytes.count), created: legacyCreated, modified: ""
            ).captureDate ?? { throw CameraProtocolError.invalid("Failed to parse legacy date") }()

            var activeChannel = FakeSonyCameraChannel(mode: .legacy, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC03004.ARW", createdMillis: captureMillis,
                                    bytes: rawBytes, legacyCreated: legacyCreated)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-LEGACY", label: "Fake")
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil(timeout: 12) { controller.phase == .browsing && controller.assets.count == 1 }
            controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: 0), includeUndated: false))
            try await waitUntil(timeout: 10) { controller.phase == .browsing && store.snapshot.originals.count == 1 }
            controller.stop()

            activeChannel = FakeSonyCameraChannel(mode: .legacy, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC03004.ARW", createdMillis: captureMillis,
                                    bytes: rawBytes, legacyCreated: legacyCreated)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil(timeout: 12) { controller.phase == .browsing && controller.assets.count == 1 }
            let reconnectLegacyScan = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
            try check(reconnectLegacyScan.needsCutoffConfirmation && reconnectLegacyScan.start == expectedLegacyDate,
                      "I14 (4d): Legacy reconnect keeps confirmation gate and defaults start to exact 14:23:45 camera time")
            controller.confirmSuggestedCutoff()
            controller.startIncremental(controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false))
            try await waitUntil(timeout: 10) { controller.phase == .browsing && store.snapshot.jobs.count == 2 && store.snapshot.jobs.last?.complete == true }
            try check(activeChannel.mobileRangeReads["DSC03004.ARW"] == nil &&
                      activeChannel.legacyFullReads["DSC03004.ARW"] == 1 &&
                      activeChannel.bytesReadByName["DSC03004.ARW"] == 524_288,
                      "I14 (4d): Legacy session never issues 0x923d range reads and falls back to full 0x1009 stream")
            controller.stop()
        }
    }

    @MainActor static func testI14SameSessionRAWToRAWIncrementalBehaviorUnchanged() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-raw2raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let baseMillis = UInt64(Date().timeIntervalSince1970 * 1000) + 5_000
        let raw1 = makeLargeRAW(size: 262_144, seed: 0x71)
        let raw2 = makeLargeRAW(size: 262_144, seed: 0x72)
        let raw3 = makeLargeRAW(size: 262_144, seed: 0x73)
        let raw4 = makeLargeRAW(size: 262_144, seed: 0x74)
        let jpgDummy = try makeLargeJPEG(targetSize: 16_384, seed: 0x75)

        let channel = FakeSonyCameraChannel(mode: .mobile, entries: [
            FakeSonyCameraEntry(content: 1, file: 1, name: "DSC04001.ARW", createdMillis: baseMillis + 1_000, bytes: raw1),
            FakeSonyCameraEntry(content: 1, file: 2, name: "DSC04001.JPG", createdMillis: baseMillis + 1_000, bytes: jpgDummy),
            FakeSonyCameraEntry(content: 2, file: 1, name: "DSC04002.ARW", createdMillis: baseMillis + 2_000, bytes: raw2),
            FakeSonyCameraEntry(content: 2, file: 2, name: "DSC04002.JPG", createdMillis: baseMillis + 2_000, bytes: jpgDummy)
        ])
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
            try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
        }
        let controller = IOSCameraController(backend: backend)
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-RAW2RAW", label: "Fake")
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 4 }
        controller.setImportFormat(.raw)

        let scan1 = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
        try check(!scan1.needsCutoffConfirmation && scan1.assets.map(\.snapshot.name) == ["DSC04001.ARW", "DSC04002.ARW"],
                  "I14 (5): Initial RAW-only scan selects only RAW files without confirmation gate")
        controller.startIncremental(scan1)
        try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }

        // Shoot 2 more RAW+JPEG pairs in the SAME session (one at exact boundary timestamp +2000ms, one at +3000ms).
        channel.resetTransferStats()
        channel.entries.append(contentsOf: [
            FakeSonyCameraEntry(content: 3, file: 1, name: "DSC04003.ARW", createdMillis: baseMillis + 2_000, bytes: raw3),
            FakeSonyCameraEntry(content: 3, file: 2, name: "DSC04003.JPG", createdMillis: baseMillis + 2_000, bytes: jpgDummy),
            FakeSonyCameraEntry(content: 4, file: 1, name: "DSC04004.ARW", createdMillis: baseMillis + 3_000, bytes: raw4),
            FakeSonyCameraEntry(content: 4, file: 2, name: "DSC04004.JPG", createdMillis: baseMillis + 3_000, bytes: jpgDummy)
        ])
        controller.refreshImport()
        try await waitUntil { !controller.scanning && controller.assets.count == 8 }

        let scan2 = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
        try check(!scan2.needsCutoffConfirmation && scan2.assets.map(\.snapshot.name) == ["DSC04003.ARW", "DSC04004.ARW"],
                  "I14 (5): Same-session RAW->RAW refresh auto-confirms boundary and queues only unseen RAWs")
        controller.startIncremental(scan2)
        try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 4 }
        try check((channel.downloadAttempts["DSC04001.ARW"] ?? 0) == 0 &&
                  (channel.downloadAttempts["DSC04002.ARW"] ?? 0) == 0 &&
                  channel.bytesReadByName["DSC04003.ARW"] == 262_144 &&
                  channel.bytesReadByName["DSC04004.ARW"] == 262_144,
                  "I14 (5): Same-session RAW->RAW performs zero reads on prior RAWs and downloads only new RAWs")

        let scan3 = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
        try check(!scan3.needsCutoffConfirmation && scan3.assets.isEmpty,
                  "I14 (5): Subsequent scan in same session reports no new photos")
        controller.stop()
    }
}
