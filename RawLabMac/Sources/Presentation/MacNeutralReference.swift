import Foundation

/// SDR 中性参考帧的长边策略（整改决策 Q8：限制长边并计入预算，关闭 M3/D-04）。
///
/// 取值推导（与既有预算体系一致）：`MacExactPreviewCache` 的预算是 512 MiB。
/// 编辑器最多同时持有两张整幅中性参考帧（原始基准 + 带几何基准），每帧是
/// RGBA8 图像加同尺寸溢出蒙版 ≈ 8 字节/像素。取长边 4096 后，最坏情况（1:1
/// 方形画幅）两帧合计 2 × 4096² × 8 B = 256 MiB，恰好等于既有预算的一半，
/// 另一半留给至多 3 条精确预览缓存项。4096 也是本机已有的导出尺寸预设
/// （`ExportSizePicker`），足以覆盖 5K 面板上的 1:1 对照缩放。
/// 渲染走 SIZE_LIMIT_LONG_EDGE（只降不放大），长边不超过上限的照片保持原生帧。
enum MacReferenceFramePolicy {
    static let longEdgeCap = 4096
}

struct MacReferenceSource: Equatable {
    let url: URL
    let modified: Date?
    let size: UInt64?
    let fileNumber: UInt64
    let raster: Bool
    let hdrFingerprint: Data?

    init(_ url: URL, raster: Bool, hdrFingerprint: Data? = nil) {
        self.url = url.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: self.url.path)
        modified = attributes?[.modificationDate] as? Date
        size = (attributes?[.size] as? NSNumber)?.uint64Value
        fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        self.raster = raster
        self.hdrFingerprint=hdrFingerprint
    }
}

struct MacNeutralReferenceKey: Equatable {
    let source: MacReferenceSource
    let processing: ProcessingIdentity
    let x3fMode: X3fMode
    let geometry: GeometrySettings
    let lens: LensCorrectionSettings
    let edge: Int?
    let hdrMode: HDRSettings.Mode?
    let hdrVersion: Int?
    let hdrCamera: HDRCameraDevelopmentSettings?
    let proRAWDecodeVersion: Int?

    init(source: MacReferenceSource, settings: Adjustments, edge: Int?) {
        self.source = source; processing = settings.processing
        x3fMode = settings.x3fMode
        geometry = settings.geometrySettings; lens = settings.lensSettings; self.edge = edge
        hdrMode=settings.hdr?.mode; hdrVersion=settings.hdr?.processingVersion
        hdrCamera = settings.isHDREditing ? settings.hdr?.neutralGeometrySettings.cameraDevelopmentSettings : nil
        proRAWDecodeVersion = settings.proRAWDecodeVersion
    }
    func canServe(_ requested: MacNeutralReferenceKey, fullResolution: Bool) -> Bool {
        source == requested.source && processing == requested.processing && x3fMode == requested.x3fMode &&
            geometry == requested.geometry && lens == requested.lens &&
            hdrMode == requested.hdrMode && hdrVersion == requested.hdrVersion && hdrCamera == requested.hdrCamera && proRAWDecodeVersion == requested.proRAWDecodeVersion &&
            (edge == requested.edge || fullResolution)
    }
    var usesOriginal: Bool { geometry.isIdentity && lens == LensCorrectionSettings() }
}
