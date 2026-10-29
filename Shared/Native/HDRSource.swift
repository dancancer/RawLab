import Foundation

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
        case SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL,SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR:
            return L10n.text("不支持此 HDR 格式或颜色描述。")
        default: return L10n.format("HDR 处理失败（%@）。",String(reason))
        }
    }
}

struct HDRSourceInfo {
    let native: sony2fuji_hdr_source_info_v1
    var fingerprint: Data { withUnsafeBytes(of:native.source_sha256) { Data($0) } }

    static func probe(_ url: URL) throws -> HDRSourceInfo? {
        guard ["jpg","jpeg","heic","heif"].contains(url.pathExtension.lowercased()) else { return nil }
        var info=sony2fuji_hdr_source_info_v1()
        info.version=1; info.struct_size=UInt32(MemoryLayout.size(ofValue:info))
        var diagnostic=sony2fuji_hdr_diagnostic_v1()
        diagnostic.version=1; diagnostic.struct_size=UInt32(MemoryLayout.size(ofValue:diagnostic))
        let status=url.path.withCString { sony2fuji_hdr_probe($0,&info,&diagnostic) }
        if status==SONY2FUJI_STATUS_OK { return HDRSourceInfo(native:info) }
        if status==SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason==UInt32(SONY2FUJI_HDR_REASON_NOT_HDR) { return nil }
        throw HDRNativeError(status:status,reason:diagnostic.reason,field:diagnostic.field)
    }
}
