import CoreGraphics
import Foundation
import ImageIO
import PhotosUI
import RawLabKit
#if RAWLAB_INSPECTION_NATIVE_ONLY
import RawLabInspectionNative
#else
import RawLabNative
#endif
import SwiftUI
import UniformTypeIdentifiers

enum Sony2FujiProcessor {
    struct RawWhiteBalance: Equatable {
        let temperature: Double
        let tint: Double
        let isCalibrated: Bool
    }
}

final class RawEditorViewModel {
    enum SourceKind: Equatable { case raw, raster }
    enum EditSaveState: Equatable { case idle, failed(String) }

    var sourceFile: PhotoSourceFile?
    var sourceIdentity: PhotoIdentity?
    var sourceKind: SourceKind? = .raw
    var activeImportRevision: UUID?
    var sourceRevision = UUID()
    var editRecordMetadata: EditorRecordMetadata?
    var isBusy = false
    var hasImage = true
    var rawWhiteBalance: Sony2FujiProcessor.RawWhiteBalance? = .init(temperature: 5500, tint: 0, isCalibrated: true)
    var pendingResetMigrationClear: (EditorEditSource, PhotoEditState, Bool)?
    var failedDraftSource: EditorEditSource?
    var persistedEditorSettings: PersistedEditorSettings?
    var editSaveState: EditSaveState = .idle
    var pendingSettings: RawSettings?

    func cancelQueuedSettingsSave() { pendingSettings = nil }
    func persistEditCandidate(_ candidate: PhotoEditState, source: EditorEditSource) -> Bool { true }
    func queueSettingsSave(_ settings: RawSettings) { pendingSettings = settings }
    func clearAdjustmentTransfer() {}
    func closeQuickPresets() {}
    func cancelProcessingMigration() {}
    func cancelAllResets() {}
    func cancelAdjustmentInteraction() {}
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
    print("PASS: \(message)")
}

func makeCGImage(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
    var data = Data(count: width * height * 4)
    data.withUnsafeMutableBytes { raw in
        let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = fill(x, y)
                let off = (y * width + x) * 4
                ptr[off] = r
                ptr[off + 1] = g
                ptr[off + 2] = b
                ptr[off + 3] = 255
            }
        }
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: space,
        bitmapInfo: info,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

func encodeExport(_ image: CGImage, type: UTType) -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
        fatalError("Failed to create CGImageDestination")
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Failed to finalize CGImageDestination")
    }
    return data as Data
}

@MainActor
func runIOSInspectionSuite() throws {
    let coordinator = EditorCoordinator()
    check(!coordinator.inspection.monitorEnabled, "iOS coordinator inspection starts disabled")
    check(coordinator.inspection.overlay == .none, "iOS coordinator overlay starts .none")

    // 1. Crosshair drag + 4 pinned anchors + geometry remapping
    coordinator.inspection.monitorEnabled = true
    coordinator.inspection.liveOutputPoint = CGPoint(x: 0.3, y: 0.7)
    let sourceSize = CGSize(width: 3000, height: 2000)
    let geom = GeometrySettings(
        cropX: 0.1,
        cropY: 0.15,
        cropWidth: 0.75,
        cropHeight: 0.7,
        quarterTurns: 3,
        flipVertical: true,
        straightenDegrees: -4.0,
        perspectiveHorizontal: -0.25,
        perspectiveVertical: 0.2
    )
    let srcPt = GeometryCoordinateMapper.outputNormToSourceNorm(
        coordinator.inspection.liveOutputPoint!,
        sourceSize: sourceSize,
        geometry: geom
    )
    check(srcPt != nil, "iOS output->source coordinate mapping succeeds")
    for i in 0..<4 {
        let p = i == 0 ? srcPt! : CGPoint(x: 0.2 * Double(i), y: 0.4)
        check(coordinator.inspection.pinAnchor(atSourcePoint: p) != nil, "iOS pin anchor #\(i + 1) succeeds")
    }
    check(coordinator.inspection.pinAnchor(atSourcePoint: CGPoint(x: 0.9, y: 0.9)) == nil, "iOS rejects 5th anchor")

    let remapped = GeometryCoordinateMapper.sourceNormToOutputNorm(
        coordinator.inspection.anchors[0].sourcePoint,
        sourceSize: sourceSize,
        geometry: geom
    )
    check(remapped != nil && abs(remapped!.x - 0.3) < 1e-4 && abs(remapped!.y - 0.7) < 1e-4,
          "iOS source->output anchor remapping round-trips accurately")

    // 2. View-end-stage overlays + 1-tap 50% gray toggle
    let beforeImg = makeCGImage(width: 12, height: 12) { _, _ in (110, 110, 110) }
    let afterImg = makeCGImage(width: 12, height: 12) { x, _ in x < 6 ? (215, 130, 105) : (50, 180, 230) }
    let beforeSample = InspectionSamplerCache.shared.sample(beforeImg, atNormalized: CGPoint(x: 0.2, y: 0.5))
    let afterSample = InspectionSamplerCache.shared.sample(afterImg, atNormalized: CGPoint(x: 0.2, y: 0.5))
    check(beforeSample?.r == 110 && (afterSample?.r ?? 0) == 215, "Before/After iOS sampling reads unmasked buffers")

    let red = InspectionColorSample(r: 255, g: 0, b: 0)
    check(abs(red.hueDeg) < 0.01 && abs(red.saturationPct - 100) < 0.01 && abs(red.luminance - 0.2126) < 1e-4,
          "iOS RGB->HSB and Rec.709 luminance match core contract")
    let straddleImg = makeCGImage(width: 4, height: 4) { x, _ in x < 2 ? (100, 100, 100) : (200, 100, 50) }
    let straddle = InspectionSamplerCache.shared.sample(straddleImg, atNormalized: CGPoint(x: 1.0 / 3.0, y: 0.5), radiusPixels: 1)
    check(straddle?.r == 133, "iOS 3x3 straddle patch rounding matches core (R=133)")
    let clipHeat = InspectionOverlayRenderer.applyOverlayPixel(r: 255, g: 100, b: 100, mode: .oversaturationHeatmap)
    check(clipHeat.0 == 255 && clipHeat.2 > 100, "iOS native overlay pixel matches core")

    coordinator.inspection.selectOverlay(.oversaturationHeatmap)
    coordinator.inspection.toggleNeutralGray50()
    check(coordinator.inspection.overlay == .neutralGray50, "iOS 1-tap 50% gray toggle ON")
    coordinator.inspection.toggleNeutralGray50()
    check(coordinator.inspection.overlay == .oversaturationHeatmap, "iOS 1-tap 50% gray toggle restores previous overlay")

    // 3. Zero PhotoEditState / Export Byte-Identity across all 5 Overlays
    var raw = RawSettings.default
    raw.exposure = 0.35
    raw.geometrySettings = geom
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let state = PhotoEditState(settings: raw, filmID: "VELVIA", updatedAt: fixedDate)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let baseStateBytes = try encoder.encode(state)
    let baseJpeg = encodeExport(afterImg, type: .jpeg)
    let basePng = encodeExport(afterImg, type: .png)

    for mode in InspectionOverlayMode.allCases {
        coordinator.inspection.selectOverlay(mode)
        _ = InspectionOverlayRenderer.shared.render(afterImg, mode: mode)
        let curState = try encoder.encode(PhotoEditState(settings: raw, filmID: "VELVIA", updatedAt: fixedDate))
        let curJpeg = encodeExport(afterImg, type: .jpeg)
        let curPng = encodeExport(afterImg, type: .png)
        check(curState == baseStateBytes, "iOS PhotoEditState byte-identical with overlay \(mode.rawValue)")
        check(curJpeg == baseJpeg, "iOS export JPEG byte-identical with overlay \(mode.rawValue)")
        check(curPng == basePng, "iOS export PNG byte-identical with overlay \(mode.rawValue)")
    }

    // 4. Reset on source change + cache clear & async overlay render
    coordinator.resetForNewSource()
    check(coordinator.inspection.anchors.isEmpty && coordinator.inspection.overlay == .none && coordinator.inspection.liveOutputPoint == nil,
          "resetForNewSource clears inspection anchors, overlay, and live point")

    final class AsyncOverlayBox: @unchecked Sendable {
        let lock = NSLock()
        var image: CGImage?
    }
    let sem = DispatchSemaphore(value: 0)
    let asyncBox = AsyncOverlayBox()
    InspectionOverlayRenderer.shared.clear()
    InspectionSamplerCache.shared.clear()
    check(InspectionOverlayRenderer.shared.entryCount == 0 && InspectionSamplerCache.shared.entryCount == 0,
          "clear() empties shared inspection caches")
    InspectionOverlayRenderer.shared.renderAsync(afterImg, mode: .sketchLuminance) { out in
        asyncBox.lock.lock()
        asyncBox.image = out
        asyncBox.lock.unlock()
        sem.signal()
    }
    let waitResult = sem.wait(timeout: .now() + 2.0)
    asyncBox.lock.lock()
    let asyncRendered = asyncBox.image
    asyncBox.lock.unlock()
    check(waitResult == .success && asyncRendered != nil, "renderAsync produces overlay off main thread")
    check(InspectionOverlayRenderer.shared.cached(afterImg, mode: .sketchLuminance) === asyncRendered,
          "cached() hits async-rendered overlay without recomputation")
    InspectionOverlayRenderer.shared.clear()
    InspectionSamplerCache.shared.clear()
    check(InspectionOverlayRenderer.shared.entryCount == 0 && InspectionSamplerCache.shared.entryCount == 0,
          "second clear() leaves caches empty")
}

@main
struct IOSInspectionSuiteMain {
    static func main() throws {
        try MainActor.assumeIsolated {
            try runIOSInspectionSuite()
        }
    }
}
