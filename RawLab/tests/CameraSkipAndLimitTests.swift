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
    var bytes: Data
    var downloadResponseCode: UInt16?
    var dropConnectionOnDownload = false

    init(content: UInt32, file: UInt32 = 1, name: String, createdMillis: UInt64, bytes: Data,
         downloadResponseCode: UInt16? = nil, dropConnectionOnDownload: Bool = false) {
        self.content = content
        self.file = file
        self.name = name
        self.createdMillis = createdMillis
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
    private(set) var objectInfoCalls = 0
    private var dropNextRead = false

    init(mode: Mode = .mobile, entries: [FakeSonyCameraEntry]) {
        self.mode = mode
        self.entries = entries
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
        out.appendLE(UInt16(0x3801))
        out.appendLE(UInt16(0))
        out.appendLE(UInt32(item.bytes.count))
        out.append(Data(repeating: 0, count: 40))
        out.append(Self.ptpString(item.name))
        out.append(Self.ptpString("20261113T100000"))
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
                appendResponse(tid, data: entry.bytes.subdata(in: offset..<end))
            } else {
                appendResponse(tid, data: entry.bytes)
            }
        default:
            appendResponse(tid, code: 0x2005)
        }
    }
}

@main struct CameraSkipAndLimitTests {
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
        try await testI13BadHeaderContinuesAndSkipsWithoutAdvancingCheckpointPastBadItem()
        try await testI13PerObjectPTPErrorContinuesWhileConnectionErrorsAbort()
        try await testI15PhotoLimitExceededOnMobileAndLegacyKeepsConnectionUsable()
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
}
