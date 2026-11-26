import RawLabKit
import Foundation
import CryptoKit
import ImageIO
import CoreGraphics
import SwiftUI
import Darwin

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
    let legacyCreated: String
    var bytes: Data
    var downloadResponseCode: UInt16?
    var shortChunkCount = 0
    var dropConnectionOnDownload = false

    init(content: UInt32, file: UInt32 = 1, name: String, createdMillis: UInt64, bytes: Data,
         legacyCreated: String = "20261113T100000",
         downloadResponseCode: UInt16? = nil, shortChunkCount: Int = 0, dropConnectionOnDownload: Bool = false) {
        self.content = content
        self.file = file
        self.name = name
        self.createdMillis = createdMillis
        self.legacyCreated = legacyCreated
        self.bytes = bytes
        self.downloadResponseCode = downloadResponseCode
        self.shortChunkCount = shortChunkCount
        self.dropConnectionOnDownload = dropConnectionOnDownload
    }
}

final class FakeSonyCameraChannel: CameraByteChannel {
    enum Mode { case mobile, legacy }
    private let lock = NSLock()
    private var buffered = Data()
    private(set) var closed = false
    let mode: Mode
    let supportsTethering: Bool
    var entries: [FakeSonyCameraEntry] {
        didSet { mobileEntriesSortedByCreatedMillis = nil }
    }
    private var mobileEntriesSortedByCreatedMillis: Bool?
    var legacyHandleCountOverride: Int?
    private(set) var downloadAttempts: [String: Int] = [:]
    private(set) var mobileRangeReads: [String: [Range<Int>]] = [:]
    private(set) var legacyFullReads: [String: Int] = [:]
    private(set) var bytesReadByName: [String: Int] = [:]
    private(set) var objectInfoCalls = 0
    private(set) var deviceInfoCalls = 0
    private(set) var shutterCommands = 0
    private(set) var recorded9207: [(UInt32, UInt32)] = []
    var tetherControls: [UInt16] = [0xd2c1, 0xd2c2]
    var tetherExtraProps: [(code: UInt16, type: UInt16, writable: Bool, enabled: UInt8, value: Int64)] = []
    var liveViewURLString: String? = nil
    var next9207Status: UInt16?
    var on9207: ((UInt32, UInt32) -> Void)?
    var onShutter: (() -> Void)?
    var onMobileDownloadChunk: ((String, Int) -> Void)?
    private var pendingOutgoing: [UInt32: (op: UInt16, param: UInt32)] = [:]
    private var dropNextRead = false

    init(mode: Mode = .mobile, supportsTethering: Bool = false, entries: [FakeSonyCameraEntry]) {
        self.mode = mode
        self.supportsTethering = supportsTethering
        self.entries = entries
    }

    func setExtraProperty(_ code: UInt16, value: Int64, enabled: UInt8 = 1) {
        lock.lock()
        if let idx = tetherExtraProps.firstIndex(where: { $0.code == code }) {
            tetherExtraProps[idx].value = value
            tetherExtraProps[idx].enabled = enabled
        }
        lock.unlock()
    }

    func updateEntries(_ body: (inout [FakeSonyCameraEntry]) -> Void) {
        lock.lock()
        body(&entries)
        lock.unlock()
    }

    func resetTransferStats() {
        lock.lock()
        downloadAttempts = [:]
        mobileRangeReads = [:]
        legacyFullReads = [:]
        bytesReadByName = [:]
        objectInfoCalls = 0
        lock.unlock()
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
        if buffered.isEmpty { buffered = Data() }
        return slice
    }

    func write(_ data: Data) throws {
        var postRespondHook: (() -> Void)?
        lock.lock()
        do {
            guard !closed else { throw CameraProtocolError.disconnected }
            var reader = CameraDataReader(data)
            let length = Int(try reader.u32())
            let packetType = try reader.u32()
            guard length == data.count else { throw CameraProtocolError.invalid("Invalid test packet length") }
            if packetType == 14 || packetType == 9 {
                lock.unlock()
                return
            }
            if packetType == 12 {
                let tid = try reader.u32()
                let val32: UInt32 = reader.remaining >= 4 ? try reader.u32() : (reader.remaining >= 2 ? UInt32(try reader.u16()) : 0)
                if let pending = pendingOutgoing.removeValue(forKey: tid), pending.op == 0x9207 {
                    recorded9207.append((pending.param, val32))
                    if let status = next9207Status {
                        next9207Status = nil
                        appendResponse(tid, code: status)
                        lock.unlock()
                        return
                    }
                    let cb = on9207
                    let shutterCb = (pending.param == 0xd2c2 && val32 == 2) ? onShutter : nil
                    let param = pending.param
                    lock.unlock()
                    cb?(param, val32)
                    shutterCb?()
                    lock.lock()
                    appendResponse(tid)
                    lock.unlock()
                    return
                }
                appendResponse(tid)
                lock.unlock()
                return
            }
            guard packetType == 6 else { throw CameraProtocolError.invalid("Unexpected test request packet \(packetType)") }
            let dataPhase = try reader.u32()
            let op = try reader.u16()
            let tid = try reader.u32()
            var params: [UInt32] = []
            while reader.remaining >= 4 { params.append(try reader.u32()) }
            if dataPhase == 2 {
                if op == 0x9207 { shutterCommands += 1 }
                pendingOutgoing[tid] = (op, params.first ?? 0)
                lock.unlock()
                return
            }
            postRespondHook = try respond(op: op, tid: tid, params: params)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        postRespondHook?()
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
        var operations: [UInt16] = mode == .mobile
            ? [0x1001, 0x1002, 0x923c, 0x923d]
            : [0x1001, 0x1002, 0x9201, 0x9202, 0x9209, 0x9212, 0x1004, 0x1007, 0x1008, 0x1009]
        if supportsTethering {
            for op: UInt16 in [0x9201, 0x9202, 0x9205, 0x9207, 0x9209] where !operations.contains(op) {
                operations.append(op)
            }
        }
        device.appendLE(UInt32(operations.count))
        operations.forEach { device.appendLE($0) }
        for _ in 0..<4 { device.appendLE(UInt32(0)) }
        for value in ["Sony Corporation", "ILCE-6700", "2.00", "FAKE-SERIAL-01"] {
            device.append(Self.ptpString(value))
        }
        return device
    }

    private func mobilePage(after cursor: UInt64, maxItems: Int) -> Data {
        let slice: ArraySlice<FakeSonyCameraEntry>
        if mobileEntriesSortedByCreatedMillis == nil {
            var sorted = true
            if entries.count > 1 {
                for i in 1..<entries.count where entries[i - 1].createdMillis > entries[i].createdMillis {
                    sorted = false
                    break
                }
            }
            mobileEntriesSortedByCreatedMillis = sorted
        }
        if mobileEntriesSortedByCreatedMillis == true {
            var lo = 0
            var hi = entries.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if entries[mid].createdMillis > cursor {
                    hi = mid
                } else {
                    lo = mid + 1
                }
            }
            slice = entries[lo..<min(lo + max(0, maxItems), entries.count)]
        } else {
            slice = entries.filter { $0.createdMillis > cursor }.prefix(maxItems)
        }
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
        out.appendLE(UInt16(item.name.lowercased().hasSuffix(".arw") ? 0xb101 : 0x3801))
        out.appendLE(UInt16(0))
        out.appendLE(UInt32(item.bytes.count))
        out.append(Data(repeating: 0, count: 40))
        out.append(Self.ptpString(item.name))
        out.append(Self.ptpString(item.legacyCreated))
        out.append(Self.ptpString(""))
        out.append(Self.ptpString(""))
        return out
    }

    private func respond(op: UInt16, tid: UInt32, params: [UInt32]) throws -> (() -> Void)? {
        switch op {
        case 0x1001:
            deviceInfoCalls += 1
            appendResponse(tid, data: deviceDataset())
        case 0x1002, 0x9201, 0x9212:
            appendResponse(tid)
        case 0x9202:
            var descriptor = Data()
            descriptor.appendLE(UInt16(0x12c))
            descriptor.appendLE(UInt32(1)); descriptor.appendLE(UInt16(0x5013))
            if supportsTethering {
                descriptor.appendLE(UInt32(tetherControls.count))
                tetherControls.forEach { descriptor.appendLE($0) }
            } else {
                descriptor.appendLE(UInt32(0))
            }
            appendResponse(tid, data: descriptor)
        case 0x9209:
            var props = Data()
            if supportsTethering {
                let extraLiveCount = liveViewURLString == nil ? 0 : 1
                props.appendLE(UInt64(2 + tetherExtraProps.count + extraLiveCount))
                for (code, value): (UInt16, UInt16) in [(0x5013, 1), (0xd222, 0x10)] {
                    props.appendLE(code)
                    props.appendLE(UInt16(4))
                    props.append(0)
                    props.append(1)
                    props.appendLE(value)
                    props.appendLE(value)
                    props.append(0)
                }
                for extra in tetherExtraProps {
                    props.appendLE(extra.code)
                    props.appendLE(extra.type)
                    props.append(extra.writable ? 1 : 0)
                    props.append(extra.enabled)
                    if extra.type == 2 {
                        props.append(UInt8(truncatingIfNeeded: extra.value))
                        props.append(UInt8(truncatingIfNeeded: extra.value))
                    } else {
                        props.appendLE(UInt16(truncatingIfNeeded: extra.value))
                        props.appendLE(UInt16(truncatingIfNeeded: extra.value))
                    }
                    props.append(0)
                }
                if let liveViewURLString {
                    props.appendLE(UInt16(0xd278))
                    props.appendLE(UInt16(0xffff))
                    props.append(0)
                    props.append(1)
                    props.append(Self.ptpString(liveViewURLString))
                    props.append(Self.ptpString(liveViewURLString))
                    props.append(0)
                }
            } else {
                props.appendLE(UInt64(0))
            }
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
                return nil
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
                return nil
            }
            downloadAttempts[entry.name, default: 0] += 1
            if entry.dropConnectionOnDownload {
                dropNextRead = true
                return nil
            }
            if let code = entry.downloadResponseCode {
                appendResponse(tid, code: code)
                return nil
            }
            if op == 0x923d {
                let offset = Int(UInt64(params[2]) | (UInt64(params[3]) << 32))
                let length = Int(params[4])
                let maxEnd = min(entry.bytes.count, offset + length)
                let end: Int
                if entry.shortChunkCount > 0 {
                    entry.shortChunkCount -= 1
                    end = maxEnd > offset ? maxEnd - 1 : offset
                } else {
                    end = maxEnd
                }
                let slice = entry.bytes.subdata(in: offset..<end)
                mobileRangeReads[entry.name, default: []].append(offset..<end)
                bytesReadByName[entry.name, default: 0] += slice.count
                appendResponse(tid, data: slice)
                if let hook = onMobileDownloadChunk {
                    return { hook(entry.name, offset) }
                }
            } else {
                legacyFullReads[entry.name, default: 0] += 1
                bytesReadByName[entry.name, default: 0] += entry.bytes.count
                appendResponse(tid, data: entry.bytes)
            }
        default:
            appendResponse(tid, code: 0x2005)
        }
        return nil
    }
}

#if !RAWLAB_XCTEST
@main
#endif
struct CameraSkipAndLimitTests {
    static let fakeCameraPrefsKey = "camera.incremental.preferences.Sony Corporation|ILCE-6700|FAKE-SERIAL-01"

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

    static func makeLargeRAW(size: Int, seed: UInt8) -> Data {
        precondition(size >= 16)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ptr[0] = 0x49; ptr[1] = 0x49; ptr[2] = 0x2a; ptr[3] = 0x00
            ptr[4] = 0x08; ptr[5] = 0x00; ptr[6] = 0x00; ptr[7] = seed
            for index in stride(from: 8, to: size, by: 4096) {
                let block = UInt32(index / 4096) ^ (UInt32(seed) << 16)
                ptr[index] = UInt8(truncatingIfNeeded: block)
                if index + 1 < size { ptr[index + 1] = UInt8(truncatingIfNeeded: block >> 8) }
                if index + 2 < size { ptr[index + 2] = UInt8(truncatingIfNeeded: block >> 16) }
                if index + 3 < size { ptr[index + 3] = UInt8(truncatingIfNeeded: block ^ 0xa5) }
            }
            ptr[size - 1] = seed ^ 0x5a
        }
        return data
    }

    static func makeLargeJPEG(targetSize: Int, seed: UInt8) throws -> Data {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = UInt8(truncatingIfNeeded: i &+ Int(seed))
            pixels[i * 4 + 1] = UInt8(truncatingIfNeeded: (i * 3) ^ Int(seed))
            pixels[i * 4 + 2] = UInt8(truncatingIfNeeded: (i * 7) &+ 19)
            pixels[i * 4 + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = ctx.makeImage() else {
            throw CameraProtocolError.invalid("Failed to build test CGImage")
        }
        let encoded = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else {
            throw CameraProtocolError.invalid("Failed to build test JPEG destination")
        }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CameraProtocolError.invalid("Failed to finalize test JPEG")
        }
        let base = encoded as Data
        guard base.count < targetSize else { return base }
        // Insert valid JPEG COM (0xFFFE) segments immediately after SOI (0xFFD8) to reach exact targetSize.
        var out = Data(capacity: targetSize)
        out.append(base.prefix(2))
        var remaining = targetSize - base.count
        while remaining >= 4 {
            let maxPayload = remaining - 4 == 1 || remaining - 4 == 2 || remaining - 4 == 3
                ? remaining - 8 : min(32_768, remaining - 4)
            let payloadCount = max(0, maxPayload)
            let segLen = UInt16(payloadCount + 2)
            out.append(contentsOf: [0xff, 0xfe, UInt8(segLen >> 8), UInt8(segLen & 0xff)])
            if payloadCount > 0 {
                out.append(Data(repeating: seed ^ 0x33, count: payloadCount))
            }
            remaining -= (4 + payloadCount)
            if remaining > 0 && remaining < 4 { break }
        }
        out.append(base.dropFirst(2))
        if out.count < targetSize {
            out.append(Data(repeating: 0, count: targetSize - out.count))
        }
        return out
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func invalidRAWBytes() -> Data {
        // PNG signature inside an .ARW file: PTP packet size matches, header validation fails.
        Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    }

    static func main() async {
        do {
            #if os(macOS)
            if let index = CommandLine.arguments.firstIndex(of: "--p222-crash-child"),
               index + 1 < CommandLine.arguments.count {
                try await runP222CrashChild(rootPath: CommandLine.arguments[index + 1])
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--p222-orphan-crash-child"),
               index + 1 < CommandLine.arguments.count {
                try await runP222OrphanCrashChild(rootPath: CommandLine.arguments[index + 1])
                return
            }
            #endif
            try await runAll()
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    @MainActor static func runAll() async throws {
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        var suite: [(String, () async throws -> Void)] = [
            ("testI13BadHeaderContinuesAndSkipsWithoutAdvancingCheckpointPastBadItem", testI13BadHeaderContinuesAndSkipsWithoutAdvancingCheckpointPastBadItem),
            ("testI13PerObjectPTPErrorContinuesWhileConnectionErrorsAbort", testI13PerObjectPTPErrorContinuesWhileConnectionErrorsAbort),
            ("testI15PhotoLimitExceededOnMobileAndLegacyKeepsConnectionUsable", testI15PhotoLimitExceededOnMobileAndLegacyKeepsConnectionUsable),
            ("testImportIdleHeartbeatKeepsSessionAndSurfacesDrop", testImportIdleHeartbeatKeepsSessionAndSurfacesDrop),
            ("testI14ReconnectDefaultCutoffAndOneTapSamplingSkipsFullDownload", testI14ReconnectDefaultCutoffAndOneTapSamplingSkipsFullDownload),
            ("testI14SamplingNegativeSafetyMiddleAndTailSingleByteTamperFallsBack", testI14SamplingNegativeSafetyMiddleAndTailSingleByteTamperFallsBack),
            ("testI14SamplingFallbackWhenMissingChangedAdjustedJPEGOrLegacy", testI14SamplingFallbackWhenMissingChangedAdjustedJPEGOrLegacy),
            ("testI14SameSessionRAWToRAWIncrementalBehaviorUnchanged", testI14SameSessionRAWToRAWIncrementalBehaviorUnchanged),
            ("testIN4SkippedFailedItemsPersistAcrossRestart", testIN4SkippedFailedItemsPersistAcrossRestart),
            ("testIN4SkippedAssetsFIFOOverMaximumLimitSurvivesRestart", testIN4SkippedAssetsFIFOOverMaximumLimitSurvivesRestart),
            ("testIN5TransientTransferAndBusyErrorsDoNotMarkItemFailed", testIN5TransientTransferAndBusyErrorsDoNotMarkItemFailed),
            ("testIN6TetheringPhotoLimitExceededKeepsSessionAliveAndRecovers", testIN6TetheringPhotoLimitExceededKeepsSessionAliveAndRecovers),
            ("testIN6TetheringResumeLimitAndExactBoundary10000To10001AndLanguageSwitch", testIN6TetheringResumeLimitAndExactBoundary10000To10001AndLanguageSwitch),
            ("testP222ManifestWritesCoalescedToOneBatchWrite", testP222ManifestWritesCoalescedToOneBatchWrite),
            ("testP222OrphanRecoveryAndPerPhotoDurability", testP222OrphanRecoveryAndPerPhotoDurability),
            ("testP222PerformBatchPersistFailureRollbackAndRecovery", testP222PerformBatchPersistFailureRollbackAndRecovery),
            ("test508ThumbnailsDoNotBlockCommandQueueOrHashFullFile", test508ThumbnailsDoNotBlockCommandQueueOrHashFullFile),
            ("testTetheringTouchFocusAndCancelLifecycle", testTetheringTouchFocusAndCancelLifecycle),
            ("testTetheringVirtualClockFocusExpiryAndBusyGuard", testTetheringVirtualClockFocusExpiryAndBusyGuard),
            ("testManualBrowseOrderNewestFirst", testManualBrowseOrderNewestFirst),
            ("testCameraImportSavesToPhotoLibraryWithoutDuplicatingOrLosingOnDenial", testCameraImportSavesToPhotoLibraryWithoutDuplicatingOrLosingOnDenial),
            ("testTetheringAutomaticallySavesNewShotsToPhotoLibrary", testTetheringAutomaticallySavesNewShotsToPhotoLibrary),
            ("testManualImportAppliesJPEGResizeAndSavesResizedBytesToPhotoLibrary", testManualImportAppliesJPEGResizeAndSavesResizedBytesToPhotoLibrary),
            ("testSSHAccessAuthFlowAndLiveViewOverTunnel", testSSHAccessAuthFlowAndLiveViewOverTunnel)
        ]
        #if os(macOS)
        suite.append(("testP222HardExitSubprocessDurabilityAndOrphanCleanup", testP222HardExitSubprocessDurabilityAndOrphanCleanup))
        #endif
        var failures: [(String, String)] = []
        for (name, testCase) in suite {
            do {
                try await testCase()
            } catch {
                fputs("FAIL [\(name)]: \(error.localizedDescription)\n", stderr)
                failures.append((name, error.localizedDescription))
            }
        }
        if !failures.isEmpty {
            let summary = failures.map { "\($0.0): \($0.1)" }.joined(separator: "; ")
            throw CameraProtocolError.invalid("\(failures.count) test group(s) failed: \(summary)")
        }
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

    @MainActor static func testImportIdleHeartbeatKeepsSessionAndSurfacesDrop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-heartbeat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let channel = FakeSonyCameraChannel(mode: .mobile, entries: [
            FakeSonyCameraEntry(content: 1, name: "DSC00001.ARW", createdMillis: 1_700_000_000_000, bytes: validRAWBytes(7))
        ])
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID(), openSession: { _, purpose, _ in
            try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
        }, importHeartbeatInterval: 0.1)
        let controller = IOSCameraController(backend: backend)
        controller.connect(endpoint: IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FAKE", label: "Fake"),
                           mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing }
        let afterConnect = channel.deviceInfoCalls
        try await waitUntil { channel.deviceInfoCalls >= afterConnect + 3 }
        try check(controller.connected && controller.phase == .browsing && !channel.closed,
                  "Idle import session sends read-only GetDeviceInfo heartbeats and stays connected")
        channel.close()
        try await waitUntil { controller.phase == .paused }
        try check(!controller.connected, "A dropped idle import session is surfaced without waiting for the next user action")
        controller.stop()
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

    @MainActor static func testI14ReconnectDefaultCutoffAndOneTapSamplingSkipsFullDownload() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-main-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)

        let midnight = Calendar.current.startOfDay(for: Date())
        let morningMillis = UInt64((midnight.timeIntervalSince1970 + 10 * 3600 + 15 * 60 + 0.125) * 1000)
        // 14:37:48.678 local time — non-midnight with sub-second (.678s) precision.
        let boundaryMillis = UInt64((midnight.timeIntervalSince1970 + 14 * 3600 + 37 * 60 + 48.678) * 1000)
        let afterBoundaryMillis = boundaryMillis + 250 // +250 ms in the exact same second!
        let exactBoundaryDate = Date(timeIntervalSince1970: Double(boundaryMillis) / 1000)

        let raw50MB_A = makeLargeRAW(size: 50_000_000, seed: 0x11)
        let raw50MB_B = makeLargeRAW(size: 50_000_000, seed: 0x22)
        let rawNew1MB = makeLargeRAW(size: 1_048_576, seed: 0x33)
        let fullDigestA = sha256Hex(raw50MB_A)
        let fullDigestB = sha256Hex(raw50MB_B)
        let fullDigestNew = sha256Hex(rawNew1MB)

        // Session 1: import two 50 MB RAWs up to 14:37:48.678.
        var activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
            FakeSonyCameraEntry(content: 1, name: "DSC01001.ARW", createdMillis: morningMillis, bytes: raw50MB_A),
            FakeSonyCameraEntry(content: 2, name: "DSC01002.ARW", createdMillis: boundaryMillis, bytes: raw50MB_B)
        ])
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
            try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
        }
        let controller = IOSCameraController(backend: backend)
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-MAIN", label: "Fake")
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 2 }

        let initialScan = controller.incrementalScan(customCutoff: midnight, includeUndated: false)
        try check(initialScan.assets.count == 2, "I14: Session 1 queues both 50 MB RAW files")
        controller.startIncremental(initialScan)
        try await waitUntil(timeout: 15) { controller.phase == .browsing && store.snapshot.originals.count == 2 }
        try check(activeChannel.bytesReadByName["DSC01002.ARW"] == 50_000_000 &&
                  (activeChannel.downloadAttempts["DSC01002.ARW"] ?? 0) == 16,
                  "I14: Session 1 performs full 50,000,000-byte download (16 x 3 MiB chunks)")
        controller.stop()

        // Session 2: Disconnect & reconnect (new SonyCameraSession UUID + reassigned PTP content handles + new +250ms shot).
        activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
            FakeSonyCameraEntry(content: 101, name: "DSC01001.ARW", createdMillis: morningMillis, bytes: raw50MB_A),
            FakeSonyCameraEntry(content: 102, name: "DSC01002.ARW", createdMillis: boundaryMillis, bytes: raw50MB_B),
            FakeSonyCameraEntry(content: 103, name: "DSC01003.ARW", createdMillis: afterBoundaryMillis, bytes: rawNew1MB)
        ])
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }

        // Requirement 1: Default cutoff after reconnect equals exact previous boundary timestamp (NOT midnight) and still requires confirmation.
        let unconfirmedScan = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: controller.includeUndated)
        try check(unconfirmedScan.needsCutoffConfirmation && unconfirmedScan.assets.isEmpty,
                  "I14 (1): Reconnect preserves security gate requiring user confirmation before queuing files")
        try check(unconfirmedScan.start == exactBoundaryDate && unconfirmedScan.start != midnight,
                  "I14 (1): Reconnect default start equals exact previous boundary timestamp (including .678 ms), not midnight")

        // Requirement 2: One-tap confirmSuggestedCutoff() preserves millisecond precision and 3-segment samples already-saved 50 MB RAW.
        controller.confirmSuggestedCutoff()
        try check(controller.customCutoff == exactBoundaryDate,
                  "I14 (2): One-tap confirmSuggestedCutoff() applies exact millisecond boundary Date")
        let confirmedScan = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: controller.includeUndated)
        try check(!confirmedScan.needsCutoffConfirmation &&
                  confirmedScan.assets.map(\.snapshot.name) == ["DSC01002.ARW", "DSC01003.ARW"],
                  "I14 (2): Confirmed scan excludes earlier DSC01001.ARW and includes boundary DSC01002.ARW + +250ms DSC01003.ARW")

        controller.startIncremental(confirmedScan)
        try await waitUntil(timeout: 15) { controller.phase == .browsing && store.snapshot.originals.count == 3 }

        let expectedRanges: [Range<Int>] = [
            0..<65_536,
            24_967_232..<25_032_768,
            49_934_464..<50_000_000
        ]
        try check((activeChannel.downloadAttempts["DSC01001.ARW"] ?? 0) == 0 &&
                  (activeChannel.bytesReadByName["DSC01001.ARW"] ?? 0) == 0,
                  "I14 (2): Photo before confirmed boundary timestamp incurs 0 PTP reads and 0 bytes")
        try check(activeChannel.downloadAttempts["DSC01002.ARW"] == 3 &&
                  activeChannel.mobileRangeReads["DSC01002.ARW"] == expectedRanges &&
                  activeChannel.bytesReadByName["DSC01002.ARW"] == 196_608,
                  "I14 (2): Already-imported 50 MB RAW reads only head/middle/tail 3 x 64 KiB (196,608 B, skipping 49,803,392 B)")
        try check(activeChannel.bytesReadByName["DSC01003.ARW"] == 1_048_576,
                  "I14 (2): Newly shot +250ms RAW is downloaded in full")

        let job2 = try store.snapshot.jobs.last ?? { throw CameraProtocolError.invalid("Missing Session 2 job") }()
        let sampledItem = try job2.items.first(where: { $0.asset.name == "DSC01002.ARW" })
            ?? { throw CameraProtocolError.invalid("Missing sampled item") }()
        try check(sampledItem.phase == .saved && sampledItem.reused == true && sampledItem.digest == fullDigestB,
                  "I14 (2): Sampled item is marked saved+reused and retains full-file SHA-256 (never sample hash)")
        try check(store.snapshot.originals.count == 3 &&
                  Set(store.snapshot.originals.map(\.digest)) == [fullDigestA, fullDigestB, fullDigestNew],
                  "I14 (2): Originals manifest retains exact 3 verified full-file entries without duplication")
        try check(controller.customCutoff == nil,
                  "I14 (2): Controller resets customCutoff after incremental job completes")
        controller.stop()

        // Also verify manual earlier cutoff selection (e.g. midnight) still works and 3-segment samples all 3 existing RAWs.
        activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
            FakeSonyCameraEntry(content: 201, name: "DSC01001.ARW", createdMillis: morningMillis, bytes: raw50MB_A),
            FakeSonyCameraEntry(content: 202, name: "DSC01002.ARW", createdMillis: boundaryMillis, bytes: raw50MB_B),
            FakeSonyCameraEntry(content: 203, name: "DSC01003.ARW", createdMillis: afterBoundaryMillis, bytes: rawNew1MB)
        ])
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }
        controller.customCutoff = midnight
        let manualScan = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
        try check(!manualScan.needsCutoffConfirmation && manualScan.assets.count == 3,
                  "I14 (2): Manual cutoff selection remains functional after reconnect")
        controller.startIncremental(manualScan)
        try await waitUntil(timeout: 10) { controller.phase == .browsing && store.snapshot.jobs.count == 3 && store.snapshot.jobs.last?.complete == true }
        try check(activeChannel.bytesReadByName["DSC01001.ARW"] == 196_608 &&
                  activeChannel.bytesReadByName["DSC01002.ARW"] == 196_608 &&
                  activeChannel.bytesReadByName["DSC01003.ARW"] == 196_608 &&
                  store.snapshot.originals.count == 3,
                  "I14 (2): Manual midnight cutoff samples all three previously imported RAWs (196,608 B each, 0 full downloads)")
        controller.stop()
    }

    @MainActor static func testI14SamplingNegativeSafetyMiddleAndTailSingleByteTamperFallsBack() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let size = 1_048_576 // 1 MiB (>= 3 * 64 KiB)
        let middleOffset = (size - 65_536) / 2 + 1_234
        let tailOffset = size - 1

        for (label, tamperOffset, expectedSampleReadsBeforeMismatch) in [
            ("middle", middleOffset, 2),
            ("tail", tailOffset, 3)
        ] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-tamper-\(label)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let captureMillis = UInt64(Date().timeIntervalSince1970 * 1000) - 60_000
            let originalBytes = makeLargeRAW(size: size, seed: 0x44)
            var tamperedBytes = originalBytes
            tamperedBytes[tamperOffset] ^= 0xff
            let originalDigest = sha256Hex(originalBytes)
            let tamperedDigest = sha256Hex(tamperedBytes)

            var activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC02001.ARW", createdMillis: captureMillis, bytes: originalBytes)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-TAMPER-\(label)", label: "Fake")
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            let scan1 = controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: Double(captureMillis) / 1000 - 1), includeUndated: false)
            controller.startIncremental(scan1)
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 1 }
            controller.stop()

            // Reconnect with same (kind, name, size, captureDate), but 1 byte tampered in middle or tail!
            activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 9, name: "DSC02001.ARW", createdMillis: captureMillis, bytes: tamperedBytes)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.confirmSuggestedCutoff()
            let scan2 = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
            controller.startIncremental(scan2)
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }

            let job2 = store.snapshot.jobs[1]
            let item2 = job2.items[0]
            try check(activeChannel.downloadAttempts["DSC02001.ARW"] == expectedSampleReadsBeforeMismatch + 1 &&
                      activeChannel.bytesReadByName["DSC02001.ARW"] == expectedSampleReadsBeforeMismatch * 65_536 + size,
                      "I14 (3-\(label)): 1-byte \(label) tamper aborts sampling at segment \(expectedSampleReadsBeforeMismatch) and falls back to full download")
            try check(item2.phase == .saved && item2.reused != true && item2.digest == tamperedDigest,
                      "I14 (3-\(label)): Tampered file is never mis-skipped; saves new original with full SHA-256")
            try check(Set(store.snapshot.originals.map(\.digest)) == [originalDigest, tamperedDigest],
                      "I14 (3-\(label)): Both original and newly downloaded tampered version exist intact in store")
            for orig in store.snapshot.originals {
                _ = try store.verifiedURL(orig.id)
            }
            controller.stop()
        }
    }

    @MainActor static func testI14SamplingFallbackWhenMissingChangedAdjustedJPEGOrLegacy() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let rawBytes = makeLargeRAW(size: 524_288, seed: 0x55)
        let captureMillis = UInt64(Date().timeIntervalSince1970 * 1000) - 120_000

        // 4a) Local original missing on disk -> falls back to full download.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-missing-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            var activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC03001.ARW", createdMillis: captureMillis, bytes: rawBytes)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-MISSING", label: "Fake")
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: 0), includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 1 }
            let savedURL = try store.verifiedURL(store.snapshot.originals[0].id)
            try FileManager.default.removeItem(at: savedURL)
            controller.stop()

            activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 2, name: "DSC03001.ARW", createdMillis: captureMillis, bytes: rawBytes)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.confirmSuggestedCutoff()
            controller.startIncremental(controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }
            try check(activeChannel.mobileRangeReads["DSC03001.ARW"] == [0..<524_288] &&
                      activeChannel.bytesReadByName["DSC03001.ARW"] == 524_288,
                      "I14 (4a): Missing local original skips sampling and performs full download")
            _ = try store.verifiedURL(store.snapshot.originals.last!.id)
            controller.stop()
        }

        // 4b) Local original corrupted/unavailable on disk (outside the 3 sample windows!) -> falls back to full download.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-changed-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            var activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC03002.ARW", createdMillis: captureMillis, bytes: rawBytes)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-CHANGED", label: "Fake")
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: 0), includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 1 }
            let savedURL = try store.verifiedURL(store.snapshot.originals[0].id)
            var corruptedLocal = try Data(contentsOf: savedURL)
            corruptedLocal[100_000] ^= 0xff // Outside [0..<65536], [229376..<294912], [458752..<524288]!
            try corruptedLocal.write(to: savedURL)
            controller.stop()

            activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 2, name: "DSC03002.ARW", createdMillis: captureMillis, bytes: rawBytes)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.confirmSuggestedCutoff()
            controller.startIncremental(controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }
            try check(activeChannel.mobileRangeReads["DSC03002.ARW"] == [0..<524_288] &&
                      activeChannel.bytesReadByName["DSC03002.ARW"] == 524_288 &&
                      store.snapshot.originals[0].availability == .changed,
                      "I14 (4b): Corrupted local original (availability != .available) skips sampling and re-downloads full file")
            _ = try store.verifiedURL(store.snapshot.originals.last!.id)
            controller.stop()
        }

        // 4c) Re-encoded JPEG (jpegSource != nil) -> falls back to full download both with adjust=true and adjust=false.
        do {
            defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-jpeg-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let jpegBytes = try makeLargeJPEG(targetSize: 300_000, seed: 0x66)
            var activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC03003.JPG", createdMillis: captureMillis, bytes: jpegBytes)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-JPEG", label: "Fake")
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.setJPEGOptions(CameraJPEGOptions(adjust: true, longEdge: 1600, quality: 80))
            controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: 0), includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 1 }
            try check(store.snapshot.originals[0].jpegSource != nil,
                      "I14 (4c): Initial adjusted JPEG import stores re-encoded copy with jpegSource != nil")
            controller.stop()

            // Reconnect with adjust == true: must NOT sample re-encoded JPEG bytes; must download full 300,000 B.
            activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 2, name: "DSC03003.JPG", createdMillis: captureMillis, bytes: jpegBytes)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.confirmSuggestedCutoff()
            controller.startIncremental(controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.jobs.count == 2 && store.snapshot.jobs.last?.complete == true }
            try check(activeChannel.mobileRangeReads["DSC03003.JPG"] == [0..<300_000] &&
                      activeChannel.bytesReadByName["DSC03003.JPG"] == 300_000,
                      "I14 (4c): Adjusted JPEG (adjust=true, jpegSource != nil) falls back to full download")
            controller.stop()

            // Reconnect and switch adjust = false while local copy has jpegSource != nil: must ALSO download full 300,000 B.
            activeChannel = FakeSonyCameraChannel(mode: .mobile, entries: [
                FakeSonyCameraEntry(content: 3, name: "DSC03003.JPG", createdMillis: captureMillis, bytes: jpegBytes)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.setJPEGOptions(CameraJPEGOptions(adjust: false))
            controller.confirmSuggestedCutoff()
            controller.startIncremental(controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }
            try check(activeChannel.mobileRangeReads["DSC03003.JPG"] == [0..<300_000] &&
                      store.snapshot.originals.last?.jpegSource == nil,
                      "I14 (4c): Switching to unadjusted JPEG when only jpegSource != nil exists downloads full camera JPEG")
            controller.stop()
        }

        // 4d) .legacy session (0x1009 stream only) -> default cutoff uses exact timestamp, download uses full 0x1009 stream (0 sampling).
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-legacy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let legacyCreated = "20261113T142345"
            let expectedLegacyDate = try CameraAssetSnapshot(
                content: 1, file: 0, storage: 0x10001, format: 0xb101,
                name: "DSC03004.ARW", size: UInt64(rawBytes.count), created: legacyCreated, modified: ""
            ).captureDate ?? { throw CameraProtocolError.invalid("Failed to parse legacy date") }()

            var activeChannel = FakeSonyCameraChannel(mode: .legacy, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC03004.ARW", createdMillis: captureMillis,
                                    bytes: rawBytes, legacyCreated: legacyCreated)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: activeChannel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-LEGACY", label: "Fake")
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil(timeout: 12) { controller.phase == .browsing && controller.assets.count == 1 }
            controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: 0), includeUndated: false))
            try await waitUntil(timeout: 10) { controller.phase == .browsing && store.snapshot.originals.count == 1 }
            controller.stop()

            activeChannel = FakeSonyCameraChannel(mode: .legacy, entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC03004.ARW", createdMillis: captureMillis,
                                    bytes: rawBytes, legacyCreated: legacyCreated)
            ])
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil(timeout: 12) { controller.phase == .browsing && controller.assets.count == 1 }
            let reconnectLegacyScan = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
            try check(reconnectLegacyScan.needsCutoffConfirmation && reconnectLegacyScan.start == expectedLegacyDate,
                      "I14 (4d): Legacy reconnect keeps confirmation gate and defaults start to exact 14:23:45 camera time")
            controller.confirmSuggestedCutoff()
            controller.startIncremental(controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false))
            try await waitUntil(timeout: 10) { controller.phase == .browsing && store.snapshot.jobs.count == 2 && store.snapshot.jobs.last?.complete == true }
            try check(activeChannel.mobileRangeReads["DSC03004.ARW"] == nil &&
                      activeChannel.legacyFullReads["DSC03004.ARW"] == 1 &&
                      activeChannel.bytesReadByName["DSC03004.ARW"] == 524_288,
                      "I14 (4d): Legacy session never issues 0x923d range reads and falls back to full 0x1009 stream")
            controller.stop()
        }
    }

    @MainActor static func testI14SameSessionRAWToRAWIncrementalBehaviorUnchanged() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-i14-raw2raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let baseMillis = UInt64(Date().timeIntervalSince1970 * 1000) + 5_000
        let raw1 = makeLargeRAW(size: 262_144, seed: 0x71)
        let raw2 = makeLargeRAW(size: 262_144, seed: 0x72)
        let raw3 = makeLargeRAW(size: 262_144, seed: 0x73)
        let raw4 = makeLargeRAW(size: 262_144, seed: 0x74)
        let jpgDummy = try makeLargeJPEG(targetSize: 16_384, seed: 0x75)

        let channel = FakeSonyCameraChannel(mode: .mobile, entries: [
            FakeSonyCameraEntry(content: 1, file: 1, name: "DSC04001.ARW", createdMillis: baseMillis + 1_000, bytes: raw1),
            FakeSonyCameraEntry(content: 1, file: 2, name: "DSC04001.JPG", createdMillis: baseMillis + 1_000, bytes: jpgDummy),
            FakeSonyCameraEntry(content: 2, file: 1, name: "DSC04002.ARW", createdMillis: baseMillis + 2_000, bytes: raw2),
            FakeSonyCameraEntry(content: 2, file: 2, name: "DSC04002.JPG", createdMillis: baseMillis + 2_000, bytes: jpgDummy)
        ])
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
            try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
        }
        let controller = IOSCameraController(backend: backend)
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I14-RAW2RAW", label: "Fake")
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 4 }
        controller.setImportFormat(.raw)

        let scan1 = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
        try check(!scan1.needsCutoffConfirmation && scan1.assets.map(\.snapshot.name) == ["DSC04001.ARW", "DSC04002.ARW"],
                  "I14 (5): Initial RAW-only scan selects only RAW files without confirmation gate")
        controller.startIncremental(scan1)
        try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }

        // Shoot 2 more RAW+JPEG pairs in the SAME session (one at exact boundary timestamp +2000ms, one at +3000ms).
        channel.resetTransferStats()
        channel.entries.append(contentsOf: [
            FakeSonyCameraEntry(content: 3, file: 1, name: "DSC04003.ARW", createdMillis: baseMillis + 2_000, bytes: raw3),
            FakeSonyCameraEntry(content: 3, file: 2, name: "DSC04003.JPG", createdMillis: baseMillis + 2_000, bytes: jpgDummy),
            FakeSonyCameraEntry(content: 4, file: 1, name: "DSC04004.ARW", createdMillis: baseMillis + 3_000, bytes: raw4),
            FakeSonyCameraEntry(content: 4, file: 2, name: "DSC04004.JPG", createdMillis: baseMillis + 3_000, bytes: jpgDummy)
        ])
        controller.refreshImport()
        try await waitUntil { !controller.scanning && controller.assets.count == 8 }

        let scan2 = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
        try check(!scan2.needsCutoffConfirmation && scan2.assets.map(\.snapshot.name) == ["DSC04003.ARW", "DSC04004.ARW"],
                  "I14 (5): Same-session RAW->RAW refresh auto-confirms boundary and queues only unseen RAWs")
        controller.startIncremental(scan2)
        try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 4 }
        try check((channel.downloadAttempts["DSC04001.ARW"] ?? 0) == 0 &&
                  (channel.downloadAttempts["DSC04002.ARW"] ?? 0) == 0 &&
                  channel.bytesReadByName["DSC04003.ARW"] == 262_144 &&
                  channel.bytesReadByName["DSC04004.ARW"] == 262_144,
                  "I14 (5): Same-session RAW->RAW performs zero reads on prior RAWs and downloads only new RAWs")

        let scan3 = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
        try check(!scan3.needsCutoffConfirmation && scan3.assets.isEmpty,
                  "I14 (5): Subsequent scan in same session reports no new photos")
        controller.stop()
    }

    @MainActor static func drainBackend(_ backend: CameraWorkspaceBackend) async {
        await withCheckedContinuation { continuation in
            backend.loadHistory { _ in continuation.resume() }
        }
    }

    @MainActor static func testIN4SkippedFailedItemsPersistAcrossRestart() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-in4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I-N4", label: "Fake")
        let baseMillis = UInt64(Date().timeIntervalSince1970 * 1000) + 10_000

        @MainActor func runInitialSessionAndSkip() async throws {
            let store = try CameraOriginalStore(directory: root)
            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC00001.ARW", createdMillis: baseMillis + 1_000, bytes: validRAWBytes(1)),
                FakeSonyCameraEntry(content: 2, name: "DSC00002.ARW", createdMillis: baseMillis + 2_000, bytes: invalidRAWBytes()),
                FakeSonyCameraEntry(content: 3, name: "DSC00003.ARW", createdMillis: baseMillis + 3_000, bytes: validRAWBytes(3))
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }
            let cutoff = Date(timeIntervalSince1970: Double(baseMillis) / 1000)
            let scan1 = controller.incrementalScan(customCutoff: cutoff, includeUndated: false)
            controller.startIncremental(scan1)
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 2 }
            let job = try store.snapshot.jobs.first ?? { throw CameraProtocolError.invalid("Missing I-N4 initial job") }()
            controller.skipFailedIncrementalItems(job)
            try await waitUntil { !controller.scanning && controller.displayedIncrementalJob == nil }
            await withCheckedContinuation { continuation in
                controller.stop { continuation.resume() }
            }
            await drainBackend(backend)
        }

        try await runInitialSessionAndSkip()

        // Simulate app restart with fresh CameraOriginalStore + CameraWorkspaceBackend + IOSCameraController
        // and reassigned PTP handles (content 101..104) plus a newly shot 4th file.
        let restartedStore = try CameraOriginalStore(directory: root)
        let restartedChannel = FakeSonyCameraChannel(entries: [
            FakeSonyCameraEntry(content: 101, name: "DSC00001.ARW", createdMillis: baseMillis + 1_000, bytes: validRAWBytes(1)),
            FakeSonyCameraEntry(content: 102, name: "DSC00002.ARW", createdMillis: baseMillis + 2_000, bytes: invalidRAWBytes()),
            FakeSonyCameraEntry(content: 103, name: "DSC00003.ARW", createdMillis: baseMillis + 3_000, bytes: validRAWBytes(3)),
            FakeSonyCameraEntry(content: 104, name: "DSC00004.ARW", createdMillis: baseMillis + 4_000, bytes: validRAWBytes(4))
        ])
        var restartedSession: SonyCameraSession?
        let restartedBackend = CameraWorkspaceBackend(storage: restartedStore, clientID: UUID()) { _, purpose, _ in
            let s = try SonyCameraSession(client: CameraPTPClient(command: restartedChannel, event: nil), purpose: purpose)
            restartedSession = s
            return s
        }
        let restartedController = IOSCameraController(backend: restartedBackend)
        restartedController.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { restartedController.phase == .browsing && restartedController.assets.count == 4 }

        try check(restartedController.skippedAssets.map(\.name) == ["DSC00002.ARW"],
                  "I-N4: Skipped bad file remains in skippedAssets after app/controller restart")

        restartedController.confirmSuggestedCutoff()
        let scanAfterRestart = restartedController.incrementalScan(customCutoff: restartedController.customCutoff, includeUndated: false)
        let scannedNames = scanAfterRestart.assets.map(\.snapshot.name)
        try check(!scannedNames.contains("DSC00002.ARW") && scannedNames.contains("DSC00004.ARW"),
                  "I-N4: Restarted incremental scan excludes previously skipped bad file even with reassigned handles")

        restartedController.startIncremental(scanAfterRestart)
        try await waitUntil { restartedController.phase == .browsing && restartedStore.snapshot.originals.count == 3 }
        try check((restartedChannel.downloadAttempts["DSC00002.ARW"] ?? 0) == 0 &&
                  restartedStore.snapshot.originals.map(\.name).sorted() == ["DSC00001.ARW", "DSC00003.ARW", "DSC00004.ARW"],
                  "I-N4: Skipped bad file incurs 0 download attempts after restart while new photo saves")
        let boundaries = restartedStore.snapshot.incrementalBoundaries(device: try restartedSession?.device ?? { throw CameraProtocolError.invalid("Missing session") }(),
                                                                      connectionKey: endpoint.connectionKey)
        let expectedCheckpoint = Date(timeIntervalSince1970: Double(baseMillis + 1_000) / 1000)
        try check(boundaries["RAW"]?.date == expectedCheckpoint,
                  "I-N4: Checkpoint remains before skipped item 2 across restart")
        restartedController.stop()
    }

    @MainActor static func testIN5TransientTransferAndBusyErrorsDoNotMarkItemFailed() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I-N5", label: "Fake")
        let now = UInt64(Date().timeIntervalSince1970 * 1000) + 1_000

        // 1) Transient short chunk ("Original chunk size changed") -> must NOT mark item .failed; item stays .interrupted and retries.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-in5-chunk-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC05001.ARW", createdMillis: now + 1_000, bytes: validRAWBytes(51)),
                FakeSonyCameraEntry(content: 2, name: "DSC05002.ARW", createdMillis: now + 2_000, bytes: makeLargeRAW(size: 4096, seed: 52), shortChunkCount: 1),
                FakeSonyCameraEntry(content: 3, name: "DSC05003.ARW", createdMillis: now + 3_000, bytes: validRAWBytes(53))
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }
            controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: Double(now) / 1000), includeUndated: false))
            try await waitUntil {
                controller.phase == .browsing &&
                    store.snapshot.jobs.last?.items[1].phase == .interrupted &&
                    controller.notice != nil
            }
            let job = try store.snapshot.jobs.first ?? { throw CameraProtocolError.invalid("Missing I-N5 chunk job") }()
            try check(controller.connected && job.failedItems.isEmpty &&
                      job.items[1].phase == .interrupted && job.items[1].failureKind == .transient &&
                      job.items[2].phase == .queued && job.pendingItems.count == 2 &&
                      !job.requiresNewImport(connected: true, assets: controller.assets),
                      "I-N5: Transient 'Original chunk size changed' marks item interrupted (not failed) and leaves remaining items retryable")

            // Resume on the same open session: item 2 now transfers cleanly with full bytes.
            controller.resumeImport(job)
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 3 }
            try check(store.snapshot.jobs[0].complete && store.snapshot.originals.count == 3,
                      "I-N5: Resuming after transient chunk size error saves the interrupted item and remaining queue")
            await withCheckedContinuation { continuation in
                controller.stop { continuation.resume() }
            }
            await drainBackend(backend)
        }

        // 2) Per-object PTP DeviceBusy (0x2019) -> transient, must NOT mark item .failed!
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-in5-busy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let busyEntry = FakeSonyCameraEntry(content: 2, name: "DSC05012.ARW", createdMillis: now + 2_000, bytes: validRAWBytes(62), downloadResponseCode: 0x2019)
            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC05011.ARW", createdMillis: now + 1_000, bytes: validRAWBytes(61)),
                busyEntry,
                FakeSonyCameraEntry(content: 3, name: "DSC05013.ARW", createdMillis: now + 3_000, bytes: validRAWBytes(63))
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }
            controller.selection = Set(controller.assets.map(\.id))
            controller.importSelected()
            try await waitUntil {
                controller.phase == .browsing &&
                    store.snapshot.jobs.last?.items[1].phase == .interrupted &&
                    controller.notice != nil
            }
            let job = try store.snapshot.jobs.first ?? { throw CameraProtocolError.invalid("Missing I-N5 busy job") }()
            try check(controller.connected && job.failedItems.isEmpty &&
                      job.items[1].phase == .interrupted && job.items[1].failureKind == .transient &&
                      job.items[2].phase == .queued,
                      "I-N5: DeviceBusy (0x2019) is treated as transient interrupted rather than permanent item failure")
            busyEntry.downloadResponseCode = nil
            controller.resumeImport(job)
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 3 }
            try check(store.snapshot.jobs[0].complete && store.snapshot.originals.count == 3,
                      "I-N5: Resuming after DeviceBusy (0x2019) completes the queue on the same connection")

            // 3) Typed failureKind drives requiresNewImport without relying on English errorDescription strings.
            let owner = controller.assets.first?.owner ?? UUID()
            let device = CameraDeviceIdentity(manufacturer: "Sony", model: "ILCE-6700", firmware: "2.00", serial: "FAKE-SERIAL-01", operations: [])
            let typedNonResumable = CameraTransferJob(
                id: UUID(), camera: device, connectionKey: endpoint.connectionKey, createdAt: Date(),
                items: [CameraTransferItem(id: UUID(), asset: controller.assets[0].snapshot, phase: .interrupted,
                                           failure: "Localized message", failureKind: .jpegGainMapAdjustment)],
                incremental: nil, listingOwner: owner
            )
            let typedResumable = CameraTransferJob(
                id: UUID(), camera: device, connectionKey: endpoint.connectionKey, createdAt: Date(),
                items: [CameraTransferItem(id: UUID(), asset: controller.assets[0].snapshot, phase: .interrupted,
                                           failure: CameraProtocolError.jpegGainMapAdjustment.errorDescription, failureKind: .transient)],
                incremental: nil, listingOwner: owner
            )
            try check(typedNonResumable.requiresNewImport(connected: true, assets: controller.assets) &&
                      !typedResumable.requiresNewImport(connected: true, assets: controller.assets),
                      "I-N5: requiresNewImport uses typed failureKind instead of matching English error text")
            await withCheckedContinuation { continuation in
                controller.stop { continuation.resume() }
            }
            await drainBackend(backend)
        }
    }

    @MainActor static func testIN6TetheringPhotoLimitExceededKeepsSessionAliveAndRecovers() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I-N6", label: "Fake")
        let baseMillis: UInt64 = 1_700_000_000_000
        let sampleBytes = validRAWBytes(77)
        let twelveThousand = (1...12_000).map { index in
            FakeSonyCameraEntry(content: UInt32(index), name: String(format: "DSC%05d.ARW", index),
                                createdMillis: baseMillis + UInt64(index), bytes: sampleBytes)
        }

        // 1) Mid-session tethering crossing > 10,000 card items during poll: keeps session & controller alive, then recovers!
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-in6-mid-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let channel = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: [twelveThousand[0]])
            var openedSession: SonyCameraSession?
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                let s = try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
                openedSession = s
                return s
            }
            let controller = IOSCameraController(backend: backend)
            UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
            controller.connect(endpoint: endpoint, mode: .tethering, cardConfirmed: true, resume: false)
            try await waitUntil { controller.phase == .ready && controller.shutterReady }

            channel.updateEntries { $0 = twelveThousand }
            try await waitUntil(timeout: 5) {
                (controller.listingLimitExceeded || controller.phase == .paused) && controller.notice == "照片 · 已到上限"
            }
            try check(openedSession?.stopped == false && !channel.closed &&
                      controller.connected && controller.phase == .ready &&
                      controller.listingLimitExceeded && !controller.shutterReady &&
                      controller.notice == "照片 · 已到上限",
                      "I-N6 (mid-tether): 12,000 items keeps tether session open, blocks shutter, and surfaces photo-limit notice")

            // Drop back <= 10,000 with 1 newly shot photo on the SAME open connection -> auto-recovers and imports new shot.
            let newShot = FakeSonyCameraEntry(content: 20_001, name: "DSC20001.ARW",
                                              createdMillis: baseMillis + 50_000, bytes: validRAWBytes(88))
            channel.updateEntries { $0 = [twelveThousand[0], newShot] }
            try await waitUntil(timeout: 6) {
                !controller.listingLimitExceeded &&
                    controller.phase == .ready &&
                    controller.shutterReady &&
                    store.snapshot.originals.count == 1
            }
            try check(controller.connected && controller.phase == .ready && controller.shutterReady &&
                      controller.notice == nil && store.snapshot.originals.map(\.name) == ["DSC20001.ARW"],
                      "I-N6 (mid-tether): Dropping back <= 10,000 on same open tether session recovers and downloads new shot")
            await withCheckedContinuation { continuation in
                controller.stop { continuation.resume() }
            }
            await drainBackend(backend)
        }

        // 2) Connecting in .tethering when card ALREADY exceeds 10,000 photos: stays connected & establishes baseline once trimmed.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-in6-init-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let channel = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: twelveThousand)
            var openedSession: SonyCameraSession?
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                let s = try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
                openedSession = s
                return s
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: endpoint, mode: .tethering, cardConfirmed: true, resume: false)
            try await waitUntil {
                (controller.phase == .ready || controller.phase == .paused) && controller.notice != nil
            }
            try check(openedSession?.stopped == false && !channel.closed &&
                      controller.connected && controller.phase == .ready &&
                      controller.listingLimitExceeded && !controller.shutterReady &&
                      controller.notice == "照片 · 已到上限",
                      "I-N6 (initial-tether): Connecting with 12,000 card items stays connected in tether ready state with limit notice")

            // Trim back to baseline [DSC00001.ARW]: must establish baseline without downloading DSC00001.ARW.
            channel.updateEntries { $0 = [twelveThousand[0]] }
            try await waitUntil(timeout: 6) { !controller.listingLimitExceeded && controller.shutterReady }
            try check(store.snapshot.originals.isEmpty && (channel.downloadAttempts["DSC00001.ARW"] ?? 0) == 0,
                      "I-N6 (initial-tether): Recovering card establishes baseline without importing pre-existing photos")

            let shotAfterRecover = FakeSonyCameraEntry(content: 20_002, name: "DSC20002.ARW",
                                                       createdMillis: baseMillis + 60_000, bytes: validRAWBytes(89))
            channel.updateEntries { $0.append(shotAfterRecover) }
            try await waitUntil(timeout: 6) { store.snapshot.originals.count == 1 }
            try check(store.snapshot.originals.map(\.name) == ["DSC20002.ARW"],
                      "I-N6 (initial-tether): Subsequent shot after baseline recovery downloads automatically")
            await withCheckedContinuation { continuation in
                controller.stop { continuation.resume() }
            }
            await drainBackend(backend)
        }
    }

    @MainActor static func testP222ManifestWritesCoalescedToOneBatchWrite() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:P2-22", label: "Fake")
        let baseMillis = UInt64(Date().timeIntervalSince1970 * 1000) + 10_000

        // 1) Importing N = 5 new photos writes 1 (enqueue) + N (1 coalesced write per photo) = N + 1 = 6 times.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-p222-ok-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let counterLock = NSLock()
            var writeCount = 0
            func resetWrites() { counterLock.lock(); writeCount = 0; counterLock.unlock() }
            func readWrites() -> Int { counterLock.lock(); defer { counterLock.unlock() }; return writeCount }

            let store = try CameraOriginalStore(directory: root) {
                counterLock.lock()
                writeCount += 1
                counterLock.unlock()
            }
            let entries = (1...5).map { index in
                FakeSonyCameraEntry(content: UInt32(index), name: String(format: "DSC080%02d.ARW", index),
                                    createdMillis: baseMillis + UInt64(index * 1_000), bytes: validRAWBytes(UInt8(80 + index)))
            }
            let channel = FakeSonyCameraChannel(entries: entries)
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 5 }

            resetWrites()
            let scan = controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: Double(baseMillis) / 1000), includeUndated: false)
            controller.startIncremental(scan)
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 5 }
            let writesForFivePhotos = readWrites()
            try check(writesForFivePhotos == 6,
                      "P2-22: Batch import of N=5 photos writes manifest.json N+1=6 times (1 enqueue + 1 per photo; actual: \(writesForFivePhotos))")
            for original in store.snapshot.originals {
                _ = try store.verifiedURL(original.id)
            }
            await withCheckedContinuation { continuation in
                controller.stop { continuation.resume() }
            }
            await drainBackend(backend)
        }

        // 2) Mixed failure batch (N = 4 photos, item 2 bad header -> failed, items 1/3/4 saved) writes 1 (enqueue) + 4 = 5 times.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-p222-mixed-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let counterLock = NSLock()
            var writeCount = 0
            func resetWrites() { counterLock.lock(); writeCount = 0; counterLock.unlock() }
            func readWrites() -> Int { counterLock.lock(); defer { counterLock.unlock() }; return writeCount }

            @MainActor func runMixedBatch() async throws {
                let store = try CameraOriginalStore(directory: root) {
                    counterLock.lock()
                    writeCount += 1
                    counterLock.unlock()
                }
                let channel = FakeSonyCameraChannel(entries: [
                    FakeSonyCameraEntry(content: 1, name: "DSC08101.ARW", createdMillis: baseMillis + 1_000, bytes: validRAWBytes(91)),
                    FakeSonyCameraEntry(content: 2, name: "DSC08102.ARW", createdMillis: baseMillis + 2_000, bytes: invalidRAWBytes()),
                    FakeSonyCameraEntry(content: 3, name: "DSC08103.ARW", createdMillis: baseMillis + 3_000, bytes: validRAWBytes(93)),
                    FakeSonyCameraEntry(content: 4, name: "DSC08104.ARW", createdMillis: baseMillis + 4_000, bytes: validRAWBytes(94))
                ])
                let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                    try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
                }
                let controller = IOSCameraController(backend: backend)
                controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
                try await waitUntil { controller.phase == .browsing && controller.assets.count == 4 }

                resetWrites()
                controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: Double(baseMillis) / 1000), includeUndated: false))
                try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 3 }
                let writes = readWrites()
                try check(writes == 5 && store.snapshot.jobs[0].failedItems.count == 1,
                          "P2-22: Mixed batch (N=4: 3 saved + 1 failed) writes N+1=5 times (actual: \(writes))")
                await withCheckedContinuation { continuation in
                    controller.stop { continuation.resume() }
                }
                await drainBackend(backend)
            }
            try await runMixedBatch()

            // Reopen from disk to prove per-photo manifests durably saved all state and published files.
            let reopened = try CameraOriginalStore(directory: root)
            try check(reopened.snapshot.originals.count == 3 &&
                      reopened.snapshot.originals.allSatisfy { $0.availability == .available } &&
                      reopened.snapshot.jobs[0].savedCount == 3 &&
                      reopened.snapshot.jobs[0].failedItems.count == 1,
                      "P2-22: Reopening persisted manifest preserves all published originals and failed item status")
            for original in reopened.snapshot.originals {
                _ = try reopened.verifiedURL(original.id)
            }
        }

        // 3) Transient interruption mid-batch (N = 3 photos, item 2 shortChunkCount: 1) writes 1 (enqueue) + 2 processed = 3,
        // and resumeImport for the remaining 2 items writes 2 times (1 per resumed photo).
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-p222-int-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let counterLock = NSLock()
            var writeCount = 0
            func resetWrites() { counterLock.lock(); writeCount = 0; counterLock.unlock() }
            func readWrites() -> Int { counterLock.lock(); defer { counterLock.unlock() }; return writeCount }

            let store = try CameraOriginalStore(directory: root) {
                counterLock.lock()
                writeCount += 1
                counterLock.unlock()
            }
            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC08201.ARW", createdMillis: baseMillis + 1_000, bytes: validRAWBytes(95)),
                FakeSonyCameraEntry(content: 2, name: "DSC08202.ARW", createdMillis: baseMillis + 2_000, bytes: makeLargeRAW(size: 4096, seed: 96), shortChunkCount: 1),
                FakeSonyCameraEntry(content: 3, name: "DSC08203.ARW", createdMillis: baseMillis + 3_000, bytes: validRAWBytes(97))
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }

            resetWrites()
            controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: Double(baseMillis) / 1000), includeUndated: false))
            try await waitUntil {
                controller.phase == .browsing && controller.manifest.jobs.last?.items[1].phase == .interrupted
            }
            let writesForInterruptedBatch = readWrites()
            try check(writesForInterruptedBatch == 3 && store.snapshot.originals.count == 1 &&
                      store.snapshot.jobs[0].items[0].phase == .saved &&
                      store.snapshot.jobs[0].items[1].phase == .interrupted &&
                      store.snapshot.jobs[0].items[2].phase == .queued,
                      "P2-22: Interrupted batch writes 1 enqueue + 2 processed items = 3 (actual: \(writesForInterruptedBatch))")

            resetWrites()
            controller.resumeImport(store.snapshot.jobs[0])
            try await waitUntil {
                controller.phase == .browsing && controller.manifest.jobs.last?.complete == true && store.snapshot.originals.count == 3
            }
            let writesForResume = readWrites()
            try check(writesForResume == 2 && store.snapshot.jobs[0].complete,
                      "P2-22: resumeImport of 2 remaining items writes 1 per resumed photo = 2 (actual: \(writesForResume))")
            await withCheckedContinuation { continuation in
                controller.stop { continuation.resume() }
            }
            await drainBackend(backend)
        }

        // 4) Mobile sampling reuse (N = 2 large RAWs) writes 1 (enqueue) + 2 (1 per reused photo) = 3.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-p222-reuse-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let counterLock = NSLock()
            var writeCount = 0
            func resetWrites() { counterLock.lock(); writeCount = 0; counterLock.unlock() }
            func readWrites() -> Int { counterLock.lock(); defer { counterLock.unlock() }; return writeCount }

            let raw1 = makeLargeRAW(size: 262_144, seed: 0x31)
            let raw2 = makeLargeRAW(size: 262_144, seed: 0x32)
            let store = try CameraOriginalStore(directory: root) {
                counterLock.lock()
                writeCount += 1
                counterLock.unlock()
            }
            let entries = [
                FakeSonyCameraEntry(content: 1, name: "DSC08211.ARW", createdMillis: baseMillis + 1_000, bytes: raw1),
                FakeSonyCameraEntry(content: 2, name: "DSC08212.ARW", createdMillis: baseMillis + 2_000, bytes: raw2)
            ]
            let ch1 = FakeSonyCameraChannel(entries: entries)
            let backend1 = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: ch1, event: nil), purpose: purpose)
            }
            let ctrl1 = IOSCameraController(backend: backend1)
            ctrl1.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { ctrl1.phase == .browsing && ctrl1.assets.count == 2 }
            ctrl1.startIncremental(ctrl1.incrementalScan(customCutoff: Date(timeIntervalSince1970: Double(baseMillis) / 1000), includeUndated: false))
            try await waitUntil { ctrl1.phase == .browsing && ctrl1.savedCount == 2 }
            await withCheckedContinuation { continuation in ctrl1.stop { continuation.resume() } }
            await drainBackend(backend1)

            resetWrites()
            let ch2 = FakeSonyCameraChannel(entries: entries)
            let backend2 = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: ch2, event: nil), purpose: purpose)
            }
            let ctrl2 = IOSCameraController(backend: backend2)
            ctrl2.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { ctrl2.phase == .browsing && ctrl2.assets.count == 2 }
            ctrl2.customCutoff = Date(timeIntervalSince1970: Double(baseMillis) / 1000)
            let rescan = ctrl2.incrementalScan(customCutoff: ctrl2.customCutoff, includeUndated: false)
            ctrl2.startIncremental(rescan)
            try await waitUntil { ctrl2.phase == .browsing && ctrl2.savedCount == 2 }
            let writesForSamplingReuse = readWrites()
            try check(writesForSamplingReuse == 3 &&
                      ch2.mobileRangeReads["DSC08211.ARW"]?.count == 3 &&
                      ch2.mobileRangeReads["DSC08212.ARW"]?.count == 3 &&
                      store.snapshot.originals.count == 2,
                      "P2-22: Mobile sampling reuse of N=2 photos writes N+1=3 times (actual: \(writesForSamplingReuse))")
            await withCheckedContinuation { continuation in ctrl2.stop { continuation.resume() } }
            await drainBackend(backend2)
        }

        // 5) Tether poll writes 0 times when idle, and N+1 times when N=2 new shots arrive.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-p222-tether-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let counterLock = NSLock()
            var writeCount = 0
            func resetWrites() { counterLock.lock(); writeCount = 0; counterLock.unlock() }
            func readWrites() -> Int { counterLock.lock(); defer { counterLock.unlock() }; return writeCount }

            let store = try CameraOriginalStore(directory: root) {
                counterLock.lock()
                writeCount += 1
                counterLock.unlock()
            }
            let channel = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: [])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: endpoint, mode: .tethering, cardConfirmed: true, resume: false)
            try await waitUntil { controller.phase == .ready && controller.shutterReady }

            resetWrites()
            try await Task.sleep(nanoseconds: 1_800_000_000)
            let writesDuringIdlePoll = readWrites()
            try check(writesDuringIdlePoll == 0,
                      "P2-22: Idle tether poll writes manifest.json 0 times (actual: \(writesDuringIdlePoll))")

            resetWrites()
            channel.updateEntries {
                $0 = [
                    FakeSonyCameraEntry(content: 1, name: "DSC08401.ARW", createdMillis: baseMillis + 1_000, bytes: validRAWBytes(101)),
                    FakeSonyCameraEntry(content: 2, name: "DSC08402.ARW", createdMillis: baseMillis + 2_000, bytes: validRAWBytes(102))
                ]
            }
            try await waitUntil(timeout: 6) { controller.savedCount == 2 && controller.originals.count == 2 }
            let writesForTetherPoll = readWrites()
            try check(writesForTetherPoll == 3,
                      "P2-22: Tether poll receiving N=2 shots writes 1 register + 2 per-shot = 3 (actual: \(writesForTetherPoll))")
            await withCheckedContinuation { continuation in controller.stop { continuation.resume() } }
            await drainBackend(backend)
        }
    }

    @MainActor static func testP222OrphanRecoveryAndPerPhotoDurability() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:P2-22-ORPHAN", label: "Fake")
        let device = CameraDeviceIdentity(manufacturer: "Sony", model: "ILCE-6700", firmware: "2.00", serial: "FAKE-SERIAL-01", operations: [])
        let baseMillis = UInt64(Date().timeIntervalSince1970 * 1000) + 10_000

        // 1) Cross-version upgrade migration (#339 whole-batch crash before manifest write -> upgraded recover()):
        // Complete original on disk + empty manifest -> re-adopted as .available (never deleted), counted in UI & bytes,
        // idempotent on subsequent restarts (0 extra writes), and reclaimable via pruneExportedOriginals once exported.
        // Only empty orphan directories are deleted; nonempty residues are preserved without indexing.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-p222-upgrade-adopt-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            do { _ = try CameraOriginalStore(directory: root) }

            let originalsRoot = root.appendingPathComponent("originals", isDirectory: true)
            let upgradeID = UUID()
            let upgradeDir = originalsRoot.appendingPathComponent(upgradeID.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: upgradeDir, withIntermediateDirectories: true)
            let upgradeBytes = makeLargeRAW(size: 8192, seed: 0x41)
            let upgradeFile = upgradeDir.appendingPathComponent("DSC_UPGRADE.ARW")
            try upgradeBytes.write(to: upgradeFile)
            let expectedMtime = Date(timeIntervalSince1970: 1_700_000_234)
            try FileManager.default.setAttributes([.modificationDate: expectedMtime], ofItemAtPath: upgradeFile.path)

            let emptyJunkDir = originalsRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: emptyJunkDir, withIntermediateDirectories: true)
            let residueDir = originalsRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: residueDir, withIntermediateDirectories: true)
            try Data([0x49, 0x49, 0x2a, 0]).write(to: residueDir.appendingPathComponent("DSC_TMP.ARW.partial"))

            var firstRecoverWrites = 0
            @MainActor func verifyFirstUpgradeBoot() async throws {
                let restartedStore = try CameraOriginalStore(directory: root) { firstRecoverWrites += 1 }
                let channel = FakeSonyCameraChannel(entries: [])
                let backend = CameraWorkspaceBackend(storage: restartedStore, clientID: UUID()) { _, purpose, _ in
                    try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
                }
                let controller = IOSCameraController(backend: backend)
                try await waitUntil { controller.originals.count == 1 }
                let remainingDirs = try FileManager.default.contentsOfDirectory(atPath: originalsRoot.path)
                let adoptedData = try Data(contentsOf: restartedStore.verifiedURL(upgradeID))
                let adoptedOriginal = controller.originals.first
                try check(firstRecoverWrites == 1 &&
                          Set(remainingDirs) == [upgradeID.uuidString.lowercased(), residueDir.lastPathComponent] &&
                          !FileManager.default.fileExists(atPath: emptyJunkDir.path) &&
                          FileManager.default.fileExists(atPath: residueDir.path) &&
                          restartedStore.snapshot.originals.count == 1 &&
                          adoptedOriginal?.id == upgradeID &&
                          adoptedOriginal?.name == "DSC_UPGRADE.ARW" &&
                          adoptedOriginal?.size == UInt64(upgradeBytes.count) &&
                          adoptedOriginal?.digest == sha256Hex(upgradeBytes) &&
                          adoptedOriginal?.availability == .available &&
                          abs((adoptedOriginal?.savedAt.timeIntervalSince1970 ?? 0) - expectedMtime.timeIntervalSince1970) < 2 &&
                          controller.storedOriginalsBytes == UInt64(upgradeBytes.count) &&
                          adoptedData == upgradeBytes,
                          "P2-22 cross-version migration: Re-adopts complete orphan into history & byte count with 1 write, deletes empty dirs, and preserves nonempty residues")
                await drainBackend(backend)
            }
            try await verifyFirstUpgradeBoot()
            await Task.yield()

            // Idempotency: reopening after re-adoption performs 0 manifest writes and preserves the entry.
            var secondRecoverWrites = 0
            let reopenedStore = try CameraOriginalStore(directory: root) { secondRecoverWrites += 1 }
            try check(secondRecoverWrites == 0 &&
                      reopenedStore.snapshot.originals.map(\.id) == [upgradeID],
                      "P2-22 cross-version migration: Second recover() is idempotent with 0 manifest writes")

            // Prune protection & reclaimability: unexported kept; exported reclaimed cleanly.
            let unexportedPrune = try reopenedStore.pruneExportedOriginals()
            let exportedPrune = try reopenedStore.pruneExportedOriginals(exportedContentIdentifiers: [sha256Hex(upgradeBytes)])
            let postPruneDirs = try FileManager.default.contentsOfDirectory(atPath: originalsRoot.path)
            try check(unexportedPrune.originals == 0 &&
                      exportedPrune.originals == 1 &&
                      exportedPrune.freedBytes == UInt64(upgradeBytes.count) &&
                      postPruneDirs == [residueDir.lastPathComponent] &&
                      reopenedStore.snapshot.originals.isEmpty,
                      "P2-22 cross-version migration: Re-adopted original resists auto-delete before export and prunes once exported while residues remain")
        }

        // 2) Mixed recovery: coalesces .prepared promotion/discard and complete orphan re-adoption into 1 manifest write,
        // keeps .available, promoted .prepared, re-adopted complete orphan, and non-UUID marker; preserves nonempty residues and sweeps empty/missing .prepared dirs.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-p222-orphan-mix-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let bytes1 = makeLargeRAW(size: 4096, seed: 0x42)
            let bytes2 = makeLargeRAW(size: 6144, seed: 0x43)
            let bytes3 = makeLargeRAW(size: 4096, seed: 0x44)
            func snap(_ content: UInt32, _ name: String, _ bytes: Data) -> CameraAssetSnapshot {
                CameraAssetSnapshot(content: content, file: 1, storage: 0, format: 0x3800, name: name,
                                    size: UInt64(bytes.count), created: "\(baseMillis + UInt64(content) * 1_000)", modified: "")
            }

            var store: CameraOriginalStore? = try CameraOriginalStore(directory: root)
            let job = try store!.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [
                snap(1, "DSC08501.ARW", bytes1),
                snap(2, "DSC08502.ARW", bytes2),
                snap(3, "DSC08503.ARW", bytes3)
            ])
            func commit(_ data: Data, _ item: CameraTransferItem) throws -> CameraStoredOriginal {
                let target = try store!.begin(job: job.id, item: item.id)
                try target.handle.write(contentsOf: data)
                try target.handle.close()
                return try store!.complete(job: job.id, item: item.id, digest: sha256Hex(data))
            }
            let kept = try commit(bytes1, job.items[0])
            let preparedValid = try commit(bytes2, job.items[1])
            let preparedMissing = try commit(bytes3, job.items[2])

            var manifest = store!.snapshot
            manifest.jobs[0].items[1].phase = .prepared
            manifest.originals[1].availability = .prepared
            manifest.jobs[0].items[2].phase = .prepared
            manifest.originals[2].availability = .prepared
            try FileManager.default.removeItem(at: store!.originalURL(preparedMissing))

            let originalsRoot = root.appendingPathComponent("originals", isDirectory: true)
            let orphanCompleteID = UUID()
            let orphanCompleteDir = originalsRoot.appendingPathComponent(orphanCompleteID.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: orphanCompleteDir, withIntermediateDirectories: true)
            let orphanBytes = makeLargeRAW(size: 5120, seed: 0x45)
            try orphanBytes.write(to: orphanCompleteDir.appendingPathComponent("DSC_ORPHAN.ARW"))

            let orphanResidueDir = originalsRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: orphanResidueDir, withIntermediateDirectories: true)
            try Data([0x49, 0x49, 0x2a, 0]).write(to: orphanResidueDir.appendingPathComponent("DSC_RESIDUE.ARW.partial"))

            let nonUUIDMarker = originalsRoot.appendingPathComponent(".keep")
            try Data([1]).write(to: nonUUIDMarker)
            store = nil
            try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)

            var mixRecoverWrites = 0
            let restartedStore = try CameraOriginalStore(directory: root) { mixRecoverWrites += 1 }
            let channel = FakeSonyCameraChannel(entries: [])
            let backend = CameraWorkspaceBackend(storage: restartedStore, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            try await waitUntil { controller.originals.count == 3 }
            try check(mixRecoverWrites == 1 &&
                      FileManager.default.fileExists(atPath: orphanResidueDir.path) &&
                      FileManager.default.fileExists(atPath: orphanCompleteDir.path) &&
                      FileManager.default.fileExists(atPath: nonUUIDMarker.path) &&
                      restartedStore.snapshot.originals.map(\.id) == [kept.id, preparedValid.id, orphanCompleteID] &&
                      controller.storedOriginalsBytes == UInt64(bytes1.count + bytes2.count + orphanBytes.count) &&
                      restartedStore.snapshot.jobs[0].items[1].phase == .saved &&
                      restartedStore.snapshot.jobs[0].items[2].phase == .interrupted,
                      "P2-22 mixed recovery: Coalesces into 1 write, re-adopts complete orphan, sweeps empty .prepared-missing dirs, and preserves residues/.available/.prepared/non-UUID marker")
            let keptData = try Data(contentsOf: restartedStore.verifiedURL(kept.id))
            let preparedData = try Data(contentsOf: restartedStore.verifiedURL(preparedValid.id))
            let adoptedData = try Data(contentsOf: restartedStore.verifiedURL(orphanCompleteID))
            try check(keptData == bytes1 && preparedData == bytes2 && adoptedData == orphanBytes,
                      "P2-22 mixed recovery: Verified file bytes remain intact for referenced and re-adopted originals")
            await drainBackend(backend)
        }

        // 3) Empty UUID directories (ignoring .DS_Store) are removed with 0 manifest writes and 0 UI ghosts.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-p222-junk-zero-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            do { _ = try CameraOriginalStore(directory: root) }
            let originalsRoot = root.appendingPathComponent("originals", isDirectory: true)
            let junkDir = originalsRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: junkDir, withIntermediateDirectories: true)
            try Data([1]).write(to: junkDir.appendingPathComponent(".DS_Store"))

            var junkRecoverWrites = 0
            let restartedStore = try CameraOriginalStore(directory: root) { junkRecoverWrites += 1 }
            let channel = FakeSonyCameraChannel(entries: [])
            let backend = CameraWorkspaceBackend(storage: restartedStore, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            await drainBackend(backend)
            try await Task.sleep(nanoseconds: 50_000_000)
            let remainingEntries = try FileManager.default.contentsOfDirectory(atPath: originalsRoot.path)
            try check(junkRecoverWrites == 0 &&
                      remainingEntries.isEmpty &&
                      restartedStore.snapshot.originals.isEmpty &&
                      controller.originals.isEmpty &&
                      controller.storedOriginalsBytes == 0,
                      "P2-22 empty-only sweep: Removes an empty orphan ignoring .DS_Store with 0 manifest writes, 0 residuals, and 0 UI ghosts")
            await drainBackend(backend)
        }
    }

    #if os(macOS)
    @MainActor private static func runP222CrashChild(rootPath: String) async throws {
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:P2-22-EXIT", label: "Fake")
        let baseMillis: UInt64 = 1_700_000_000_000
        let counterLock = NSLock()
        var writeCount = 0
        func readWrites() -> Int { counterLock.lock(); defer { counterLock.unlock() }; return writeCount }

        let store = try CameraOriginalStore(directory: root) {
            counterLock.lock()
            writeCount += 1
            counterLock.unlock()
        }
        let entries = [
            FakeSonyCameraEntry(content: 1, name: "DSC08301.ARW", createdMillis: baseMillis + 1_000, bytes: makeLargeRAW(size: 262_144, seed: 0x61)),
            FakeSonyCameraEntry(content: 2, name: "DSC08302.ARW", createdMillis: baseMillis + 2_000, bytes: makeLargeRAW(size: (3 << 20) + 4096, seed: 0x62)),
            FakeSonyCameraEntry(content: 3, name: "DSC08303.ARW", createdMillis: baseMillis + 3_000, bytes: makeLargeRAW(size: 8192, seed: 0x63))
        ]
        let photo1ObservedOnUI = DispatchSemaphore(value: 0)
        let channel = FakeSonyCameraChannel(entries: entries)
        channel.onMobileDownloadChunk = { name, offset in
            guard name == "DSC08302.ARW", offset > 0 else { return }
            guard photo1ObservedOnUI.wait(timeout: .now() + 5) == .success else {
                fputs("Child timed out waiting for UI observation of photo 1 before _exit\n", stderr)
                Darwin._exit(99)
            }
            Darwin._exit(42)
        }
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
            try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
        }
        let controller = IOSCameraController(backend: backend)
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }
        let scan = controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: Double(baseMillis) / 1000), includeUndated: false)
        controller.startIncremental(scan)
        try await waitUntil(timeout: 10) {
            controller.savedCount == 1 && controller.originals.count == 1
        }
        let writesAtPhoto1Saved = readWrites()
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let diskManifest = try JSONDecoder().decode(CameraOriginalManifest.self, from: manifestData)
        guard writesAtPhoto1Saved == 2,
              diskManifest.originals.count == 1,
              diskManifest.originals[0].name == "DSC08301.ARW",
              diskManifest.jobs.first?.items.first?.phase == .saved else {
            fputs("Child invariant failed at photo 1 saved: writes=\(writesAtPhoto1Saved), diskOriginals=\(diskManifest.originals.count)\n", stderr)
            Darwin._exit(98)
        }
        photo1ObservedOnUI.signal()
        try await Task.sleep(nanoseconds: 5_000_000_000)
        Darwin._exit(97)
    }

    private static func runP222OrphanCrashChild(rootPath: String) async throws {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        _ = try CameraOriginalStore(directory: root)
        let originalsRoot = root.appendingPathComponent("originals", isDirectory: true)
        let completeDir = originalsRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: completeDir, withIntermediateDirectories: true)
        try makeLargeRAW(size: 8192, seed: 0x71).write(to: completeDir.appendingPathComponent("DSC_ORPHAN.ARW"))

        let residueDir = originalsRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: residueDir, withIntermediateDirectories: true)
        try Data([0x49, 0x49, 0x2a, 0]).write(to: residueDir.appendingPathComponent("DSC_TMP.ARW.partial"))

        let emptyJunkDir = originalsRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: emptyJunkDir, withIntermediateDirectories: true)
        Darwin._exit(42)
    }

    private static func runSubprocess(flag: String, root: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [flag, root.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationReason != .exit || process.terminationStatus != 42 {
            let errText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CameraProtocolError.invalid("Child \(flag) exited unexpectedly (reason: \(process.terminationReason.rawValue), status: \(process.terminationStatus)): \(errText)")
        }
        return process.terminationStatus
    }

    @MainActor static func testP222HardExitSubprocessDurabilityAndOrphanCleanup() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:P2-22-EXIT", label: "Fake")
        let baseMillis: UInt64 = 1_700_000_000_000

        // Part A: Real import child process saves photo 1, starts photo 2 chunk 2 -> Darwin._exit(42).
        // Parent restarts store + backend + controller and verifies:
        // (1) Photo 1 is durably persisted in manifest & originals/, counted in storedOriginalsBytes, and not re-downloaded on resume.
        // (2) Photo 2 partial file is cleaned, originals/ has 0 unreferenced directories, and remaining items 2+3 resume cleanly.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-p222-exit-a-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let exitStatus = try runSubprocess(flag: "--p222-crash-child", root: root)
            try check(exitStatus == 42, "P2-22 _exit(42) Part A: Child process hard-exited with status 42 during photo 2 download")

            let photo1Bytes = makeLargeRAW(size: 262_144, seed: 0x61)
            let photo2Bytes = makeLargeRAW(size: (3 << 20) + 4096, seed: 0x62)
            let photo3Bytes = makeLargeRAW(size: 8192, seed: 0x63)

            let restartedStore = try CameraOriginalStore(directory: root)
            let partialEntries = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("partial").path)
            let originalDirEntries = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path)
            let photo1 = try restartedStore.snapshot.originals.first ?? {
                throw CameraProtocolError.invalid("Photo 1 missing after _exit(42) recovery")
            }()
            try check(restartedStore.snapshot.originals.count == 1 &&
                      photo1.name == "DSC08301.ARW" &&
                      partialEntries.isEmpty &&
                      originalDirEntries == [photo1.id.uuidString.lowercased()],
                      "P2-22 _exit(42) Part A: Restart retains photo 1, sweeps partial/ of photo 2, and leaves 0 orphan directories")
            try check(try Data(contentsOf: restartedStore.verifiedURL(photo1.id)) == photo1Bytes,
                      "P2-22 _exit(42) Part A: Persisted photo 1 bytes verify intact on disk")

            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 101, name: "DSC08301.ARW", createdMillis: baseMillis + 1_000, bytes: photo1Bytes),
                FakeSonyCameraEntry(content: 102, name: "DSC08302.ARW", createdMillis: baseMillis + 2_000, bytes: photo2Bytes),
                FakeSonyCameraEntry(content: 103, name: "DSC08303.ARW", createdMillis: baseMillis + 3_000, bytes: photo3Bytes)
            ])
            let backend = CameraWorkspaceBackend(storage: restartedStore, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            try await waitUntil { controller.originals.count == 1 && controller.unfinishedJobs.count == 1 }
            try check(controller.storedOriginalsBytes == UInt64(photo1Bytes.count) &&
                      restartedStore.snapshot.jobs[0].items.map(\.phase) == [.saved, .queued, .queued],
                      "P2-22 _exit(42) Part A: Controller reports photo 1 bytes and shows items 2 & 3 pending")

            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 3 }
            try check(restartedStore.snapshot.jobs[0].requiresNewImport(connected: true, assets: controller.assets),
                      "P2-22 _exit(42) Part A: Reconnect across process restart routes unhashed pending items to fresh selection")

            // Fresh incremental scan over all 3 assets reuses persisted photo 1 via 3-segment sampling (no full re-download, no duplicate file).
            controller.customCutoff = Date(timeIntervalSince1970: Double(baseMillis) / 1000)
            let reconnectScan = controller.incrementalScan(customCutoff: controller.customCutoff, includeUndated: false)
            controller.startIncremental(reconnectScan)
            try await waitUntil(timeout: 10) {
                controller.phase == .browsing && restartedStore.snapshot.originals.count == 3 && controller.savedCount == 3
            }
            let expectedTotalBytes = UInt64(photo1Bytes.count + photo2Bytes.count + photo3Bytes.count)
            let postReconnectDirs = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path)
            let expectedDirs = Set(restartedStore.snapshot.originals.map { $0.id.uuidString.lowercased() })
            let job2 = restartedStore.snapshot.jobs.last
            let reusedItem1 = job2?.items.first { $0.asset.name == "DSC08301.ARW" }
            try check(channel.mobileRangeReads["DSC08301.ARW"]?.count == 3 &&
                      channel.bytesReadByName["DSC08301.ARW"] == 3 * 65_536 &&
                      reusedItem1?.reused == true &&
                      reusedItem1?.sourceID == photo1.id &&
                      job2?.complete == true &&
                      controller.storedOriginalsBytes == expectedTotalBytes &&
                      Set(postReconnectDirs) == expectedDirs &&
                      postReconnectDirs.count == 3,
                      "P2-22 _exit(42) Part A: Reconnect samples & reuses photo 1 without full re-download or disk duplication")
            await withCheckedContinuation { continuation in controller.stop { continuation.resume() } }
            await drainBackend(backend)
        }

        // Part B: Hard-exit child leaves unreferenced originals/<uuid>/ dirs: 1 complete photo (cross-version #339 crash)
        // plus a nonempty residue dir and an empty dir. Parent restarts store + backend + controller:
        // complete original is re-adopted and prunable after export; empty dir is deleted; nonempty residue is preserved.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-p222-exit-b-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let exitStatus = try runSubprocess(flag: "--p222-orphan-crash-child", root: root)
            let originalsRoot = root.appendingPathComponent("originals", isDirectory: true)
            let preRestartOriginals = try FileManager.default.contentsOfDirectory(atPath: originalsRoot.path)
            try check(exitStatus == 42 && preRestartOriginals.count == 3,
                      "P2-22 _exit(42) Part B: Child exited 42 leaving a complete original, a nonempty residue, and an empty directory before restart")

            let orphanBytes = makeLargeRAW(size: 8192, seed: 0x71)
            let restartedStore = try CameraOriginalStore(directory: root)
            let channel = FakeSonyCameraChannel(entries: [])
            let backend = CameraWorkspaceBackend(storage: restartedStore, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            try await waitUntil { controller.originals.count == 1 }
            let postRestartOriginals = try FileManager.default.contentsOfDirectory(atPath: originalsRoot.path)
            let adopted = try restartedStore.snapshot.originals.first ?? {
                throw CameraProtocolError.invalid("Complete orphan was not re-adopted in Part B")
            }()
            let adoptedData = try Data(contentsOf: restartedStore.verifiedURL(adopted.id))
            let residueName = try postRestartOriginals.first { name in
                FileManager.default.fileExists(atPath: originalsRoot.appendingPathComponent(name).appendingPathComponent("DSC_TMP.ARW.partial").path)
            } ?? { throw CameraProtocolError.invalid("Nonempty residue was deleted in Part B") }()
            try check(Set(postRestartOriginals) == [adopted.id.uuidString.lowercased(), residueName] &&
                      restartedStore.snapshot.originals.count == 1 &&
                      adopted.name == "DSC_ORPHAN.ARW" &&
                      adopted.availability == .available &&
                      controller.originals.map(\.id) == [adopted.id] &&
                      controller.storedOriginalsBytes == UInt64(orphanBytes.count) &&
                      adoptedData == orphanBytes,
                      "P2-22 _exit(42) Part B: Complete orphan re-adopted without loss, empty directory removed, and nonempty residue preserved")

            let pruned = try restartedStore.pruneExportedOriginals(exportedContentIdentifiers: [sha256Hex(orphanBytes)])
            let postPruneOriginals = try FileManager.default.contentsOfDirectory(atPath: originalsRoot.path)
            try check(pruned.originals == 1 && pruned.freedBytes == UInt64(orphanBytes.count) && postPruneOriginals == [residueName],
                      "P2-22 _exit(42) Part B: Re-adopted orphan reclaims via pruneExportedOriginals once exported while the residue remains")
            await drainBackend(backend)
        }
    }
    #endif

    @MainActor static func testIN4SkippedAssetsFIFOOverMaximumLimitSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-in4-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I-N4-CAP", label: "Fake")
        let device = CameraDeviceIdentity(manufacturer: "Sony", model: "ILCE-6700", firmware: "2.00", serial: "FAKE-SERIAL-01", operations: [])
        let baseMillis: UInt64 = 1_700_000_000_000

        func snapshot(_ index: Int) -> CameraAssetSnapshot {
            CameraAssetSnapshot(content: UInt32(index), file: 1, storage: 0, format: 0x3800,
                                name: String(format: "DSC%05d.ARW", index), size: 4096,
                                created: "\(baseMillis + UInt64(index))", modified: "")
        }

        func populateAndReopenCheck() async throws {
            let store = try CameraOriginalStore(directory: root)
            // Save 1 valid historical original to verify all originals survive restart after >10,000 skips.
            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 90_001, name: "DSC90001.ARW", createdMillis: baseMillis, bytes: validRAWBytes(71))
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
            controller.startIncremental(controller.incrementalScan(customCutoff: Date(timeIntervalSince1970: Double(baseMillis) / 1000 - 1), includeUndated: false))
            try await waitUntil { controller.phase == .browsing && store.snapshot.originals.count == 1 }
            await withCheckedContinuation { continuation in
                controller.stop { continuation.resume() }
            }
            await drainBackend(backend)

            // Skip 6,000 items then 4,001 items (cumulative 10,001 > maximumAssets 10,000).
            let batch1 = (1...6_000).map(snapshot)
            let job1 = try store.enqueue(device: device, connectionKey: endpoint.connectionKey,
                                         assets: batch1, listingOwner: UUID(),
                                         incremental: CameraIncrementalPlan(format: .raw, jpeg: CameraJPEGOptions(), boundary: nil, owner: nil, boundaries: nil))
            try store.performBatch {
                for item in job1.items {
                    try store.interrupt(job: job1.id, item: item.id, error: "bad header", cancelled: false, failureKind: .headerInvalid)
                }
            }
            try store.skipFailedIncrementalItems(job1.id)

            let batch2 = (6_001...10_001).map(snapshot)
            let job2 = try store.enqueue(device: device, connectionKey: endpoint.connectionKey,
                                         assets: batch2, listingOwner: UUID(),
                                         incremental: CameraIncrementalPlan(format: .raw, jpeg: CameraJPEGOptions(), boundary: nil, owner: nil, boundaries: nil))
            try store.performBatch {
                for item in job2.items {
                    try store.interrupt(job: job2.id, item: item.id, error: "bad header", cancelled: false, failureKind: .headerInvalid)
                }
            }
            try store.skipFailedIncrementalItems(job2.id)
        }

        try await populateAndReopenCheck()

        // Reopen store from disk: must not throw "Invalid camera storage manifest" and must preserve originals + newest 10,000 skipped items.
        let reopened = try CameraOriginalStore(directory: root)
        let skipped = reopened.snapshot.skippedAssets(for: device, connectionKey: endpoint.connectionKey)
        try check(reopened.snapshot.originals.count == 1,
                  "I-N4 FIFO cap: Reopening after 6,000 + 4,001 skipped items preserves historical originals")
        _ = try reopened.verifiedURL(reopened.snapshot.originals[0].id)
        try check(skipped.count == CameraIncrementalScan.maximumAssets &&
                  skipped.first?.name == "DSC00002.ARW" &&
                  skipped.last?.name == "DSC10001.ARW",
                  "I-N4 FIFO cap: Evicts oldest entry (DSC00001.ARW) and keeps newest 10,000 skipped items")
    }

    @MainActor static func testIN6TetheringResumeLimitAndExactBoundary10000To10001AndLanguageSwitch() async throws {
        let previousLang = UserDefaults.standard.string(forKey: L10n.preferenceKey)
        defer {
            UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey)
            if let previousLang {
                UserDefaults.standard.set(previousLang, forKey: L10n.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: L10n.preferenceKey)
            }
        }
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:I-N6-EDGE", label: "Fake")
        let baseMillis: UInt64 = 1_700_000_000_000
        let sampleBytes = validRAWBytes(77)
        let exact10000 = (1...10_000).map { index in
            FakeSonyCameraEntry(content: UInt32(index), name: String(format: "DSC%05d.ARW", index),
                                createdMillis: baseMillis + UInt64(index), bytes: sampleBytes)
        }

        // Part A: 10,000 -> legal shutter -> 10,001 -> .ready + listingLimitExceeded keep-alive past shutterTimeout -> backend.capture guard -> language switch cleanup -> recovery.
        do {
            UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-in6-10000-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let channel = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: exact10000)
            let shot10001 = FakeSonyCameraEntry(content: 10_001, name: "DSC10001.ARW",
                                                createdMillis: baseMillis + 50_000, bytes: validRAWBytes(92))
            channel.onShutter = { [weak channel] in
                // Caller already holds channel lock during write().
                channel?.entries.append(shot10001)
            }
            var openedSession: SonyCameraSession?
            var capturedRun: IOSCameraRun?
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID(), shutterTimeout: 3.5) { run, purpose, _ in
                capturedRun = run
                let s = try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
                openedSession = s
                return s
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: endpoint, mode: .tethering, cardConfirmed: true, resume: false)
            try await waitUntil { controller.phase == .ready && controller.shutterReady }
            try check(!controller.listingLimitExceeded,
                      "I-N6 boundary: Exactly 10,000 card items succeeds without triggering photoLimitExceeded")

            controller.capture()
            try await waitUntil(timeout: 6) {
                controller.listingLimitExceeded && controller.notice == "照片 · 已到上限"
            }
            try check(controller.connected && controller.phase == .ready && !controller.shutterReady &&
                      openedSession?.stopped == false && !channel.closed,
                      "I-N6 boundary: 10,000 -> legal shutter -> 10,001 settles to .ready + listingLimitExceeded instead of .waiting or .paused")

            // Wait past shutterTimeout (3.5s) across at least one more poll: captureUnknown 35s timeout must be exempted under limit.
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try check(controller.connected && controller.phase == .ready && controller.listingLimitExceeded &&
                      openedSession?.stopped == false && !channel.closed && controller.hasUnknownShot,
                      "I-N6 boundary: Poll elapsed past shutterTimeout exempts captureUnknown disconnect while listingLimitExceeded holds")

            // Direct backend.capture guard during async window / listingLimitExceeded must not fire shutter.
            let shuttersBefore = channel.shutterCommands
            if let run = capturedRun { backend.capture(run) }
            try await Task.sleep(nanoseconds: 200_000_000)
            try check(channel.shutterCommands == shuttersBefore && controller.phase == .ready,
                      "I-N6 guard: backend.capture drops shutter while listingLimitExceeded is active and stays .ready")

            // Finding 5: Switching UI language while over limit must still clear the limit notice upon recovery.
            UserDefaults.standard.set("en", forKey: L10n.preferenceKey)
            channel.updateEntries { $0 = [exact10000[0], exact10000[1], shot10001] }
            try await waitUntil(timeout: 6) {
                !controller.listingLimitExceeded &&
                    controller.phase == .ready &&
                    controller.shutterReady &&
                    store.snapshot.originals.count == 1
            }
            try check(controller.notice == nil && !controller.hasUnknownShot &&
                      store.snapshot.originals.map(\.name) == ["DSC10001.ARW"],
                      "I-N6 & L10n: Recovery clears limit notice regardless of mid-limit language switch and downloads shot 10,001")
            await withCheckedContinuation { continuation in
                controller.stop { continuation.resume() }
            }
            await drainBackend(backend)
        }

        // Part B: resume: true when card exceeds 10,000 keeps tether alive, blocks backend.capture, and triggers finishTetherResume upon recovery.
        do {
            UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-in6-resume-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let shot = FakeSonyCameraEntry(content: 20_001, name: "DSC20001.ARW",
                                           createdMillis: baseMillis + 60_000, bytes: validRAWBytes(83))
            @MainActor func recordTetherSession() async throws {
                let store1 = try CameraOriginalStore(directory: root)
                let ch1 = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: [])
                let backend1 = CameraWorkspaceBackend(storage: store1, clientID: UUID()) { _, purpose, _ in
                    try SonyCameraSession(client: CameraPTPClient(command: ch1, event: nil), purpose: purpose)
                }
                let ctrl1 = IOSCameraController(backend: backend1)
                ctrl1.connect(endpoint: endpoint, mode: .tethering, cardConfirmed: true, resume: false)
                try await waitUntil { ctrl1.phase == .ready && ctrl1.shutterReady }
                ch1.updateEntries { $0.append(shot) }
                try await waitUntil(timeout: 6) { store1.snapshot.originals.count == 1 && store1.snapshot.canResumeTether }
                await withCheckedContinuation { continuation in
                    ctrl1.stop { continuation.resume() }
                }
                await drainBackend(backend1)
            }
            try await recordTetherSession()

            let over10001 = [shot] + exact10000
            let store2 = try CameraOriginalStore(directory: root)
            let ch2 = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: over10001)
            var run2: IOSCameraRun?
            let backend2 = CameraWorkspaceBackend(storage: store2, clientID: UUID()) { run, purpose, _ in
                run2 = run
                return try SonyCameraSession(client: CameraPTPClient(command: ch2, event: nil), purpose: purpose)
            }
            let ctrl2 = IOSCameraController(backend: backend2)
            ctrl2.connect(endpoint: endpoint, mode: .tethering, cardConfirmed: true, resume: true)
            try await waitUntil(timeout: 5) { ctrl2.listingLimitExceeded && ctrl2.notice == "照片 · 已到上限" }
            try check(ctrl2.connected && ctrl2.phase == .ready && !ctrl2.shutterReady && !ch2.closed,
                      "I-N6 (resume:true): Reconnecting over 10,000 stays connected in .ready with limit notice")

            if let run2 { backend2.capture(run2) }
            try await Task.sleep(nanoseconds: 200_000_000)
            try check(ch2.shutterCommands == 0 && ctrl2.phase == .ready,
                      "I-N6 (resume:true): backend.capture blocks shutter while needsTetherResume + limit holds")

            ch2.updateEntries { $0 = [shot] }
            try await waitUntil(timeout: 6) {
                !ctrl2.listingLimitExceeded && ctrl2.phase == .ready && ctrl2.shutterReady
            }
            try check(ctrl2.notice == "已恢复已登记的接收任务。断线期间拍摄的照片请从相机手动导入。",
                      "I-N6 (resume:true): Dropping back <= 10,000 triggers finishTetherResume and unlocks shutter")
            await withCheckedContinuation { continuation in
                ctrl2.stop { continuation.resume() }
            }
            await drainBackend(backend2)
        }
    }

    @MainActor static func testP222PerformBatchPersistFailureRollbackAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-p222-fail-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:P2-22-FAIL", label: "Fake")
        let device = CameraDeviceIdentity(manufacturer: "Sony", model: "ILCE-6700", firmware: "2.00", serial: "FAKE-SERIAL-01", operations: [])
        let baseMillis: UInt64 = 1_700_000_000_000
        let counterLock = NSLock()
        var writeCount = 0
        func resetWrites() { counterLock.lock(); writeCount = 0; counterLock.unlock() }
        func readWrites() -> Int { counterLock.lock(); defer { counterLock.unlock() }; return writeCount }

        func asset(_ index: Int) -> CameraAssetSnapshot {
            CameraAssetSnapshot(content: UInt32(index), file: 1, storage: 0, format: 0x3800,
                                name: String(format: "DSC09%03d.ARW", index), size: 1024,
                                created: "\(baseMillis + UInt64(index))", modified: "")
        }

        func runCheck() async throws {
            let store = try CameraOriginalStore(directory: root) {
                counterLock.lock(); writeCount += 1; counterLock.unlock()
            }
            _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(0)])
            try check(store.snapshot.jobs.count == 1, "P2-22 persist failure: Seed job written")
            resetWrites()

            // 1) Normal batch exit where persist() fails: must throw, roll back memory to 1 seed job, and keep batchDepth == 0 so next batch still coalesces.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
            var normalExitThrew = false
            do {
                try store.performBatch {
                    _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(1)])
                    _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(2)])
                    _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(3)])
                }
            } catch {
                normalExitThrew = true
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try check(normalExitThrew && store.snapshot.jobs.count == 1 && readWrites() == 0,
                      "P2-22 persist failure: Rolls back memory state cleanly on exit persist failure (jobs: \(store.snapshot.jobs.count), writes: \(readWrites()))")

            try store.performBatch {
                _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(11)])
                _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(12)])
                _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(13)])
            }
            let writesAfterNormalRecovery = readWrites()
            try check(writesAfterNormalRecovery == 1 && store.snapshot.jobs.count == 4,
                      "P2-22 persist failure recovery: Next performBatch with 3 changes still coalesces to 1 write (actual: \(writesAfterNormalRecovery))")

            // 2) Exception batch exit where persist() also fails: must surface persist failure (not swallow), roll back, and recover batchDepth.
            resetWrites()
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
            var exceptionExitError: Error?
            do {
                try store.performBatch {
                    _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(21)])
                    _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(22)])
                    throw CameraProtocolError.cancelled
                }
            } catch {
                exceptionExitError = error
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            let isCancelledOnly = (exceptionExitError as? CameraProtocolError).map {
                if case .cancelled = $0 { return true }; return false
            } ?? false
            try check(exceptionExitError != nil && !isCancelledOnly && store.snapshot.jobs.count == 4 && readWrites() == 0,
                      "P2-22 catch persist failure: Surfaces storage persist failure and rolls back pre-batch state")

            try store.performBatch {
                _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(31)])
                _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(32)])
                _ = try store.enqueue(device: device, connectionKey: endpoint.connectionKey, assets: [asset(33)])
            }
            let writesAfterCatchRecovery = readWrites()
            try check(writesAfterCatchRecovery == 1 && store.snapshot.jobs.count == 7,
                      "P2-22 catch persist failure recovery: Next performBatch with 3 changes still coalesces to 1 write (actual: \(writesAfterCatchRecovery))")
        }

        try await runCheck()
        let reopened = try CameraOriginalStore(directory: root)
        try check(reopened.snapshot.jobs.count == 7,
                  "P2-22 persist failure recovery: On-disk manifest matches 7 committed jobs with zero split-brain")
    }

    @MainActor static func test508ThumbnailsDoNotBlockCommandQueueOrHashFullFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-508-thumb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let jpegBytes = try makeLargeJPEG(targetSize: 256_000, seed: 7)
        let digest = sha256Hex(jpegBytes)
        let device = CameraDeviceIdentity(manufacturer: "Sony", model: "ILCE-6700", firmware: "2.00", serial: "0508", operations: [0x923c, 0x923d])
        let snapshot = CameraAssetSnapshot(content: 1, file: 1, storage: 0, format: 0,
                                           name: "DSC00508.JPG", size: UInt64(jpegBytes.count),
                                           created: "1700000050800", modified: "")
        let job = try store.enqueue(device: device, connectionKey: "fixture", assets: [snapshot])
        let target = try store.begin(job: job.id, item: job.items[0].id)
        try target.handle.write(contentsOf: jpegBytes)
        try target.handle.close()
        let savedOriginal = try store.complete(job: job.id, item: job.items[0].id, digest: digest)
        let savedURL = store.originalURL(savedOriginal)

        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID())
        let controller = IOSCameraController(backend: backend)
        try await waitUntil { !controller.manifest.originals.isEmpty }

        FileDigestCache.shared.invalidateAll()
        let beforeWork = CameraOriginalStore.fullFileHashCount + FileDigestCache.shared.digestComputeCount
        let beforeFileCount = FileDigestCache.shared.digestComputeCount(for: savedURL)

        let stateLock = NSLock()
        var queueEntered = false
        let releaseQueue = DispatchSemaphore(value: 0)
        backend.queue.async {
            stateLock.lock(); queueEntered = true; stateLock.unlock()
            _ = releaseQueue.wait(timeout: .now() + 5)
        }
        defer { releaseQueue.signal() }
        try await waitUntil(timeout: 2.0) {
            stateLock.lock(); defer { stateLock.unlock() }
            return queueEntered
        }
        try check({ stateLock.lock(); defer { stateLock.unlock() }; return queueEntered }(),
                  "508 setup: backend.queue entered blocked state")

        controller.thumbnail(savedOriginal)
        try await waitUntil(timeout: 1.5) {
            controller.thumbnails[savedOriginal.id.uuidString] != nil
        }
        let afterThumbWork = CameraOriginalStore.fullFileHashCount + FileDigestCache.shared.digestComputeCount
        try check(afterThumbWork - beforeWork == 0 && FileDigestCache.shared.digestComputeCount(for: savedURL) == beforeFileCount,
                  "508 thumbnail loads while backend.queue is blocked with 0 full-file SHA-256 computations")

        controller.showPreview(savedOriginal)
        try await waitUntil(timeout: 1.5) {
            !controller.previewLoading && controller.preview != nil
        }
        let afterPreviewWork = CameraOriginalStore.fullFileHashCount + FileDigestCache.shared.digestComputeCount
        try check(afterPreviewWork - beforeWork == 0 && FileDigestCache.shared.digestComputeCount(for: savedURL) == beforeFileCount,
                  "508 original preview loads while backend.queue is blocked with 0 full-file SHA-256 computations")
    }

    @MainActor static func testTetheringTouchFocusAndCancelLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-tether-focus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let channel = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: [])
        channel.tetherControls = [0xd2c1, 0xd2c2, 0xd2e4, 0xd2e5, 0xd2dc]
        channel.tetherExtraProps = [
            (0x500a, 4, true, 1, 2),
            (0xd22c, 4, true, 1, 0x0001),
            (0xd284, 2, false, 1, 1),
            (0xd285, 2, false, 0, 0),
            (0xd213, 2, false, 1, 1),
        ]
        var nextS1Indication: Int64 = 6
        channel.on9207 = { code, value in
            if code == 0xd2e4 {
                channel.setExtraProperty(0xd285, value: 1, enabled: 1)
                // Simulate real a7C II: 0xD2E4 leaves 0xD213=1 until S1 half-press (0xD2C1).
                channel.setExtraProperty(0xd213, value: 1, enabled: 1)
            } else if code == 0xd2c1 && value == 2 {
                channel.setExtraProperty(0xd213, value: nextS1Indication, enabled: 1)
            } else if code == 0xd2c1 && value == 1 {
                channel.setExtraProperty(0xd213, value: 1, enabled: 1)
            } else if code == 0xd2e5 && value == 1 {
                channel.setExtraProperty(0xd285, value: 0, enabled: 0)
                channel.setExtraProperty(0xd213, value: 1, enabled: 1)
            }
        }
        var openedSession: SonyCameraSession?
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
            let s = try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            openedSession = s
            return s
        }
        let controller = IOSCameraController(backend: backend)
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FOCUS", label: "Fake")
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
        controller.connect(endpoint: endpoint, mode: .tethering, cardConfirmed: true, resume: false)
        try await waitUntil { controller.phase == .ready && controller.shutterReady }
        try check(!controller.cameraFocusLocked, "Initial 0xD213=1 is not focus-locked")

        // 1. Tap-to-focus via 0xD2E4 + S1 half-press latches cameraFocusLocked=true even after S1 release resets 0xD213=1
        controller.setFocusPoint(u: 0.25, v: 0.25, x: 160, y: 120)
        try check(controller.focusBusy && controller.tapFocusPoint != nil && controller.liveViewFrames.isEmpty,
                  "setFocusPoint enters focusBusy with tap reticle and clears stale overlays")
        try await waitUntil(timeout: 3.0) { !controller.focusBusy }
        try check(controller.phase == .ready && controller.canCancelTouchFocus && controller.cameraFocusLocked &&
                  controller.properties[0xd213]?.number == 1 && controller.notice == nil &&
                  channel.recorded9207.map(\.0) == [0xd2e4, 0xd2c1, 0xd2c1] &&
                  channel.recorded9207.map(\.1) == [UInt32((160 << 16) | 120), 2, 1],
                  "Tether tap-to-focus runs 0xD2E4 then S1 press+release and latches focus lock")

        // 1b. Low-contrast failure (0xD213=3) clears previous lock and keeps cameraFocusLocked=false
        nextS1Indication = 3
        controller.setFocusPoint(u: 0.4, v: 0.4, x: 256, y: 192)
        try await waitUntil(timeout: 3.0) { !controller.focusBusy }
        try check(controller.phase == .ready && !controller.cameraFocusLocked && controller.notice == nil,
                  "Low-contrast 0xD213=3 leaves cameraFocusLocked false")
        nextS1Indication = 6

        // 2. Cancel touch focus via 0xD2E5 clears cancel pill and resets 0xD285=0
        controller.cancelTouchFocus()
        try await waitUntil(timeout: 3.0) { !controller.focusBusy }
        try check(controller.phase == .ready && !controller.canCancelTouchFocus && !controller.cameraFocusLocked && controller.notice == nil &&
                  channel.recorded9207.suffix(2).map(\.0) == [0xd2e5, 0xd2e5] &&
                  channel.recorded9207.suffix(2).map(\.1) == [2, 1],
                  "cancelTouchFocus sends 0xD2E5 press+release, clears focus lock, and hides cancel pill")

        // 3. Non-fatal PTP rejection keeps tether session .ready with notice
        channel.next9207Status = 0x2019
        controller.setFocusPoint(u: 0.5, v: 0.5, x: 320, y: 240)
        try await waitUntil(timeout: 3.0) { !controller.focusBusy && controller.notice != nil }
        try check(controller.connected && controller.phase == .ready && openedSession?.stopped == false &&
                  controller.tapFocusPoint == nil && controller.notice == "当前状态下相机未接受对焦点设置。",
                  "Aligned 0x9207 rejection keeps tether session ready with focus notice")

        // 4. Manual focus (0x500A == 1, 0xD284 == 0) surfaces MF notice with 0 extra 0x9207 writes
        channel.setExtraProperty(0xd284, value: 0, enabled: 0)
        channel.setExtraProperty(0x500a, value: 1, enabled: 1)
        let writeCountBeforeMF = channel.recorded9207.count
        controller.setFocusPoint(u: 0.5, v: 0.5, x: 320, y: 240)
        try await waitUntil(timeout: 3.0) { !controller.focusBusy && controller.notice == "当前为手动对焦（MF），无法选择对焦点。" }
        try check(controller.connected && controller.phase == .ready && channel.recorded9207.count == writeCountBeforeMF,
                  "MF mode reports notice with 0 0x9207 writes and keeps session ready")

        await withCheckedContinuation { continuation in
            controller.stop { continuation.resume() }
        }
        await drainBackend(backend)
    }

    @MainActor static func testManualBrowseOrderNewestFirst() async throws {
        // 1) Mobile protocol end-to-end via controller: newest capture first, equal timestamps reversed, undated last,
        //    while controller.assets retains protocol listing order.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-manual-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let baseMillis: UInt64 = 1_700_000_000_000
        let sample = validRAWBytes(1)
        let entries = [
            FakeSonyCameraEntry(content: 1, name: "DSC00000.ARW", createdMillis: 1, bytes: sample),
            FakeSonyCameraEntry(content: 2, name: "DSC00001.ARW", createdMillis: baseMillis + 1_000, bytes: sample),
            FakeSonyCameraEntry(content: 3, name: "DSC00002.ARW", createdMillis: baseMillis + 2_000, bytes: sample),
            FakeSonyCameraEntry(content: 4, name: "DSC00002.JPG", createdMillis: baseMillis + 2_000, bytes: sample),
            FakeSonyCameraEntry(content: 5, name: "DSC00003.ARW", createdMillis: baseMillis + 5_000, bytes: sample),
            FakeSonyCameraEntry(content: 6, name: "DSC00004.ARW", createdMillis: baseMillis + 9_000, bytes: sample)
        ]
        let channel = FakeSonyCameraChannel(mode: .mobile, entries: entries)
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
            try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
        }
        let controller = IOSCameraController(backend: backend)
        controller.connect(endpoint: IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FAKE", label: "Fake"),
                           mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 6 }

        try check(controller.assets.map(\.snapshot.name) == [
            "DSC00000.ARW", "DSC00001.ARW", "DSC00002.ARW", "DSC00002.JPG", "DSC00003.ARW", "DSC00004.ARW"
        ], "Manual sort preserves protocol listing order in controller.assets")
        try check(controller.manualAssets.map(\.snapshot.name) == [
            "DSC00004.ARW", "DSC00003.ARW", "DSC00002.JPG", "DSC00002.ARW", "DSC00001.ARW", "DSC00000.ARW"
        ], "Manual browse order shows newest mobile capture first, reverses equal-timestamp ties, and puts undated last")
        controller.stop()

        // 2) Legacy protocol snapshots (yyyyMMdd'T'HHmmss): newest first, same-second burst reversed, undated last.
        let owner = UUID()
        func legacy(_ content: UInt32, _ name: String, _ created: String) -> CameraRemoteAsset {
            CameraRemoteAsset(owner: owner, snapshot: CameraAssetSnapshot(
                content: content, file: 0, storage: 0x00010001, format: 0x3801,
                name: name, size: 1024, created: created, modified: ""
            ))
        }
        let legacyInput = [
            legacy(1, "DSC_OLD.ARW", "20261120T090000"),
            legacy(2, "DSC_BURST_1.ARW", "20261121T170000"),
            legacy(3, "DSC_BURST_2.JPG", "20261121T170000"),
            legacy(4, "DSC_MID.ARW", "20261121T103000"),
            legacy(5, "DSC_UNDATED.ARW", "")
        ]
        try check(IOSCameraController.manualBrowseOrder(legacyInput).map(\.snapshot.name) == [
            "DSC_BURST_2.JPG", "DSC_BURST_1.ARW", "DSC_MID.ARW", "DSC_OLD.ARW", "DSC_UNDATED.ARW"
        ], "Manual browse order sorts legacy snapshots newest first, reverses same-second ties, and puts undated last")
    }

    @MainActor static func testCameraImportSavesToPhotoLibraryWithoutDuplicatingOrLosingOnDenial() async throws {
        final class MockCameraPhotoLibrarySaver: CameraPhotoLibrarySaving {
            private let lock = NSLock()
            var authorized = true
            var shouldFailSave = false
            var existingAssetIDs: Set<String>? = nil
            private(set) var savedFiles: [(assetID: String, filename: String, digest: String, fileExisted: Bool)] = []
            private var nextID = 1

            func requestAddAuthorization() -> Bool {
                lock.lock(); defer { lock.unlock() }
                return authorized
            }

            func assetExists(_ identifier: String) -> Bool? {
                lock.lock(); defer { lock.unlock() }
                guard let existingAssetIDs else { return nil }
                return existingAssetIDs.contains(identifier)
            }

            func saveOriginal(at fileURL: URL, filename: String, digest: String) throws -> String {
                lock.lock(); defer { lock.unlock() }
                guard authorized else { throw CameraPhotoLibraryError.permissionDenied }
                guard !shouldFailSave else { throw CameraPhotoLibraryError.saveFailed("Simulated Photos write error") }
                let assetID = "ph-asset-\(nextID)"
                nextID += 1
                let existed = FileManager.default.fileExists(atPath: fileURL.path)
                savedFiles.append((assetID: assetID, filename: filename, digest: digest, fileExisted: existed))
                if existingAssetIDs != nil { existingAssetIDs?.insert(assetID) }
                return assetID
            }
        }

        // Subtest A: Normal import (ARW + JPG) saves to Photos via fileURL, avoids duplicates on re-import,
        // and re-saves if deleted from Photos when verifiable.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-photos-a-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let saver = MockCameraPhotoLibrarySaver()
            let now = UInt64(Date().timeIntervalSince1970 * 1000) + 1_000
            let rawBytes = validRAWBytes(11)
            let jpegBytes = try makeLargeJPEG(targetSize: 16_384, seed: 22)
            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC09001.ARW", createdMillis: now + 1_000, bytes: rawBytes),
                FakeSonyCameraEntry(content: 2, name: "DSC09002.JPG", createdMillis: now + 2_000, bytes: jpegBytes)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID(), photoLibrarySaver: saver) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            controller.connect(endpoint: IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FAKE", label: "Fake"),
                               mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 2 }

            controller.selection = Set(controller.assets.map(\.id))
            controller.importSelected()
            try await waitUntil { controller.phase == .browsing && controller.lastSavedToPhotoLibraryCount == 2 }

            try check(saver.savedFiles.count == 2 && saver.savedFiles.allSatisfy(\.fileExisted),
                      "Photos Subtest A: Imports stream verified on-disk ARW and JPG files to photo library")
            try check(controller.notice == nil && !controller.photoLibraryPermissionDenied && controller.selection.isEmpty,
                      "Photos Subtest A: Successful import shows zero error, reports 2 saved, and clears selection")
            let rawOrig = try store.snapshot.originals.first { $0.name == "DSC09001.ARW" }
                ?? { throw CameraProtocolError.invalid("Missing DSC09001.ARW") }()
            let jpgOrig = try store.snapshot.originals.first { $0.name == "DSC09002.JPG" }
                ?? { throw CameraProtocolError.invalid("Missing DSC09002.JPG") }()
            try check(rawOrig.photoLibraryAssetID == "ph-asset-1" && jpgOrig.photoLibraryAssetID == "ph-asset-2",
                      "Photos Subtest A: photoLibraryAssetID is recorded in store snapshot")

            let onDiskManifest = try JSONDecoder().decode(
                CameraOriginalManifest.self,
                from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
            )
            let diskRawID = onDiskManifest.originals.first { $0.name == "DSC09001.ARW" }?.photoLibraryAssetID
            let diskJpgID = onDiskManifest.originals.first { $0.name == "DSC09002.JPG" }?.photoLibraryAssetID
            try check(diskRawID == "ph-asset-1" && diskJpgID == "ph-asset-2",
                      "Photos Subtest A: photoLibraryAssetID persists to manifest.json on disk")

            // Re-import in addOnly mode (assetExists returns nil): must NOT duplicate in Photos.
            controller.selection = Set(controller.assets.map(\.id))
            controller.importSelected()
            try await waitUntil { controller.phase == .browsing && controller.lastSavedToPhotoLibraryCount == 2 }
            try check(saver.savedFiles.count == 2,
                      "Photos Subtest A: Re-import in addOnly mode does not duplicate already-saved Photos assets")

            // Simulate user deleting DSC09001.ARW from Photos while DSC09002.JPG remains.
            saver.existingAssetIDs = [jpgOrig.photoLibraryAssetID!]
            controller.selection = Set(controller.assets.map(\.id))
            controller.importSelected()
            try await waitUntil { controller.phase == .browsing && saver.savedFiles.count == 3 }
            let updatedRawID = store.snapshot.originals.first { $0.name == "DSC09001.ARW" }?.photoLibraryAssetID
            try check(saver.savedFiles.count == 3 && saver.savedFiles[2].filename == "DSC09001.ARW" && updatedRawID == "ph-asset-3",
                      "Photos Subtest A: Deleted-from-Photos asset is re-saved once when verified missing, updating assetID")
            controller.stop()
        }

        // Subtest B: Permission denied keeps local originals in CameraOriginalStore, keeps session connected,
        // and subsequent re-import after permission grant saves the sampled reuse to Photos.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-photos-b-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let saver = MockCameraPhotoLibrarySaver()
            saver.authorized = false
            let now = UInt64(Date().timeIntervalSince1970 * 1000) + 1_000
            let rawBytes = makeLargeRAW(size: 256_000, seed: 3)
            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC09003.ARW", createdMillis: now + 1_000, bytes: rawBytes)
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID(), photoLibrarySaver: saver) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
            controller.connect(endpoint: IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FAKE", label: "Fake"),
                               mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }

            controller.selection = [controller.assets[0].id]
            controller.importSelected()
            try await waitUntil { controller.phase == .browsing && controller.notice != nil }

            try check(store.snapshot.originals.count == 1 && store.snapshot.originals[0].photoLibraryAssetID == nil && saver.savedFiles.isEmpty,
                      "Photos Subtest B: Denied Photos permission retains downloaded original locally with nil photoLibraryAssetID")
            try check(controller.connected && controller.photoLibraryPermissionDenied && controller.lastSavedToPhotoLibraryCount == 0
                      && controller.notice == "照片已保存在 RawLab 内，但未保存到手机相册。请在系统设置中允许 RawLab 添加照片。",
                      "Photos Subtest B: Denied Photos permission keeps camera connected and surfaces actionable guidance")

            // Grant permission and re-import (triggers 3x64KiB sampling reuse and completes Photos save).
            channel.resetTransferStats()
            saver.authorized = true
            controller.selection = [controller.assets[0].id]
            controller.importSelected()
            try await waitUntil { controller.phase == .browsing && controller.lastSavedToPhotoLibraryCount == 1 }

            let sampledBytes = channel.mobileRangeReads["DSC09003.ARW", default: []].reduce(0) { $0 + $1.count }
            try check(saver.savedFiles.count == 1 && store.snapshot.originals[0].photoLibraryAssetID == "ph-asset-1"
                      && !controller.photoLibraryPermissionDenied && controller.notice == nil && sampledBytes == 196_608,
                      "Photos Subtest B: Re-importing after permission grant reuses local original and saves to Photos")
            controller.stop()
        }

        // Subtest C: Photos write error preserves local original and keeps camera connected.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-photos-c-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try CameraOriginalStore(directory: root)
            let saver = MockCameraPhotoLibrarySaver()
            saver.shouldFailSave = true
            let now = UInt64(Date().timeIntervalSince1970 * 1000) + 1_000
            let channel = FakeSonyCameraChannel(entries: [
                FakeSonyCameraEntry(content: 1, name: "DSC09004.ARW", createdMillis: now + 1_000, bytes: validRAWBytes(4))
            ])
            let backend = CameraWorkspaceBackend(storage: store, clientID: UUID(), photoLibrarySaver: saver) { _, purpose, _ in
                try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
            }
            let controller = IOSCameraController(backend: backend)
            UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
            controller.connect(endpoint: IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FAKE", label: "Fake"),
                               mode: .importing, cardConfirmed: false, resume: false)
            try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }

            controller.selection = [controller.assets[0].id]
            controller.importSelected()
            try await waitUntil { controller.phase == .browsing && controller.notice != nil }

            try check(store.snapshot.originals.count == 1 && store.snapshot.originals[0].photoLibraryAssetID == nil
                      && controller.connected && !controller.photoLibraryPermissionDenied
                      && controller.notice == "照片已保存在 RawLab 内，但部分照片未能保存到手机相册。",
                      "Photos Subtest C: Photos write failure retains local original, stays connected, and shows partial-failure notice")
            controller.stop()
        }
    }

    @MainActor static func testTetheringAutomaticallySavesNewShotsToPhotoLibrary() async throws {
        final class TetherPhotoLibrarySaver: CameraPhotoLibrarySaving {
            private let lock = NSLock()
            var authorized = true
            private(set) var requestAuthCalls = 0
            private(set) var savedFiles: [(assetID: String, filename: String, fileExisted: Bool)] = []
            private var nextID = 1

            func requestAddAuthorization() -> Bool {
                lock.lock(); defer { lock.unlock() }
                requestAuthCalls += 1
                return authorized
            }

            func saveOriginal(at fileURL: URL, filename: String, digest: String) throws -> String {
                lock.lock(); defer { lock.unlock() }
                guard authorized else { throw CameraPhotoLibraryError.permissionDenied }
                let assetID = "ph-tether-\(nextID)"
                nextID += 1
                savedFiles.append((assetID: assetID, filename: filename, fileExisted: FileManager.default.fileExists(atPath: fileURL.path)))
                return assetID
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-tether-photos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let saver = TetherPhotoLibrarySaver()
        let baseMillis: UInt64 = 1_700_000_000_000
        let baselineEntry = FakeSonyCameraEntry(content: 1, name: "DSC09100.ARW", createdMillis: baseMillis + 1_000, bytes: validRAWBytes(90))
        let channel = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: [baselineEntry])
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID(), photoLibrarySaver: saver) { _, purpose, _ in
            try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
        }
        let controller = IOSCameraController(backend: backend)
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
        controller.connect(endpoint: IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:TETHER-PH", label: "Fake"),
                           mode: .tethering, cardConfirmed: true, resume: false)
        try await waitUntil { controller.phase == .ready && controller.canCapture }

        try check(saver.requestAuthCalls >= 1 && saver.savedFiles.isEmpty,
                  "Tether Photos: Pre-authorizes photo library on connect without saving baseline card photos")

        // Shot 1: Software shutter appends DSC09101.ARW -> auto-downloaded & saved to Photos.
        channel.onShutter = { [weak channel] in
            channel?.entries.append(
                FakeSonyCameraEntry(content: 2, name: "DSC09101.ARW", createdMillis: baseMillis + 2_000, bytes: validRAWBytes(91))
            )
        }
        controller.capture()
        try await waitUntil(timeout: 8) { controller.phase == .ready && controller.recentTetherOriginals.count == 1 }
        try check(saver.savedFiles.count == 1 && saver.savedFiles[0].filename == "DSC09101.ARW" && saver.savedFiles[0].fileExisted
                  && controller.recentTetherOriginals[0].photoLibraryAssetID == "ph-tether-1" && controller.notice == nil,
                  "Tether Photos (Shot 1): Software shutter auto-saves new ARW to photo library with assetID")

        // Shot 2: Camera-side shutter appends DSC09102.JPG -> polled & saved to Photos without duplicating Shot 1.
        let jpegBytes = try makeLargeJPEG(targetSize: 16_384, seed: 92)
        channel.updateEntries {
            $0.append(FakeSonyCameraEntry(content: 3, name: "DSC09102.JPG", createdMillis: baseMillis + 3_000, bytes: jpegBytes))
        }
        try await waitUntil(timeout: 8) { controller.phase == .ready && controller.recentTetherOriginals.count == 2 }
        try check(saver.savedFiles.count == 2 && saver.savedFiles[1].filename == "DSC09102.JPG" && saver.savedFiles[1].fileExisted
                  && controller.recentTetherOriginals.allSatisfy { $0.photoLibraryAssetID != nil },
                  "Tether Photos (Shot 2): Camera-side shutter auto-saves new JPG to photo library without duplicating Shot 1")

        // Shot 3: Photos permission denied mid-session -> preserves local original in store and keeps tether ready.
        saver.authorized = false
        channel.updateEntries {
            $0.append(FakeSonyCameraEntry(content: 4, name: "DSC09103.ARW", createdMillis: baseMillis + 4_000, bytes: validRAWBytes(93)))
        }
        try await waitUntil(timeout: 8) {
            controller.phase == .ready && controller.recentTetherOriginals.count == 3 && controller.notice != nil
        }
        let shot3 = controller.recentTetherOriginals.first { $0.name == "DSC09103.ARW" }
        try check(controller.connected && controller.phase == .ready && controller.canCapture
                  && controller.photoLibraryPermissionDenied
                  && controller.notice == "照片已保存在 RawLab 内，但未保存到手机相册。请在系统设置中允许 RawLab 添加照片。"
                  && store.snapshot.originals.count == 3 && shot3?.photoLibraryAssetID == nil,
                  "Tether Photos (Shot 3): Denied Photos permission retains local tethered original and keeps tether session active")

        await withCheckedContinuation { continuation in
            controller.stop { continuation.resume() }
        }
        await drainBackend(backend)
    }

    @MainActor static func testManualImportAppliesJPEGResizeAndSavesResizedBytesToPhotoLibrary() async throws {
        final class RecordingPhotoLibrarySaver: CameraPhotoLibrarySaving {
            private let lock = NSLock()
            private var nextID = 1
            private(set) var saved: [(filename: String, url: URL, size: UInt64, pixelSize: CGSize?)] = []

            func requestAddAuthorization() -> Bool { true }

            func saveOriginal(at fileURL: URL, filename: String, digest: String) throws -> String {
                let data = try Data(contentsOf: fileURL)
                let dims: CGSize?
                if let src = CGImageSourceCreateWithData(data as CFData, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                   let w = props[kCGImagePropertyPixelWidth] as? Int,
                   let h = props[kCGImagePropertyPixelHeight] as? Int {
                    dims = CGSize(width: w, height: h)
                } else {
                    dims = nil
                }
                lock.lock(); defer { lock.unlock() }
                let assetID = "ph-manual-jpeg-\(nextID)"
                nextID += 1
                saved.append((filename: filename, url: fileURL, size: UInt64(data.count), pixelSize: dims))
                return assetID
            }
        }

        func makeLargeLandscapeJPEG(width: Int, height: Int, targetSize: Int) throws -> Data {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw CameraProtocolError.invalid("Failed to construct test CGContext")
            }
            ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = ctx.makeImage() else {
                throw CameraProtocolError.invalid("Failed to construct test CGImage")
            }
            let encoded = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else {
                throw CameraProtocolError.invalid("Failed to construct JPEG encoder")
            }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw CameraProtocolError.invalid("Failed to finalize landscape JPEG")
            }
            let base = encoded as Data
            var out = Data(capacity: max(targetSize, base.count))
            out.append(base.prefix(2))
            var remaining = max(0, targetSize - base.count)
            while remaining >= 4 {
                let payload = min(32_768, remaining - 4)
                let segLen = UInt16(payload + 2)
                out.append(contentsOf: [0xff, 0xfe, UInt8(segLen >> 8), UInt8(segLen & 0xff)])
                out.append(Data(repeating: 0x22, count: payload))
                remaining -= (4 + payload)
            }
            out.append(base.dropFirst(2))
            return out
        }

        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-manual-jpeg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let saver = RecordingPhotoLibrarySaver()
        let rawBytes = validRAWBytes(15)
        let jpegBytes = try makeLargeLandscapeJPEG(width: 128, height: 64, targetSize: 250_000)
        let baseMillis: UInt64 = 1_700_000_000_000
        let channel = FakeSonyCameraChannel(entries: [
            FakeSonyCameraEntry(content: 1, name: "DSC09201.ARW", createdMillis: baseMillis + 1_000, bytes: rawBytes),
            FakeSonyCameraEntry(content: 2, name: "DSC09201.JPG", createdMillis: baseMillis + 1_000, bytes: jpegBytes)
        ])
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID(), photoLibrarySaver: saver) { _, purpose, _ in
            try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
        }
        let controller = IOSCameraController(backend: backend)
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:MANUAL-JPEG", label: "Fake")
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 2 }

        // 1) Manual mode with adjust=true shrinks JPEG to 40x20, keeps ARW untouched, and sends shrunk JPEG to Photos.
        controller.setIncrementalMode(false)
        controller.setJPEGOptions(CameraJPEGOptions(adjust: true, longEdge: 40, quality: 72))
        controller.selection = Set(controller.assets.map(\.id))
        controller.importSelected()
        try await waitUntil { controller.phase == .browsing && controller.lastSavedToPhotoLibraryCount == 2 }

        let adjustedOrig = try store.snapshot.originals.first { $0.name == "DSC09201.JPG" }
            ?? { throw CameraProtocolError.invalid("Missing manual adjusted JPG") }()
        let savedToPhotosAdjusted = saver.saved.first { $0.filename == "DSC09201.JPG" }
        try check(adjustedOrig.jpegSource?.options == CameraJPEGOptions(adjust: true, longEdge: 40, quality: 72)
                  && savedToPhotosAdjusted?.pixelSize == CGSize(width: 40, height: 20)
                  && adjustedOrig.size < UInt64(jpegBytes.count),
                  "Manual import with adjust=true resizes JPEG to 40x20 and streams resized file to Photos")
        let storedRaw = try store.snapshot.originals.first { $0.name == "DSC09201.ARW" }
            ?? { throw CameraProtocolError.invalid("Missing manual ARW") }()
        let storedRawBytes = try Data(contentsOf: store.verifiedURL(storedRaw.id))
        try check(storedRaw.jpegSource == nil && storedRawBytes == rawBytes,
                  "Manual import with JPEG resize leaves paired ARW untouched")

        // 2) Switch to adjust=false and manually import the JPEG: keeps full 128x64 resolution without reusing resized copy.
        controller.setJPEGOptions(CameraJPEGOptions(adjust: false))
        let jpgAsset = try controller.assets.first { $0.snapshot.name == "DSC09201.JPG" }
            ?? { throw CameraProtocolError.invalid("Missing JPG remote asset") }()
        controller.selection = [jpgAsset.id]
        controller.importSelected()
        try await waitUntil { controller.phase == .browsing && saver.saved.count == 3 }
        let fullSavedToPhotos = saver.saved.last
        let unadjustedOrig = store.snapshot.originals.last { $0.name == "DSC09201.JPG" }
        try check(unadjustedOrig?.jpegSource == nil && unadjustedOrig?.id != adjustedOrig.id
                  && fullSavedToPhotos?.pixelSize == CGSize(width: 128, height: 64)
                  && unadjustedOrig?.size == UInt64(jpegBytes.count),
                  "Manual import with adjust=false stores full 128x64 JPEG original")

        // 3) Re-enable adjust=true when an unadjusted local copy exists: must NOT bypass resizing via 3x64KiB sampling!
        channel.resetTransferStats()
        controller.setJPEGOptions(CameraJPEGOptions(adjust: true, longEdge: 40, quality: 72))
        controller.selection = [jpgAsset.id]
        controller.importSelected()
        try await waitUntil { controller.phase == .browsing && channel.bytesReadByName["DSC09201.JPG"] == jpegBytes.count }
        try check(channel.mobileRangeReads["DSC09201.JPG"] == [0..<jpegBytes.count],
                  "Manual import with adjust=true downloads full bytes rather than sampling unadjusted original")

        await withCheckedContinuation { continuation in
            controller.stop { continuation.resume() }
        }
        await drainBackend(backend)
    }

    @MainActor static func testSSHAccessAuthFlowAndLiveViewOverTunnel() async throws {
        defer { UserDefaults.standard.removeObject(forKey: fakeCameraPrefsKey) }
        final class InMemoryAuthStore: CameraAccessAuthStoring {
            private let lock = NSLock()
            private var storage: [String: CameraAccessAuthRecord] = [:]
            func load(cameraID: String) -> CameraAccessAuthRecord? {
                lock.lock(); defer { lock.unlock() }; return storage[cameraID]
            }
            func save(cameraID: String, record: CameraAccessAuthRecord) -> Bool {
                lock.lock(); storage[cameraID] = record; lock.unlock(); return true
            }
            func delete(cameraID: String) {
                lock.lock(); storage.removeValue(forKey: cameraID); lock.unlock()
            }
        }

        final class SynchronizedEventChannel: CameraByteChannel {
            private let lock = NSLock()
            private let semaphore = DispatchSemaphore(value: 0)
            private var outgoing = Data()
            private(set) var closed = false
            func read(_ count: Int) throws -> Data {
                lock.lock()
                if !closed, outgoing.count >= count {
                    let slice = Data(outgoing.prefix(count))
                    outgoing.removeFirst(count)
                    lock.unlock()
                    return slice
                }
                lock.unlock()
                semaphore.wait()
                throw CameraProtocolError.disconnected
            }
            func write(_ data: Data) throws {
                var reader = CameraDataReader(data)
                _ = try reader.u32()
                let type = try reader.u32()
                guard type == 3 else { throw CameraProtocolError.invalid("Unexpected event init packet \(type)") }
                lock.lock()
                outgoing.append(CameraWire.packet(4, Data()))
                lock.unlock()
            }
            func close() {
                lock.lock()
                if closed { lock.unlock(); return }
                closed = true
                lock.unlock()
                semaphore.signal()
            }
        }

        final class PTPIPCommandBridgeChannel: CameraByteChannel {
            private let inner: CameraByteChannel
            private let lock = NSLock()
            private var initAckBuffer = Data()
            init(_ inner: CameraByteChannel) { self.inner = inner }
            func read(_ count: Int) throws -> Data {
                lock.lock()
                if !initAckBuffer.isEmpty {
                    let prefixCount = min(count, initAckBuffer.count)
                    var out = Data(initAckBuffer.prefix(prefixCount))
                    initAckBuffer.removeFirst(prefixCount)
                    lock.unlock()
                    if out.count < count {
                        out.append(try inner.read(count - out.count))
                    }
                    return out
                }
                lock.unlock()
                return try inner.read(count)
            }
            func write(_ data: Data) throws {
                var reader = CameraDataReader(data)
                _ = try reader.u32()
                let type = try reader.u32()
                if type == 1 {
                    var ack = Data()
                    ack.appendLE(UInt32(0x42))
                    ack.append(Data(repeating: 0x11, count: 20))
                    lock.lock()
                    initAckBuffer.append(CameraWire.packet(2, ack))
                    lock.unlock()
                    return
                }
                try inner.write(data)
            }
            func close() { inner.close() }
        }

        final class FailingPTPIPChannel: CameraByteChannel {
            func read(_ count: Int) throws -> Data { throw CameraProtocolError.disconnected }
            func write(_ data: Data) throws {}
            func close() {}
        }

        final class LiveViewStreamChannel: CameraByteChannel {
            private let lock = NSLock()
            private let closeSemaphore = DispatchSemaphore(value: 0)
            private var outgoing: Data
            private(set) var written = Data()
            private(set) var closed = false
            init(response: Data) { self.outgoing = response }
            func read(_ count: Int) throws -> Data {
                lock.lock()
                if !closed, outgoing.count >= count {
                    let slice = Data(outgoing.prefix(count))
                    outgoing.removeFirst(count)
                    lock.unlock()
                    return slice
                }
                lock.unlock()
                closeSemaphore.wait()
                throw CameraProtocolError.disconnected
            }
            func write(_ data: Data) throws {
                lock.lock(); written.append(data); lock.unlock()
            }
            func close() {
                lock.lock()
                if closed { lock.unlock(); return }
                closed = true
                lock.unlock()
                closeSemaphore.signal()
            }
        }

        final class FakeSSHTunnel: CameraSSHTunneling {
            let hostProbe: CameraSSHHostProbe
            private let openPort: (UInt16, Set<UInt16>) throws -> CameraByteChannel
            private(set) var closed = false
            private(set) var openedPorts: [UInt16] = []
            init(probe: CameraSSHHostProbe, openPort: @escaping (UInt16, Set<UInt16>) throws -> CameraByteChannel) {
                self.hostProbe = probe
                self.openPort = openPort
            }
            func openChannel(port: UInt16, allowedPorts: Set<UInt16>, timeout: TimeInterval) throws -> CameraByteChannel {
                openedPorts.append(port)
                return try openPort(port, allowedPorts)
            }
            func close() { closed = true }
        }

        final class FakeSSHTransport: CameraSSHTransporting {
            let probe: CameraSSHHostProbe
            var expectedUser = "camuser"
            var expectedPassword = "campass"
            var connectAttempts = 0
            var openTunnelChannel: (UInt16, Set<UInt16>) throws -> CameraByteChannel
            init(probe: CameraSSHHostProbe, openTunnelChannel: @escaping (UInt16, Set<UInt16>) throws -> CameraByteChannel) {
                self.probe = probe
                self.openTunnelChannel = openTunnelChannel
            }
            func probeHostKey(host: String, port: UInt16, timeout: TimeInterval) throws -> CameraSSHHostProbe {
                probe
            }
            func connect(host: String, port: UInt16, username: String, password: String,
                         expectedFingerprint: String, timeout: TimeInterval) throws -> CameraSSHTunneling {
                connectAttempts += 1
                guard constantTimeCameraFingerprintEquals(expectedFingerprint, probe.fingerprint) else {
                    throw CameraProtocolError.sshFingerprintMismatch(
                        expected: expectedFingerprint,
                        actual: probe.fingerprint,
                        keyType: probe.keyType
                    )
                }
                guard username == expectedUser, password == expectedPassword else {
                    throw CameraProtocolError.sshAuthenticationFailed
                }
                return FakeSSHTunnel(probe: probe, openPort: openTunnelChannel)
            }
        }

        // Also assert slot1 vs slot2 withoutLocator remains distinct.
        let s1 = CameraAssetSnapshot(content: 10, file: 1, storage: 0, format: 0, name: "DSC00010.ARW", size: 1024, created: "100", modified: "", slot: 1)
        let s2 = CameraAssetSnapshot(content: 10, file: 1, storage: 0, format: 0, name: "DSC00010.ARW", size: 1024, created: "100", modified: "", slot: 2)
        try check(s1.withoutLocator != s2.withoutLocator && s2.withoutLocator.slot == 2,
                  "CameraAssetSnapshot.withoutLocator preserves slot distinction")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-ssh-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let authStore = InMemoryAuthStore()
        let validFP = "SHA256:" + Data(repeating: 0x42, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let probe = CameraSSHHostProbe(host: "192.168.122.1", port: 22, fingerprint: validFP, keyType: "ecdsa-sha2-nistp256")
        let baseMillis: UInt64 = 1_700_000_000_000
        let jpegLiveFrame = try makeLargeJPEG(targetSize: 1024, seed: 88)
        var livePacket = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        livePacket.appendLE(UInt32(16))
        livePacket.appendLE(UInt32(jpegLiveFrame.count))
        livePacket.appendLE(UInt32(0))
        livePacket.appendLE(UInt32(0))
        livePacket.append(jpegLiveFrame)

        var failPTPOverTunnel = true
        var activePTPChannel = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: [
            FakeSonyCameraEntry(content: 1, name: "DSC00100.ARW", createdMillis: baseMillis + 1_000, bytes: validRAWBytes(1))
        ])
        var ptpConnectionCount = 0
        var lastLiveChannel: LiveViewStreamChannel?

        let transport = FakeSSHTransport(probe: probe) { port, _ in
            if port == 60152 {
                let ch = LiveViewStreamChannel(response: livePacket)
                lastLiveChannel = ch
                return ch
            }
            if failPTPOverTunnel {
                return FailingPTPIPChannel()
            }
            ptpConnectionCount += 1
            if ptpConnectionCount % 2 == 1 {
                return PTPIPCommandBridgeChannel(activePTPChannel)
            } else {
                return SynchronizedEventChannel()
            }
        }

        let backend = CameraWorkspaceBackend(
            storage: store,
            clientID: UUID(),
            sshTransport: transport,
            authStore: authStore,
            directChannelOpener: CameraDirectChannelOpener { _, _ in throw CameraProtocolError.connectionRefused }
        )
        let controller = IOSCameraController(backend: backend)
        let endpoint = IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:FAKE-SSH", label: "Fake")

        // 1. Direct refused -> SSH probed -> prompts Access Auth.
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.accessAuthPrompt != nil && controller.phase == .paused }
        try check(controller.accessAuthPrompt?.fingerprint == validFP && controller.accessAuthPrompt?.hasSavedCredentials == false,
                  "Direct connection refusal with reachable SSH surfaces IOSCameraAccessAuthPrompt")

        // 2. Submitting valid SSH credentials when PTP/IP over tunnel fails must NOT save credentials and must clear auth card to show error.
        controller.submitAccessAuth(user: "camuser", password: "campass")
        try await waitUntil { controller.phase == .paused && controller.accessAuthPrompt == nil && controller.notice != nil }
        try check(authStore.load(cameraID: endpoint.connectionKey) == nil,
                  "Credentials are NOT persisted when PTP/IP session fails inside SSH tunnel")

        // 3. Reconnect, submit credentials with healthy PTP/IP -> browses assets and saves credentials.
        failPTPOverTunnel = false
        ptpConnectionCount = 0
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.accessAuthPrompt != nil }
        controller.submitAccessAuth(user: "camuser", password: "campass")
        try await waitUntil { controller.phase == .browsing && controller.assets.count == 1 }
        try check(controller.accessAuthPrompt == nil && authStore.load(cameraID: endpoint.connectionKey)?.user == "camuser",
                  "Successful SSH + PTP/IP connect browses assets and saves credentials in authStore")

        await withCheckedContinuation { continuation in
            controller.stop { continuation.resume() }
        }

        // 4. Subsequent connect auto-authenticates over SSH without showing prompt, and forgetSavedAccessAuth deletes stored record.
        activePTPChannel = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: [
            FakeSonyCameraEntry(content: 2, name: "DSC00101.ARW", createdMillis: baseMillis + 2_000, bytes: validRAWBytes(2))
        ])
        ptpConnectionCount = 0
        let attemptsBeforeAuto = transport.connectAttempts
        controller.connect(endpoint: endpoint, mode: .importing, cardConfirmed: false, resume: false)
        try await waitUntil { controller.phase == .browsing && controller.assets.first?.snapshot.name == "DSC00101.ARW" }
        try check(controller.accessAuthPrompt == nil && transport.connectAttempts == attemptsBeforeAuto + 1,
                  "Subsequent connect auto-authenticates via saved SSH credentials")
        await withCheckedContinuation { continuation in
            controller.stop { continuation.resume() }
        }

        backend.forgetAccessAuth(cameraID: endpoint.connectionKey)
        await drainBackend(backend)
        try check(authStore.load(cameraID: endpoint.connectionKey) == nil,
                  "forgetAccessAuth clears stored SSH credentials")

        // 5. Tethering mode over SSH tunnel opens Live View through run.channelOpener on port 60152 with Host: localhost:60152.
        activePTPChannel = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: [])
        activePTPChannel.liveViewURLString = "http://192.168.122.1:60152/liveviewstream?k=ssh"
        ptpConnectionCount = 0
        controller.connect(endpoint: endpoint, mode: .tethering, cardConfirmed: true, resume: false)
        try await waitUntil { controller.accessAuthPrompt != nil }
        controller.submitAccessAuth(user: "camuser", password: "campass")
        try await waitUntil(timeout: 8) { controller.phase == .ready && controller.frame != nil }
        let liveRequest = String(data: lastLiveChannel?.written ?? Data(), encoding: .utf8) ?? ""
        try check(liveRequest.contains("Host: localhost:60152\r\n") && !liveRequest.contains("Host: 192.168.122.1"),
                  "Tethering over SSH tunnel opens Live View port 60152 via tunnel with Host: localhost:60152")

        await withCheckedContinuation { continuation in
            controller.stop { continuation.resume() }
        }
        await drainBackend(backend)
    }

    @MainActor static func testTetheringVirtualClockFocusExpiryAndBusyGuard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-vclock-focus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let jpeg = try makeLargeJPEG(targetSize: 16_384, seed: 0x33)
        let channel = FakeSonyCameraChannel(mode: .mobile, supportsTethering: true, entries: [])
        channel.tetherControls = [0xd2c1, 0xd2c2, 0xd2e4, 0xd2e5]
        channel.tetherExtraProps = [
            (0x500a, 4, true, 1, 2),
            (0xd284, 2, false, 1, 1),
            (0xd285, 2, false, 0, 0),
            (0xd213, 2, false, 1, 1),
        ]
        channel.on9207 = { code, value in
            if code == 0xd2e4 {
                channel.setExtraProperty(0xd285, value: 1, enabled: 1)
            } else if code == 0xd2c1 && value == 2 {
                channel.setExtraProperty(0xd213, value: 6, enabled: 1)
            } else if code == 0xd2c1 && value == 1 {
                channel.setExtraProperty(0xd213, value: 1, enabled: 1)
            }
        }
        let clock = VirtualCameraFocusClock(initialMillis: 10_000)
        let backend = CameraWorkspaceBackend(storage: store, clientID: UUID()) { _, purpose, _ in
            try SonyCameraSession(client: CameraPTPClient(command: channel, event: nil), purpose: purpose)
        }
        let controller = IOSCameraController(backend: backend, focusClock: clock)
        controller.connect(endpoint: IOSCameraEndpoint(host: "192.168.122.1", connectionKey: "SSID:VCLOCK", label: "Fake"),
                           mode: .tethering, cardConfirmed: true, resume: false)
        try await waitUntil { controller.phase == .ready }
        _ = jpeg
        controller.setFocusPoint(u: 0.5, v: 0.5, x: 320, y: 240)
        try check(controller.focusBusy && controller.tapFocusPoint != nil, "Tap starts focusBusy=true")
        clock.advance(byMillis: 5_000)
        try check(controller.focusBusy && controller.tapFocusPoint != nil, "Virtual clock while busy never clears reticle")
        try await waitUntil { !controller.focusBusy }
        try check(controller.tapFocusPoint != nil && controller.cameraFocusLocked, "Focus completes and locks reticle")
        clock.advance(byMillis: 1_799)
        try check(controller.tapFocusPoint != nil, "Reticle remains visible at 1799ms")
        clock.advance(byMillis: 1)
        try check(controller.tapFocusPoint == nil, "Reticle expires deterministically at 1800ms")

        await withCheckedContinuation { continuation in
            controller.stop { continuation.resume() }
        }
        await drainBackend(backend)
    }
}
