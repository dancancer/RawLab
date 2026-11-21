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
        try testFocusCoordinateMappingAndMetadata()
        try testSonySessionTouchFocusAndFocusArea()
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

    static func testFocusCoordinateMappingAndMetadata() throws {
        let quarter = CameraWire.focusPoint(tapX: 160, tapY: 120, containerWidth: 640, containerHeight: 480, imageWidth: 640, imageHeight: 480)
        try check(quarter?.x == 160 && quarter?.y == 120 && quarter?.packed == ((160 << 16) | 120),
                  "Quarter tap maps to (160, 120) on 640x480 Sony grid")

        // 640x480 image AspectFit inside 640x640 container -> letterbox top 80..560
        try check(CameraWire.focusPoint(tapX: 320, tapY: 40, containerWidth: 640, containerHeight: 640, imageWidth: 640, imageHeight: 480) == nil,
                  "Tap in top letterbox bar is ignored")
        try check(CameraWire.focusPoint(tapX: 320, tapY: 600, containerWidth: 640, containerHeight: 640, imageWidth: 640, imageHeight: 480) == nil,
                  "Tap in bottom letterbox bar is ignored")
        let topLeft = CameraWire.focusPoint(tapX: 0, tapY: 80, containerWidth: 640, containerHeight: 640, imageWidth: 640, imageHeight: 480)
        let bottomRight = CameraWire.focusPoint(tapX: 640, tapY: 560, containerWidth: 640, containerHeight: 640, imageWidth: 640, imageHeight: 480)
        try check(topLeft?.x == 0 && topLeft?.y == 0 && bottomRight?.x == 639 && bottomRight?.y == 479,
                  "Fitted rect corners map and clamp to 0..639 x 0..479")

        // Pillarbox 640x480 in 800x480 -> fitted left 80..720
        try check(CameraWire.focusPoint(tapX: 40, tapY: 240, containerWidth: 800, containerHeight: 480, imageWidth: 640, imageHeight: 480) == nil &&
                  CameraWire.focusPoint(tapX: 760, tapY: 240, containerWidth: 800, containerHeight: 480, imageWidth: 640, imageHeight: 480) == nil &&
                  CameraWire.focusPoint(tapX: 0, tapY: 0, containerWidth: 0, containerHeight: 480, imageWidth: 640, imageHeight: 480) == nil,
                  "Pillarbox and invalid container sizes return nil")

        let bounds = try CameraWire.liveFrameBounds([16, 100, 116, 136])
        try check(bounds.size == 236 && bounds.image == 0..<100 && bounds.metadata == 100..<236,
                  "liveFrameBounds extracts both JPEG and metadata sub-ranges")
        try check(try CameraWire.liveFrameBounds([16, 100, 0, 0]).metadata == nil,
                  "liveFrameBounds omits empty metadata range")

        // Real a6700 136-byte v0x68 empty metadata vector (matches alpha2go sonyliveviewmeta_test.go)
        let a6700Hex = """
        68 00 02 00 00 00 00 00 01 00 00 00 00 00 00 00
        02 00 00 00 00 00 00 00 fc ff ff ff fb ff ff ff
        ff 7f 00 00 00 00 00 00 00 00 00 00 00 00 00 00
        00 00 00 00 00 00 00 00 00 00 0a 00 00 80 07 00
        00 00 00 00 00 00 00 00 00 00 0a 00 00 80 07 00
        00 00 00 00 00 00 00 00 00 00 0a 00 00 80 07 00
        00 00 00 00 00 00 00 00 00 00 0a 00 00 80 07 00
        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
        00 00 00 00 00 00 00 00
        """
        let cleanHex = a6700Hex.filter { !$0.isWhitespace }
        var a6700Bytes = Data()
        var idx = cleanHex.startIndex
        while idx < cleanHex.endIndex {
            let next = cleanHex.index(idx, offsetBy: 2)
            a6700Bytes.append(UInt8(cleanHex[idx..<next], radix: 16)!)
            idx = next
        }
        try check(a6700Bytes.count == 136 && CameraWire.liveViewFrames(a6700Bytes).isEmpty,
                  "Real a6700 v0x68 metadata with empty frame blocks parses cleanly")

        func metaBlock(xmax: UInt32, ymax: UInt32, entries: [(type: UInt16, state: UInt16, cx: UInt32, cy: UInt32, h: UInt32, w: UInt32)]) -> Data {
            var b = Data()
            b.appendLE(xmax); b.appendLE(ymax); b.appendLE(UInt16(entries.count)); b.append(Data(repeating: 0, count: 6))
            for e in entries {
                b.appendLE(e.type); b.appendLE(e.state); b.appendLE(UInt32(0))
                b.appendLE(e.cx); b.appendLE(e.cy); b.appendLE(e.h); b.appendLE(e.w)
            }
            return b
        }
        func synthMeta(version: UInt16) -> Data {
            var b = Data(); b.appendLE(version); b.append(Data(repeating: 0, count: 0x28 - 2))
            b.append(metaBlock(xmax: 1, ymax: 1, entries: []))
            b.append(metaBlock(xmax: 100, ymax: 50, entries: [(type: 1, state: 2, cx: 10, cy: 20, h: 4, w: 6)]))
            if version > 0x64 {
                b.append(metaBlock(xmax: 100, ymax: 50, entries: [(type: 2, state: 1, cx: 30, cy: 40, h: 8, w: 12)]))
                b.append(metaBlock(xmax: 100, ymax: 50, entries: [(type: 5, state: 1, cx: 50, cy: 5, h: 2, w: 3)]))
            }
            return b
        }

        let v68 = synthMeta(version: 0x68)
        let slicedV68 = (Data([0xaa, 0xbb]) + v68).dropFirst(2) // non-zero startIndex slice
        let parsed68 = CameraWire.liveViewFrames(slicedV68)
        try check(parsed68 == [
            CameraLiveViewFrame(kind: .focus, cx: 0.1, cy: 0.4, width: 0.06, height: 0.08, focused: true),
            CameraLiveViewFrame(kind: .face, cx: 0.3, cy: 0.8, width: 0.12, height: 0.16, focused: true),
            CameraLiveViewFrame(kind: .tracking, cx: 0.5, cy: 0.1, width: 0.03, height: 0.04, focused: false),
        ], "v0x68 liveViewFrames decodes H before W across non-zero-startIndex slice")

        let parsed64 = CameraWire.liveViewFrames(synthMeta(version: 0x64))
        try check(parsed64.count == 1 && parsed64[0].kind == .focus, "v0x64 decodes focus block only")
        try check(CameraWire.liveViewFrames(synthMeta(version: 0x27)).isEmpty, "v0x27 yields empty frames")
        try check(CameraWire.liveViewFrames(v68.prefix(0x30)).isEmpty, "Truncated metadata fails soft")
        var oversized = v68
        oversized[0x28 + 8] = 0xff; oversized[0x28 + 9] = 0xff
        try check(CameraWire.liveViewFrames(oversized).isEmpty, "Oversized metadata block count fails soft")
    }

    static func testSonySessionTouchFocusAndFocusArea() throws {
        // 1. Primary 0xD2E4 when 0xD284 == 1
        let touchChannel = MockFocusCameraChannel(
            controls: [0xd2c1, 0xd2c2, 0xd2e4, 0xd2e5, 0xd2dc],
            props: [
                (0x500a, 4, true, 1, 2, [2, 1]),
                (0xd22c, 4, true, 1, 0x0001, [0x0001, 0x0102]),
                (0xd284, 2, false, 1, 1, []),
                (0xd285, 2, false, 0, 0, []),
            ]
        )
        let touchSession = try SonyCameraSession(client: CameraPTPClient(command: touchChannel, event: nil), purpose: .tethering)
        _ = try touchSession.setFocusPoint(x: 160, y: 120)
        try check(touchChannel.recorded9207.count == 1 &&
                  touchChannel.recorded9207[0].0 == 0xd2e4 &&
                  touchChannel.recorded9207[0].1 == UInt32((160 << 16) | 120),
                  "0xD2E4 remote touch sends packed (x<<16)|y when 0xD284 is enabled and 1")

        // 2. Cancel active touch first when 0xD284 == 0 and 0xD285 == 1, then retry 0xD2E4
        let cancelFirstChannel = MockFocusCameraChannel(
            controls: [0xd2c1, 0xd2c2, 0xd2e4, 0xd2e5],
            props: [
                (0x500a, 4, true, 1, 2, [2, 1]),
                (0xd284, 2, false, 1, 0, []),
                (0xd285, 2, false, 1, 1, []),
            ]
        )
        cancelFirstChannel.on9207 = { code, val in
            if code == 0xd2e5 && val == 1 {
                cancelFirstChannel.setPropValue(0xd284, 1)
                cancelFirstChannel.setPropValue(0xd285, 0)
            }
        }
        let cancelFirstSession = try SonyCameraSession(client: CameraPTPClient(command: cancelFirstChannel, event: nil), purpose: .tethering)
        _ = try cancelFirstSession.setFocusPoint(x: 320, y: 240)
        try check(cancelFirstChannel.recorded9207.map(\.0) == [0xd2e5, 0xd2e5, 0xd2e4] &&
                  cancelFirstChannel.recorded9207.map(\.1) == [2, 1, UInt32((320 << 16) | 240)],
                  "Tap cancels active touch (0xD2E5 2->1) and re-evaluates 0xD284 before 0xD2E4")

        // 3. Fallback 0xD2DC when Spot M (0x0102)
        let spotChannel = MockFocusCameraChannel(
            controls: [0xd2c1, 0xd2c2, 0xd2dc],
            props: [
                (0x500a, 4, true, 1, 2, [2, 1]),
                (0xd22c, 4, true, 1, 0x0102, [0x0001, 0x0002, 0x0102]),
            ]
        )
        let spotSession = try SonyCameraSession(client: CameraPTPClient(command: spotChannel, event: nil), purpose: .tethering)
        _ = try spotSession.setFocusPoint(x: 400, y: 100)
        try check(spotChannel.recorded9207.count == 1 &&
                  spotChannel.recorded9207[0].0 == 0xd2dc &&
                  spotChannel.recorded9207[0].1 == UInt32((400 << 16) | 100),
                  "0xD2DC fallback moves AF area in Spot M")

        // 4. Fixed area rejection (0 writes)
        for fixed: Int64 in [0x0001, 0x0003, 0x0201, 0x0203] {
            let fixedChannel = MockFocusCameraChannel(
                controls: [0xd2c1, 0xd2c2, 0xd2dc],
                props: [(0x500a, 4, true, 1, 2, [2, 1]), (0xd22c, 4, true, 1, fixed, [fixed, 0x0102])]
            )
            let fixedSession = try SonyCameraSession(client: CameraPTPClient(command: fixedChannel, event: nil), purpose: .tethering)
            var gotFixed = false
            do { _ = try fixedSession.setFocusPoint(x: 100, y: 100) }
            catch CameraProtocolError.focusUnavailable(.focusAreaFixed) { gotFixed = true }
            try check(gotFixed && fixedChannel.recorded9207.isEmpty,
                      "Fixed focus area \(String(format: "0x%04X", fixed)) rejects with 0 writes")
        }

        // 5. Manual focus (0x500A == 1) and unsupported controls reject with 0 writes
        let mfChannel = MockFocusCameraChannel(
            controls: [0xd2c1, 0xd2c2, 0xd2dc],
            props: [(0x500a, 4, true, 1, 1, [1, 2]), (0xd22c, 4, true, 1, 0x0102, [0x0102])]
        )
        let mfSession = try SonyCameraSession(client: CameraPTPClient(command: mfChannel, event: nil), purpose: .tethering)
        var gotMF = false
        do { _ = try mfSession.setFocusPoint(x: 100, y: 100) }
        catch CameraProtocolError.focusUnavailable(.manualFocus) { gotMF = true }
        try check(gotMF && mfChannel.recorded9207.isEmpty, "MF rejects focus point with 0 writes")

        let unsupportedChannel = MockFocusCameraChannel(controls: [0xd2c1, 0xd2c2], props: [(0x500a, 4, true, 1, 2, [2])])
        let unsupportedSession = try SonyCameraSession(client: CameraPTPClient(command: unsupportedChannel, event: nil), purpose: .tethering)
        var gotUnsupported = false
        do { _ = try unsupportedSession.setFocusPoint(x: 100, y: 100) }
        catch CameraProtocolError.focusUnavailable(.unsupported) { gotUnsupported = true }
        try check(gotUnsupported && unsupportedChannel.recorded9207.isEmpty, "Unsupported controls reject with 0 writes")

        // 6. Import purpose never writes focus or 0xD22C
        let importChannel = MockFocusCameraChannel(
            controls: [0xd2c1, 0xd2c2, 0xd2e4, 0xd2dc],
            props: [(0xd284, 2, false, 1, 1, []), (0xd22c, 4, true, 1, 0x0001, [0x0001, 0x0102])]
        )
        let importSession = try SonyCameraSession(client: CameraPTPClient(command: importChannel, event: nil), purpose: .importing)
        try rejects("Import purpose forbids tap-to-focus") { _ = try importSession.setFocusPoint(x: 100, y: 100) }
        try rejects("Import purpose forbids 0xD22C parameter write") { _ = try importSession.setParameter(0xd22c, value: 0x0102) }
        try check(importChannel.recorded9207.isEmpty && importChannel.recorded9205.isEmpty, "Import purpose executes 0 writes")

        // 7. Aligned PTP rejection keeps channel open; cancelTouchFocus releases on press failure
        touchChannel.next9207Status = 0x2019
        var gotRejected = false
        do { _ = try touchSession.setFocusPoint(x: 100, y: 100) }
        catch CameraProtocolError.focusRejected { gotRejected = true }
        try check(gotRejected && !touchChannel.closed && !touchSession.stopped,
                  "Aligned 0x9207 rejection throws .focusRejected without closing session")

        let cancelErrChannel = MockFocusCameraChannel(
            controls: [0xd2c1, 0xd2c2, 0xd2e5],
            props: [(0xd285, 2, false, 1, 1, [])]
        )
        cancelErrChannel.next9207Status = 0x2005
        let cancelErrSession = try SonyCameraSession(client: CameraPTPClient(command: cancelErrChannel, event: nil), purpose: .tethering)
        var gotCancelRejected = false
        do { _ = try cancelErrSession.cancelTouchFocus() }
        catch CameraProtocolError.focusRejected { gotCancelRejected = true }
        try check(gotCancelRejected && !cancelErrChannel.closed &&
                  cancelErrChannel.recorded9207.map(\.0) == [0xd2e5, 0xd2e5] &&
                  cancelErrChannel.recorded9207.map(\.1) == [2, 1],
                  "Failed cancelTouchFocus press still sends 0xD2E5 release=1 and keeps session open")

        // 8. 0xD22C Focus Area setParameter write & confirmation
        let updated = try spotSession.setParameter(0xd22c, value: 0x0002)
        try check(updated.confirmed && updated.values[0xd22c]?.number == 0x0002 &&
                  spotChannel.recorded9205.count == 1 &&
                  spotChannel.recorded9205[0].0 == 0xd22c &&
                  spotChannel.recorded9205[0].1 == 0x0002,
                  "0xD22C Focus Area writes u16 via 0x9205 and confirms readback")
    }
}

final class MockFocusCameraChannel: CameraByteChannel {
    private let controls: [UInt16]
    private var props: [(code: UInt16, type: UInt16, writable: Bool, enabled: UInt8, value: Int64, choices: [Int64])]
    private var outgoing = Data()
    private var pendingOp: (tid: UInt32, op: UInt16, param: UInt32)?
    private(set) var closed = false
    private(set) var recorded9207: [(UInt32, UInt32)] = []
    private(set) var recorded9205: [(UInt32, UInt32)] = []
    var next9207Status: UInt16?
    var on9207: ((UInt32, UInt32) -> Void)?

    init(controls: [UInt16], props: [(code: UInt16, type: UInt16, writable: Bool, enabled: UInt8, value: Int64, choices: [Int64])]) {
        self.controls = controls
        self.props = props
    }

    func setPropValue(_ code: UInt16, _ value: Int64) {
        if let idx = props.firstIndex(where: { $0.code == code }) { props[idx].value = value }
    }

    func read(_ count: Int) throws -> Data {
        guard !closed, outgoing.count >= count else { throw CameraProtocolError.disconnected }
        let data = Data(outgoing.prefix(count))
        outgoing.removeFirst(count)
        return data
    }

    func write(_ data: Data) throws {
        var r = CameraDataReader(data)
        _ = try r.u32()
        let type = try r.u32()
        if type == 9 || type == 14 { return }
        if type == 12 {
            let tid = try r.u32()
            guard let pending = pendingOp, pending.tid == tid else { throw CameraProtocolError.invalid("Unexpected data") }
            pendingOp = nil
            if pending.op == 0x9207 {
                let value: UInt32 = r.remaining >= 4 ? try r.u32() : UInt32(try r.u16())
                recorded9207.append((pending.param, value))
                if let status = next9207Status {
                    next9207Status = nil
                    outgoing.append(CameraProtocolTests.transactionResponse(tid, code: status))
                    return
                }
                on9207?(pending.param, value)
                outgoing.append(CameraProtocolTests.transactionResponse(tid))
            } else if pending.op == 0x9205 {
                let value = UInt32(try r.u16())
                recorded9205.append((pending.param, value))
                setPropValue(UInt16(pending.param), Int64(value))
                outgoing.append(CameraProtocolTests.transactionResponse(tid))
            }
            return
        }
        guard type == 6 else { return }
        let phase = try r.u32()
        let op = try r.u16()
        let tid = try r.u32()
        var params: [UInt32] = []
        while r.remaining >= 4 { params.append(try r.u32()) }
        if phase == 2 {
            pendingOp = (tid, op, params.first ?? 0)
            return
        }
        switch op {
        case 0x1001:
            var dev = Data()
            dev.appendLE(UInt16(100)); dev.appendLE(UInt32(17)); dev.appendLE(UInt16(100))
            dev.append(0); dev.appendLE(UInt16(0))
            let ops: [UInt16] = [0x1001, 0x1002, 0x9201, 0x9202, 0x9205, 0x9207, 0x9209, 0x923c, 0x923d]
            dev.appendLE(UInt32(ops.count)); ops.forEach { dev.appendLE($0) }
            for _ in 0..<4 { dev.appendLE(UInt32(0)) }
            for v in ["Sony", "ILCE-6700", "2.00", "focus-test"] { dev.append(CameraProtocolTests.ptpString(v)) }
            outgoing.append(CameraProtocolTests.transactionResponse(tid, data: dev))
        case 0x1002, 0x9201:
            outgoing.append(CameraProtocolTests.transactionResponse(tid))
        case 0x9202:
            var ext = Data()
            ext.appendLE(UInt16(0x12c))
            ext.appendLE(UInt32(props.count)); props.forEach { ext.appendLE($0.code) }
            ext.appendLE(UInt32(controls.count)); controls.forEach { ext.appendLE($0) }
            outgoing.append(CameraProtocolTests.transactionResponse(tid, data: ext))
        case 0x9209:
            var p = Data(); p.appendLE(UInt64(props.count))
            for item in props {
                p.appendLE(item.code); p.appendLE(item.type)
                p.append(item.writable ? 1 : 0); p.append(item.enabled)
                if item.type == 2 { p.append(UInt8(item.value)); p.append(UInt8(item.value)) }
                else { p.appendLE(UInt16(item.value)); p.appendLE(UInt16(item.value)) }
                p.append(2)
                for _ in 0..<2 {
                    p.appendLE(UInt16(item.choices.count))
                    for c in item.choices {
                        if item.type == 2 { p.append(UInt8(c)) } else { p.appendLE(UInt16(c)) }
                    }
                }
            }
            outgoing.append(CameraProtocolTests.transactionResponse(tid, data: p))
        default:
            outgoing.append(CameraProtocolTests.transactionResponse(tid, code: 0x2005))
        }
    }

    func close() { closed = true }
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
