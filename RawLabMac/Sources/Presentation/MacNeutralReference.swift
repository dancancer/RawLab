import Foundation

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

    init(source: MacReferenceSource, settings: Adjustments, edge: Int?) {
        self.source = source; processing = settings.processing
        x3fMode = settings.x3fMode
        geometry = settings.geometrySettings; lens = settings.lensSettings; self.edge = edge
        hdrMode=settings.hdr?.mode; hdrVersion=settings.hdr?.processingVersion
    }
    func canServe(_ requested: MacNeutralReferenceKey, fullResolution: Bool) -> Bool {
        source == requested.source && processing == requested.processing && x3fMode == requested.x3fMode &&
            geometry == requested.geometry && lens == requested.lens &&
            hdrMode == requested.hdrMode && hdrVersion == requested.hdrVersion &&
            (edge == requested.edge || fullResolution)
    }
    var usesOriginal: Bool { geometry.isIdentity && lens == LensCorrectionSettings() }
}
