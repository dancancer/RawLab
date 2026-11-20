import Foundation

@main struct CameraProtocolTests {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw CameraProtocolError.invalid(message) }
        print("PASS: \(message)")
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { print("PASS: \(message)"); return }
        throw CameraProtocolError.invalid(message)
    }
    static func transactionResponse(_ tid: UInt32, code: UInt16 = 0x2001, data: Data? = nil) -> Data {
        var output = Data()
        if let data {
            var start = Data(); start.appendLE(tid); start.appendLE(UInt64(data.count))
            var end = Data(); end.appendLE(tid); end.append(data)
            output.append(CameraWire.packet(9, start)); output.append(CameraWire.packet(12, end))
        }
        var status = Data(); status.appendLE(code); status.appendLE(tid)
        output.append(CameraWire.packet(7, status)); return output
    }
    static func ptpString(_ string: String) -> Data {
        var bytes = Data([UInt8(string.utf16.count + 1)])
        bytes.append((string + "\0").data(using: .utf16LittleEndian)!); return bytes
    }
    static func remoteInitialization(drive: UInt16) -> Data {
        var device = Data()
        device.appendLE(UInt16(100)); device.appendLE(UInt32(17)); device.appendLE(UInt16(100))
        device.append(0); device.appendLE(UInt16(0))
        let operations: [UInt16] = [0x1001, 0x1002, 0x9201, 0x9202, 0x9205, 0x9207, 0x9209, 0x923c, 0x923d]
        device.appendLE(UInt32(operations.count)); operations.forEach { device.appendLE($0) }
        for _ in 0..<4 { device.appendLE(UInt32(0)) }
        for value in ["Sony", "Other Sony Model", "9.99", "fixture"] { device.append(ptpString(value)) }
        var extended = Data(); extended.appendLE(UInt16(0x12c)); extended.appendLE(UInt32(1)); extended.appendLE(UInt16(0x5013))
        extended.appendLE(UInt32(2)); extended.appendLE(UInt16(0xd2c1)); extended.appendLE(UInt16(0xd2c2))
        var properties = Data(); properties.appendLE(UInt64(1)); properties.appendLE(UInt16(0x5013))
        properties.appendLE(UInt16(4)); properties.append(contentsOf: [0, 1]); properties.appendLE(UInt16(1)); properties.appendLE(drive); properties.append(0)
        return transactionResponse(1, data: device) + transactionResponse(0) + transactionResponse(1) + transactionResponse(2) + transactionResponse(3, data: extended) + transactionResponse(4) + transactionResponse(5, data: properties)
    }
    static func operationCodes(_ channel: ScriptedCameraChannel) throws -> [UInt16] {
        try channel.sent.compactMap { packet in
            var reader = CameraDataReader(packet)
            _ = try reader.u32()
            guard try reader.u32() == 6 else { return nil }
            _ = try reader.u32()
            return try reader.u16()
        }
    }
    static func main() throws {
        var reader = CameraDataReader(Data([0x34, 0x12, 0xff, 0xff, 0xff, 0xff]))
        try check(try reader.u16() == 0x1234 && reader.u32() == UInt32.max, "Unaligned little-endian values")
        try rejects("Truncated scalar is rejected") { _ = try reader.u8() }
        var credentials = Data([10, 0, 0]); credentials.append("DIRECT-X".data(using: .ascii)!)
        try check(try CameraWire.wifiCredential(credentials, password: false) == "DIRECT-X", "BLE credentials use the framed ASCII value")
        try rejects("Credential length mismatch is rejected") { _ = try CameraWire.wifiCredential(Data([2, 0, 0, 65]), password: false) }
        var page = Data(repeating: 0, count: 144); page.appendLE(UInt32(101))
        try rejects("Oversized mobile page is rejected before allocation") { _ = try CameraWire.mobilePage(page, owner: UUID()) }
        var properties = Data(); properties.appendLE(UInt64(1)); properties.appendLE(UInt16(0x5010)); properties.appendLE(UInt16(3))
        properties.append(contentsOf: [1, 1]); properties.appendLE(Int16(0)); properties.appendLE(Int16(-1000)); properties.append(2)
        properties.appendLE(UInt16(2)); properties.appendLE(Int16(-1000)); properties.appendLE(Int16(1000)); properties.appendLE(UInt16(0))
        let parsed = try CameraWire.properties(properties, enumTables: 2)
        try check(parsed[0x5010]?.number == -1000 && parsed[0x5010]?.accepts(1000) == true && parsed[0x5010]?.accepts(0) == false,
                  "Signed EV and descriptor-only choices")
        try rejects("Trailing property bytes are rejected") { _ = try CameraWire.properties(properties + Data([0]), enumTables: 2) }
        try check(try CameraWire.liveURL("http://localhost:8080/liveviewstream?k=secret", camera: "192.168.1.2").host == "192.168.1.2", "Live view is pinned to the camera endpoint")
        try rejects("Foreign live-view endpoint is rejected") { _ = try CameraWire.liveURL("http://example.com:8080/liveviewstream", camera: "192.168.1.2") }
        try rejects("Overlapping live-view frame regions are rejected") { _ = try CameraWire.liveFrameBounds([16, 100, 20, 10]) }
        var response = Data(); response.appendLE(UInt16(0x2001)); response.appendLE(UInt32(1))
        var start = Data(); start.appendLE(UInt32(1)); start.appendLE(UInt64(3))
        var end = Data(); end.appendLE(UInt32(1)); end.append(contentsOf: [1, 2, 3])
        let channel = ScriptedCameraChannel(CameraWire.packet(13, Data()) + CameraWire.packet(9, start) + CameraWire.packet(12, end) + CameraWire.packet(7, response))
        let client = CameraPTPClient(command: channel, event: nil)
        try check(try client.operation(0x1001, requiresData: true, limit: 4) == Data([1, 2, 3]), "Transaction receives data through final response and answers ping")
        try check(channel.sent.contains(CameraWire.packet(14, Data())), "Ping response is written")
        response = Data(); response.appendLE(UInt16(0x2005)); response.appendLE(UInt32(1))
        let rejected = ScriptedCameraChannel(CameraWire.packet(7, response))
        try rejects("Complete remote rejection is reported") { _ = try CameraPTPClient(command: rejected, event: nil).operation(0x1001, requiresData: true, limit: 4) }
        try check(!rejected.closed, "Aligned remote rejection does not destroy the stream")
        start = Data(); start.appendLE(UInt32(99)); start.appendLE(UInt64(1))
        let wrong = ScriptedCameraChannel(CameraWire.packet(9, start))
        try rejects("Wrong transaction closes the owner") { _ = try CameraPTPClient(command: wrong, event: nil).operation(0x1001, requiresData: true, limit: 4) }
        try check(wrong.closed, "Malformed framing cannot be reused")
        let objectBytes = Data(repeating: 0x5a, count: 1 << 20)
        let streaming = ScriptedCameraChannel(transactionResponse(1, data: objectBytes))
        var received = 0
        try CameraPTPClient(command: streaming, event: nil).streamObject(handle: 1, size: UInt64(objectBytes.count)) { received += $0.count }
        try check(received == objectBytes.count && streaming.maximumRead <= 65536, "A whole legacy original packet is streamed in bounded blocks")
        let preflight = ScriptedCameraChannel(remoteInitialization(drive: 2))
        let importCompatible = try SonyCameraSession(client: CameraPTPClient(command: preflight, event: nil), purpose: .tethering)
        try check(importCompatible.device.model == "Other Sony Model", "Unknown compatible Sony model and firmware are admitted by protocol")
        let drive = CameraProperty(code: 0x5013, type: 4, writable: false, enabled: 1, current: .number(1),
            form: 0, minimum: nil, maximum: nil, step: nil, choices: [])
        let cardOff = CameraProperty(code: 0xd222, type: 6, writable: false, enabled: 1, current: .number(0),
            form: 0, minimum: nil, maximum: nil, step: nil, choices: [])
        let cardOn = CameraProperty(code: 0xd222, type: 6, writable: false, enabled: 1, current: .number(0x10),
            form: 0, minimum: nil, maximum: nil, step: nil, choices: [])
        try check(!importCompatible.captureReady([0x5013: drive, 0xd222: cardOff], cardConfirmed: true),
                  "Advertised card-saving state blocks shutter regardless of model name")
        try check(importCompatible.captureReady([0x5013: drive, 0xd222: cardOn], cardConfirmed: false),
                  "Advertised card-saving capability enables shutter on an unverified Sony model")
        try check(!importCompatible.captureReady([0x5013: drive], cardConfirmed: false) &&
                  importCompatible.captureReady([0x5013: drive], cardConfirmed: true),
                  "Missing card-saving status requires explicit confirmation")
        var recorded = false
        do { try importCompatible.capture(cardConfirmed: true) { recorded = true }; throw CameraProtocolError.invalid("Expected preflight rejection") }
        catch CameraProtocolError.captureNotSent { }
        let preflightCodes = try operationCodes(preflight)
        try check(!recorded && !preflightCodes.contains(0x9207), "Preflight rejection never records or transmits a shutter")
        let uncertain = ScriptedCameraChannel(remoteInitialization(drive: 1) + transactionResponse(6) + transactionResponse(7, code: 0x2005) + transactionResponse(8) + transactionResponse(9))
        let capturing = try SonyCameraSession(client: CameraPTPClient(command: uncertain, event: nil), purpose: .tethering)
        do { try capturing.capture(cardConfirmed: true) { recorded = true }; throw CameraProtocolError.invalid("Expected unknown shutter result") }
        catch CameraProtocolError.captureUnknown { }
        let shutterCodes = try operationCodes(uncertain)
        try check(recorded && uncertain.closed && shutterCodes.filter { $0 == 0x9207 }.count == 4,
                  "Unknown capture releases buttons, closes the session and never retries exposure")

        try test552IncrementalCursorVerification()
    }

    static func mobileDeviceInfo() -> Data {
        var device = Data()
        device.appendLE(UInt16(100)); device.appendLE(UInt32(17)); device.appendLE(UInt16(100))
        device.append(0); device.appendLE(UInt16(0))
        let operations: [UInt16] = [0x1001, 0x1002, 0x923c, 0x923d]
        device.appendLE(UInt32(operations.count)); operations.forEach { device.appendLE($0) }
        for _ in 0..<4 { device.appendLE(UInt32(0)) }
        for value in ["Sony", "ILCE-7M4", "1.00", "0552"] { device.append(ptpString(value)) }
        return device
    }

    static func mobilePagePayload(_ entries: [(content: UInt32, file: UInt32, name: String, size: UInt64, created: UInt64)]) -> Data {
        var data = Data(repeating: 0, count: 144)
        data.appendLE(UInt32(entries.count))
        for entry in entries {
            data.appendLE(UInt32(0))
            data.appendLE(entry.content)
            data.append(Data(repeating: 0, count: 20))
            data.appendLE(entry.created)
            data.append(Data(repeating: 0, count: 36))
            data.appendLE(UInt32(0)) // shot marks
            data.appendLE(UInt32(1)) // file count
            let pathBytes = Array(("/DCIM/100MSDCF/" + entry.name).utf8) + [0]
            data.appendLE(entry.file)
            data.appendLE(UInt32(pathBytes.count))
            data.append(contentsOf: pathBytes)
            data.appendLE(UInt32(0))
            data.appendLE(entry.size)
            data.append(Data(repeating: 0, count: 32))
            data.appendLE(UInt32(0)) // extra
            data.appendLE(UInt32(0)) // video
            data.appendLE(UInt32(0)) // audio
        }
        return data
    }

    static func test552IncrementalCursorVerification() throws {
        var entries: [(content: UInt32, file: UInt32, name: String, size: UInt64, created: UInt64)] = []
        let baseCreated: UInt64 = 1_700_000_000_000
        for i in 0..<250 {
            entries.append((
                content: UInt32(1000 + i),
                file: 1,
                name: String(format: "DSC%05d.ARW", i),
                size: 1024,
                created: baseCreated + UInt64(i * 10)
            ))
        }
        let channel = MockMobileCameraChannel(entries: entries, deviceInfo: mobileDeviceInfo())
        let session = try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: .importing)

        let listed = try session.listAssets()
        try check(listed.count == 250, "#552 setup: listAssets returns all 250 mobile assets")
        let listProbes = channel.listProbeLog
        try check(listProbes.count == 3 && listProbes[0].cursor == 0,
                  "#552 setup: full listAssets traverses 3 pages starting from cursor 0")

        // 1. Download/verify asset #240 (on page 3): must issue exactly 1 0x923c probe at created - 1
        channel.resetListProbeLog()
        let target = listed[240]
        let expectedCursor = UInt64(target.snapshot.created)! - 1
        let digest = try session.originalDigest(target) { _ in }
        try check(digest.count == 64, "#552 originalDigest completes for asset 240")
        let verifyProbes = channel.listProbeLog
        try check(verifyProbes.count == 1 && verifyProbes[0].cursor == expectedCursor,
                  "#552 readOriginal verifies asset via 1 incremental 0x923c probe at created-1 (actual count=\(verifyProbes.count), cursors=\(verifyProbes.map(\.cursor)))")

        // 2. Removed/mutated asset on card with >100 newer assets after it: stops early in 1 probe (page.cursor > targetCreated)
        let missingTarget = listed[120]
        let missingExpectedCursor = UInt64(missingTarget.snapshot.created)! - 1
        channel.listedEntries.removeAll { $0.content == missingTarget.snapshot.content }
        channel.resetListProbeLog()
        var threwRemoved = false
        do {
            _ = try session.originalDigest(missingTarget) { _ in }
        } catch CameraProtocolError.transientTransfer {
            threwRemoved = true
        }
        let removedProbes = channel.listProbeLog
        try check(threwRemoved && removedProbes.count == 1 && removedProbes[0].cursor == missingExpectedCursor && !channel.closed,
                  "#552 missing asset stops early in 1 incremental probe with transientTransfer and keeps session open")

        // 3. Edge case: created == 0 must not underflow UInt64
        let zeroEntry: (content: UInt32, file: UInt32, name: String, size: UInt64, created: UInt64) = (
            content: 9999, file: 1, name: "DSC09999.ARW", size: 1024, created: 0
        )
        let zeroChannel = MockMobileCameraChannel(entries: [zeroEntry] + entries, deviceInfo: mobileDeviceInfo())
        let zeroSession = try SonyCameraSession(client: CameraPTPClient(command: zeroChannel, event: nil), purpose: .importing)
        let zeroAssets = try zeroSession.listAssets()
        zeroChannel.resetListProbeLog()
        _ = try zeroSession.originalDigest(zeroAssets[0]) { _ in }
        let zeroProbes = zeroChannel.listProbeLog
        try check(zeroProbes.count == 1 && zeroProbes[0].cursor == 0,
                  "#552 created == 0 seeks safely with cursor 0 without UInt64 underflow")

        // 4. DeviceBusy (0x2019) on 0x923c keeps channel open and propagates CameraProtocolError.response
        zeroChannel.overrideListStatusCode = 0x2019
        var gotBusy = false
        do {
            _ = try zeroSession.originalDigest(zeroAssets[0]) { _ in }
        } catch CameraProtocolError.response(0x923c, 0x2019) {
            gotBusy = true
        }
        try check(gotBusy && !zeroChannel.closed,
                  "#552 0x923c busy response (0x2019) propagates response error without closing channel")
    }
}

final class MockMobileCameraChannel: CameraByteChannel {
    var entries: [(content: UInt32, file: UInt32, name: String, size: UInt64, created: UInt64)]
    var listedEntries: [(content: UInt32, file: UInt32, name: String, size: UInt64, created: UInt64)]
    let deviceInfo: Data
    var overrideListStatusCode: UInt16?
    private(set) var listProbeLog: [(cursor: UInt64, count: UInt32)] = []
    private(set) var closed = false
    private var outgoing = Data()

    init(entries: [(content: UInt32, file: UInt32, name: String, size: UInt64, created: UInt64)], deviceInfo: Data) {
        self.entries = entries
        self.listedEntries = entries
        self.deviceInfo = deviceInfo
    }

    func resetListProbeLog() {
        listProbeLog.removeAll()
    }

    func read(_ count: Int) throws -> Data {
        guard !closed, outgoing.count >= count else { throw CameraProtocolError.disconnected }
        let data = Data(outgoing.prefix(count))
        outgoing.removeFirst(count)
        return data
    }

    func write(_ data: Data) throws {
        var reader = CameraDataReader(data)
        _ = try reader.u32() // packet length
        let type = try reader.u32()
        guard type == 6 else { return }
        _ = try reader.u32() // phase
        let op = try reader.u16()
        let tid = try reader.u32()
        var params: [UInt32] = []
        while reader.remaining >= 4 {
            params.append(try reader.u32())
        }
        switch op {
        case 0x1001:
            outgoing.append(CameraProtocolTests.transactionResponse(tid, data: deviceInfo))
        case 0x1002:
            outgoing.append(CameraProtocolTests.transactionResponse(tid))
        case 0x923c:
            let cursor = UInt64(params[0]) | (UInt64(params[1]) << 32)
            let requested = params.count > 2 ? params[2] : 100
            listProbeLog.append((cursor: cursor, count: requested))
            if let code = overrideListStatusCode {
                outgoing.append(CameraProtocolTests.transactionResponse(tid, code: code))
                return
            }
            let filtered = cursor == 0 ? listedEntries : listedEntries.filter { $0.created > cursor }
            let pageEntries = Array(filtered.prefix(Int(requested)))
            let payload = CameraProtocolTests.mobilePagePayload(pageEntries)
            outgoing.append(CameraProtocolTests.transactionResponse(tid, data: payload))
        case 0x923d:
            let content = params[0]
            let offset = UInt64(params[2]) | (UInt64(params[3]) << 32)
            let length = Int(params[4])
            guard let entry = entries.first(where: { $0.content == content }),
                  offset + UInt64(length) <= entry.size else {
                outgoing.append(CameraProtocolTests.transactionResponse(tid, code: 0x2009))
                return
            }
            var bytes = Data(repeating: UInt8(content & 0xff), count: length)
            if offset == 0, length >= 4 {
                bytes.replaceSubrange(0..<4, with: [0x49, 0x49, 0x2a, 0x00])
            }
            outgoing.append(CameraProtocolTests.transactionResponse(tid, data: bytes))
        default:
            outgoing.append(CameraProtocolTests.transactionResponse(tid, code: 0x2005))
        }
    }

    func close() { closed = true }
}

final class ScriptedCameraChannel: CameraByteChannel {
    var bytes: Data; var sent: [Data] = []; var closed = false; var maximumRead = 0
    init(_ bytes: Data) { self.bytes = bytes }
    func read(_ count: Int) throws -> Data {
        maximumRead = max(maximumRead, count)
        guard !closed, bytes.count >= count else { throw CameraProtocolError.disconnected }
        let data = Data(bytes.prefix(count)); bytes.removeFirst(count); return data
    }
    func write(_ data: Data) throws { sent.append(data) }
    func close() { closed = true }
}
