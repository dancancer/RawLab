import Foundation

struct MacReferenceSource: Equatable {
    let url: URL
    let modified: Date?
    let size: UInt64?
    let fileNumber: UInt64
    let raster: Bool

    init(_ url: URL, raster: Bool) {
        self.url = url.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: self.url.path)
        modified = attributes?[.modificationDate] as? Date
        size = (attributes?[.size] as? NSNumber)?.uint64Value
        fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        self.raster = raster
    }
}

struct MacNeutralReferenceKey: Equatable {
    let source: MacReferenceSource
    let processing: ProcessingIdentity
    let geometry: GeometrySettings
    let lens: LensCorrectionSettings
    let edge: Int?

    init(source: MacReferenceSource, settings: Adjustments, edge: Int?) {
        self.source = source; processing = settings.processing
        geometry = settings.geometrySettings; lens = settings.lensSettings; self.edge = edge
    }
    func canServe(_ requested: MacNeutralReferenceKey, fullResolution: Bool) -> Bool {
        source == requested.source && processing == requested.processing && geometry == requested.geometry && lens == requested.lens &&
            (edge == requested.edge || fullResolution)
    }
    var usesOriginal: Bool { geometry.isIdentity && lens == LensCorrectionSettings() }
}
