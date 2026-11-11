import Foundation

enum CameraProtocolError: Error, LocalizedError {
    case invalid(String), unsupported(String), response(UInt16, UInt16)
    case disconnected, cancelled, timeout, jpegProcessing
    case captureNotSent(String), captureUnknown, tetherRecoveryRequired

    var errorDescription: String? {
        switch self {
        case .invalid(let detail), .unsupported(let detail), .captureNotSent(let detail): return detail
        case .response(let operation, let code): return String(format: "PTP 0x%04X → 0x%04X", operation, code)
        case .disconnected: return "Camera connection closed"
        case .cancelled: return "Camera operation cancelled"
        case .timeout: return "Camera operation timed out"
        case .jpegProcessing: return "Could not process the camera JPEG with the selected settings"
        case .captureUnknown: return "Shutter result is unknown; check the camera"
        case .tetherRecoveryRequired: return "Cannot verify the previous camera-card baseline; select originals manually or start a new session"
        }
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

struct CameraDataReader {
    private let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = Data(data) }
    var remaining: Int { data.count - offset }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw CameraProtocolError.invalid("Truncated camera data") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func skip(_ count: Int) throws { _ = try take(count) }
    private mutating func unsigned(_ size: Int) throws -> UInt64 {
        let bytes = try take(size)
        return bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    mutating func u8() throws -> UInt8 { UInt8(try unsigned(1)) }
    mutating func u16() throws -> UInt16 { UInt16(try unsigned(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try unsigned(4)) }
    mutating func u64() throws -> UInt64 { try unsigned(8) }
    mutating func string(terminated: Bool = true) throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var bytes = try take(count * 2)
        if bytes.suffix(2) == Data([0, 0]) { bytes.removeLast(2) }
        else if terminated { throw CameraProtocolError.invalid("Unterminated PTP string") }
        guard let value = String(data: bytes, encoding: .utf16LittleEndian), !value.contains("\0") else {
            throw CameraProtocolError.invalid("Invalid PTP string")
        }
        return value
    }
    mutating func u16Array() throws -> Set<UInt16> {
        let count = Int(try u32())
        guard count <= 4096, count * 2 <= remaining else { throw CameraProtocolError.invalid("PTP array exceeds budget") }
        var result: Set<UInt16> = []
        for _ in 0..<count { result.insert(try u16()) }
        return result
    }
}

struct CameraDeviceIdentity: Codable, Equatable {
    let manufacturer: String, model: String, firmware: String, serial: String
    let operations: Set<UInt16>
    var stableKey: String { [manufacturer, model, serial].joined(separator: "|") }
    var supportsMobileContents: Bool { operations.isSuperset(of: [0x923c, 0x923d]) }
    var supportsLegacyContents: Bool { operations.isSuperset(of: [0x1002, 0x9201, 0x9202, 0x9209, 0x9212, 0x1004, 0x1007, 0x1008, 0x1009]) }
    var usesLegacyCardSetting: Bool { model == "ZV-E10" }
}

struct CameraAssetSnapshot: Codable, Hashable {
    let content: UInt32, file: UInt32, storage: UInt32, format: UInt16
    let name: String, size: UInt64, created: String, modified: String
    var kind: String { name.lowercased().hasSuffix(".arw") ? "RAW" : "JPEG" }
    var key: String { "\(storage):\(content):\(file):\(format):\(name):\(size):\(created):\(modified)" }
    var transferable: Bool { size > 0 && size <= 1 << 30 }
}
struct CameraRemoteAsset: Identifiable, Hashable {
    let owner: UUID
    let snapshot: CameraAssetSnapshot
    var id: String { "\(owner.uuidString):\(snapshot.key)" }
}
enum CameraPropertyValue: Equatable {
    case number(Int64), text(String), opaque
}
struct CameraProperty: Equatable, Identifiable {
    let code: UInt16, type: UInt16
    let writable: Bool
    let enabled: UInt8
    let current: CameraPropertyValue
    let form: UInt8
    let minimum: Int64?, maximum: Int64?, step: Int64?
    let choices: [Int64]
    var id: UInt16 { code }
    var number: Int64? { if case .number(let value) = current { return value }; return nil }
    var text: String? { if case .text(let value) = current { return value }; return nil }
    func accepts(_ value: Int64) -> Bool {
        guard writable, enabled == 1 else { return false }
        switch type {
        case 3: guard (-32768...32767).contains(value) else { return false }
        case 4: guard (0...65535).contains(value) else { return false }
        case 6: guard (0...Int64(UInt32.max)).contains(value) else { return false }
        default: return false
        }
        if form == 2 { return choices.contains(value) }
        guard form == 1, let minimum, let maximum, let step, step > 0,
              value >= minimum, value <= maximum else { return false }
        return (value - minimum) % step == 0
    }
    var selectableValues: [Int64] {
        if form == 2 { return Array(Set(choices)).sorted().filter(accepts) }
        guard [UInt16(3), 4, 6].contains(type), form == 1, let minimum, let maximum, let step,
              minimum >= -32768, maximum <= Int64(UInt32.max), step > 0, step <= Int64(UInt32.max),
              maximum >= minimum, (maximum - minimum) / step <= 512 else { return [] }
        return stride(from: minimum, through: maximum, by: Int(step)).filter(accepts)
    }
}

enum CameraWire {
    static let dataLimit = 8 << 20
    static func packet(_ type: UInt32, _ payload: Data) -> Data {
        var data = Data(); data.appendLE(UInt32(payload.count + 8)); data.appendLE(type); data.append(payload)
        return data
    }
    static func wifiCredential(_ bytes: Data, password: Bool) throws -> String {
        guard bytes.count >= 4, Int(bytes[0]) == bytes.count - 1 else { throw CameraProtocolError.invalid("Invalid Wi-Fi credential length") }
        var value = Data(bytes.dropFirst(3))
        while value.last == 0 { value.removeLast() }
        let range = password ? 8...63 : 1...32
        guard range.contains(value.count), value.allSatisfy({ (32...126).contains($0) }),
              let text = String(data: value, encoding: .ascii) else { throw CameraProtocolError.invalid("Invalid Wi-Fi credential") }
        return text
    }
    static func device(_ bytes: Data) throws -> CameraDeviceIdentity {
        var reader = CameraDataReader(bytes)
        _ = try reader.u16(); let vendor = try reader.u32()
        _ = try reader.u16(); _ = try reader.string(); _ = try reader.u16()
        let operations = try reader.u16Array()
        for _ in 0..<4 { _ = try reader.u16Array() }
        let device = try CameraDeviceIdentity(manufacturer: reader.string(), model: reader.string(),
            firmware: reader.string(), serial: reader.string(), operations: operations)
        guard vendor == 17, device.manufacturer.lowercased().contains("sony"),
              !device.model.isEmpty, !device.firmware.isEmpty else { throw CameraProtocolError.unsupported("Not a Sony PTP camera") }
        return device
    }
    static func photoName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".arw") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
    }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
    static func validateHeader(name: String, data: Data) throws {
        let tiff = data.starts(with: [0x49, 0x49, 0x2a, 0]) || data.starts(with: [0x4d, 0x4d, 0, 0x2a])
        let jpeg = data.starts(with: [0xff, 0xd8, 0xff])
        guard name.lowercased().hasSuffix(".arw") ? tiff : photoName(name) && jpeg else {
            throw CameraProtocolError.invalid("Original RAW/JPEG header does not match its name")
        }
    }
    static func mobilePage(_ bytes: Data, owner: UUID) throws -> (count: Int, cursor: UInt64, assets: [CameraRemoteAsset]) {
        var reader = CameraDataReader(bytes)
        try reader.skip(144)
        let count = Int(try reader.u32())
        guard count <= 100 else { throw CameraProtocolError.invalid("Camera page exceeds budget") }
        var cursor: UInt64 = 0, assets: [CameraRemoteAsset] = []
        for _ in 0..<count {
            _ = try reader.u32(); let content = try reader.u32(); try reader.skip(20)
            cursor = try reader.u64(); try reader.skip(36)
            let marks = Int(try reader.u32())
            guard marks <= 1 << 20 else { throw CameraProtocolError.invalid("Shot marks exceed budget") }
            try reader.skip(marks)
            let files = Int(try reader.u32())
            guard files <= 32 else { throw CameraProtocolError.invalid("Camera representations exceed budget") }
            for _ in 0..<files {
                let file = try reader.u32(), length = Int(try reader.u32())
                guard file <= 65535, (1...4096).contains(length) else { throw CameraProtocolError.invalid("Invalid camera path length") }
                let path = try reader.take(length)
                guard path.last == 0, let full = String(data: path.dropLast(), encoding: .utf8) else {
                    throw CameraProtocolError.invalid("Invalid camera path")
                }
                let name = full.components(separatedBy: "/").last ?? ""
                guard validName(name) else { throw CameraProtocolError.invalid("Invalid camera filename") }
                _ = try reader.u32(); let size = try reader.u64(); try reader.skip(32)
                if try reader.u32() != 0 { try reader.skip(8) }
                let video = try reader.u32() != 0
                if video { try reader.skip(76) }
                let audio = try reader.u32() != 0
                if audio { try reader.skip(16) }
                if !video, !audio, size > 0, photoName(name) {
                    assets.append(CameraRemoteAsset(owner: owner, snapshot: CameraAssetSnapshot(content: content,
                        file: file, storage: 0, format: 0, name: name, size: size, created: String(cursor), modified: "")))
                }
            }
        }
        guard reader.remaining == 0 else { throw CameraProtocolError.invalid("Trailing camera page bytes") }
        return (count, cursor, assets)
    }
    static func legacyObject(_ handle: UInt32, bytes: Data, owner: UUID) throws -> CameraRemoteAsset {
        var reader = CameraDataReader(bytes)
        let storage = try reader.u32(), format = try reader.u16()
        _ = try reader.u16(); let size = UInt64(try reader.u32()); try reader.skip(40)
        let name = try reader.string(), created = try reader.string(), modified = try reader.string()
        _ = try reader.string()
        guard reader.remaining == 0, validName(name) else { throw CameraProtocolError.invalid("Invalid legacy object metadata") }
        return CameraRemoteAsset(owner: owner, snapshot: CameraAssetSnapshot(content: handle, file: 0,
            storage: storage, format: format, name: name, size: size, created: created, modified: modified))
    }
    static func properties(_ bytes: Data, enumTables: Int) throws -> [UInt16: CameraProperty] {
        guard enumTables == 1 || enumTables == 2 else { throw CameraProtocolError.invalid("Unknown Sony property version") }
        var reader = CameraDataReader(bytes)
        let count = try reader.u64()
        guard count <= 4096 else { throw CameraProtocolError.invalid("Property count exceeds budget") }
        var output: [UInt16: CameraProperty] = [:], enumCount = 0
        for _ in 0..<count {
            let code = try reader.u16(), type = try reader.u16(), writable = try reader.u8(), enabled = try reader.u8()
            _ = try propertyValue(&reader, type: type); let current = try propertyValue(&reader, type: type)
            let form = try reader.u8()
            var minimum: Int64?, maximum: Int64?, step: Int64?, choices: [Int64] = []
            if form == 1 {
                let low = try propertyValue(&reader, type: type), high = try propertyValue(&reader, type: type),
                    increment = try propertyValue(&reader, type: type)
                if case .number(let a) = low, case .number(let b) = high, case .number(let c) = increment {
                    minimum = a; maximum = b; step = c
                }
            } else if form == 2 {
                for table in 0..<enumTables {
                    let size = Int(try reader.u16()); enumCount += size
                    guard size <= 4096, enumCount <= 65536 else { throw CameraProtocolError.invalid("Property choices exceed budget") }
                    for _ in 0..<size {
                        let value = try propertyValue(&reader, type: type)
                        if table == 0, case .number(let number) = value { choices.append(number) }
                    }
                }
            } else if form != 0 { throw CameraProtocolError.invalid("Unknown property form") }
            guard output[code] == nil else { throw CameraProtocolError.invalid("Duplicate camera property") }
            output[code] = CameraProperty(code: code, type: type, writable: writable == 1, enabled: enabled,
                current: current, form: form, minimum: minimum, maximum: maximum, step: step, choices: choices)
        }
        guard reader.remaining == 0 else { throw CameraProtocolError.invalid("Trailing camera properties") }
        return output
    }
    private static func propertyValue(_ reader: inout CameraDataReader, type: UInt16) throws -> CameraPropertyValue {
        if type == 0xffff { return .text(try reader.string(terminated: false)) }
        if type & 0x4000 != 0 {
            let count = try reader.u32(), scalar = type & ~UInt16(0x4000)
            guard count <= 4096, (1...10).contains(scalar) else { throw CameraProtocolError.invalid("Property array exceeds budget") }
            for _ in 0..<count { _ = try propertyValue(&reader, type: scalar) }
            return .opaque
        }
        switch type {
        case 1: return .number(Int64(Int8(bitPattern: try reader.u8())))
        case 2: return .number(Int64(try reader.u8()))
        case 3: return .number(Int64(Int16(bitPattern: try reader.u16())))
        case 4: return .number(Int64(try reader.u16()))
        case 5: return .number(Int64(Int32(bitPattern: try reader.u32())))
        case 6: return .number(Int64(try reader.u32()))
        case 7, 8: return .number(Int64(bitPattern: try reader.u64()))
        case 9, 10: try reader.skip(16); return .opaque
        default: throw CameraProtocolError.invalid("Unknown camera property type")
        }
    }
    static func liveURL(_ raw: String, camera: String) throws -> URL {
        guard var url = URLComponents(string: raw), url.scheme == "http", let host = url.host,
              host == "localhost" || host == camera, let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.fragment == nil, url.percentEncodedPath == "/liveviewstream" else {
            throw CameraProtocolError.unsupported("Unsupported live-view endpoint")
        }
        url.host = camera
        guard let result = url.url else { throw CameraProtocolError.invalid("Invalid live-view endpoint") }
        return result
    }
    static func liveFrameBounds(_ fields: [UInt32]) throws -> (size: Int, image: Range<Int>) {
        guard fields.count == 4 else { throw CameraProtocolError.invalid("Invalid frame header") }
        let image = UInt64(fields[0]), length = UInt64(fields[1]), metadata = UInt64(fields[2]), metadataLength = UInt64(fields[3])
        let imageEnd = image + length, metadataEnd = metadata + metadataLength
        let total = max(imageEnd, metadataLength == 0 ? 16 : metadataEnd)
        guard image >= 16, length >= 4, total <= dataLimit,
              metadataLength == 0 || (metadata >= 16 && !(image < metadataEnd && metadata < imageEnd)) else {
            throw CameraProtocolError.invalid("Invalid live-view frame bounds")
        }
        return (Int(total - 16), Int(image - 16)..<Int(imageEnd - 16))
    }
}
