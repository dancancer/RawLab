import Foundation

enum CameraFocusUnavailableReason: Error, Equatable {
    case manualFocus
    case focusAreaFixed
    case unsupported
}

enum CameraFocusPointTarget: Equatable {
    case remoteTouch
    case afAreaPosition
    var controlCode: UInt16 { self == .remoteTouch ? 0xd2e4 : 0xd2dc }
}

enum CameraLiveViewFrameKind: Equatable {
    case focus
    case face
    case tracking

    var cKind: sony2fuji_sony_live_view_frame_kind {
        switch self {
        case .focus: return SONY2FUJI_SONY_LIVE_FRAME_FOCUS
        case .face: return SONY2FUJI_SONY_LIVE_FRAME_FACE
        case .tracking: return SONY2FUJI_SONY_LIVE_FRAME_TRACKING
        }
    }

    init(cKind: sony2fuji_sony_live_view_frame_kind) {
        switch cKind {
        case SONY2FUJI_SONY_LIVE_FRAME_FACE: self = .face
        case SONY2FUJI_SONY_LIVE_FRAME_TRACKING: self = .tracking
        default: self = .focus
        }
    }
}

struct CameraLiveViewFrame: Equatable {
    let kind: CameraLiveViewFrameKind
    let cx: Double
    let cy: Double
    let width: Double
    let height: Double
    let focused: Bool

    var cFrame: sony2fuji_sony_live_view_frame {
        sony2fuji_sony_live_view_frame(
            kind: kind.cKind,
            focused: focused ? 1 : 0,
            cx: cx,
            cy: cy,
            width: width,
            height: height
        )
    }
}

struct CameraOverlayBox: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let isNormalizedSquare: Bool
}

struct CameraFocusTapPoint: Equatable {
    let u: Double
    let v: Double
    let x: Int
    let y: Int
    var packed: UInt32 { (UInt32(x) << 16) | UInt32(y) }
}

enum CameraProtocolError: Error, LocalizedError, Equatable {
    case invalid(String), invalidOriginalHeader, transientTransfer(String), unsupported(String), response(UInt16, UInt16)
    case disconnected, cancelled, timeout, localNetworkDenied, connectionRefused, jpegProcessing, jpegGainMapAdjustment, importRecoveryRequired
    case sshAuthenticationFailed, sshFingerprintMismatch(expected: String, actual: String, keyType: String), sshUnsupportedAuthMethod
    case captureNotSent(String), captureUnknown, tetherRecoveryRequired
    case photoLimitExceeded, photoLibraryDenied, photoLibrarySaveFailed, itemFailed(String, String)
    case focusUnavailable(CameraFocusUnavailableReason), focusRejected

    var errorDescription: String? {
        switch self {
        case .invalid(let detail), .transientTransfer(let detail), .unsupported(let detail), .captureNotSent(let detail):
            return detail
        case .invalidOriginalHeader:
            return "Original RAW/JPEG header does not match its name"
        case .response(let operation, let code): return String(format: "PTP 0x%04X → 0x%04X", operation, code)
        case .disconnected: return "Camera connection closed"
        case .cancelled: return "Camera operation cancelled"
        case .timeout: return "Camera operation timed out"
        case .localNetworkDenied: return "Local network access is denied"
        case .connectionRefused: return "Camera endpoint refused connection"
        case .sshAuthenticationFailed: return "Camera access authentication failed"
        case .sshFingerprintMismatch: return "Camera SSH key fingerprint changed"
        case .sshUnsupportedAuthMethod: return "Camera requires an SSH authentication method unsupported on iOS"
        case .jpegProcessing: return "Could not process the camera JPEG with the selected settings"
        case .jpegGainMapAdjustment: return "JPEG adjustment would discard HDR gain-map metadata"
        case .importRecoveryRequired: return "Cannot verify the camera original; select it again"
        case .captureUnknown: return "Shutter result is unknown; check the camera"
        case .tetherRecoveryRequired: return "Cannot verify the previous camera-card baseline; select originals manually or start a new session"
        case .photoLimitExceeded: return "Camera card exceeds the photo listing limit"
        case .photoLibraryDenied: return "Photo library add permission is denied"
        case .photoLibrarySaveFailed: return "Could not save some imported photos to the photo library"
        case .itemFailed(_, let detail): return detail
        case .focusUnavailable(.manualFocus): return "Manual focus is active"
        case .focusUnavailable(.focusAreaFixed): return "Focus area cannot move in the current mode"
        case .focusUnavailable(.unsupported): return "Remote focus point selection is unavailable"
        case .focusRejected: return "Camera rejected the focus point request"
        }
    }

    var isNonFatalFocusError: Bool {
        switch self {
        case .focusUnavailable, .focusRejected: return true
        default: return false
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
    let slot: UInt32

    init(content: UInt32, file: UInt32, storage: UInt32, format: UInt16,
         name: String, size: UInt64, created: String, modified: String, slot: UInt32 = 1) {
        self.content = content
        self.file = file
        self.storage = storage
        self.format = format
        self.name = name
        self.size = size
        self.created = created
        self.modified = modified
        self.slot = slot == 2 ? 2 : 1
    }

    enum CodingKeys: String, CodingKey {
        case content, file, storage, format, name, size, created, modified, slot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(UInt32.self, forKey: .content)
        file = try container.decode(UInt32.self, forKey: .file)
        storage = try container.decode(UInt32.self, forKey: .storage)
        format = try container.decode(UInt16.self, forKey: .format)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decode(UInt64.self, forKey: .size)
        created = try container.decode(String.self, forKey: .created)
        modified = try container.decode(String.self, forKey: .modified)
        let decodedSlot = try container.decodeIfPresent(UInt32.self, forKey: .slot) ?? 1
        slot = decodedSlot == 2 ? 2 : 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content, forKey: .content)
        try container.encode(file, forKey: .file)
        try container.encode(storage, forKey: .storage)
        try container.encode(format, forKey: .format)
        try container.encode(name, forKey: .name)
        try container.encode(size, forKey: .size)
        try container.encode(created, forKey: .created)
        try container.encode(modified, forKey: .modified)
        if effectiveSlot != 1 {
            try container.encode(effectiveSlot, forKey: .slot)
        }
    }

    var effectiveSlot: UInt32 { slot == 2 ? 2 : 1 }
    var kind: String { name.lowercased().hasSuffix(".arw") ? "RAW" : "JPEG" }
    var key: String {
        let base = "\(storage):\(content):\(file):\(format):\(name):\(size):\(created):\(modified)"
        return effectiveSlot == 1 ? base : "slot\(effectiveSlot):\(base)"
    }
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
    private var cInfo: sony2fuji_sony_property_info {
        sony2fuji_sony_property_info(
            code: code,
            type: type,
            writable: writable ? 1 : 0,
            enabled: enabled,
            form: form,
            reserved0: 0,
            value_kind: {
                switch current {
                case .number: return SONY2FUJI_SONY_PROP_NUMBER
                case .text: return SONY2FUJI_SONY_PROP_TEXT
                case .opaque: return SONY2FUJI_SONY_PROP_OPAQUE
                }
            }(),
            number_value: number ?? 0,
            has_range: (form == 1 && minimum != nil && maximum != nil && step != nil) ? 1 : 0,
            choice_count: UInt32(choices.count),
            minimum: minimum ?? 0,
            maximum: maximum ?? 0,
            step: step ?? 0
        )
    }
    func accepts(_ value: Int64) -> Bool {
        var info = cInfo
        return choices.withUnsafeBufferPointer { buf in
            sony2fuji_sony_property_accepts(&info, buf.baseAddress, UInt32(buf.count), value) != 0
        }
    }
    var selectableValues: [Int64] {
        var info = cInfo
        return choices.withUnsafeBufferPointer { buf in
            var count: UInt32 = 0
            guard sony2fuji_sony_property_options(
                &info, buf.baseAddress, UInt32(buf.count),
                1, 1, 513, nil, 0, &count
            ) == SONY2FUJI_STATUS_OK, count > 0 else {
                return []
            }
            var out = [Int64](repeating: 0, count: Int(count))
            let status = out.withUnsafeMutableBufferPointer { outBuf in
                sony2fuji_sony_property_options(
                    &info, buf.baseAddress, UInt32(buf.count),
                    1, 1, 513, outBuf.baseAddress, count, &count
                )
            }
            return status == SONY2FUJI_STATUS_OK ? Array(out.prefix(Int(count))) : []
        }
    }
}

enum CameraWire {
    static let dataLimit = Int(SONY2FUJI_SONY_PTPIP_DATA_LIMIT)
    static let slotDatesLimit = Int(SONY2FUJI_SONY_SLOT_DATES_LIMIT)

    static func packet(_ type: UInt32, _ payload: Data) -> Data {
        var data = Data()
        data.appendLE(UInt32(payload.count + 8))
        data.appendLE(type)
        data.append(payload)
        return data
    }

    static func wifiCredential(_ bytes: Data, password: Bool) throws -> String {
        let raw = Array(bytes)
        var outLen = 0
        let sizeStatus = raw.withUnsafeBufferPointer { buf in
            sony2fuji_sony_parse_wifi_credential(buf.baseAddress, buf.count, password ? 1 : 0, nil, 0, &outLen)
        }
        guard sizeStatus == SONY2FUJI_STATUS_OK else {
            throw CameraProtocolError.invalid("Invalid Wi-Fi credential")
        }
        var outBuf = [CChar](repeating: 0, count: outLen + 1)
        let status = raw.withUnsafeBufferPointer { buf in
            sony2fuji_sony_parse_wifi_credential(
                buf.baseAddress, buf.count, password ? 1 : 0, &outBuf, outBuf.count, &outLen
            )
        }
        guard status == SONY2FUJI_STATUS_OK else {
            throw CameraProtocolError.invalid("Invalid Wi-Fi credential")
        }
        return String(cString: outBuf)
    }
    static func slotDateCount(_ bytes: Data) throws -> UInt32 {
        let raw = Array(bytes)
        var count: UInt32 = 0
        let status = raw.withUnsafeBufferPointer { buf in
            sony2fuji_sony_parse_slot_photo_count(buf.baseAddress, buf.count, &count)
        }
        guard status == SONY2FUJI_STATUS_OK else {
            throw CameraProtocolError.invalid("Invalid camera slot photo count")
        }
        return count
    }

    static func device(_ bytes: Data) throws -> CameraDeviceIdentity {
        let raw = Array(bytes)
        var ptr: OpaquePointer?
        let status = raw.withUnsafeBufferPointer { buf in
            sony2fuji_sony_parse_device_info(buf.baseAddress, buf.count, &ptr)
        }
        if status == SONY2FUJI_STATUS_UNSUPPORTED {
            throw CameraProtocolError.unsupported("Not a Sony PTP camera")
        }
        guard status == SONY2FUJI_STATUS_OK, let ptr else {
            throw CameraProtocolError.invalid("Truncated camera device info")
        }
        defer { sony2fuji_sony_device_info_free(ptr) }
        var opCount: UInt32 = 0
        guard sony2fuji_sony_device_info_operations(ptr, nil, 0, &opCount) == SONY2FUJI_STATUS_OK else {
            throw CameraProtocolError.invalid("Invalid camera device operations")
        }
        var ops = [UInt16](repeating: 0, count: Int(opCount))
        if opCount > 0 {
            guard ops.withUnsafeMutableBufferPointer({ buf in
                sony2fuji_sony_device_info_operations(ptr, buf.baseAddress, opCount, &opCount)
            }) == SONY2FUJI_STATUS_OK else {
                throw CameraProtocolError.invalid("Invalid camera device operations")
            }
        }
        return CameraDeviceIdentity(
            manufacturer: String(cString: sony2fuji_sony_device_info_manufacturer(ptr)),
            model: String(cString: sony2fuji_sony_device_info_model(ptr)),
            firmware: String(cString: sony2fuji_sony_device_info_firmware(ptr)),
            serial: String(cString: sony2fuji_sony_device_info_serial(ptr)),
            operations: Set(ops.prefix(Int(opCount)))
        )
    }

    static func photoName(_ name: String) -> Bool {
        name.withCString { sony2fuji_sony_is_photo_filename($0) != 0 }
    }

    static func validName(_ name: String) -> Bool {
        name.withCString { sony2fuji_sony_is_valid_photo_filename($0) != 0 }
    }

    static func validateHeader(name: String, data: Data) throws {
        let raw = Array(data)
        let ok = name.withCString { cName in
            raw.withUnsafeBufferPointer { buf in
                sony2fuji_sony_validate_photo_header(cName, buf.baseAddress, buf.count) != 0
            }
        }
        guard ok else { throw CameraProtocolError.invalidOriginalHeader }
    }

    static func mobilePage(_ bytes: Data, owner: UUID, slot: UInt32 = 1) throws -> (count: Int, cursor: UInt64, assets: [CameraRemoteAsset]) {
        let raw = Array(bytes)
        var ptr: OpaquePointer?
        let status = raw.withUnsafeBufferPointer { buf in
            sony2fuji_sony_parse_mobile_page(buf.baseAddress, buf.count, &ptr)
        }
        guard status == SONY2FUJI_STATUS_OK, let ptr else {
            throw CameraProtocolError.invalid("Invalid camera page")
        }
        defer { sony2fuji_sony_mobile_page_free(ptr) }
        let entryCount = Int(sony2fuji_sony_mobile_page_entry_count(ptr))
        let cursor = sony2fuji_sony_mobile_page_cursor(ptr)
        let assetCount = sony2fuji_sony_mobile_page_asset_count(ptr)
        var assets: [CameraRemoteAsset] = []
        assets.reserveCapacity(Int(assetCount))
        let normalizedSlot: UInt32 = slot == 2 ? 2 : 1
        for idx in 0..<assetCount {
            var info = sony2fuji_sony_mobile_asset_info()
            var cName: UnsafePointer<CChar>?
            guard sony2fuji_sony_mobile_page_asset_at(ptr, idx, &info, &cName) == SONY2FUJI_STATUS_OK,
                  let cName else {
                throw CameraProtocolError.invalid("Invalid camera page asset")
            }
            assets.append(CameraRemoteAsset(
                owner: owner,
                snapshot: CameraAssetSnapshot(
                    content: info.content,
                    file: info.file,
                    storage: 0,
                    format: 0,
                    name: String(cString: cName),
                    size: info.size,
                    created: String(info.created),
                    modified: "",
                    slot: normalizedSlot
                )
            ))
        }
        return (entryCount, cursor, assets)
    }

    static func legacyObject(_ handle: UInt32, bytes: Data, owner: UUID) throws -> CameraRemoteAsset {
        let raw = Array(bytes)
        var ptr: OpaquePointer?
        let status = raw.withUnsafeBufferPointer { buf in
            sony2fuji_sony_parse_legacy_object(buf.baseAddress, buf.count, &ptr)
        }
        guard status == SONY2FUJI_STATUS_OK, let ptr else {
            throw CameraProtocolError.invalid("Invalid legacy object metadata")
        }
        defer { sony2fuji_sony_legacy_object_free(ptr) }
        var info = sony2fuji_sony_legacy_object_info()
        var cName: UnsafePointer<CChar>?
        var cCreated: UnsafePointer<CChar>?
        var cModified: UnsafePointer<CChar>?
        guard sony2fuji_sony_legacy_object_get(ptr, &info, &cName, &cCreated, &cModified) == SONY2FUJI_STATUS_OK,
              let cName, let cCreated, let cModified else {
            throw CameraProtocolError.invalid("Invalid legacy object metadata")
        }
        return CameraRemoteAsset(
            owner: owner,
            snapshot: CameraAssetSnapshot(
                content: handle,
                file: 0,
                storage: info.storage,
                format: info.format,
                name: String(cString: cName),
                size: info.size,
                created: String(cString: cCreated),
                modified: String(cString: cModified)
            )
        )
    }

    static func properties(_ bytes: Data, enumTables: Int) throws -> [UInt16: CameraProperty] {
        let raw = Array(bytes)
        var ptr: OpaquePointer?
        let status = raw.withUnsafeBufferPointer { buf in
            sony2fuji_sony_parse_properties(buf.baseAddress, buf.count, Int32(enumTables), &ptr)
        }
        guard status == SONY2FUJI_STATUS_OK, let ptr else {
            throw CameraProtocolError.invalid("Invalid camera properties")
        }
        defer { sony2fuji_sony_property_table_free(ptr) }
        let count = sony2fuji_sony_property_table_count(ptr)
        var output: [UInt16: CameraProperty] = [:]
        output.reserveCapacity(Int(count))
        for idx in 0..<count {
            var info = sony2fuji_sony_property_info()
            guard sony2fuji_sony_property_table_get_at(ptr, idx, &info) == SONY2FUJI_STATUS_OK else {
                throw CameraProtocolError.invalid("Invalid camera property entry")
            }
            let current: CameraPropertyValue
            switch info.value_kind {
            case SONY2FUJI_SONY_PROP_NUMBER:
                current = .number(info.number_value)
            case SONY2FUJI_SONY_PROP_TEXT:
                current = .text(String(cString: sony2fuji_sony_property_table_text_at(ptr, idx)))
            default:
                current = .opaque
            }
            var choices: [Int64] = []
            if info.choice_count > 0 {
                var cCount = info.choice_count
                var buf = [Int64](repeating: 0, count: Int(cCount))
                guard buf.withUnsafeMutableBufferPointer({ outBuf in
                    sony2fuji_sony_property_table_choices_at(ptr, idx, outBuf.baseAddress, cCount, &cCount)
                }) == SONY2FUJI_STATUS_OK else {
                    throw CameraProtocolError.invalid("Invalid camera property choices")
                }
                choices = Array(buf.prefix(Int(cCount)))
            }
            output[info.code] = CameraProperty(
                code: info.code,
                type: info.type,
                writable: info.writable != 0,
                enabled: info.enabled,
                current: current,
                form: info.form,
                minimum: info.has_range != 0 ? info.minimum : nil,
                maximum: info.has_range != 0 ? info.maximum : nil,
                step: info.has_range != 0 ? info.step : nil,
                choices: choices
            )
        }
        return output
    }

    static func withPropertyTable<R>(_ properties: [UInt16: CameraProperty], _ body: (OpaquePointer) -> R) -> R {
        let numeric = properties.values.filter { $0.number != nil }
        var payload = Data()
        payload.appendLE(UInt64(numeric.count))
        for prop in numeric {
            let v = UInt64(bitPattern: prop.number ?? 0)
            payload.appendLE(prop.code)
            payload.appendLE(UInt16(8))
            payload.append(prop.writable ? 1 : 0)
            payload.append(prop.enabled)
            payload.appendLE(v)
            payload.appendLE(v)
            payload.append(0)
        }
        let raw = Array(payload)
        var ptr: OpaquePointer?
        let status = raw.withUnsafeBufferPointer { buf in
            sony2fuji_sony_parse_properties(buf.baseAddress, buf.count, 2, &ptr)
        }
        precondition(status == SONY2FUJI_STATUS_OK && ptr != nil)
        defer { sony2fuji_sony_property_table_free(ptr) }
        return body(ptr!)
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

    static func liveFrameBounds(_ fields: [UInt32]) throws -> (size: Int, image: Range<Int>, metadata: Range<Int>?) {
        guard fields.count == 4 else { throw CameraProtocolError.invalid("Invalid frame header") }
        var bounds = sony2fuji_sony_live_frame_bounds()
        let status = fields.withUnsafeBufferPointer { buf in
            sony2fuji_sony_parse_live_frame_bounds(buf.baseAddress, UInt64(SONY2FUJI_SONY_PTPIP_DATA_LIMIT), &bounds)
        }
        guard status == SONY2FUJI_STATUS_OK else {
            throw CameraProtocolError.invalid("Invalid live-view frame bounds")
        }
        let metaRange: Range<Int>? = bounds.has_metadata != 0
            ? Int(bounds.metadata_offset)..<Int(bounds.metadata_offset + bounds.metadata_length)
            : nil
        return (
            Int(bounds.body_size),
            Int(bounds.image_offset)..<Int(bounds.image_offset + bounds.image_length),
            metaRange
        )
    }

    static func liveViewFrames(_ rawMeta: Data) -> [CameraLiveViewFrame] {
        let raw = Array(rawMeta)
        var count: UInt32 = 0
        let sizeStatus = raw.withUnsafeBufferPointer { buf in
            sony2fuji_sony_parse_live_view_frames(buf.baseAddress, buf.count, nil, 0, &count)
        }
        guard sizeStatus == SONY2FUJI_STATUS_OK, count > 0 else { return [] }
        var frames = [sony2fuji_sony_live_view_frame](repeating: sony2fuji_sony_live_view_frame(), count: Int(count))
        let status = raw.withUnsafeBufferPointer { metaBuf in
            frames.withUnsafeMutableBufferPointer { outBuf in
                sony2fuji_sony_parse_live_view_frames(
                    metaBuf.baseAddress, metaBuf.count, outBuf.baseAddress, count, &count
                )
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { return [] }
        return frames.prefix(Int(count)).map {
            CameraLiveViewFrame(
                kind: CameraLiveViewFrameKind(cKind: $0.kind),
                cx: $0.cx,
                cy: $0.cy,
                width: $0.width,
                height: $0.height,
                focused: $0.focused != 0
            )
        }
    }

    static func focusPoint(tapX: Double, tapY: Double, containerWidth: Double, containerHeight: Double,
                           imageWidth: Double, imageHeight: Double) -> CameraFocusTapPoint? {
        var valid: Int32 = 0
        var tap = sony2fuji_sony_focus_tap_point()
        guard sony2fuji_sony_focus_point_from_tap(
            tapX, tapY, containerWidth, containerHeight, imageWidth, imageHeight, &valid, &tap
        ) == SONY2FUJI_STATUS_OK, valid != 0 else {
            return nil
        }
        return CameraFocusTapPoint(u: tap.u, v: tap.v, x: Int(tap.x), y: Int(tap.y))
    }

    static func focusOverlayBox(frame: CameraLiveViewFrame, left: Double, top: Double,
                                fittedWidth: Double, fittedHeight: Double) -> CameraOverlayBox {
        var cFrame = frame.cFrame
        var box = sony2fuji_sony_focus_overlay_box()
        _ = sony2fuji_sony_compute_focus_overlay_box(&cFrame, left, top, fittedWidth, fittedHeight, &box)
        return CameraOverlayBox(
            x: box.x,
            y: box.y,
            width: box.width,
            height: box.height,
            isNormalizedSquare: box.is_normalized_square != 0
        )
    }

    static func normalizedFocusSquareRatio(frame: CameraLiveViewFrame, imageWidth: Double, imageHeight: Double) -> Double? {
        var cFrame = frame.cFrame
        var valid: Int32 = 0
        var ratio: Double = 0
        guard sony2fuji_sony_normalized_focus_square_ratio(
            &cFrame, imageWidth, imageHeight, &valid, &ratio
        ) == SONY2FUJI_STATUS_OK, valid != 0 else {
            return nil
        }
        return ratio
    }

    static func tapFocusSide(fittedWidth: Double, fittedHeight: Double, lastSquareRatio: Double? = nil) -> Double {
        var side: Double = 34.0
        _ = sony2fuji_sony_tap_focus_side(
            fittedWidth,
            fittedHeight,
            34.0,
            52.0,
            20.0,
            lastSquareRatio != nil ? 1 : 0,
            lastSquareRatio ?? 0.0,
            &side
        )
        return side
    }
}

struct CameraWifiQrCredentials: Equatable {
    enum Format: Equatable {
        case sonyW01
        case standardWifi
    }

    let ssid: String
    let password: String
    let model: String?
    let format: Format
}

enum CameraWifiQrCode {
    private static let maxPayloadLength = 1024
    private static let allowedWifiSecurity: Set<String> = ["", "WPA", "WPA2", "WPA3", "SAE", "WPA/WPA2", "WPA2/WPA3"]

    static func parse(_ raw: String) -> CameraWifiQrCredentials? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxPayloadLength else { return nil }
        let upper = trimmed.uppercased()
        if upper.hasPrefix("W01:") {
            return parseSonyW01(String(trimmed.dropFirst(4)))
        }
        if upper.hasPrefix("WIFI:") {
            return parseStandardWifi(String(trimmed.dropFirst(5)))
        }
        return nil
    }

    private static func parseSonyW01(_ body: String) -> CameraWifiQrCredentials? {
        let fields = splitEscapedFields(body, unescapeColons: false)
        guard let rawSsid = fields["S"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSsid.isEmpty,
              let password = fields["P"] else { return nil }
        let modelField = fields["C"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = (modelField?.isEmpty == false) ? modelField : nil
        let ssid: String
        if !rawSsid.hasPrefix("DIRECT-"), let normalizedModel {
            ssid = "DIRECT-\(rawSsid):\(normalizedModel)"
        } else {
            ssid = rawSsid
        }
        guard isValidSsid(ssid), isValidPassphrase(password) else { return nil }
        return CameraWifiQrCredentials(
            ssid: ssid,
            password: password,
            model: normalizedModel ?? extractDirectModel(ssid),
            format: .sonyW01
        )
    }

    private static func parseStandardWifi(_ body: String) -> CameraWifiQrCredentials? {
        let fields = splitEscapedFields(body, unescapeColons: true)
        let security = fields["T"]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard allowedWifiSecurity.contains(security) else { return nil }
        guard let ssid = fields["S"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ssid.isEmpty,
              let password = fields["P"],
              isValidSsid(ssid),
              isValidPassphrase(password) else { return nil }
        return CameraWifiQrCredentials(
            ssid: ssid,
            password: password,
            model: extractDirectModel(ssid),
            format: .standardWifi
        )
    }

    private static func splitEscapedFields(_ body: String, unescapeColons: Bool) -> [String: String] {
        var result: [String: String] = [:]
        var token = ""
        let chars = Array(body)
        var index = 0
        func flushToken() {
            guard !token.isEmpty else { return }
            if let colon = token.firstIndex(of: ":"), colon > token.startIndex {
                let key = String(token[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let rawValue = String(token[token.index(after: colon)...])
                if !key.isEmpty, result[key] == nil {
                    result[key] = unescapeValue(rawValue, unescapeColons: unescapeColons)
                }
            }
            token.removeAll(keepingCapacity: true)
        }
        while index < chars.count {
            let ch = chars[index]
            if ch == "\\", index + 1 < chars.count {
                token.append(ch)
                token.append(chars[index + 1])
                index += 2
                continue
            }
            if ch == ";" {
                flushToken()
                index += 1
                continue
            }
            token.append(ch)
            index += 1
        }
        flushToken()
        return result
    }

    private static func unescapeValue(_ raw: String, unescapeColons: Bool) -> String {
        var out = ""
        let chars = Array(raw)
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                let shouldUnescape = next == "\\" || next == ";" ||
                    (unescapeColons && (next == ":" || next == "," || next == "\""))
                if shouldUnescape {
                    out.append(next)
                    index += 2
                    continue
                }
            }
            out.append(ch)
            index += 1
        }
        return out
    }

    static func isValidSsid(_ ssid: String) -> Bool {
        let count = ssid.utf8.count
        guard (1...32).contains(count) else { return false }
        return !ssid.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    static func isValidPassphrase(_ password: String) -> Bool {
        guard (8...63).contains(password.count) else { return false }
        return password.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value <= 126 }
    }

    private static func extractDirectModel(_ ssid: String) -> String? {
        guard ssid.hasPrefix("DIRECT-"), let colon = ssid.firstIndex(of: ":") else { return nil }
        let suffix = String(ssid[ssid.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }
}
