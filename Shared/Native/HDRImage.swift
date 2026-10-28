import Foundation

final class HDRImage {
    private var storage: sony2fuji_hdr_image_pair_v1
    let sourceURL: URL
    let sourceInfo: HDRSourceInfo
    private static let lifetimeLock=NSLock()
    private static var livingBytes=0
    private static var livingCount=0

    var width: Int { Int(storage.hdr.width) }
    var height: Int { Int(storage.hdr.height) }
    var nativeWidth: Int { Int(storage.native_width) }
    var nativeHeight: Int { Int(storage.native_height) }
    var outputNativeWidth: Int { Int(storage.output_native_width) }
    var outputNativeHeight: Int { Int(storage.output_native_height) }
    var byteCount: Int { Int(storage.hdr.size_bytes+storage.sdr.size_bytes) }
    var isProxy: Bool { storage.is_proxy != 0 }
    var sourceHeadroom: Float { storage.source_headroom }
    var editedHeadroom: Float { storage.hdr.content_headroom }
    static var liveAllocations: (count: Int, bytes: Int) {
        lifetimeLock.lock(); defer { lifetimeLock.unlock() }
        return (livingCount,livingBytes)
    }

    private init(owned: sony2fuji_hdr_image_pair_v1, url: URL, info: HDRSourceInfo) {
        storage=owned; sourceURL=url; sourceInfo=info
        Self.lifetimeLock.lock(); Self.livingCount+=1; Self.livingBytes+=byteCount; Self.lifetimeLock.unlock()
    }
    deinit {
        Self.lifetimeLock.lock(); Self.livingCount-=1; Self.livingBytes-=byteCount; Self.lifetimeLock.unlock()
        sony2fuji_hdr_release_pair(&storage)
    }

    func withPair<T>(_ body: (UnsafePointer<sony2fuji_hdr_image_pair_v1>) throws -> T) rethrows -> T {
        // 结构副本只是借用视图；其全部 buffer 由本对象统一持有和释放。
        var view=storage
        return try withExtendedLifetime(self) { try withUnsafePointer(to:&view,body) }
    }

    static func decode(_ url: URL, info: HDRSourceInfo, intent: sony2fuji_intent,
                       longEdge: Int? = nil) throws -> HDRImage {
        guard intent==SONY2FUJI_INTENT_FINAL || intent==SONY2FUJI_INTENT_PREVIEW,
              longEdge.map({ (1...65535).contains($0) }) ?? true,
              intent != SONY2FUJI_INTENT_FINAL || longEdge==nil else { throw HDRRequestError.invalidSettings }
        var options=sony2fuji_hdr_decode_options_v1()
        options.version=1; options.struct_size=UInt32(MemoryLayout.size(ofValue:options))
        options.intent=UInt32(intent.rawValue); options.long_edge=UInt32(longEdge ?? 0)
        var result=emptyPair(); var diagnostic=emptyDiagnostic()
        let status=url.path.withCString { sony2fuji_hdr_decode($0,&options,&result,&diagnostic) }
        guard status==SONY2FUJI_STATUS_OK else { throw failure(status,diagnostic) }
        let actual=withUnsafeBytes(of:result.source_sha256) { Data($0) }
        guard actual==info.fingerprint else {
            sony2fuji_hdr_release_pair(&result)
            throw HDRNativeError(status:SONY2FUJI_STATUS_INVALID_ARGUMENT,
                reason:UInt32(SONY2FUJI_HDR_REASON_SOURCE_CHANGED),field:UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
        }
        return HDRImage(owned:result,url:url,info:info)
    }

    func rendered(session: OpaquePointer, settings: HDRSettings, intent: sony2fuji_intent,
                  longEdge: Int? = nil) throws -> HDRImage {
        var request=try makeHDRRequest(settings:settings,intent:intent,longEdge:longEdge)
        var result=Self.emptyPair(); var diagnostic=Self.emptyDiagnostic()
        let status=withPair { sony2fuji_hdr_render(session,$0,&request,&result,&diagnostic) }
        guard status==SONY2FUJI_STATUS_OK else { throw Self.failure(status,diagnostic) }
        return HDRImage(owned:result,url:sourceURL,info:sourceInfo)
    }

    func exportJPEG(to output: URL, baseColor: HDRRecipe.BaseColor = .displayP3) throws {
        var config=sony2fuji_hdr_export_config_v1()
        config.version=1; config.struct_size=UInt32(MemoryLayout.size(ofValue:config))
        config.jpeg_quality=95; config.base_color=UInt32(baseColor == .displayP3 ? SONY2FUJI_HDR_COLOR_DISPLAY_P3 : SONY2FUJI_HDR_COLOR_SRGB)
        config.metadata_policy=UInt32(SONY2FUJI_HDR_METADATA_ISO_XMP); config.source_sha256=storage.source_sha256
        var diagnostic=Self.emptyDiagnostic()
        let status=sourceURL.path.withCString { source in output.path.withCString { destination in
            config.metadata_source_path=source
            return withPair { sony2fuji_hdr_export_jpeg($0,&config,destination,&diagnostic) }
        } }
        guard status==SONY2FUJI_STATUS_OK else { throw Self.failure(status,diagnostic) }
    }

    func exportSDR(to output: URL, format: sony2fuji_output_format) throws {
        var config=sony2fuji_hdr_sdr_export_config_v1()
        config.version=1; config.struct_size=UInt32(MemoryLayout.size(ofValue:config))
        config.output_format=UInt32(format.rawValue); config.quality=95; config.source_sha256=storage.source_sha256
        var diagnostic=Self.emptyDiagnostic()
        let status=sourceURL.path.withCString { source in output.path.withCString { destination in
            config.metadata_source_path=source
            return withPair { sony2fuji_hdr_export_sdr($0,&config,destination,&diagnostic) }
        } }
        guard status==SONY2FUJI_STATUS_OK else { throw Self.failure(status,diagnostic) }
    }

    private static func emptyPair() -> sony2fuji_hdr_image_pair_v1 {
        var value=sony2fuji_hdr_image_pair_v1(); value.version=1
        value.struct_size=UInt32(MemoryLayout.size(ofValue:value)); return value
    }
    private static func emptyDiagnostic() -> sony2fuji_hdr_diagnostic_v1 {
        var value=sony2fuji_hdr_diagnostic_v1(); value.version=1
        value.struct_size=UInt32(MemoryLayout.size(ofValue:value)); return value
    }
    private static func failure(_ status: sony2fuji_status,_ diagnostic: sony2fuji_hdr_diagnostic_v1) -> HDRNativeError {
        HDRNativeError(status:status,reason:diagnostic.reason,field:diagnostic.field)
    }
}

// 只缓存不可变的解码来源；结果属于当前画布或短期任务，不复制进此缓存。
final class HDRSourceCache {
    static let shared=HDRSourceCache()
    private struct Key: Hashable { let url: URL; let fingerprint: Data; let edge: Int }
    private struct Entry { let image: HDRImage; var use: UInt64 }
    private var entries=[Key:Entry]()
    private var clock: UInt64=0
    private let lock=NSLock()
    let limit: Int
    private(set) var bytes=0
    init(limit: Int = 128*1024*1024) { self.limit=max(0,limit) }

    func preview(_ url: URL, info: HDRSourceInfo, longEdge: Int) throws -> HDRImage {
        lock.lock(); defer { lock.unlock() }
        if entries.keys.contains(where:{ $0.url != url.standardizedFileURL || $0.fingerprint != info.fingerprint }) {
            entries.removeAll(); bytes=0
        }
        clock &+= 1
        let key=Key(url:url.standardizedFileURL,fingerprint:info.fingerprint,edge:longEdge)
        if var cached=entries[key] { cached.use=clock; entries[key]=cached; return cached.image }
        let image=try HDRImage.decode(url,info:info,intent:SONY2FUJI_INTENT_PREVIEW,longEdge:longEdge)
        if image.byteCount<=limit {
            while bytes+image.byteCount>limit, let oldest=entries.min(by:{ $0.value.use<$1.value.use }) {
                bytes-=oldest.value.image.byteCount; entries.removeValue(forKey:oldest.key)
            }
            entries[key]=Entry(image:image,use:clock); bytes+=image.byteCount
        }
        return image
    }
    func clear() { lock.lock(); entries.removeAll(); bytes=0; lock.unlock() }
}
