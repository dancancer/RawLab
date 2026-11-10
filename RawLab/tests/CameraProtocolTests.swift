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

    }
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
