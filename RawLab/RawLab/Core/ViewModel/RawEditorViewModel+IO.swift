import Foundation
import ImageIO
import UIKit

enum ImageSourceKind {
    case raw
    case raster
}

enum EditorError: LocalizedError {
    case noImageLoaded
    case renderFailed
    case sampleNotFound

    var errorDescription: String? {
        switch self {
        case .noImageLoaded:
            return "No image loaded."
        case .renderFailed:
            return "Image render failed."
        case .sampleNotFound:
            return "Sample RAW not found."
        }
    }
}

extension RawEditorViewModel {
    struct RawPreviewBase {
        let buffer: Sony2FujiProcessor.Buffer
        let previewBuffer: Sony2FujiProcessor.Buffer
        let basePreviewImage: UIImage?
        let baseHistogram: [CGFloat]
        let lutID: String?
        let lutApplied: Bool
        let orientation: CGImagePropertyOrientation?
    }

    struct RasterPreviewBase {
        let buffer: Sony2FujiProcessor.Buffer
        let previewBuffer: Sony2FujiProcessor.Buffer
        let basePreviewImage: UIImage?
        let baseHistogram: [CGFloat]
        let orientation: CGImagePropertyOrientation?
    }

    func buildRawPreviewBase(url: URL) throws -> RawPreviewBase {
        let rawBase = try processor.processRaw(
            url: url,
            settings: .default,
            previewLongEdge: previewMaxDimension,
            lutURL: nil
        )
        let previewBuffer = try processor.processBuffer(
            buffer: rawBase.buffer,
            settings: .default,
            previewLongEdge: interactivePreviewMaxDimension,
            lutURL: nil
        )
        let basePreviewImage = processor.makeUIImage(from: rawBase.buffer, orientation: rawBase.orientation)
        let baseHistogram = processor.computeHistogram(from: rawBase.buffer, bins: histogramBins)

        return RawPreviewBase(
            buffer: rawBase.buffer,
            previewBuffer: previewBuffer,
            basePreviewImage: basePreviewImage,
            baseHistogram: baseHistogram,
            lutID: nil,
            lutApplied: false,
            orientation: rawBase.orientation
        )
    }

    func buildRasterPreviewBase(url: URL) throws -> RasterPreviewBase {
        let rasterBase = try processor.loadRasterBuffer(url: url)
        let baseBuffer = try processor.processBuffer(
            buffer: rasterBase.buffer,
            settings: .default,
            previewLongEdge: previewMaxDimension,
            lutURL: nil
        )
        let previewBuffer = try processor.processBuffer(
            buffer: rasterBase.buffer,
            settings: .default,
            previewLongEdge: interactivePreviewMaxDimension,
            lutURL: nil
        )
        let basePreviewImage = processor.makeUIImage(from: baseBuffer, orientation: rasterBase.orientation)
        let baseHistogram = processor.computeHistogram(from: baseBuffer, bins: histogramBins)

        return RasterPreviewBase(
            buffer: baseBuffer,
            previewBuffer: previewBuffer,
            basePreviewImage: basePreviewImage,
            baseHistogram: baseHistogram,
            orientation: rasterBase.orientation
        )
    }
}

extension RawEditorViewModel {
    func importImage(from source: PhotoImportSource, settings: RawSettings) {
        statusMessage = nil
        isBusy = true
        previewWorkItem?.cancel()
        previewWorkItem = nil
        cancelHistogramWorkItem()
        setLatestRenderID(UUID())
        lastPreviewRequest = nil

        let sourceKind: ImageSourceKind = source.isRaw ? .raw : .raster

        DispatchQueue.global(qos: .userInitiated).async {
            let didStart = source.url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    source.url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let localURL = try self.copyToCache(source.url)
                if sourceKind == .raw {
                    let rawBase = try self.buildRawPreviewBase(url: localURL)
                    let lutURL = self.lutURL(for: settings)
                    let previewResult = try self.processor.processRaw(
                        url: localURL,
                        settings: settings,
                        previewLongEdge: self.previewMaxDimension,
                        lutURL: lutURL
                    )
                    let adjustedImage = self.processor.makeUIImage(
                        from: previewResult.buffer,
                        orientation: previewResult.orientation ?? rawBase.orientation
                    )
                    let adjustedHistogram = self.processor.computeHistogram(
                        from: previewResult.buffer,
                        bins: self.histogramBins
                    )

                    DispatchQueue.main.async {
                        self.sourceURL = localURL
                        self.sourceKind = sourceKind
                        self.sourceOrientation = previewResult.orientation ?? rawBase.orientation
                        self.draftBuffer = rawBase.buffer
                        self.draftPreviewBuffer = rawBase.previewBuffer
                        self.basePreviewImage = rawBase.basePreviewImage
                        self.baseHistogram = rawBase.baseHistogram
                        self.rawLUTID = settings.lutID
                        self.rawLUTApplied = settings.lutID != nil && settings.lutStrength > 0
                        self.previewImage = adjustedImage
                        self.histogram = adjustedHistogram
                        self.hasImage = rawBase.basePreviewImage != nil || adjustedImage != nil
                        self.isBusy = false
                        if adjustedImage == nil {
                            self.statusMessage = "Preview render failed."
                        }
                    }
                } else {
                    let rasterBase = try self.buildRasterPreviewBase(url: localURL)
                    let adjustedBuffer = try self.processor.processBuffer(
                        buffer: rasterBase.buffer,
                        settings: settings,
                        previewLongEdge: self.previewMaxDimension,
                        lutURL: self.lutURL(for: settings)
                    )
                    let adjustedImage = self.processor.makeUIImage(
                        from: adjustedBuffer,
                        orientation: rasterBase.orientation
                    )
                    let adjustedHistogram = self.processor.computeHistogram(
                        from: adjustedBuffer,
                        bins: self.histogramBins
                    )

                    DispatchQueue.main.async {
                        self.sourceURL = localURL
                        self.sourceKind = sourceKind
                        self.sourceOrientation = rasterBase.orientation
                        self.draftBuffer = rasterBase.buffer
                        self.draftPreviewBuffer = rasterBase.previewBuffer
                        self.basePreviewImage = rasterBase.basePreviewImage
                        self.baseHistogram = rasterBase.baseHistogram
                        self.rawLUTID = nil
                        self.rawLUTApplied = false
                        self.previewImage = adjustedImage
                        self.histogram = adjustedHistogram
                        self.hasImage = rasterBase.basePreviewImage != nil || adjustedImage != nil
                        self.isBusy = false
                        if adjustedImage == nil {
                            self.statusMessage = "Preview render failed."
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                    self.previewImage = nil
                    self.basePreviewImage = nil
                    self.draftPreviewBuffer = nil
                    self.draftBuffer = nil
                    self.sourceURL = nil
                    self.sourceKind = nil
                    self.sourceOrientation = nil
                    self.rawLUTID = nil
                    self.rawLUTApplied = false
                    self.hasImage = false
                    self.histogram = []
                    self.baseHistogram = []
                }
            }
        }
    }

    func exportJPEG(settings: RawSettings, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let sourceURL, let sourceKind else {
            completion(.failure(EditorError.noImageLoaded))
            return
        }

        isBusy = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let lutURL = self.lutURL(for: settings)
                let data: Data

                if sourceKind == .raw {
                    let result = try self.processor.processRaw(
                        url: sourceURL,
                        settings: settings,
                        previewLongEdge: nil,
                        lutURL: lutURL
                    )
                    let output = try self.processor.makeJPEGData(
                        from: result.buffer,
                        sourceURL: sourceURL,
                        orientation: result.orientation,
                        quality: 0.92
                    )
                    data = output
                } else {
                    let raster = try self.processor.loadRasterBuffer(url: sourceURL)
                    let outputBuffer = try self.processor.processBuffer(
                        buffer: raster.buffer,
                        settings: settings,
                        previewLongEdge: nil,
                        lutURL: lutURL
                    )
                    let output = try self.processor.makeJPEGData(
                        from: outputBuffer,
                        sourceURL: sourceURL,
                        orientation: raster.orientation,
                        quality: 0.92
                    )
                    data = output
                }

                DispatchQueue.main.async {
                    self.isBusy = false
                    completion(.success(data))
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    completion(.failure(error))
                }
            }
        }
    }

    func runBundledSampleSmokeTest(settings: RawSettings) {
        guard let url = Bundle.main.url(forResource: sampleResourceName, withExtension: sampleResourceExtension) else {
            statusMessage = "Sample RAW not found in app bundle."
            return
        }

        statusMessage = nil
        isBusy = true
        let lutURL = lutURL(for: settings)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rawPreview = try self.buildRawPreviewBase(url: url)
                let previewResult = try self.processor.processRaw(
                    url: url,
                    settings: settings,
                    previewLongEdge: self.previewMaxDimension,
                    lutURL: lutURL
                )
                let previewImage = self.processor.makeUIImage(
                    from: previewResult.buffer,
                    orientation: previewResult.orientation ?? rawPreview.orientation
                )
                let previewHistogram = self.processor.computeHistogram(
                    from: previewResult.buffer,
                    bins: self.histogramBins
                )

                let fullResult = try self.processor.processRaw(
                    url: url,
                    settings: settings,
                    previewLongEdge: nil,
                    lutURL: lutURL
                )
                let data = try self.processor.makeJPEGData(
                    from: fullResult.buffer,
                    sourceURL: url,
                    orientation: fullResult.orientation,
                    quality: 0.92
                )

                DispatchQueue.main.async {
                    self.sourceURL = url
                    self.sourceKind = .raw
                    self.sourceOrientation = previewResult.orientation ?? rawPreview.orientation
                    self.draftBuffer = rawPreview.buffer
                    self.draftPreviewBuffer = rawPreview.previewBuffer
                    self.basePreviewImage = rawPreview.basePreviewImage
                    self.baseHistogram = rawPreview.baseHistogram
                    self.rawLUTID = settings.lutID
                    self.rawLUTApplied = settings.lutID != nil && settings.lutStrength > 0
                    self.previewImage = previewImage
                    self.histogram = previewHistogram
                    self.hasImage = rawPreview.basePreviewImage != nil || previewImage != nil
                    self.isBusy = false
                    let sizeKB = Double(data.count) / 1024.0
                    let message = String(format: "Sample decode OK: %.1f KB JPEG", sizeKB)
                    self.statusMessage = message
                    self.writeSmokeTestResult("OK: \(message)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                    self.previewImage = nil
                    self.basePreviewImage = nil
                    self.draftPreviewBuffer = nil
                    self.draftBuffer = nil
                    self.sourceURL = nil
                    self.sourceKind = nil
                    self.sourceOrientation = nil
                    self.rawLUTID = nil
                    self.rawLUTApplied = false
                    self.hasImage = false
                    self.histogram = []
                    self.baseHistogram = []
                    self.writeSmokeTestResult("FAIL: \(error.localizedDescription)")
                }
            }
        }
    }
}

private extension RawEditorViewModel {
    func copyToCache(_ sourceURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cacheDir = cacheRoot.appendingPathComponent("RawLab", isDirectory: true)

        if !fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }

        let fileName = sourceURL.lastPathComponent.isEmpty ? UUID().uuidString : sourceURL.lastPathComponent
        let destinationURL = cacheDir.appendingPathComponent(fileName)
        if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
            return destinationURL
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func writeSmokeTestResult(_ message: String) {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cacheDir = cacheRoot.appendingPathComponent("RawLab", isDirectory: true)
        let resultURL = cacheDir.appendingPathComponent("smoke_test.txt")

        do {
            if !fileManager.fileExists(atPath: cacheDir.path) {
                try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            }
            try message.data(using: .utf8)?.write(to: resultURL)
        } catch {
            return
        }
    }
}
