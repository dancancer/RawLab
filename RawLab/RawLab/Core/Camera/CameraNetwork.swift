import Foundation
import Network

private final class CameraNetworkResult<T> {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    let semaphore = DispatchSemaphore(value: 0)
    func finish(_ value: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; lock.unlock(); semaphore.signal()
    }
    func value() throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let result else { throw CameraProtocolError.timeout }
        return try result.get()
    }
}

final class CameraTCPChannel: CameraByteChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "rawlab.camera.network")
    private var timeout: TimeInterval
    private let lock = NSLock()
    private var closed = false
    private var buffered = Data()

    init(host: String, port: UInt16 = 15740, timeout: TimeInterval = 15) throws {
        guard Self.localIPv4(host), port > 0 else { throw CameraProtocolError.invalid("Camera endpoint must be a local IPv4 address") }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredInterfaceType = .wifi
        self.timeout = timeout
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        let ready = CameraNetworkResult<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.finish(.success(()))
            case .failed(let error): ready.finish(.failure(error))
            case .cancelled: ready.finish(.failure(CameraProtocolError.cancelled))
            default: break
            }
        }
        connection.start(queue: queue)
        guard ready.semaphore.wait(timeout: .now() + 10) == .success else { connection.cancel(); throw CameraProtocolError.timeout }
        do { try ready.value() } catch { connection.cancel(); throw error }
        connection.stateUpdateHandler = nil
    }

    static func localIPv4(_ host: String) -> Bool {
        let fields = host.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return false }
        let bytes = fields.compactMap { UInt8($0) }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || bytes[0] == 172 && (16...31).contains(bytes[1]) ||
            bytes[0] == 192 && bytes[1] == 168 || bytes[0] == 169 && bytes[1] == 254
    }

    private func ensureOpen() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw CameraProtocolError.cancelled }
    }
    private func wait<T>(_ result: CameraNetworkResult<T>, timeout: TimeInterval) throws -> T {
        let finished = timeout == 0 ? { result.semaphore.wait(); return true }() :
            result.semaphore.wait(timeout: .now() + timeout) == .success
        guard finished else { close(); throw CameraProtocolError.timeout }
        return try result.value()
    }
    func write(_ data: Data) throws {
        try ensureOpen()
        let result = CameraNetworkResult<Void>()
        connection.send(content: data, completion: .contentProcessed { error in
            result.finish(error.map { .failure($0) } ?? .success(()))
        })
        try wait(result, timeout: 10)
    }
    func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= CameraWire.dataLimit else { throw CameraProtocolError.invalid("Network read exceeds budget") }
        while buffered.count < count {
            try ensureOpen()
            let result = CameraNetworkResult<Data>()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, complete, error in
                if let error { result.finish(.failure(error)) }
                else if let data, !data.isEmpty { result.finish(.success(data)) }
                else if complete { result.finish(.failure(CameraProtocolError.disconnected)) }
                else { result.finish(.failure(CameraProtocolError.invalid("Empty camera network read"))) }
            }
            buffered.append(try wait(result, timeout: timeout))
        }
        let data = Data(buffered.prefix(count)); buffered.removeFirst(count); return data
    }
    func beginEventLoop() { timeout = 0 }
    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true; lock.unlock(); connection.cancel()
    }
    deinit { close() }
}

final class CameraLiveStream {
    private let channel: CameraByteChannel
    private var chunked = false
    private var chunkRemaining = 0

    init(host: String, url: URL) throws {
        let validated = try CameraWire.liveURL(url.absoluteString, camera: host)
        let channel = try CameraTCPChannel(host: host, port: UInt16(validated.port!), timeout: 5)
        self.channel = channel
        do {
            let components = URLComponents(url: validated, resolvingAgainstBaseURL: false)!
            let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            let request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(validated.port!)\r\nAccept: */*\r\nConnection: close\r\n\r\n"
            try channel.write(Data(request.utf8))
            let status = try line(limit: 4096)
            let parts = status.split(separator: " ")
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1] == "200" else {
                throw CameraProtocolError.unsupported("Camera live-view HTTP response rejected")
            }
            var count = status.utf8.count
            while true {
                let header = try line(limit: 4096); count += header.utf8.count + 2
                guard count <= 16384 else { throw CameraProtocolError.invalid("Live-view headers exceed budget") }
                if header.isEmpty { break }
                let pair = header.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { throw CameraProtocolError.invalid("Invalid live-view header") }
                let name = pair[0].lowercased(), value = pair[1].trimmingCharacters(in: .whitespaces).lowercased()
                if name == "transfer-encoding" {
                    guard value == "chunked" else { throw CameraProtocolError.unsupported("Unsupported live-view transfer encoding") }
                    chunked = true
                }
                if name == "content-encoding", value != "identity" { throw CameraProtocolError.unsupported("Compressed live-view stream is unsupported") }
            }
        } catch { channel.close(); throw error }
    }
    private func line(limit: Int) throws -> String {
        var bytes = Data()
        for _ in 0..<limit {
            bytes.append(try channel.read(1))
            if bytes.suffix(2) == Data([13, 10]) {
                guard let line = String(data: bytes.dropLast(2), encoding: .ascii) else { throw CameraProtocolError.invalid("Invalid HTTP header text") }
                return line
            }
        }
        throw CameraProtocolError.invalid("HTTP line exceeds budget")
    }
    private func body(_ count: Int) throws -> Data {
        if !chunked { return try channel.read(count) }
        var result = Data()
        while result.count < count {
            if chunkRemaining == 0 {
                let size = try line(limit: 128).split(separator: ";", maxSplits: 1).first ?? ""
                guard let length = Int(size, radix: 16), length > 0, length <= CameraWire.dataLimit else { throw CameraProtocolError.disconnected }
                chunkRemaining = length
            }
            let size = min(count - result.count, chunkRemaining)
            result.append(try channel.read(size)); chunkRemaining -= size
            if chunkRemaining == 0, try channel.read(2) != Data([13, 10]) { throw CameraProtocolError.invalid("Invalid HTTP chunk ending") }
        }
        return result
    }
    func frame() throws -> Data {
        var reader = CameraDataReader(try body(16)), fields: [UInt32] = []
        for _ in 0..<4 { fields.append(try reader.u32()) }
        let bounds = try CameraWire.liveFrameBounds(fields)
        let bytes = try body(bounds.size)
        let image = bytes.subdata(in: bounds.image)
        guard image.starts(with: [0xff, 0xd8]) else { throw CameraProtocolError.invalid("Live-view frame is not JPEG") }
        return image
    }
    func close() { channel.close() }
    deinit { close() }
}
