import Foundation
import CryptoKit

enum CameraSessionPurpose { case importing, tethering }
enum CameraContentsFamily { case mobile, legacy }

struct CameraFocusPointResult {
    let properties: [UInt16: CameraProperty]
    let focusLocked: Bool
}

final class SonyCameraSession {
    static let maximumListedAssets = 10_000
    static let maximumMobilePages = 1_000

    let id = UUID()
    let device: CameraDeviceIdentity
    let family: CameraContentsFamily?
    let purpose: CameraSessionPurpose
    let client: CameraPTPClient
    private(set) var controls: Set<UInt16> = []
    private(set) var enumTables = 2
    private(set) var remoteReady = false
    private(set) var contentsEntered = false
    private var remoteReadyAt: TimeInterval = 0
    private let stateLock = NSLock()
    private var stopping = false, capturing = false

    static func open(host: String, purpose: CameraSessionPurpose, clientID: UUID,
                     register: (CameraPTPClient) -> Void) throws -> SonyCameraSession {
        let command = try CameraTCPChannel(host: host)
        let event: CameraTCPChannel
        do { event = try CameraTCPChannel(host: host) }
        catch { command.close(); throw error }
        let client = CameraPTPClient(command: command, event: event)
        register(client)
        do {
            try client.initialize(clientID: clientID)
            return try SonyCameraSession(client: client, purpose: purpose)
        } catch { client.close(); throw error }
    }

    init(client: CameraPTPClient, purpose: CameraSessionPurpose) throws {
        self.client = client; self.purpose = purpose
        device = try CameraWire.device(client.operation(0x1001, requiresData: true, limit: 1 << 20))
        family = device.supportsMobileContents ? .mobile : device.supportsLegacyContents ? .legacy : nil
        do {
            guard device.operations.contains(0x1002) else { throw CameraProtocolError.unsupported("Camera session operation is unavailable") }
            _ = try client.operation(0x1002, parameters: [1])
            if purpose == .tethering || family == .legacy { try initializeRemote() }
            if purpose == .importing {
                guard family != nil else { throw CameraProtocolError.unsupported("Original photo browsing is unavailable in this camera mode") }
                if family == .legacy { try enterContents() }
            }
        } catch { client.close(); throw error }
    }

    var stopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopping || client.isClosed }
    func checkRunning() throws { if stopped { throw CameraProtocolError.cancelled } }
    func requestStop() {
        stateLock.lock(); stopping = true; let mayClose = !capturing; stateLock.unlock()
        if mayClose { client.close() }
    }
    func close() { requestStop() }
    func finish() {
        if contentsEntered, !client.isClosed { _ = try? client.operation(0x9212, parameters: [2, 0, 1]) }
        requestStop()
    }
    private func pause(_ duration: TimeInterval, allowStopped: Bool = false) throws {
        let until = ProcessInfo.processInfo.systemUptime + duration
        while ProcessInfo.processInfo.systemUptime < until {
            if !allowStopped { try checkRunning() }
            Thread.sleep(forTimeInterval: min(0.05, max(0, until - ProcessInfo.processInfo.systemUptime)))
        }
    }

    private func initializeRemote() throws {
        guard device.operations.isSuperset(of: [0x9201, 0x9202, 0x9209]) else {
            throw CameraProtocolError.unsupported("Remote shooting protocol is unavailable")
        }
        _ = try client.operation(0x9201, parameters: [1, 0, 0], limit: 65536)
        _ = try client.operation(0x9201, parameters: [2, 0, 0], limit: 65536)
        var initialized = false
        for _ in 0..<20 {
            try checkRunning()
            let bytes = try client.operation(0x9202, parameters: [0x12c, 1], requiresData: true, limit: 65536)
            if !bytes.isEmpty {
                var reader = CameraDataReader(bytes)
                let version = try reader.u16(), properties = try reader.u16Array()
                controls = try reader.u16Array()
                guard [UInt16(0x12c), 0xc8].contains(version), reader.remaining == 0 else {
                    throw CameraProtocolError.unsupported("Unsupported Sony remote descriptor version")
                }
                enumTables = version == 0x12c ? 2 : 1
                if !properties.isEmpty || !controls.isEmpty { initialized = true; break }
            }
            try pause(0.1)
        }
        guard initialized else { throw CameraProtocolError.timeout }
        _ = try client.operation(0x9201, parameters: [3, 0, 0], limit: 65536)
        remoteReady = true; remoteReadyAt = ProcessInfo.processInfo.systemUptime
        if purpose == .tethering, family == .legacy { try pause(3.5) }
    }

    private func storageIDs() throws -> [UInt32] {
        var reader = CameraDataReader(try client.operation(0x1004, requiresData: true, limit: 4096))
        let count = Int(try reader.u32())
        guard count <= 32, reader.remaining == count * 4 else { throw CameraProtocolError.invalid("Invalid camera storage list") }
        return try (0..<count).map { _ in try reader.u32() }
    }
    private func enterContents() throws {
        guard family == .legacy, remoteReady else { throw CameraProtocolError.unsupported("Legacy contents mode is unavailable") }
        try pause(max(0, 3.5 - (ProcessInfo.processInfo.systemUptime - remoteReadyAt)))
        _ = try client.operation(0x9212, parameters: [2, 1, 0])
        contentsEntered = true
        for _ in 0..<20 {
            if try !storageIDs().isEmpty { return }
            try pause(0.25)
        }
        throw CameraProtocolError.unsupported("Camera card is not available")
    }

    func listAssets() throws -> [CameraRemoteAsset] {
        try checkRunning()
        do {
            switch family {
            case .mobile:
                var cursor: UInt64 = 0, assets: [CameraRemoteAsset] = [], seen: Set<String> = []
                for _ in 0..<Self.maximumMobilePages {
                    try checkRunning()
                    let bytes = try client.operation(0x923c, parameters: [UInt32(truncatingIfNeeded: cursor), UInt32(cursor >> 32), 100, 1, 0],
                                                     requiresData: true, limit: CameraWire.dataLimit)
                    let page = try CameraWire.mobilePage(bytes, owner: id)
                    for asset in page.assets where seen.insert(asset.snapshot.key).inserted { assets.append(asset) }
                    guard assets.count <= Self.maximumListedAssets else { throw CameraProtocolError.photoLimitExceeded }
                    if page.count < 100 { return assets }
                    guard page.cursor > cursor else { throw CameraProtocolError.invalid("Camera page cursor did not advance") }
                    cursor = page.cursor
                }
                throw CameraProtocolError.photoLimitExceeded
            case .legacy:
                guard contentsEntered else { throw CameraProtocolError.unsupported("Open a separate card session before reading legacy contents") }
                var handles: Set<UInt32> = [], assets: [CameraRemoteAsset] = []
                for storage in try storageIDs() {
                    var reader = CameraDataReader(try client.operation(0x1007, parameters: [storage, 0, 0], requiresData: true, limit: CameraWire.dataLimit))
                    let count = Int(try reader.u32())
                    guard count >= 0, reader.remaining == count * 4 else { throw CameraProtocolError.invalid("Invalid camera object handles") }
                    guard count <= Self.maximumListedAssets, handles.count + count <= Self.maximumListedAssets else {
                        throw CameraProtocolError.photoLimitExceeded
                    }
                    for _ in 0..<count {
                        try checkRunning()
                        let handle = try reader.u32()
                        guard handles.insert(handle).inserted else { throw CameraProtocolError.invalid("Duplicate camera handles") }
                        let asset = try legacyAsset(handle)
                        if CameraWire.photoName(asset.snapshot.name), asset.snapshot.size > 0 { assets.append(asset) }
                    }
                }
                return assets
            case nil: throw CameraProtocolError.unsupported("Original photo browsing is unavailable")
            }
        } catch CameraProtocolError.response(let op, let code) { throw CameraProtocolError.response(op, code) }
        catch CameraProtocolError.photoLimitExceeded { throw CameraProtocolError.photoLimitExceeded }
        catch { client.close(); throw error }
    }
    private func legacyAsset(_ handle: UInt32) throws -> CameraRemoteAsset {
        try CameraWire.legacyObject(handle, bytes: client.operation(0x1008, parameters: [handle], requiresData: true, limit: 4096), owner: id)
    }
    func preview(_ asset: CameraRemoteAsset, large: Bool = false) throws -> Data {
        try checkRunning()
        guard asset.owner == id else { throw CameraProtocolError.invalid("Camera photo belongs to another session") }
        if family == .mobile {
            guard device.operations.contains(0x923e) else { throw CameraProtocolError.unsupported("Camera previews are unavailable") }
            return try client.operation(0x923e, parameters: [asset.snapshot.content, 1 << 24 | asset.snapshot.file, large ? 2 : 1],
                                        requiresData: true, limit: large ? 8 << 20 : 2 << 20)
        }
        guard contentsEntered, device.operations.contains(0x100a) else { throw CameraProtocolError.unsupported("Camera thumbnails are unavailable") }
        return try client.operation(0x100a, parameters: [asset.snapshot.content], requiresData: true, limit: 2 << 20)
    }

    func download(_ asset: CameraRemoteAsset, to handle: FileHandle, progress: (UInt64) -> Void) throws -> String {
        let digest = try readOriginal(asset, progress: progress) { try handle.write(contentsOf: $0) }
        try handle.synchronize()
        return digest
    }

    func originalDigest(_ asset: CameraRemoteAsset, progress: (UInt64) -> Void) throws -> String {
        try readOriginal(asset, progress: progress) { _ in }
    }

    func readMobileRange(_ asset: CameraRemoteAsset, offset: UInt64, length: Int) throws -> Data {
        try checkRunning()
        guard family == .mobile, asset.owner == id, asset.snapshot.transferable,
              length > 0, UInt64(length) <= asset.snapshot.size, offset <= asset.snapshot.size - UInt64(length) else {
            throw CameraProtocolError.unsupported("Mobile range read is unavailable")
        }
        let bytes = try client.operation(0x923d, parameters: [
            asset.snapshot.content, 1 << 24 | asset.snapshot.file,
            UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), UInt32(length)
        ], requiresData: true, limit: length)
        guard bytes.count == length else { throw CameraProtocolError.transientTransfer("Original chunk size changed") }
        return bytes
    }

    private func hasMobileAsset(_ asset: CameraRemoteAsset) throws -> Bool {
        guard let targetCreated = UInt64(asset.snapshot.created) else {
            return try listAssets().contains(where: { $0.snapshot == asset.snapshot })
        }
        var cursor: UInt64 = targetCreated > 0 ? targetCreated - 1 : 0
        do {
            for _ in 0..<Self.maximumMobilePages {
                try checkRunning()
                let bytes = try client.operation(
                    0x923c,
                    parameters: [UInt32(truncatingIfNeeded: cursor), UInt32(cursor >> 32), 100, 1, 0],
                    requiresData: true,
                    limit: CameraWire.dataLimit
                )
                let page = try CameraWire.mobilePage(bytes, owner: id)
                if page.assets.contains(where: { $0.snapshot == asset.snapshot }) {
                    return true
                }
                if page.count < 100 || page.cursor > targetCreated {
                    return false
                }
                guard page.cursor > cursor else {
                    throw CameraProtocolError.invalid("Camera page cursor did not advance")
                }
                cursor = page.cursor
            }
            return false
        } catch CameraProtocolError.response(let op, let code) {
            throw CameraProtocolError.response(op, code)
        } catch {
            client.close()
            throw error
        }
    }

    private func readOriginal(_ asset: CameraRemoteAsset, progress: (UInt64) -> Void,
                              consume: (Data) throws -> Void) throws -> String {
        try checkRunning()
        guard asset.owner == id, asset.snapshot.transferable else { throw CameraProtocolError.invalid("Camera original is outside this session or budget") }
        var digest = SHA256(), received: UInt64 = 0, prefix = Data()
        func receive(_ data: Data) throws {
            try checkRunning()
            if prefix.count < 4 { prefix.append(data.prefix(4 - prefix.count)) }
            try consume(data)
            digest.update(data: data); received += UInt64(data.count); progress(received)
        }
        if family == .mobile {
            while received < asset.snapshot.size {
                let count = min(UInt64(3 << 20), asset.snapshot.size - received)
                let bytes = try client.operation(0x923d, parameters: [asset.snapshot.content, 1 << 24 | asset.snapshot.file,
                    UInt32(truncatingIfNeeded: received), UInt32(received >> 32), UInt32(count)], requiresData: true, limit: Int(count))
                guard bytes.count == count else { throw CameraProtocolError.transientTransfer("Original chunk size changed") }
                try receive(bytes)
            }
            guard try hasMobileAsset(asset) else { throw CameraProtocolError.transientTransfer("Original metadata changed during transfer") }
        } else {
            guard contentsEntered, try legacyAsset(asset.snapshot.content).snapshot == asset.snapshot else { throw CameraProtocolError.transientTransfer("Original metadata changed before transfer") }
            try client.streamObject(handle: asset.snapshot.content, size: asset.snapshot.size, sink: receive)
            guard try legacyAsset(asset.snapshot.content).snapshot == asset.snapshot else { throw CameraProtocolError.transientTransfer("Original metadata changed during transfer") }
        }
        guard received == asset.snapshot.size else { throw CameraProtocolError.invalid("Original size mismatch") }
        try CameraWire.validateHeader(name: asset.snapshot.name, data: prefix)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func properties() throws -> [UInt16: CameraProperty] {
        try checkRunning()
        guard remoteReady else { throw CameraProtocolError.unsupported("Remote properties are unavailable") }
        for attempt in 0...2 {
            do {
                return try CameraWire.properties(client.operation(0x9209, parameters: enumTables == 1 ? [] : [0],
                    requiresData: true, limit: CameraWire.dataLimit), enumTables: enumTables)
            } catch CameraProtocolError.response(let op, let code) {
                if op == 0x9209 && code == 0x2019 && attempt < 2 && !stopped {
                    try pause(0.1 * Double(attempt + 1))
                    continue
                }
                throw CameraProtocolError.response(op, code)
            } catch {
                client.close()
                throw error
            }
        }
        throw CameraProtocolError.response(0x9209, 0x2019)
    }
    var canWriteParameters: Bool {
        purpose == .tethering && remoteReady && !contentsEntered && !stopped && enumTables == 2 && device.operations.contains(0x9205)
    }
    var hasShutter: Bool {
        purpose == .tethering && remoteReady && !contentsEntered && !stopped &&
            device.operations.contains(0x9207) && controls.isSuperset(of: [0xd2c1, 0xd2c2])
    }
    func captureReady(_ properties: [UInt16: CameraProperty], cardConfirmed: Bool) -> Bool {
        guard hasShutter, family != nil, properties[0x5013]?.number == 1 else { return false }
        if family == .mobile, let destination = properties[0xd222]?.number { return destination & 0x10 != 0 }
        return cardConfirmed
    }
    static func parameterType(_ code: UInt16) -> UInt16? {
        switch code {
        case 0x5005, 0x5007, 0x500a, 0xd20f, 0xd22c: return 4
        case 0x5010: return 3
        case 0xd20d, 0xd21e, 0xd226: return 6
        default: return nil
        }
    }
    static let fixedFocusAreas: Set<Int64> = [0x0001, 0x0003, 0x0201, 0x0203]

    static func isFocusLocked(_ properties: [UInt16: CameraProperty]) -> Bool {
        guard let value = properties[0xd213]?.number else { return false }
        return value == 2 || value == 6
    }

    static func isFocusFailed(_ properties: [UInt16: CameraProperty]) -> Bool {
        guard let value = properties[0xd213]?.number else { return false }
        return value == 3 || value == 7
    }

    func canCancelTouchFocus(_ properties: [UInt16: CameraProperty]) -> Bool {
        purpose == .tethering && remoteReady && !contentsEntered && !stopped &&
            device.operations.contains(0x9207) && controls.contains(0xd2e5) &&
            properties[0xd285]?.enabled == 1 && properties[0xd285]?.number == 1
    }

    func focusTarget(_ properties: [UInt16: CameraProperty]) -> Result<CameraFocusPointTarget, CameraFocusUnavailableReason> {
        guard purpose == .tethering, remoteReady, !contentsEntered, !stopped,
              device.operations.contains(0x9207) else { return .failure(.unsupported) }
        if controls.contains(0xd2e4), properties[0xd284]?.enabled == 1, properties[0xd284]?.number == 1 {
            return .success(.remoteTouch)
        }
        if properties[0x500a]?.number == 1 {
            return .failure(.manualFocus)
        }
        if controls.contains(0xd2dc) {
            if let area = properties[0xd22c]?.number, Self.fixedFocusAreas.contains(area) {
                return .failure(.focusAreaFixed)
            }
            return .success(.afAreaPosition)
        }
        if controls.contains(0xd2e4), let area = properties[0xd22c]?.number, Self.fixedFocusAreas.contains(area) {
            return .failure(.focusAreaFixed)
        }
        return .failure(.unsupported)
    }

    func setFocusPoint(x: Int, y: Int) throws -> CameraFocusPointResult {
        try checkRunning()
        guard purpose == .tethering, remoteReady, !contentsEntered,
              device.operations.contains(0x9207) else { throw CameraProtocolError.focusUnavailable(.unsupported) }
        guard (0...639).contains(x), (0...479).contains(y) else {
            throw CameraProtocolError.invalid("Focus point outside camera grid")
        }
        var latest = try properties()
        if controls.contains(0xd2e4),
           !(latest[0xd284]?.enabled == 1 && latest[0xd284]?.number == 1),
           canCancelTouchFocus(latest) {
            try sendTouchCancel()
            try pause(0.05)
            latest = try properties()
        }
        let target: CameraFocusPointTarget
        switch focusTarget(latest) {
        case .success(let resolved): target = resolved
        case .failure(let reason): throw CameraProtocolError.focusUnavailable(reason)
        }
        var bytes = Data()
        bytes.appendLE(UInt32((x << 16) | y))
        do {
            _ = try client.operation(0x9207, parameters: [UInt32(target.controlCode)], outgoing: bytes)
        } catch CameraProtocolError.response {
            throw CameraProtocolError.focusRejected
        }
        try pause(0.1)
        latest = try properties()
        let focusLocked = Self.isFocusLocked(latest)
        if !focusLocked, controls.contains(0xd2c1), latest[0x500a]?.number != 1 {
            return try acquireFocusWithHalfPress(initialProperties: latest)
        }
        return CameraFocusPointResult(properties: latest, focusLocked: focusLocked)
    }

    private func acquireFocusWithHalfPress(initialProperties: [UInt16: CameraProperty]) throws -> CameraFocusPointResult {
        stateLock.lock()
        if stopping {
            stateLock.unlock()
            throw CameraProtocolError.cancelled
        }
        capturing = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            capturing = false
            let stop = stopping
            stateLock.unlock()
            if stop { client.close() }
        }

        func sendHalfPress(_ value: UInt16) throws {
            var bytes = Data()
            bytes.appendLE(value)
            _ = try client.operation(0x9207, parameters: [0xd2c1], outgoing: bytes)
        }

        var half = false
        var pressRejectedByCamera = false
        var fatalError: Error?
        var achieved = false
        var current = initialProperties

        do {
            half = true
            try sendHalfPress(2)
            for attempt in 0..<15 {
                try pause(0.1)
                current = try properties()
                guard let indication = current[0xd213]?.number else {
                    if attempt >= 2 { break }
                    continue
                }
                if indication == 2 || indication == 6 {
                    achieved = true
                    break
                }
                if indication == 3 {
                    break
                }
                if indication == 7 && attempt >= 5 {
                    break
                }
            }
        } catch CameraProtocolError.response {
            pressRejectedByCamera = true
        } catch {
            fatalError = error
        }

        if half && !client.isClosed {
            do {
                try sendHalfPress(1)
                half = false
            } catch CameraProtocolError.response {
                half = false
            } catch {
                if fatalError == nil { fatalError = error }
            }
        }
        if let fatalError { throw fatalError }
        if !pressRejectedByCamera && !stopped {
            try? pause(0.05)
            if !stopped, let refreshed = try? properties() {
                current = refreshed
            }
        }
        return CameraFocusPointResult(properties: current, focusLocked: achieved || Self.isFocusLocked(current))
    }

    func cancelTouchFocus() throws -> [UInt16: CameraProperty] {
        try checkRunning()
        let latest = try properties()
        guard canCancelTouchFocus(latest) else { throw CameraProtocolError.focusUnavailable(.unsupported) }
        try sendTouchCancel()
        try pause(0.1)
        return try properties()
    }

    private func sendTouchCancel() throws {
        func send(_ value: UInt16) throws {
            var bytes = Data(); bytes.appendLE(value)
            _ = try client.operation(0x9207, parameters: [0xd2e5], outgoing: bytes)
        }
        var pressed = false
        var failure: Error?
        do {
            pressed = true
            try send(2)
            try pause(0.05)
            try send(1)
            pressed = false
        } catch {
            failure = error
        }
        if pressed, !client.isClosed {
            do { try send(1) }
            catch { if failure == nil { failure = error } }
        }
        if let failure {
            if case CameraProtocolError.response = failure { throw CameraProtocolError.focusRejected }
            throw failure
        }
    }
    func setParameter(_ code: UInt16, value: Int64) throws -> (confirmed: Bool, values: [UInt16: CameraProperty]) {
        guard canWriteParameters, let type = Self.parameterType(code), !(code == 0xd20d && value == 0) else {
            throw CameraProtocolError.unsupported("Camera parameter is read-only")
        }
        var latest = try properties()
        guard let descriptor = latest[code], descriptor.type == type, descriptor.accepts(value) else {
            throw CameraProtocolError.unsupported("Camera parameter value is unavailable")
        }
        if descriptor.number == value { return (true, latest) }
        var bytes = Data()
        if type == 6 { bytes.appendLE(UInt32(truncatingIfNeeded: value)) }
        else { bytes.appendLE(UInt16(truncatingIfNeeded: value)) }
        _ = try client.operation(0x9205, parameters: [UInt32(code)], outgoing: bytes)
        for _ in 0..<12 {
            try pause(0.1); latest = try properties()
            if latest[code]?.number == value { return (true, latest) }
        }
        return (false, latest)
    }

    func capture(cardConfirmed: Bool, beforeSend: () throws -> Void) throws {
        let state: [UInt16: CameraProperty]
        do { state = try properties() } catch { throw CameraProtocolError.captureNotSent(error.localizedDescription) }
        guard captureReady(state, cardConfirmed: cardConfirmed) else {
            throw CameraProtocolError.captureNotSent("Use single-shot drive and save originals to the camera card")
        }
        stateLock.lock()
        if stopping { stateLock.unlock(); throw CameraProtocolError.captureNotSent("Camera operation cancelled") }
        capturing = true; stateLock.unlock()
        var half = false, full = false, failure: Error?
        defer {
            stateLock.lock(); capturing = false; let stop = stopping; stateLock.unlock()
            if stop { client.close() }
        }
        do { try beforeSend(); try checkRunning() }
        catch { throw CameraProtocolError.captureNotSent(error.localizedDescription) }
        func button(_ code: UInt32, _ value: UInt16) throws {
            var bytes = Data(); bytes.appendLE(value)
            _ = try client.operation(0x9207, parameters: [code], outgoing: bytes)
        }
        do {
            half = true; try button(0xd2c1, 2); try pause(0.5)
            full = true; try button(0xd2c2, 2); try pause(0.035)
            try button(0xd2c2, 1); full = false; try pause(1)
            try button(0xd2c1, 1); half = false
        } catch { failure = error }
        if !client.isClosed {
            if full { do { try button(0xd2c2, 1) } catch { failure = error } }
            if half, !client.isClosed { do { try button(0xd2c1, 1) } catch { failure = error } }
        }
        if failure != nil { client.close(); throw CameraProtocolError.captureUnknown }
    }
}
