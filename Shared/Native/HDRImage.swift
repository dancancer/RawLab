import Foundation

enum HDRLookAssetStore {
    static func installHDRSilver() throws -> HDRLookSettings {
        guard let source = Bundle.main.url(forResource: "HDR Silver", withExtension: "cube", subdirectory: "BundledLooks/HDR") else {
            throw invalidAsset
        }
        return try install(source)
    }

    static func install(_ source: URL, in directory: URL = HDRLookSettings.directory) throws -> HDRLookSettings {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard source.pathExtension.lowercased() == "cube" else { throw invalidAsset }
        let bytes = try HDRLookSettings.readAssetBytes(source)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString).cube")
        defer { try? manager.removeItem(at: staging) }
        try bytes.write(to: staging, options: .withoutOverwriting)
        let hash = try fingerprint(staging)
        let name = source.deletingPathExtension().lastPathComponent
        let settings = HDRLookSettings(sha256: hash, name: name, strength: 1)
        guard settings.isValid, let destination = settings.asset(in: directory) else { throw invalidAsset }
        do { try manager.moveItem(at: staging, to: destination) }
        catch {
            guard manager.fileExists(atPath: destination.path), try fingerprint(destination) == hash else { throw error }
        }
        return settings
    }

    private static var invalidAsset: HDRNativeError {
        HDRNativeError(status: SONY2FUJI_STATUS_INVALID_ARGUMENT, reason: UInt32(SONY2FUJI_HDR_REASON_LOOK_RESOURCE),
            field: UInt32(SONY2FUJI_HDR_FIELD_LOOK))
    }

    private static func fingerprint(_ url: URL) throws -> String {
        var info = sony2fuji_hdr_look_info_v1()
        info.version = 1; info.struct_size = UInt32(MemoryLayout.size(ofValue: info))
        let status = url.path.withCString { sony2fuji_hdr_probe_look($0, &info, nil) }
        guard status == SONY2FUJI_STATUS_OK else { throw invalidAsset }
        return withUnsafeBytes(of: info.sha256) { String(decoding: $0.prefix(64), as: UTF8.self) }
    }
}

enum HDRCameraProfileAssetStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/HDRCameraProfiles", isDirectory: true)
    }

    static func install(_ source: URL, in directory: URL = Self.directory) throws -> HDRCameraProfile {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard ["dcp", "rlook"].contains(source.pathExtension.lowercased()) else {
            throw error(status: SONY2FUJI_STATUS_INVALID_ARGUMENT)
        }
        let bytes = try HDRLookSettings.readAssetBytes(source)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try bytes.write(to: staging, options: .withoutOverwriting)
        var info = sony2fuji_hdr_camera_profile_info_v1()
        info.version = 1; info.struct_size = UInt32(MemoryLayout.size(ofValue: info))
        let status = staging.path.withCString { sony2fuji_hdr_probe_camera_profile($0, &info, nil) }
        guard status == SONY2FUJI_STATUS_OK else { throw error(status: status) }
        let digest = withUnsafeBytes(of: info.sha256) { String(decoding: $0.prefix(64), as: UTF8.self) }
        let profile = HDRCameraProfile(sha256: digest, name: source.deletingPathExtension().lastPathComponent)
        guard profile.isValid else { throw error(status: SONY2FUJI_STATUS_INVALID_ARGUMENT) }
        try bytes.write(to: asset(profile, in: directory), options: .atomic)
        return profile
    }

    @discardableResult static func url(for profile: HDRCameraProfile, in directory: URL = Self.directory) throws -> URL {
        let url = asset(profile, in: directory)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw error(status: SONY2FUJI_STATUS_IO_ERROR)
        }
        return url
    }

    private static func asset(_ profile: HDRCameraProfile, in directory: URL) -> URL {
        directory.appendingPathComponent(profile.sha256).appendingPathExtension("profile")
    }

    private static func error(status: sony2fuji_status) -> HDRNativeError {
        HDRNativeError(status: status, reason: UInt32(SONY2FUJI_HDR_REASON_CAMERA_PROFILE),
            field: UInt32(SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT))
    }
}
extension HDRSettings {
    var missingResourceMessage: String? {
        if let asset = lookSettings.asset(), !FileManager.default.isReadableFile(atPath: asset.path) {
            return L10n.text("上次使用的外观不可用，请重新选择或导入外观。")
        }
        if let profile = cameraDevelopmentSettings.cameraProfile,
           (try? HDRCameraProfileAssetStore.url(for: profile)) == nil {
            return L10n.text("找不到 HDR 相机配置，请重新导入。")
        }
        return nil
    }

    func previewSettings(lookDirectory: URL = HDRLookSettings.directory,
                         profileDirectory: URL = HDRCameraProfileAssetStore.directory) -> HDRSettings {
        var preview = self
        // 只剥离预览副本；编辑记录保留引用，正式导出仍严格校验资源。
        if let asset = lookSettings.asset(in: lookDirectory), !FileManager.default.isReadableFile(atPath: asset.path) {
            preview.lookSettings = HDRLookSettings()
        }
        if let profile = cameraDevelopmentSettings.cameraProfile,
           (try? HDRCameraProfileAssetStore.url(for: profile, in: profileDirectory)) == nil {
            preview.cameraDevelopmentSettings.cameraProfile = nil
        }
        return preview
    }
}

import CoreGraphics

func hdrNativeGeometrySize(_ source: CGSize, geometry: GeometrySettings) throws -> CGSize {
    let width=Double(source.width),height=Double(source.height)
    guard width.isFinite,height.isFinite,width>0,height>0,width<=Double(UInt32.max),height<=Double(UInt32.max),
          width.rounded()==width,height.rounded()==height else { throw HDRRequestError.invalidSettings }
    var settings=HDRSettings(); settings.geometry=geometry
    let request=try makeHDRRequest(settings:settings,intent:SONY2FUJI_INTENT_PREVIEW)
    var outputWidth: UInt32=0,outputHeight: UInt32=0
    var diagnostic=sony2fuji_hdr_diagnostic_v1(); diagnostic.version=1
    diagnostic.struct_size=UInt32(MemoryLayout.size(ofValue:diagnostic))
    let status=withHDRRequestPrefix(request) {
        sony2fuji_hdr_geometry_size(UInt32(width),UInt32(height),$0,&outputWidth,&outputHeight,&diagnostic)
    }
    guard status==SONY2FUJI_STATUS_OK else {
        throw HDRNativeError(status:status,reason:diagnostic.reason,field:diagnostic.field)
    }
    return CGSize(width:Int(outputWidth),height:Int(outputHeight))
}

final class HDRImage {
    private var storage: sony2fuji_hdr_image_pair_v1
    private let proRAWBuffers: (hdr: Data, sdr: Data)?
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

    private init(owned: sony2fuji_hdr_image_pair_v1, url: URL, info: HDRSourceInfo, proRAWBuffers: (hdr: Data, sdr: Data)? = nil) {
        self.proRAWBuffers = proRAWBuffers
        storage=owned; sourceURL=url; sourceInfo=info
        Self.lifetimeLock.lock(); Self.livingCount+=1; Self.livingBytes+=byteCount; Self.lifetimeLock.unlock()
    }
    deinit {
        Self.lifetimeLock.lock(); Self.livingCount-=1; Self.livingBytes-=byteCount; Self.lifetimeLock.unlock()
        if proRAWBuffers == nil { sony2fuji_hdr_release_pair(&storage) }
    }

    func withPair<T>(_ body: (UnsafePointer<sony2fuji_hdr_image_pair_v1>) throws -> T) rethrows -> T {
        // 结构副本只是借用视图；其全部 buffer 由本对象统一持有和释放。
        var view=storage
        if let proRAWBuffers {
            return try proRAWBuffers.hdr.withUnsafeBytes { hdr in
                try proRAWBuffers.sdr.withUnsafeBytes { sdr in
                    view.hdr.data = UnsafeMutableRawPointer(mutating: hdr.baseAddress)
                    view.sdr.data = UnsafeMutableRawPointer(mutating: sdr.baseAddress)
                    return try withUnsafePointer(to: &view, body)
                }
            }
        }
        return try withExtendedLifetime(self) { try withUnsafePointer(to:&view,body) }
    }

    static func cameraAIKey(_ url: URL, session: OpaquePointer?) throws -> String {
        var key = [CChar](repeating: 0, count: 65)
        var diagnostic = emptyDiagnostic()
        let status = url.path.withCString { path in
            key.withUnsafeMutableBufferPointer {
                sony2fuji_hdr_camera_ai_key(session, path, $0.baseAddress, UInt32($0.count), &diagnostic)
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { throw failure(status, diagnostic) }
        return String(cString: key)
    }

    static func decode(_ url: URL, info: HDRSourceInfo, intent: sony2fuji_intent,
                       longEdge: Int? = nil, session: OpaquePointer? = nil,
                       camera: HDRCameraDevelopmentSettings = HDRCameraDevelopmentSettings(),
                       cameraAIKey: String? = nil,
                       cancelled: () -> Bool = { false }) throws -> HDRImage {
        guard intent==SONY2FUJI_INTENT_FINAL || intent==SONY2FUJI_INTENT_PREVIEW,
              longEdge.map({ (1...65535).contains($0) }) ?? true,
              intent != SONY2FUJI_INTENT_FINAL || longEdge==nil,
              camera.isValid, camera.isDefault || info.isCameraRAW,
              cameraAIKey == nil || (info.isCameraRAW && session != nil && camera.cameraProfile == nil) else {
            throw HDRRequestError.invalidSettings
        }
        let profileURL = try camera.cameraProfile.map { try HDRCameraProfileAssetStore.url(for: $0) }
        if let proRAW = info.proRAW, let stamp = info.cameraStamp {
            guard intent != SONY2FUJI_INTENT_PREVIEW || longEdge != nil else { throw HDRRequestError.invalidSettings }
            let developed = try proRAW.decode(url, stamp: stamp, longEdge: longEdge, cancelled: cancelled)
            return HDRImage(owned: developed.pair, url: url, info: info, proRAWBuffers: (developed.hdr, developed.sdr))
        }
        var options=sony2fuji_hdr_decode_options_v1()
        options.version=1; options.struct_size=UInt32(MemoryLayout.size(ofValue:options))
        options.intent=UInt32(intent.rawValue); options.long_edge=UInt32(longEdge ?? 0)
        var result=emptyPair(); var diagnostic=emptyDiagnostic()
        let status = url.path.withCString { path in
            if info.isCameraRAW {
                var development = sony2fuji_hdr_camera_development_v1()
                development.version = 1; development.struct_size = UInt32(MemoryLayout.size(ofValue: development))
                development.white_balance = UInt32(camera.whiteBalance == .asShot ? SONY2FUJI_HDR_CAMERA_WB_AS_SHOT : SONY2FUJI_HDR_CAMERA_WB_TEMPERATURE)
                development.exposure_reference = UInt32(camera.exposureReference == .metadata ? SONY2FUJI_HDR_CAMERA_EXPOSURE_METADATA : SONY2FUJI_HDR_CAMERA_EXPOSURE_SENSOR)
                development.temperature = Float(camera.temperature); development.tint = Float(camera.tint)
                development.fbdd_level = UInt32(camera.fbddLevel)
                development.lens_flags = UInt32((camera.lensDistortion ? SONY2FUJI_HDR_CAMERA_LENS_DISTORTION : 0) |
                    (camera.lensTCA ? SONY2FUJI_HDR_CAMERA_LENS_TCA : 0) |
                    (camera.lensActive && camera.lensAutoCrop ? SONY2FUJI_HDR_CAMERA_LENS_AUTO_CROP : 0))
                func decode(_ lensProfile: UnsafePointer<CChar>?) -> sony2fuji_status {
                    development.lens_profile_id = lensProfile
                    if let profile = camera.cameraProfile, let profileURL {
                        var profiled = sony2fuji_hdr_camera_development_v2()
                        profiled.base = development
                        profiled.base.version = 2
                        profiled.base.struct_size = UInt32(MemoryLayout.size(ofValue: profiled))
                        withUnsafeMutableBytes(of: &profiled.profile_sha256) { $0.copyBytes(from: profile.sha256.utf8) }
                        return profileURL.path.withCString { resource in
                            profiled.profile_path = resource
                            return withUnsafePointer(to: &profiled) {
                                $0.withMemoryRebound(to: sony2fuji_hdr_camera_development_v1.self, capacity: 1) {
                                    sony2fuji_hdr_decode_camera_raw_with_development(session, path, &options, $0, &result, &diagnostic)
                                }
                            }
                        }
                    }
                    if cameraAIKey != nil {
                        return sony2fuji_hdr_decode_camera_raw_with_ai(session, path, &options, &development, &result, &diagnostic)
                    }
                    return sony2fuji_hdr_decode_camera_raw_with_development(session, path, &options, &development, &result, &diagnostic)
                }
                return camera.lensProfile?.withCString(decode) ?? decode(nil)
            }
            return sony2fuji_hdr_decode(path, &options, &result, &diagnostic)
        }
        guard status==SONY2FUJI_STATUS_OK else { throw failure(status,diagnostic) }
        let actual=withUnsafeBytes(of:result.source_sha256) { Data($0) }
        let sameSource = info.isCameraRAW
            ? (try? HDRSourceInfo.CameraStamp(url)) == info.cameraStamp
            : actual == info.fingerprint
        let sameAI = cameraAIKey.map { (try? Self.cameraAIKey(url, session: session)) == $0 } ?? true
        guard sameSource && sameAI else {
            sony2fuji_hdr_release_pair(&result)
            throw HDRNativeError(status:SONY2FUJI_STATUS_INVALID_ARGUMENT,
                reason:UInt32(SONY2FUJI_HDR_REASON_SOURCE_CHANGED),field:UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
        }
        return HDRImage(owned:result,url:url,info:info)
    }

    func rendered(session: OpaquePointer, settings: HDRSettings, intent: sony2fuji_intent,
                  longEdge: Int? = nil) throws -> HDRImage {
        let request=try makeHDRRequest(settings:settings,intent:intent,longEdge:longEdge)
        var result=Self.emptyPair(); var diagnostic=Self.emptyDiagnostic()
        let status=withPair { pair in
            withHDRRequestPrefix(request) { sony2fuji_hdr_render(session,pair,$0,&result,&diagnostic) }
        }
        guard status==SONY2FUJI_STATUS_OK else { throw Self.failure(status,diagnostic) }
        return HDRImage(owned:result,url:sourceURL,info:sourceInfo)
    }

    func exportJPEG(to output: URL, baseColor: HDRRecipe.BaseColor = .displayP3) throws {
        try exportGainMap(to: output, baseColor: baseColor, heif: false)
    }

    static var heifExportAvailable: Bool { sony2fuji_hdr_heif_export_available() != 0 }

    func exportHEIF(to output: URL, baseColor: HDRRecipe.BaseColor = .displayP3) throws {
        try exportGainMap(to: output, baseColor: baseColor, heif: true)
    }

    private func exportGainMap(to output: URL, baseColor: HDRRecipe.BaseColor, heif: Bool) throws {
        try validateProRAWExport(to: output)
        var config=sony2fuji_hdr_export_config_v1()
        config.version=1; config.struct_size=UInt32(MemoryLayout.size(ofValue:config))
        config.jpeg_quality=95; config.base_color=UInt32(baseColor == .displayP3 ? SONY2FUJI_HDR_COLOR_DISPLAY_P3 : SONY2FUJI_HDR_COLOR_SRGB)
        config.metadata_policy=UInt32(heif ? SONY2FUJI_HDR_METADATA_ISO : SONY2FUJI_HDR_METADATA_ISO_XMP)
        config.source_sha256=storage.source_sha256
        var diagnostic=Self.emptyDiagnostic()
        let status=sourceURL.path.withCString { source in output.path.withCString { destination in
            config.metadata_source_path = sourceInfo.isCameraRAW ? nil : source
            return withPair {
                heif ? sony2fuji_hdr_export_heif($0,&config,destination,&diagnostic)
                    : sony2fuji_hdr_export_jpeg($0,&config,destination,&diagnostic)
            }
        } }
        guard status==SONY2FUJI_STATUS_OK else { throw Self.failure(status,diagnostic) }
    }

    func exportSDR(to output: URL, format: sony2fuji_output_format) throws {
        try validateProRAWExport(to: output)
        var config=sony2fuji_hdr_sdr_export_config_v1()
        config.version=1; config.struct_size=UInt32(MemoryLayout.size(ofValue:config))
        config.output_format=UInt32(format.rawValue); config.quality=95; config.source_sha256=storage.source_sha256
        var diagnostic=Self.emptyDiagnostic()
        let status=sourceURL.path.withCString { source in output.path.withCString { destination in
            config.metadata_source_path = sourceInfo.isCameraRAW || format == SONY2FUJI_OUTPUT_DNG && sourceInfo.proRAW != nil ? nil : source
            return withPair { sony2fuji_hdr_export_sdr($0,&config,destination,&diagnostic) }
        } }
        guard status==SONY2FUJI_STATUS_OK else { throw Self.failure(status,diagnostic) }
    }

    private func validateProRAWExport(to output: URL) throws {
        guard sourceInfo.proRAW != nil, let stamp = sourceInfo.cameraStamp else { return }
        let destination = try? HDRSourceInfo.CameraStamp(output)
        let sameIdentity = stamp.inode != nil && stamp.device != nil &&
            destination?.inode == stamp.inode && destination?.device == stamp.device
        if sameIdentity || sourceURL.resolvingSymlinksInPath().standardizedFileURL ==
            output.resolvingSymlinksInPath().standardizedFileURL {
            throw HDRNativeError(status: SONY2FUJI_STATUS_INVALID_ARGUMENT,
                                 reason: UInt32(SONY2FUJI_HDR_REASON_SAME_FILE), field: UInt32(SONY2FUJI_HDR_FIELD_PATH))
        }
        guard (try? HDRSourceInfo.CameraStamp(sourceURL)) == stamp else {
            throw HDRNativeError(status: SONY2FUJI_STATUS_INVALID_ARGUMENT,
                                 reason: UInt32(SONY2FUJI_HDR_REASON_SOURCE_CHANGED), field: UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
        }
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
    private struct Key: Hashable {
        let url: URL
        let fingerprint: Data
        let cameraStamp: HDRSourceInfo.CameraStamp?
        let proRAW: ProRAWSource?
        let camera: HDRCameraDevelopmentSettings
        let cameraAIKey: String?
        let lensDatabase: URL?
        let edge: Int
    }
    private struct Entry { let image: HDRImage; var use: UInt64 }
    private var entries=[Key:Entry]()
    private var clock: UInt64=0
    private let lock=NSLock()
    let limit: Int
    private(set) var bytes=0
    init(limit: Int = 128*1024*1024) { self.limit=max(0,limit) }

    func preview(_ url: URL, info: HDRSourceInfo, longEdge: Int, session: OpaquePointer? = nil,
                 camera: HDRCameraDevelopmentSettings = HDRCameraDevelopmentSettings(), lensDatabase: URL? = nil,
                 cameraAIKey: String? = nil,
                 cancelled: () -> Bool = { false }) throws -> HDRImage {
        let longEdge = info.proRAW == nil ? longEdge : min(longEdge, ProRAWSource.previewLimit)
        lock.lock(); defer { lock.unlock() }
        if entries.keys.contains(where:{ $0.url != url.standardizedFileURL || $0.fingerprint != info.fingerprint || $0.cameraStamp != info.cameraStamp || $0.proRAW != info.proRAW }) {
            entries.removeAll(); bytes=0
        }
        clock &+= 1
        let key=Key(url:url.standardizedFileURL,fingerprint:info.fingerprint,cameraStamp:info.cameraStamp,proRAW:info.proRAW,
                    camera:camera,cameraAIKey:cameraAIKey,
                    lensDatabase:camera.lensActive ? lensDatabase?.standardizedFileURL : nil,edge:longEdge)
        if var cached=entries[key] {
            if let profile = camera.cameraProfile { try HDRCameraProfileAssetStore.url(for: profile) }
            cached.use=clock; entries[key]=cached; return cached.image
        }
        let image=try HDRImage.decode(url,info:info,intent:SONY2FUJI_INTENT_PREVIEW,longEdge:longEdge,session:session,
                                      camera:camera,cameraAIKey:cameraAIKey,cancelled:cancelled)
        if image.byteCount<=limit {
            while bytes+image.byteCount>limit, let oldest=entries.min(by:{ $0.value.use<$1.value.use }) {
                bytes-=oldest.value.image.byteCount; entries.removeValue(forKey:oldest.key)
            }
            entries[key]=Entry(image:image,use:clock); bytes+=image.byteCount
        }
        return image
    }

    func autoExposure(_ url: URL, settings: HDRSettings, proRAWDecodeVersion: Int?,
                      session: OpaquePointer?, lensDatabase: URL? = nil, cameraAIKey: String? = nil) throws -> Double {
        guard let info = try HDRSourceInfo.probe(url) ?? HDRSourceInfo.probeRAW(url) else {
            throw HDRSettings.ModeError.unsupportedSource
        }
        if info.proRAW != nil { try ProRAWSource.validatedDecodeVersion(proRAWDecodeVersion) }
        let source = try preview(url, info: info, longEdge: 1280, session: info.isCameraRAW ? session : nil,
                                 camera:settings.cameraDevelopmentSettings,lensDatabase:lensDatabase,cameraAIKey:cameraAIKey)
        var exposure: Float = 0
        var diagnostic = sony2fuji_hdr_diagnostic_v1()
        diagnostic.version = SONY2FUJI_HDR_VERSION
        diagnostic.struct_size = UInt32(MemoryLayout<sony2fuji_hdr_diagnostic_v1>.size)
        let status = source.withPair {
            sony2fuji_hdr_estimate_auto_exposure($0, Float(settings.temperature), Float(settings.tint), &exposure, &diagnostic)
        }
        guard status == SONY2FUJI_STATUS_OK else {
            throw HDRNativeError(status: status, reason: diagnostic.reason, field: diagnostic.field)
        }
        return Double(exposure)
    }

    func clear() { lock.lock(); entries.removeAll(); bytes=0; lock.unlock() }
}
