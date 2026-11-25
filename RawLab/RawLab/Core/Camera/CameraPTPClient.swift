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
    private var event: CameraByteChannel?
    private let stateLock = NSLock()
    private var closed = false
    private var transaction: UInt32 = 0
    private static let operations: Set<UInt16> = [0x1001, 0x1002, 0x1003, 0x1004, 0x1007, 0x1008,
        0x1009, 0x100a, 0x9201, 0x9202, 0x9205, 0x9207, 0x9209, 0x9212, 0x923b, 0x923c, 0x923d, 0x923e]
    init(command: CameraByteChannel, event: CameraByteChannel?) { self.command = command; self.event = event }
    var isClosed: Bool { stateLock.lock(); defer { stateLock.unlock() }; return closed }
    func close() {
        stateLock.lock()
        if closed { stateLock.unlock(); return }
        closed = true
        let eventChannel = event
        stateLock.unlock()
        command.close()
        eventChannel?.close()
    }

    private static func buildPacket(_ build: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?) -> sony2fuji_status) throws -> Data {
        var needed = 0
        guard build(nil, 0, &needed) == SONY2FUJI_STATUS_OK else {
            throw CameraProtocolError.invalid("PTP/IP packet build failed")
        }
        var bytes = [UInt8](repeating: 0, count: needed)
        let status = bytes.withUnsafeMutableBufferPointer { buf in
            build(buf.baseAddress, buf.count, &needed)
        }
        guard status == SONY2FUJI_STATUS_OK else {
            throw CameraProtocolError.invalid("PTP/IP packet build failed")
        }
        return Data(bytes.prefix(needed))
    }

    func initialize(clientID: UUID,
                    openEvent: (() throws -> CameraByteChannel)? = nil,
                    eventReceived: @escaping (UInt16) -> Void = { _ in }) throws {
        do {
            var id = clientID.uuid
            let initCmd = try withUnsafeBytes(of: &id) { rawID -> Data in
                let guidPtr = rawID.bindMemory(to: UInt8.self).baseAddress
                return try "RawLab".withCString { namePtr in
                    try Self.buildPacket { out, cap, outLen in
                        sony2fuji_sony_ptpip_build_init_cmd(guidPtr, namePtr, 0x10000, out, cap, outLen)
                    }
                }
            }
            try command.write(initCmd)
            let ack = try packet(command, limit: 4096)
            var connNum: UInt32 = 0
            let ackBytes = Array(ack.data)
            let ackStatus = ackBytes.withUnsafeBufferPointer { buf in
                sony2fuji_sony_ptpip_parse_init_cmd_ack(buf.baseAddress, buf.count, &connNum)
            }
            guard ack.type == 2, ackStatus == SONY2FUJI_STATUS_OK else {
                throw CameraProtocolError.invalid("PTP/IP command initialization rejected")
            }
            let eventChannel: CameraByteChannel
            if let openEvent {
                guard !isClosed else { throw CameraProtocolError.cancelled }
                let opened = try openEvent()
                stateLock.lock()
                if closed {
                    stateLock.unlock()
                    opened.close()
                    throw CameraProtocolError.cancelled
                }
                event = opened
                stateLock.unlock()
                eventChannel = opened
            } else {
                stateLock.lock()
                let existing = event
                stateLock.unlock()
                guard let existing else {
                    throw CameraProtocolError.invalid("PTP/IP command initialization rejected")
                }
                eventChannel = existing
            }
            let initEvt = try Self.buildPacket { out, cap, outLen in
                sony2fuji_sony_ptpip_build_init_evt(connNum, out, cap, outLen)
            }
            try eventChannel.write(initEvt)
            let ready = try packet(eventChannel, limit: 4096)
            guard ready.type == 4, ready.data.isEmpty else {
                throw CameraProtocolError.invalid("PTP/IP event initialization rejected")
            }
            let probeResp = try Self.buildPacket { out, cap, outLen in
                sony2fuji_sony_ptpip_build_probe_resp(out, cap, outLen)
            }
            eventChannel.beginEventLoop()
            DispatchQueue(label: "rawlab.camera.events").async { [weak self] in
                guard let self else { return }
                do {
                    while !self.isClosed {
                        let eventPacket = try self.packet(eventChannel, limit: 4096)
                        if eventPacket.type == 13, eventPacket.data.isEmpty {
                            try eventChannel.write(probeResp); continue
                        }
                        var parsed = sony2fuji_sony_ptpip_event()
                        let evtBytes = Array(eventPacket.data)
                        let evtStatus = evtBytes.withUnsafeBufferPointer { buf in
                            sony2fuji_sony_ptpip_parse_event(buf.baseAddress, buf.count, &parsed)
                        }
                        guard eventPacket.type == 8, evtStatus == SONY2FUJI_STATUS_OK else {
                            throw CameraProtocolError.invalid("Invalid PTP event")
                        }
                        eventReceived(parsed.event_code)
                    }
                } catch {
                    self.close()
                }
            }
        } catch {
            close(); throw error
        }
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
            let opReq = try Self.buildPacket { out, cap, outLen in
                parameters.withUnsafeBufferPointer { pBuf in
                    sony2fuji_sony_ptpip_build_op_req(
                        UInt32(outgoing == nil ? 1 : 2), operation, tid,
                        pBuf.baseAddress, UInt32(pBuf.count), out, cap, outLen
                    )
                }
            }
            try command.write(opReq)
            if let outgoing {
                let begin = try Self.buildPacket { out, cap, outLen in
                    sony2fuji_sony_ptpip_build_start_data(tid, UInt64(outgoing.count), out, cap, outLen)
                }
                try command.write(begin)
                let outBytes = Array(outgoing)
                let end = try Self.buildPacket { out, cap, outLen in
                    outBytes.withUnsafeBufferPointer { buf in
                        sony2fuji_sony_ptpip_build_end_data(tid, buf.baseAddress, buf.count, out, cap, outLen)
                    }
                }
                try command.write(end)
            }
            var expected: UInt64?, received: UInt64 = 0, ended = false
            for _ in 0..<10000 {
                let header = try packetHeader(command, limit: max(4096, limit + 4))
                switch header.type {
                case 9:
                    guard expected == nil else { throw CameraProtocolError.invalid("Invalid PTP start data") }
                    let raw = Array(try command.read(header.size))
                    var startData = sony2fuji_sony_ptpip_start_data()
                    let st = raw.withUnsafeBufferPointer { buf in
                        sony2fuji_sony_ptpip_parse_start_data(buf.baseAddress, buf.count, &startData)
                    }
                    guard st == SONY2FUJI_STATUS_OK else { throw CameraProtocolError.invalid("Invalid PTP start data") }
                    guard startData.transaction_id == tid else { throw CameraProtocolError.invalid("PTP start transaction mismatch") }
                    let count = startData.total_bytes
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
                    let raw = Array(try command.read(header.size))
                    var resp = sony2fuji_sony_ptpip_response()
                    let st = raw.withUnsafeBufferPointer { buf in
                        sony2fuji_sony_ptpip_parse_response(buf.baseAddress, buf.count, &resp)
                    }
                    guard st == SONY2FUJI_STATUS_OK else { throw CameraProtocolError.invalid("Invalid PTP response") }
                    guard resp.transaction_id == tid, expected == nil || ended else { throw CameraProtocolError.invalid("PTP response transaction mismatch") }
                    guard resp.response_code == 0x2001 else { throw CameraProtocolError.response(operation, resp.response_code) }
                    guard !requiresData || ended else { throw CameraProtocolError.invalid("Required camera data missing") }
                    return
                case 13 where header.size == 0:
                    let probeResp = try Self.buildPacket { out, cap, outLen in
                        sony2fuji_sony_ptpip_build_probe_resp(out, cap, outLen)
                    }
                    try command.write(probeResp)
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
        let raw = Array(try channel.read(8))
        var header = sony2fuji_sony_ptpip_header()
        let st = raw.withUnsafeBufferPointer { buf in
            sony2fuji_sony_ptpip_parse_header(buf.baseAddress, buf.count, limit, &header)
        }
        guard st == SONY2FUJI_STATUS_OK else { throw CameraProtocolError.invalid("Invalid PTP/IP packet length") }
        return (header.packet_type, Int(header.payload_size))
    }
    private func packet(_ channel: CameraByteChannel, limit: Int) throws -> (type: UInt32, data: Data) {
        let header = try packetHeader(channel, limit: UInt64(limit))
        return (header.type, try channel.read(header.size))
    }
}
