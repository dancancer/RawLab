import Foundation
import ImageIO

struct HDRNativeError: LocalizedError {
    let status: sony2fuji_status
    let reason: UInt32
    let field: UInt32
    var errorDescription: String? {
        switch Int(reason) {
        case SONY2FUJI_HDR_REASON_NOT_HDR: return L10n.text("此照片没有可编辑的 HDR 增益图。")
        case SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM: return L10n.text("HDR 照片需要 macOS 15 或 iOS 18 及以上版本。")
        case SONY2FUJI_HDR_REASON_OUT_OF_MEMORY: return L10n.text("内存不足，无法完整处理此 HDR 照片。请关闭其他照片后重试。")
        case SONY2FUJI_HDR_REASON_SOURCE_CHANGED: return L10n.text("原始照片已变化，请重新导入。")
        case SONY2FUJI_HDR_REASON_OUTPUT_IO: return L10n.text("无法写入 HDR 导出文件，请检查可用空间和目标权限。")
        case SONY2FUJI_HDR_REASON_SAME_FILE: return L10n.text("导出不能覆盖原始照片。请选择其他文件。")
        case SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU: return L10n.text("HDR 编辑目前使用 CPU。请将 GPU 模式设为自动或关闭。")
        case SONY2FUJI_HDR_REASON_PREVIEW_SOURCE: return L10n.text("预览不能用于导出，请从原始照片重新生成。")
        case SONY2FUJI_HDR_REASON_MALFORMED_AUX: return L10n.text("HDR 增益图损坏，无法还原此照片。")
        case SONY2FUJI_HDR_REASON_LOOK_RESOURCE: return L10n.text("无法读取外观文件。")
        case SONY2FUJI_HDR_REASON_CAMERA_DEVELOPMENT: return L10n.text("无效或不可用的相机显影设置（白平衡或镜头校正）。")
        case SONY2FUJI_HDR_REASON_CAMERA_AI: return L10n.text("此照片或构建尚不能使用 AI 降噪。")
        case SONY2FUJI_HDR_REASON_CAMERA_PROFILE:
            return status == SONY2FUJI_STATUS_IO_ERROR ? L10n.text("找不到 HDR 相机配置，请重新导入。") :
                L10n.text("无法读取 HDR 相机配置，或配置与当前相机不匹配。")
        case SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL,SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR:
            return L10n.text("不支持此 HDR 格式或颜色描述。")
        default: return L10n.format("HDR 处理失败（%@）。",String(reason))
        }
    }
}

struct HDRSourceInfo {
    let native: sony2fuji_hdr_source_info_v1
    var cameraStamp: CameraStamp? = nil
    var proRAW: ProRAWSource? = nil
    var supportsBayerDevelopment = false
    var cameraProcessingVersion = SONY2FUJI_PROCESSING_BASIC_V3
    var isDevelopedRAW: Bool { isCameraRAW || proRAW != nil }
    var isCameraRAW: Bool { native.container == UInt32(SONY2FUJI_HDR_CONTAINER_CAMERA_RAW) }

    func validateEditDecodeVersion(_ saved: Int?) throws {
        if proRAW != nil { try ProRAWSource.validatedDecodeVersion(saved) }
        else if saved != nil { throw HDRSettings.ModeError.invalidSettings }
    }

    static func validateEditingSource(_ url: URL, proRAWDecodeVersion: Int?) throws {
        guard let info = try probe(url) ?? probeRAW(url) else { throw HDRSettings.ModeError.unsupportedSource }
        try info.validateEditDecodeVersion(proRAWDecodeVersion)
    }

    struct CameraStamp: Hashable {
        let modified: Date?
        let size: NSNumber?
        let inode: NSNumber?
        let device: NSNumber?

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            modified = attributes[.modificationDate] as? Date
            size = attributes[.size] as? NSNumber
            inode = attributes[.systemFileNumber] as? NSNumber
            device = attributes[.systemNumber] as? NSNumber
        }
    }

    static func probeRAW(_ url: URL) throws -> HDRSourceInfo? {
        try probeRAW(url, processing: SONY2FUJI_PROCESSING_BASIC_V3)
    }

    static func probeRAW(_ url: URL, processing: sony2fuji_processing_version) throws -> HDRSourceInfo? {
        guard #available(macOS 15, iOS 18, *) else { return nil }
        if url.pathExtension.lowercased() == "dng" {
            let stamp = try CameraStamp(url)
            if let proRAW = try ProRAWSource.probe(url), try CameraStamp(url) == stamp {
                var info = sony2fuji_hdr_source_info_v1()
                info.version = 1
                info.struct_size = UInt32(MemoryLayout.size(ofValue: info))
                info.width = UInt32(proRAW.width)
                info.height = UInt32(proRAW.height)
                info.orientation = 1
                return HDRSourceInfo(native: info, cameraStamp: stamp, proRAW: proRAW)
            }
        }
        return try probeCameraRAW(url, processing: processing)
    }

    static func probeCameraRAW(_ url: URL, processing: sony2fuji_processing_version = SONY2FUJI_PROCESSING_BASIC_V3) throws -> HDRSourceInfo? {
        guard #available(macOS 15, iOS 18, *) else { return nil }
        let stamp = try CameraStamp(url)
        var camera = sony2fuji_hdr_camera_source_info_v1()
        camera.base.version = 1
        camera.base.struct_size = UInt32(MemoryLayout.size(ofValue: camera))
        var diagnostic = sony2fuji_hdr_diagnostic_v1()
        diagnostic.version = 1
        diagnostic.struct_size = UInt32(MemoryLayout.size(ofValue: diagnostic))
        let status = url.path.withCString { path in
            withUnsafeMutablePointer(to: &camera) { pointer in
                pointer.withMemoryRebound(to: sony2fuji_hdr_source_info_v1.self, capacity: 1) {
                    sony2fuji_hdr_probe_camera_raw_with_processing(path, processing, $0, &diagnostic)
                }
            }
        }
        if status == SONY2FUJI_STATUS_OK {
            return HDRSourceInfo(native: camera.base, cameraStamp: stamp,
                supportsBayerDevelopment: camera.capabilities & UInt32(SONY2FUJI_HDR_CAMERA_SOURCE_BAYER) != 0,
                cameraProcessingVersion: processing)
        }
        if status == SONY2FUJI_STATUS_UNSUPPORTED &&
            diagnostic.reason == UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW) { return nil }
        throw HDRNativeError(status: status, reason: diagnostic.reason, field: diagnostic.field)
    }
    var fingerprint: Data { withUnsafeBytes(of:native.source_sha256) { Data($0) } }

    typealias NativeProbe = (UnsafePointer<CChar>?, UnsafeMutablePointer<sony2fuji_hdr_source_info_v1>?,
                            UnsafeMutablePointer<sony2fuji_hdr_diagnostic_v1>?) -> sony2fuji_status
    typealias Probe = (URL, () -> Void) throws -> HDRSourceInfo?
    static var systemSupportsHDR: Bool {
        if #available(macOS 15, iOS 18, *) { return true }
        return false
    }

    static func probe(_ url: URL, onSDRFallback: () -> Void = {}, supportsHDR: Bool = systemSupportsHDR,
                      allowSDRFallback: Bool = true,
                      nativeProbe: NativeProbe = sony2fuji_hdr_probe) throws -> HDRSourceInfo? {
        guard ["jpg","jpeg","heic","heif"].contains(url.pathExtension.lowercased()) else { return nil }
        var info=sony2fuji_hdr_source_info_v1()
        info.version=1; info.struct_size=UInt32(MemoryLayout.size(ofValue:info))
        var diagnostic=sony2fuji_hdr_diagnostic_v1()
        diagnostic.version=1; diagnostic.struct_size=UInt32(MemoryLayout.size(ofValue:diagnostic))
        let status=url.path.withCString { nativeProbe($0,&info,&diagnostic) }
        if status==SONY2FUJI_STATUS_OK { return HDRSourceInfo(native:info) }
        if status==SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason==UInt32(SONY2FUJI_HDR_REASON_NOT_HDR) { return nil }
        #if os(macOS)
        if allowSDRFallback && !supportsHDR && status == SONY2FUJI_STATUS_UNSUPPORTED &&
            diagnostic.reason == UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM) {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let appleAuxiliary = source.flatMap { CGImageSourceCopyAuxiliaryDataInfoAtIndex($0, 0, kCGImageAuxiliaryDataTypeHDRGainMap) }
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            let declaresISO = data?.range(of: Data("urn:iso:std:iso:ts:21496:-1".utf8)) != nil
            let declaresAppleGainMap = !declaresISO && ["urn:com:apple:photo:2020:aux:hdrgainmap", "http://ns.apple.com/HDRGainMap/1.0/"].contains {
                data?.range(of: Data($0.utf8)) != nil
            }
            // SDR 加载器仍拒绝 Apple 辅助增益图，预检不能把它当作可导出的基图。
            // ImageIO 未返回辅助数据时也保留容器内 Apple 声明的严格诊断。
            if appleAuxiliary == nil && !declaresAppleGainMap {
                onSDRFallback()
                return nil
            }
        }
        #endif
        throw HDRNativeError(status:status,reason:diagnostic.reason,field:diagnostic.field)
    }
}
