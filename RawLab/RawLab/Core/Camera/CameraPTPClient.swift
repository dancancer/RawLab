import Foundation

protocol CameraByteChannel: AnyObject {
    func read(_ count: Int) throws -> Data
    func write(_ data: Data) throws
    func close()
    func beginEventLoop()
}

extension CameraByteChannel { func beginEventLoop() {} }

/// command 仅由同一串行 owner 调用；event 使用独立读取线程，关闭可从任何线程发起。
final class CameraPTPClient {
    let command: CameraByteChannel
    let event: CameraByteChannel?
    private let stateLock = NSLock()
    private var closed = false
    private var transaction: UInt32 = 0
    private static let operations: Set<UInt16> = [0x1001, 0x1002, 0x1003, 0x1004, 0x1007, 0x1008,
        0x1009, 0x100a, 0x9201, 0x9202, 0x9205, 0x9207, 0x9209, 0x9212, 0x923c, 0x923d, 0x923e]
    init(command: CameraByteChannel, event: CameraByteChannel?) { self.command = command; self.event = event }
    var isClosed: Bool { stateLock.lock(); defer { stateLock.unlock() }; return closed }
    func close() {
        stateLock.lock()
        if closed { stateLock.unlock(); return }
        closed = true; stateLock.unlock()
        command.close(); event?.close()
    }

    func initialize(clientID: UUID, eventReceived: @escaping (UInt16) -> Void = { _ in }) throws {
        do {
            var id = clientID.uuid
            var payload = withUnsafeBytes(of: &id) { Data($0) }
            payload.append("RawLab\0".data(using: .utf16LittleEndian)!)
            payload.appendLE(UInt32(0x10000))
            try command.write(CameraWire.packet(1, payload))
            let ack = try packet(command, limit: 4096)
            guard ack.type == 2, ack.data.count >= 24, let event else {
                throw CameraProtocolError.invalid("PTP/IP command initialization rejected")
            }
            var reader = CameraDataReader(ack.data), connection = Data()
            connection.appendLE(try reader.u32())
            try event.write(CameraWire.packet(3, connection))
            let ready = try packet(event, limit: 4096)
            guard ready.type == 4, ready.data.isEmpty else {
                throw CameraProtocolError.invalid("PTP/IP event initialization rejected")
            }
            event.beginEventLoop()
            DispatchQueue(label: "rawlab.camera.events").async { [weak self] in
                guard let self else { return }
                do {
                    while !self.isClosed {
                        let eventPacket = try self.packet(event, limit: 4096)
                        if eventPacket.type == 13, eventPacket.data.isEmpty {
                            try event.write(CameraWire.packet(14, Data())); continue
                        }
                        guard eventPacket.type == 8, (6...18).contains(eventPacket.data.count),
                              (eventPacket.data.count - 6) % 4 == 0 else { throw CameraProtocolError.invalid("Invalid PTP event") }
                        var data = CameraDataReader(eventPacket.data)
                        eventReceived(try data.u16())
                    }
                } catch { self.close() }
            }
        } catch { close(); throw error }
    }

    func operation(_ operation: UInt16, parameters: [UInt32] = [], outgoing: Data? = nil,
                   requiresData: Bool = false, limit: Int = 0) throws -> Data {
        guard limit >= 0, limit <= CameraWire.dataLimit else { throw CameraProtocolError.invalid("PTP operation budget") }
        var data = Data()
        try exchange(operation, parameters: parameters, outgoing: outgoing, requiresData: requiresData,
                     limit: UInt64(limit)) { data.append($0) }
        return data
    }

    func streamObject(handle: UInt32, size: UInt64, sink: (Data) throws -> Void) throws {
        guard size > 0, size <= 1 << 30 else { throw CameraProtocolError.invalid("Original exceeds transfer budget") }
        try exchange(0x1009, parameters: [handle], requiresData: true, limit: size, exactSize: size, sink: sink)
    }

    private func exchange(_ operation: UInt16, parameters: [UInt32], outgoing: Data? = nil,
                          requiresData: Bool, limit: UInt64, exactSize: UInt64? = nil,
                          sink: (Data) throws -> Void) throws {
        guard Self.operations.contains(operation), parameters.count <= 5,
              outgoing == nil || ([UInt16(0x9205), 0x9207].contains(operation) && outgoing!.count <= 4) else {
            throw CameraProtocolError.unsupported("Operation outside the implemented Sony protocol")
        }
        guard !isClosed else { throw CameraProtocolError.disconnected }
        if operation == 0x1002 { transaction = 0 }
        else {
            guard transaction < UInt32.max else { close(); throw CameraProtocolError.invalid("Transaction limit reached") }
            transaction += 1
        }
        let tid = transaction
        do {
            var request = Data(); request.appendLE(UInt32(outgoing == nil ? 1 : 2))
            request.appendLE(operation); request.appendLE(tid)
            for parameter in parameters { request.appendLE(parameter) }
            try command.write(CameraWire.packet(6, request))
            if let outgoing {
                var begin = Data(); begin.appendLE(tid); begin.appendLE(UInt64(outgoing.count))
                try command.write(CameraWire.packet(9, begin))
                var end = Data(); end.appendLE(tid); end.append(outgoing)
                try command.write(CameraWire.packet(12, end))
            }
            var expected: UInt64?, received: UInt64 = 0, ended = false
            for _ in 0..<10000 {
                let header = try packetHeader(command, limit: max(4096, limit + 4))
                switch header.type {
                case 9:
                    guard expected == nil, header.size == 12 else { throw CameraProtocolError.invalid("Invalid PTP start data") }
                    var data = CameraDataReader(try command.read(12))
                    guard try data.u32() == tid else { throw CameraProtocolError.invalid("PTP start transaction mismatch") }
                    let count = try data.u64()
                    guard count <= limit, exactSize == nil || count == exactSize else { throw CameraProtocolError.invalid("PTP data exceeds declared object size") }
                    expected = count
                case 10, 12:
                    guard let expected, !ended, header.size >= 4 else { throw CameraProtocolError.invalid("Unexpected PTP data") }
                    var data = CameraDataReader(try command.read(4))
                    guard try data.u32() == tid else { throw CameraProtocolError.invalid("PTP data transaction mismatch") }
                    var remaining = header.size - 4
                    guard UInt64(remaining) <= expected - received else { throw CameraProtocolError.invalid("PTP data exceeds declared length") }
                    while remaining > 0 {
                        let count = min(64 << 10, remaining)
                        let bytes = try command.read(count)
                        try sink(bytes)
                        received += UInt64(bytes.count); remaining -= bytes.count
                    }
                    if header.type == 12 {
                        guard received == expected else { throw CameraProtocolError.invalid("Incomplete camera data") }
                        ended = true
                    }
                case 7:
                    guard (6...26).contains(header.size), (header.size - 6) % 4 == 0 else { throw CameraProtocolError.invalid("Invalid PTP response") }
                    var data = CameraDataReader(try command.read(header.size))
                    let code = try data.u16()
                    guard try data.u32() == tid, expected == nil || ended else { throw CameraProtocolError.invalid("PTP response transaction mismatch") }
                    guard code == 0x2001 else { throw CameraProtocolError.response(operation, code) }
                    guard !requiresData || ended else { throw CameraProtocolError.invalid("Required camera data missing") }
                    return
                case 13 where header.size == 0: try command.write(CameraWire.packet(14, Data()))
                default: throw CameraProtocolError.invalid("Unexpected PTP/IP packet")
                }
            }
            throw CameraProtocolError.invalid("PTP packet budget exceeded")
        } catch CameraProtocolError.response(let operation, let code) {
            throw CameraProtocolError.response(operation, code)
        } catch {
            close()
            throw error
        }
    }

    private func packetHeader(_ channel: CameraByteChannel, limit: UInt64) throws -> (type: UInt32, size: Int) {
        var reader = CameraDataReader(try channel.read(8))
        let length = try reader.u32(), type = try reader.u32()
        guard length >= 8, UInt64(length - 8) <= limit else { throw CameraProtocolError.invalid("Invalid PTP/IP packet length") }
        return (type, Int(length - 8))
    }
    private func packet(_ channel: CameraByteChannel, limit: Int) throws -> (type: UInt32, data: Data) {
        let header = try packetHeader(channel, limit: UInt64(limit))
        return (header.type, try channel.read(header.size))
    }
}
