import RawLabKit
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

struct HDRViewportROI: Equatable, Sendable {
    var normX0: Double
    var normY0: Double
    var normX1: Double
    var normY1: Double
    var maxOutputLongEdge: Int
    var baseContentHeadroom: Float
    var sourceX0: Int = 0
    var sourceY0: Int = 0
    var fullSourceWidth: Int = 0
    var fullSourceHeight: Int = 0
}

struct HDRViewportROIResult: Equatable, Sendable {
    let nativeX0: Int
    let nativeY0: Int
    let nativeX1: Int
    let nativeY1: Int
    let fullNativeWidth: Int
    let fullNativeHeight: Int
    let isProxy: Bool
}

struct HDRSourceBounds: Equatable, Sendable {
    let sourceX0: Int
    let sourceY0: Int
    let sourceX1: Int
    let sourceY1: Int
    let nativeX0: Int
    let nativeY0: Int
    let nativeX1: Int
    let nativeY1: Int
    let fullNativeWidth: Int
    let fullNativeHeight: Int
    let outputWidth: Int
    let outputHeight: Int
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

    private final class SessionCallbackBox {
        let check: (() -> Bool)?
        let progress: ((Double) -> Void)?
        init(check: (() -> Bool)?, progress: ((Double) -> Void)?) {
            self.check = check
            self.progress = progress
        }
    }

    static func withSessionCallbacks<T>(
        _ session: OpaquePointer?,
        cancelled: (() -> Bool)? = nil,
        progress: ((Double) -> Void)? = nil,
        _ body: () throws -> T
    ) throws -> T {
        guard let session, cancelled != nil || progress != nil else {
            if cancelled?() == true || Task.isCancelled { throw CancellationError() }
            return try body()
        }
        return try withoutActuallyEscaping(cancelled ?? { false }) { cancelFn in
            try withoutActuallyEscaping(progress ?? { _ in }) { progressFn in
                let box = SessionCallbackBox(
                    check: cancelled == nil ? nil : { cancelFn() || Task.isCancelled },
                    progress: progress == nil ? nil : progressFn
                )
                let opaque = Unmanaged.passUnretained(box).toOpaque()
                if cancelled != nil {
                    let st = sony2fuji_session_set_cancellation_callback(session, { pointer in
                        guard let pointer else { return 0 }
                        return Unmanaged<SessionCallbackBox>.fromOpaque(pointer).takeUnretainedValue().check?() == true ? 1 : 0
                    }, opaque)
                    guard st == SONY2FUJI_STATUS_OK else { throw HDRRequestError.invalidSettings }
                }
                if progress != nil {
                    let st = sony2fuji_session_set_hdr_progress_callback(session, { pointer, completed, total in
                        guard let pointer, total > 0 else { return }
                        let fraction = min(1.0, max(0.0, Double(completed) / Double(total)))
                        Unmanaged<SessionCallbackBox>.fromOpaque(pointer).takeUnretainedValue().progress?(fraction)
                    }, opaque)
                    guard st == SONY2FUJI_STATUS_OK else {
                        if cancelled != nil { _ = sony2fuji_session_set_cancellation_callback(session, nil, nil) }
                        throw HDRRequestError.invalidSettings
                    }
                }
                defer {
                    if cancelled != nil { _ = sony2fuji_session_set_cancellation_callback(session, nil, nil) }
                    if progress != nil { _ = sony2fuji_session_set_hdr_progress_callback(session, nil, nil) }
                    withExtendedLifetime(box) {}
                }
                if box.check?() == true { throw CancellationError() }
                return try body()
            }
        }
    }

    static func decode(_ url: URL, info: HDRSourceInfo, intent: sony2fuji_intent,
                       longEdge: Int? = nil, session: OpaquePointer? = nil,
                       camera: HDRCameraDevelopmentSettings = HDRCameraDevelopmentSettings(),
                       cameraAIKey: String? = nil,
                       cancelled: () -> Bool = { false }) throws -> HDRImage {
        try decode(url, info: info, intent: intent, longEdge: longEdge, session: session,
                   camera: camera, cameraAIKey: cameraAIKey, progress: nil, cancelled: cancelled)
    }

    static func decode(_ url: URL, info: HDRSourceInfo, intent: sony2fuji_intent,
                       longEdge: Int? = nil, session: OpaquePointer? = nil,
                       camera: HDRCameraDevelopmentSettings = HDRCameraDevelopmentSettings(),
                       cameraAIKey: String? = nil,
                       progress: ((Double) -> Void)?,
                       cancelled: () -> Bool = { false }) throws -> HDRImage {
        try withoutActuallyEscaping(cancelled) { cancelled in
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
                progress?(0)
                let developed = try proRAW.decode(url, stamp: stamp, longEdge: longEdge, cancelled: cancelled)
                progress?(1)
                return HDRImage(owned: developed.pair, url: url, info: info, proRAWBuffers: (developed.hdr, developed.sdr))
            }
            var decodeSession = session
            defer {
                if session == nil, let decodeSession { sony2fuji_session_destroy(decodeSession) }
            }
            if info.isCameraRAW || progress != nil {
                if decodeSession == nil {
                    let status = sony2fuji_session_create(&decodeSession)
                    guard status == SONY2FUJI_STATUS_OK else {
                        throw HDRNativeError(status: status, reason: UInt32(SONY2FUJI_HDR_REASON_OUT_OF_MEMORY),
                            field: UInt32(SONY2FUJI_HDR_FIELD_SESSION))
                    }
                }
            }
            if info.isCameraRAW {
                if let decodeSession {
                    let status = CanonicalEditRecipe.processingOnlyJSON(processingVersion: Int(info.cameraProcessingVersion.rawValue))
                        .withCString { sony2fuji_apply_params(decodeSession, $0) }
                    guard status == SONY2FUJI_STATUS_OK else { throw HDRRequestError.invalidSettings }
                }
            }
            var options=sony2fuji_hdr_decode_options_v1()
            options.version=1; options.struct_size=UInt32(MemoryLayout.size(ofValue:options))
            options.intent=UInt32(intent.rawValue); options.long_edge=UInt32(longEdge ?? 0)
            var result=emptyPair(); var diagnostic=emptyDiagnostic()
            let status = try withSessionCallbacks(decodeSession, cancelled: cancelled, progress: progress) {
                url.path.withCString { path in
                    if info.isCameraRAW {
                        return Self.withCameraDevelopment(camera, profileURL: profileURL) { devPtr in
                            if cameraAIKey != nil {
                                return sony2fuji_hdr_decode_camera_raw_with_ai(decodeSession, path, &options, devPtr, &result, &diagnostic)
                            }
                            return sony2fuji_hdr_decode_camera_raw_with_development(decodeSession, path, &options, devPtr, &result, &diagnostic)
                        }
                    }
                    return sony2fuji_hdr_decode_with_session(decodeSession, path, &options, &result, &diagnostic)
                }
            }
            if status == SONY2FUJI_STATUS_CANCELLED { throw CancellationError() }
            guard status==SONY2FUJI_STATUS_OK else { throw failure(status,diagnostic) }
            let actual=withUnsafeBytes(of:result.source_sha256) { Data($0) }
            let sameSource = info.isCameraRAW
                ? (try? HDRSourceInfo.CameraStamp(url)) == info.cameraStamp
                : actual == info.fingerprint
            let sameAI = cameraAIKey.map { (try? Self.cameraAIKey(url, session: decodeSession)) == $0 } ?? true
            guard sameSource && sameAI else {
                sony2fuji_hdr_release_pair(&result)
                throw HDRNativeError(status:SONY2FUJI_STATUS_INVALID_ARGUMENT,
                    reason:UInt32(SONY2FUJI_HDR_REASON_SOURCE_CHANGED),field:UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
            }
            return HDRImage(owned:result,url:url,info:info)
        }
    }

    func rendered(session: OpaquePointer, settings: HDRSettings, intent: sony2fuji_intent,
                  longEdge: Int? = nil, outputSharpening: OutputSharpening = .off,
                  cancelled: (() -> Bool)? = nil,
                  progress: ((Double) -> Void)? = nil) throws -> HDRImage {
        let request=try makeHDRRequest(settings:settings,intent:intent,longEdge:longEdge,outputSharpening:outputSharpening)
        var result=Self.emptyPair(); var diagnostic=Self.emptyDiagnostic()
        let status = try Self.withSessionCallbacks(session, cancelled: cancelled, progress: progress) {
            withPair { pair in
                withHDRRequestPrefix(request) { sony2fuji_hdr_render(session,pair,$0,&result,&diagnostic) }
            }
        }
        if status == SONY2FUJI_STATUS_CANCELLED { throw CancellationError() }
        guard status==SONY2FUJI_STATUS_OK else { throw Self.failure(status,diagnostic) }
        return HDRImage(owned:result,url:sourceURL,info:sourceInfo)
    }

    static func fromProRAW(pair: sony2fuji_hdr_image_pair_v1, url: URL, info: HDRSourceInfo,
                           buffers: (hdr: Data, sdr: Data)) -> HDRImage {
        HDRImage(owned: pair, url: url, info: info, proRAWBuffers: buffers)
    }

    static func roiSourceBounds(nativeWidth: Int, nativeHeight: Int, settings: HDRSettings,
                                roi: HDRViewportROI, longEdge: Int? = nil) throws -> HDRSourceBounds {
        guard nativeWidth > 0, nativeHeight > 0 else { throw HDRRequestError.invalidSettings }
        let request = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_PREVIEW, longEdge: longEdge)
        var nativeRoi = makeNativeRoi(roi)
        var bounds = sony2fuji_hdr_roi_source_bounds_v1()
        bounds.version = 1
        bounds.struct_size = UInt32(MemoryLayout.size(ofValue: bounds))
        var diagnostic = emptyDiagnostic()
        let status = withHDRRequestPrefix(request) { reqPtr in
            sony2fuji_hdr_roi_source_bounds(UInt32(nativeWidth), UInt32(nativeHeight),
                                            reqPtr, &nativeRoi, &bounds, &diagnostic)
        }
        guard status == SONY2FUJI_STATUS_OK else { throw failure(status, diagnostic) }
        return HDRSourceBounds(
            sourceX0: Int(bounds.source_x0), sourceY0: Int(bounds.source_y0),
            sourceX1: Int(bounds.source_x1), sourceY1: Int(bounds.source_y1),
            nativeX0: Int(bounds.native_x0), nativeY0: Int(bounds.native_y0),
            nativeX1: Int(bounds.native_x1), nativeY1: Int(bounds.native_y1),
            fullNativeWidth: Int(bounds.full_native_width),
            fullNativeHeight: Int(bounds.full_native_height),
            outputWidth: Int(bounds.output_width),
            outputHeight: Int(bounds.output_height)
        )
    }

    func renderedROI(session: OpaquePointer, settings: HDRSettings, roi: HDRViewportROI,
                     longEdge: Int? = nil) throws -> (image: HDRImage, result: HDRViewportROIResult) {
        let request = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_PREVIEW, longEdge: longEdge)
        var nativeRoi = Self.makeNativeRoi(roi)
        var result = Self.emptyPair()
        var outRoi = Self.emptyRoiResult()
        var diagnostic = Self.emptyDiagnostic()
        let status = withPair { pair in
            withHDRRequestPrefix(request) { reqPtr in
                sony2fuji_hdr_render_roi(session, pair, reqPtr, &nativeRoi, &result, &outRoi, &diagnostic)
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { throw Self.failure(status, diagnostic) }
        return (HDRImage(owned: result, url: sourceURL, info: sourceInfo), Self.makeRoiResult(outRoi))
    }

    static func renderCameraRawROI(session: OpaquePointer, url: URL, info: HDRSourceInfo,
                                   settings: HDRSettings, roi: HDRViewportROI,
                                   longEdge: Int? = nil, useAI: Bool = false) throws -> (image: HDRImage, result: HDRViewportROIResult) {
        guard info.isCameraRAW else { throw HDRRequestError.invalidSettings }
        let camera = settings.cameraDevelopmentSettings
        guard camera.isValid else { throw HDRRequestError.invalidSettings }
        let applyStatus = CanonicalEditRecipe.processingOnlyJSON(processingVersion: Int(info.cameraProcessingVersion.rawValue))
            .withCString { sony2fuji_apply_params(session, $0) }
        guard applyStatus == SONY2FUJI_STATUS_OK else { throw HDRRequestError.invalidSettings }
        let profileURL = try camera.cameraProfile.map { try HDRCameraProfileAssetStore.url(for: $0) }
        let request = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_PREVIEW, longEdge: longEdge)
        var nativeRoi = makeNativeRoi(roi)
        var result = emptyPair()
        var outRoi = emptyRoiResult()
        var diagnostic = emptyDiagnostic()
        let status = url.path.withCString { path in
            withHDRRequestPrefix(request) { reqPtr in
                withCameraDevelopment(camera, profileURL: profileURL) { devPtr in
                    sony2fuji_hdr_render_camera_raw_roi(session, path, devPtr, useAI ? 1 : 0,
                                                        reqPtr, &nativeRoi, &result, &outRoi, &diagnostic)
                }
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { throw failure(status, diagnostic) }
        return (HDRImage(owned: result, url: url, info: info), makeRoiResult(outRoi))
    }

    static func renderFileROI(session: OpaquePointer, url: URL, info: HDRSourceInfo,
                              settings: HDRSettings, roi: HDRViewportROI,
                              longEdge: Int? = nil) throws -> (image: HDRImage, result: HDRViewportROIResult) {
        guard !info.isCameraRAW, info.proRAW == nil else { throw HDRRequestError.invalidSettings }
        let request = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_PREVIEW, longEdge: longEdge)
        var nativeRoi = makeNativeRoi(roi)
        var result = emptyPair()
        var outRoi = emptyRoiResult()
        var diagnostic = emptyDiagnostic()
        let status = url.path.withCString { path in
            withHDRRequestPrefix(request) { reqPtr in
                sony2fuji_hdr_render_file_roi(session, path, reqPtr, &nativeRoi, &result, &outRoi, &diagnostic)
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { throw failure(status, diagnostic) }
        return (HDRImage(owned: result, url: url, info: info), makeRoiResult(outRoi))
    }

    static func clearSessionCache(session: OpaquePointer) {
        sony2fuji_hdr_clear_session_cache(session)
    }

    func exportJPEG(to output: URL, baseColor: HDRRecipe.BaseColor = .displayP3,
                    session: OpaquePointer? = nil, cancelled: (() -> Bool)? = nil,
                    progress: ((Double) -> Void)? = nil) throws {
        try exportGainMap(to: output, baseColor: baseColor, heif: false, session: session, cancelled: cancelled, progress: progress)
    }

    static var heifExportAvailable: Bool { sony2fuji_hdr_heif_export_available() != 0 }

    func exportHEIF(to output: URL, baseColor: HDRRecipe.BaseColor = .displayP3,
                    session: OpaquePointer? = nil, cancelled: (() -> Bool)? = nil,
                    progress: ((Double) -> Void)? = nil) throws {
        try exportGainMap(to: output, baseColor: baseColor, heif: true, session: session, cancelled: cancelled, progress: progress)
    }

    @discardableResult
    static func exportTiled(_ url: URL, info: HDRSourceInfo, settings: HDRSettings, output: URL,
                           longEdge: Int?, outputSharpening: OutputSharpening = .off, format: UInt32, session: OpaquePointer,
                           cancelled: () -> Bool = { false },
                           progress: ((Double) -> Void)? = nil) throws -> sony2fuji_hdr_stream_result_v1 {
        guard info.proRAW == nil else { throw HDRRequestError.invalidSettings }
        let request = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_FINAL, longEdge: longEdge, outputSharpening: outputSharpening)
        return try withoutActuallyEscaping(cancelled) { predicate in
            if predicate() || Task.isCancelled { throw CancellationError() }
            let decodeWeight = info.isCameraRAW ? 0.35 : 0.0
            let source = info.isCameraRAW ? try decode(
                url, info: info, intent: SONY2FUJI_INTENT_FINAL,
                session: session, camera: settings.cameraDevelopmentSettings,
                progress: progress.map { report in { report($0 * decodeWeight) } },
                cancelled: predicate
            ) : nil
            if info.isCameraRAW, (try? HDRSourceInfo.CameraStamp(url)) != info.cameraStamp {
                throw HDRNativeError(status: SONY2FUJI_STATUS_INVALID_ARGUMENT,
                    reason: UInt32(SONY2FUJI_HDR_REASON_SOURCE_CHANGED), field: UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
            }
            var config = sony2fuji_hdr_export_config_v1()
            config.version = 1; config.struct_size = UInt32(MemoryLayout.size(ofValue: config))
            config.jpeg_quality = 95; config.base_color = UInt32(SONY2FUJI_HDR_COLOR_DISPLAY_P3)
            config.metadata_policy = UInt32(SONY2FUJI_HDR_METADATA_ISO)
            config.source_sha256 = info.native.source_sha256
            var result = sony2fuji_hdr_stream_result_v1()
            result.version = 1; result.struct_size = UInt32(MemoryLayout.size(ofValue: result))
            var diagnostic = emptyDiagnostic()
            let tiledProgress: ((Double) -> Void)? = progress.map { report in
                { fraction in report(decodeWeight + fraction * (1.0 - decodeWeight)) }
            }
            let status = try withSessionCallbacks(session, cancelled: predicate, progress: tiledProgress) {
                url.path.withCString { original in output.path.withCString { destination in
                    FileManager.default.temporaryDirectory.path.withCString { temporary in
                        config.metadata_source_path = info.isCameraRAW ? nil : original
                        let perform = { (pair: UnsafePointer<sony2fuji_hdr_image_pair_v1>?) in
                            withHDRRequestPrefix(request) {
                                sony2fuji_hdr_export_tiled(session, pair, nil, original, $0, &config, format,
                                    temporary, destination, &result, &diagnostic)
                            }
                        }
                        return source.map { $0.withPair { perform($0) } } ?? perform(nil)
                    }
                } }
            }
            if status == SONY2FUJI_STATUS_CANCELLED { throw CancellationError() }
            guard status == SONY2FUJI_STATUS_OK else { throw failure(status, diagnostic) }
            return result
        }
    }

    private func exportGainMap(to output: URL, baseColor: HDRRecipe.BaseColor, heif: Bool,
                               session: OpaquePointer? = nil, cancelled: (() -> Bool)? = nil,
                               progress: ((Double) -> Void)? = nil) throws {
        try validateProRAWExport(to: output)
        var config=sony2fuji_hdr_export_config_v1()
        config.version=1; config.struct_size=UInt32(MemoryLayout.size(ofValue:config))
        config.jpeg_quality=95; config.base_color=UInt32(baseColor == .displayP3 ? SONY2FUJI_HDR_COLOR_DISPLAY_P3 : SONY2FUJI_HDR_COLOR_SRGB)
        config.metadata_policy=UInt32(heif ? SONY2FUJI_HDR_METADATA_ISO : SONY2FUJI_HDR_METADATA_ISO_XMP)
        config.source_sha256=storage.source_sha256
        var diagnostic=Self.emptyDiagnostic()
        let status = try Self.withSessionCallbacks(session, cancelled: cancelled, progress: progress) {
            sourceURL.path.withCString { source in output.path.withCString { destination in
                config.metadata_source_path = sourceInfo.isCameraRAW ? nil : source
                return withPair {
                    heif ? sony2fuji_hdr_export_heif_with_session(session, $0, &config, destination, &diagnostic)
                        : sony2fuji_hdr_export_jpeg_with_session(session, $0, &config, destination, &diagnostic)
                }
            } }
        }
        if status == SONY2FUJI_STATUS_CANCELLED { throw CancellationError() }
        guard status==SONY2FUJI_STATUS_OK else { throw Self.failure(status,diagnostic) }
    }

    func exportSDR(to output: URL, format: sony2fuji_output_format,
                   session: OpaquePointer? = nil, cancelled: (() -> Bool)? = nil,
                   progress: ((Double) -> Void)? = nil) throws {
        try validateProRAWExport(to: output)
        var config=sony2fuji_hdr_sdr_export_config_v1()
        config.version=1; config.struct_size=UInt32(MemoryLayout.size(ofValue:config))
        config.output_format=UInt32(format.rawValue); config.quality=95; config.source_sha256=storage.source_sha256
        var diagnostic=Self.emptyDiagnostic()
        let status = try Self.withSessionCallbacks(session, cancelled: cancelled, progress: progress) {
            sourceURL.path.withCString { source in output.path.withCString { destination in
                config.metadata_source_path = sourceInfo.isCameraRAW || format == SONY2FUJI_OUTPUT_DNG && sourceInfo.proRAW != nil ? nil : source
                return withPair { sony2fuji_hdr_export_sdr_with_session(session, $0, &config, destination, &diagnostic) }
            } }
        }
        if status == SONY2FUJI_STATUS_CANCELLED { throw CancellationError() }
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
    private static func emptyRoiResult() -> sony2fuji_hdr_roi_result_v1 {
        var value = sony2fuji_hdr_roi_result_v1()
        value.version = 1
        value.struct_size = UInt32(MemoryLayout.size(ofValue: value))
        return value
    }
    private static func makeNativeRoi(_ roi: HDRViewportROI) -> sony2fuji_hdr_roi_v1 {
        var value = sony2fuji_hdr_roi_v1()
        value.version = 1
        value.struct_size = UInt32(MemoryLayout.size(ofValue: value))
        value.norm_x0 = roi.normX0
        value.norm_y0 = roi.normY0
        value.norm_x1 = roi.normX1
        value.norm_y1 = roi.normY1
        value.max_output_long_edge = UInt32(max(0, roi.maxOutputLongEdge))
        value.base_content_headroom = roi.baseContentHeadroom
        value.source_x0 = UInt32(max(0, roi.sourceX0))
        value.source_y0 = UInt32(max(0, roi.sourceY0))
        value.full_source_width = UInt32(max(0, roi.fullSourceWidth))
        value.full_source_height = UInt32(max(0, roi.fullSourceHeight))
        return value
    }
    private static func makeRoiResult(_ raw: sony2fuji_hdr_roi_result_v1) -> HDRViewportROIResult {
        HDRViewportROIResult(
            nativeX0: Int(raw.native_x0), nativeY0: Int(raw.native_y0),
            nativeX1: Int(raw.native_x1), nativeY1: Int(raw.native_y1),
            fullNativeWidth: Int(raw.full_native_width),
            fullNativeHeight: Int(raw.full_native_height),
            isProxy: raw.is_proxy != 0
        )
    }
    private static func withCameraDevelopment(
        _ camera: HDRCameraDevelopmentSettings,
        profileURL: URL?,
        _ body: (UnsafePointer<sony2fuji_hdr_camera_development_v1>) -> sony2fuji_status
    ) -> sony2fuji_status {
        var development = sony2fuji_hdr_camera_development_v1()
        development.version = 1
        development.struct_size = UInt32(MemoryLayout.size(ofValue: development))
        development.white_balance = UInt32(camera.whiteBalance == .asShot ? SONY2FUJI_HDR_CAMERA_WB_AS_SHOT : SONY2FUJI_HDR_CAMERA_WB_TEMPERATURE)
        development.exposure_reference = UInt32(camera.exposureReference == .metadata ? SONY2FUJI_HDR_CAMERA_EXPOSURE_METADATA : SONY2FUJI_HDR_CAMERA_EXPOSURE_SENSOR)
        development.temperature = Float(camera.temperature)
        development.tint = Float(camera.tint)
        development.fbdd_level = UInt32(camera.fbddLevel)
        development.lens_flags = UInt32((camera.lensDistortion ? SONY2FUJI_HDR_CAMERA_LENS_DISTORTION : 0) |
            (camera.lensTCA ? SONY2FUJI_HDR_CAMERA_LENS_TCA : 0) |
            (camera.lensVignetting ? SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING : 0) |
            (camera.lensActive && camera.lensAutoCrop ? SONY2FUJI_HDR_CAMERA_LENS_AUTO_CROP : 0))
        func invoke(_ lensProfile: UnsafePointer<CChar>?) -> sony2fuji_status {
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
                        $0.withMemoryRebound(to: sony2fuji_hdr_camera_development_v1.self, capacity: 1) { body($0) }
                    }
                }
            }
            return withUnsafePointer(to: &development, body)
        }
        return camera.lensProfile?.withCString(invoke) ?? invoke(nil)
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
        let cameraProcessingVersion: UInt32
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
        let key=Key(url:url.standardizedFileURL,fingerprint:info.fingerprint,cameraStamp:info.cameraStamp,
                    cameraProcessingVersion:info.cameraProcessingVersion.rawValue,proRAW:info.proRAW,
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
                      session: OpaquePointer?, lensDatabase: URL? = nil, cameraAIKey: String? = nil,
                      processing: sony2fuji_processing_version = SONY2FUJI_PROCESSING_BASIC_V3) throws -> Double {
        guard let info = try HDRSourceInfo.probe(url) ?? HDRSourceInfo.probeRAW(url, processing: processing) else {
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
