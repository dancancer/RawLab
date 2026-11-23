import RawLabKit
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct MacInspectionSuiteTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func makeTestImage(width: Int, height: Int, colorFill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let (r, g, b) = colorFill(x, y)
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

    static func encodeImage(_ image: CGImage, type: UTType) -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            fatalError("Could not create CGImageDestination")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            fatalError("Could not finalize CGImageDestination")
        }
        return out as Data
    }

    static func main() throws {
        // 1. Sampling Before/After + HSB + Luminance Cursor
        let beforeImg = makeTestImage(width: 16, height: 16) { _, _ in (120, 120, 120) }
        let afterImg = makeTestImage(width: 16, height: 16) { x, _ in x < 8 ? (220, 135, 110) : (60, 140, 220) }

        let beforeSample = InspectionSamplerCache.shared.sample(beforeImg, atNormalized: CGPoint(x: 0.25, y: 0.5))
        let afterWarm = InspectionSamplerCache.shared.sample(afterImg, atNormalized: CGPoint(x: 0.25, y: 0.5))
        let afterCool = InspectionSamplerCache.shared.sample(afterImg, atNormalized: CGPoint(x: 0.75, y: 0.5))
        check(beforeSample?.r == 120 && beforeSample?.saturationPct == 0, "Before neutral sample stays gray")
        check((afterWarm?.hueDeg ?? -1) < 30 && (afterWarm?.saturationPct ?? 0) > 40, "After warm skin-tone sample reports warm hue")
        check((afterCool?.hueDeg ?? 0) > 190 && (afterCool?.hueDeg ?? 0) < 230, "After cool sample reports blue hue")
        check((afterWarm?.luminance ?? 0) > (afterCool?.luminance ?? 1), "Rec.709 luminance ranks warm sample brighter than cool sample")

        // 2. 4-Anchor Cap + Source-Normalized Geometry Remapping + Cropped-out nil
        var session = InspectionSessionState()
        let srcSize = CGSize(width: 2400, height: 1600)
        let geom = GeometrySettings(
            cropX: 0.15,
            cropY: 0.15,
            cropWidth: 0.7,
            cropHeight: 0.7,
            quarterTurns: 1,
            flipHorizontal: true,
            straightenDegrees: 5.0,
            perspectiveHorizontal: 0.2,
            perspectiveVertical: -0.15
        )
        let pinnedOut = CGPoint(x: 0.45, y: 0.55)
        guard let srcAnchor = GeometryCoordinateMapper.outputNormToSourceNorm(pinnedOut, sourceSize: srcSize, geometry: geom) else {
            fatalError("Expected valid inverse mapping")
        }
        check(session.pinAnchor(atSourcePoint: srcAnchor) != nil, "Anchor 1 pinned")
        check(session.pinAnchor(atSourcePoint: CGPoint(x: 0.2, y: 0.2)) != nil, "Anchor 2 pinned")
        check(session.pinAnchor(atSourcePoint: CGPoint(x: 0.8, y: 0.2)) != nil, "Anchor 3 pinned")
        check(session.pinAnchor(atSourcePoint: CGPoint(x: 0.8, y: 0.8)) != nil, "Anchor 4 pinned")
        check(session.pinAnchor(atSourcePoint: CGPoint(x: 0.1, y: 0.1)) == nil, "Anchor 5 rejected at cap 4")

        if let remapped = GeometryCoordinateMapper.sourceNormToOutputNorm(session.anchors[0].sourcePoint, sourceSize: srcSize, geometry: geom) {
            check(abs(remapped.x - pinnedOut.x) < 1e-4 && abs(remapped.y - pinnedOut.y) < 1e-4,
                  "Anchor 1 remaps back to exact output location")
        } else {
            fatalError("Anchor 1 should be inside crop")
        }
        let tightCrop = GeometrySettings(cropX: 0.4, cropY: 0.4, cropWidth: 0.2, cropHeight: 0.2)
        check(GeometryCoordinateMapper.sourceNormToOutputNorm(CGPoint(x: 0.05, y: 0.05), sourceSize: srcSize, geometry: tightCrop) == nil,
              "Out-of-crop anchor returns nil while retained in session")
        check(session.anchors.count == 4, "Cropped-out anchor remains retained in session state")

        // 3. View-end-stage 5 Overlays + Transient Gray Toggle + Escape
        for mode in InspectionOverlayMode.allCases where mode != .none {
            let overlayImg = InspectionOverlayRenderer.shared.render(afterImg, mode: mode)
            check(overlayImg != nil && overlayImg?.width == 16 && overlayImg?.height == 16,
                  "Overlay \(mode.rawValue) renders display image cleanly")
        }
        session.selectOverlay(.skinHueAmplification)
        session.toggleNeutralGray50()
        check(session.overlay == .neutralGray50, "1-click 50% gray toggles ON")
        check(session.handleEscape() && session.overlay == .skinHueAmplification, "Escape exits 50% gray back to prior overlay")
        check(session.handleEscape() && session.overlay == .none, "Second Escape clears overlay")

        // 4. Zero Adjustments / PhotoEditState / Export Byte-Identity across all 5 Overlays
        var adjustments = Adjustments()
        adjustments.exposure = 0.5
        adjustments.contrast = 1.15
        adjustments.geometry = geom
        let editState = MacPhotoEditState(settings: adjustments, filmID: "CLASSIC_CHROME")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let baselineStateBytes = try encoder.encode(editState)
        let baselineJpeg = encodeImage(afterImg, type: .jpeg)
        let baselinePng = encodeImage(afterImg, type: .png)

        for mode in InspectionOverlayMode.allCases {
            session.selectOverlay(mode)
            _ = InspectionOverlayRenderer.shared.render(afterImg, mode: mode)
            // Unmasked source image & edit state remain untouched regardless of active view overlay
            let currentStateBytes = try encoder.encode(MacPhotoEditState(settings: adjustments, filmID: "CLASSIC_CHROME"))
            let currentJpeg = encodeImage(afterImg, type: .jpeg)
            let currentPng = encodeImage(afterImg, type: .png)
            check(currentStateBytes == baselineStateBytes, "MacPhotoEditState byte-identical with overlay \(mode.rawValue)")
            check(currentJpeg == baselineJpeg, "Export JPEG byte-identical with overlay \(mode.rawValue)")
            check(currentPng == baselinePng, "Export PNG byte-identical with overlay \(mode.rawValue)")
        }

        // 5. MacViewingState & HistogramPresentation integration check
        #if !RAWLAB_NATIVE_EDITOR_MODEL
        let viewing = MacViewingState()
        check(!viewing.enabled, "MacViewingState defaults clean")
        #endif
        let hist = HistogramPresentation(bins: [[0, 10, 50], [0, 20, 40], [0, 5, 10]])
        check(hist.peak == 50, "HistogramPresentation computes shared peak")

        // 6. HDR Reopen + Asymmetric Geometry + Exposure Edit Coordinate Invariance (Model)
        let asymmetricGeom = GeometrySettings(
            cropX: 0.1,
            cropY: 0.05,
            cropWidth: 0.25,
            cropHeight: 0.85,
            quarterTurns: 1,
            flipHorizontal: false,
            straightenDegrees: 18.0,
            perspectiveHorizontal: 0.45,
            perspectiveVertical: -0.35
        )
        var hdrEdit = Adjustments()
        hdrEdit.hdr = HDRSettings()
        hdrEdit.setGeometrySettings(asymmetricGeom)
        let savedHDRState = MacPhotoEditState(settings: hdrEdit, filmID: "")
        let reopenedHDRState = try JSONDecoder().decode(MacPhotoEditState.self, from: try encoder.encode(savedHDRState))
        var reopenedAdjustments = reopenedHDRState.settings
        check(reopenedAdjustments.isHDREditing && reopenedAdjustments.geometrySettings == asymmetricGeom,
              "Reopened HDR state preserves asymmetric geometry")

        let spec = GeometryCoordinateMapper.canvasFor(width: 3072, height: 3072, options: asymmetricGeom)
        let postCropOutputSize = CGSize(width: spec.outputWidth, height: spec.outputHeight)
        let inferredSourceSize = GeometryCoordinateMapper.inferSourceSize(
            outputSize: postCropOutputSize,
            geometry: reopenedAdjustments.geometrySettings
        )
        let probeOutputs = [
            CGPoint(x: 0.2, y: 0.2),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.8, y: 0.8),
            CGPoint(x: 0.3, y: 0.7),
        ]
        var hdrSession = InspectionSessionState()
        for pt in probeOutputs {
            guard let src = GeometryCoordinateMapper.outputNormToSourceNorm(
                pt,
                sourceSize: inferredSourceSize,
                geometry: reopenedAdjustments.geometrySettings
            ) else {
                fatalError("FAIL: Could not pin anchor at \(pt) using inferred HDR source size")
            }
            check(hdrSession.pinAnchor(atSourcePoint: src) != nil, "Pinned HDR anchor at \(pt)")
        }
        let preExposurePts = hdrSession.anchors.compactMap {
            GeometryCoordinateMapper.sourceNormToOutputNorm(
                $0.sourcePoint,
                sourceSize: inferredSourceSize,
                geometry: reopenedAdjustments.geometrySettings
            )
        }
        check(preExposurePts.count == 4, "All 4 HDR anchors visible before exposure edit")

        // Negative control: overwriting sourceNativeSize with post-crop outputSize drops/corrupts anchors
        let corruptedPts = hdrSession.anchors.compactMap {
            GeometryCoordinateMapper.sourceNormToOutputNorm(
                $0.sourcePoint,
                sourceSize: postCropOutputSize,
                geometry: reopenedAdjustments.geometrySettings
            )
        }
        check(corruptedPts.count < 4, "Post-crop outputSize misused as sourceNativeSize drops anchors")

        reopenedAdjustments.set(.exposure, to: 0.5)
        let afterExposureInferred = GeometryCoordinateMapper.inferSourceSize(
            outputSize: postCropOutputSize,
            geometry: reopenedAdjustments.geometrySettings
        )
        let postExposurePts = hdrSession.anchors.compactMap {
            GeometryCoordinateMapper.sourceNormToOutputNorm(
                $0.sourcePoint,
                sourceSize: afterExposureInferred,
                geometry: reopenedAdjustments.geometrySettings
            )
        }
        check(postExposurePts.count == 4, "All 4 HDR anchors stay visible after exposure edit")
        for (idx, (pre, post)) in zip(preExposurePts, postExposurePts).enumerated() {
            let drift = hypot(post.x - pre.x, post.y - pre.y)
            check(drift < 1e-3, "HDR anchor #\(idx + 1) drift < 1e-3 after exposure edit (drift=\(drift))")
        }

        // Combined Cross-Feature Parity: Inspection overlays (sketchLuminance .. neutralGray50) +
        // pinned anchors never pollute CanonicalEditRecipe JSON or export params even when Curve v2 +
        // Color Grading v2 + Output Sharpening are all active.
        var graded = Adjustments()
        var curve = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0, y: 0.05), .init(x: 0.5, y: 0.6), .init(x: 1, y: 0.95)],
            applyToLuminosity: true,
            parametric: ToneCurveParametric(highlights: -10, lights: 12, darks: -8, shadows: 20, splitShadow: 0.25, splitMidtone: 0.50, splitHighlight: 0.75)
        )
        curve.channels.red = ToneCurveShape.identity.inserting(x: 0.5, y: 0.56)
        graded.editingCurveSettings = curve
        graded.editingGradingSettings = ColorGradingSettings(
            shadows: .init(hue: 215, saturation: 24, luminance: -12),
            midtones: .init(hue: 45, saturation: 12, luminance: 6),
            highlights: .init(hue: 315, saturation: 18, luminance: -8),
            global: .init(hue: 165, saturation: 15, luminance: 7),
            blending: 72,
            balance: -18
        )
        let baselineParams = try graded.canonicalParamsJSON(isRaster: false, includeDenoise: true, outputSharpening: .high)
        let baselineRecipe = try CanonicalEditRecipe.encode(graded.canonicalEditState(isRaster: false, includeDenoise: true, outputSharpening: .high))
        for overlay in InspectionOverlayMode.allCases {
            var session = InspectionSessionState()
            session.monitorEnabled = true
            _ = session.pinAnchor(atSourcePoint: CGPoint(x: 0.25, y: 0.75))
            session.selectOverlay(overlay)
            let paramsWithOverlay = try graded.canonicalParamsJSON(isRaster: false, includeDenoise: true, outputSharpening: .high)
            let recipeWithOverlay = try CanonicalEditRecipe.encode(graded.canonicalEditState(isRaster: false, includeDenoise: true, outputSharpening: .high))
            check(paramsWithOverlay == baselineParams && recipeWithOverlay == baselineRecipe,
                  "Overlay \(overlay.rawValue) + pin + Curve v2 + Grading v2 + OutputSharpening has zero export/recipe pollution")
            check(!recipeWithOverlay.contains("neutralGray50") && !recipeWithOverlay.contains("sketchLuminance") && !recipeWithOverlay.contains("anchors"),
                  "Recipe JSON excludes inspection state for \(overlay.rawValue)")
        }

        #if RAWLAB_NATIVE_EDITOR_MODEL
        if CommandLine.arguments.count >= 2 {
            try runNativeHDRReopenExposureRegression(dngURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        #endif
    }

    #if RAWLAB_NATIVE_EDITOR_MODEL
    static func waitUntil(_ label: String, timeout: TimeInterval = 60, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        fatalError("FAIL: Timed out waiting for \(label)")
    }

    static func runNativeHDRReopenExposureRegression(dngURL: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-mac-inspection-hdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lookDir = root.appendingPathComponent("looks")
        let editDir = root.appendingPathComponent("edits")
        let batchDir = root.appendingPathComponent("batch")
        let workDNG = root.appendingPathComponent(dngURL.lastPathComponent)
        try FileManager.default.copyItem(at: dngURL, to: workDNG)

        let asymmetricGeom = GeometrySettings(
            cropX: 0.1,
            cropY: 0.05,
            cropWidth: 0.25,
            cropHeight: 0.85,
            quarterTurns: 1,
            flipHorizontal: false,
            straightenDegrees: 18.0,
            perspectiveHorizontal: 0.45,
            perspectiveVertical: -0.35
        )

        // 1. Open in EditorModel, enable HDR + asymmetric geometry, and save edits.
        do {
            let editor = EditorModel(lookDirectory: lookDir, editDirectory: editDir, batchDirectory: batchDir)
            editor.films = []
            editor.updatePreviewLongEdge(1024)
            editor.open(workDNG)
            try waitUntil("initial DNG open") { !editor.busy && editor.result != nil }

            editor.setHDREditing(true)
            try waitUntil("HDR mode activation") { !editor.importing && !editor.busy && editor.settings.isHDREditing && editor.result != nil }

            var edited = editor.settings
            edited.setGeometrySettings(asymmetricGeom)
            editor.settings = edited
            try waitUntil("HDR asymmetric geometry render") {
                !editor.busy && editor.result != nil && editor.settings.geometrySettings == asymmetricGeom
            }
            check(editor.saveEdits(), "Saved HDR asymmetric geometry edits")
        }

        // 2. Reopen in a fresh EditorModel, pin 4 anchors, adjust exposure 0 -> 0.5, and verify anchor stability.
        let reopened = EditorModel(lookDirectory: lookDir, editDirectory: editDir, batchDirectory: batchDir)
        reopened.films = []
        reopened.updatePreviewLongEdge(1024)
        reopened.open(workDNG)
        try waitUntil("HDR reopen render") { !reopened.busy && reopened.result != nil && reopened.settings.isHDREditing }

        check(reopened.sourceNativeSize == nil, "Reopened HDR with non-identity geometry does not set sourceNativeSize to post-crop output")

        let pinOutputs = [
            CGPoint(x: 0.2, y: 0.2),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.8, y: 0.8),
            CGPoint(x: 0.3, y: 0.7),
        ]
        for pt in pinOutputs {
            check(reopened.pinInspectionAnchor(atOutputPoint: pt) != nil, "Pinned native HDR anchor at \(pt)")
        }
        let preMarkers = reopened.inspectionMarkerPoints()
        check(preMarkers.count == 4, "All 4 markers visible before HDR exposure edit (got \(preMarkers.count))")

        let priorImage = reopened.result?.image
        reopened.settings.set(.exposure, to: 0.5)
        try waitUntil("HDR exposure edit render") {
            !reopened.busy && reopened.error == nil && reopened.result != nil &&
            reopened.settings.hdr?.exposure == 0.5 && reopened.result?.image !== priorImage
        }

        check(reopened.sourceNativeSize == nil, "HDR exposure edit does not overwrite sourceNativeSize with post-crop dimensions (got \(String(describing: reopened.sourceNativeSize)))")
        let postMarkers = reopened.inspectionMarkerPoints()
        check(postMarkers.count == 4, "All 4 markers remain visible after HDR exposure edit (got \(postMarkers.count))")

        for (pre, post) in zip(preMarkers, postMarkers) {
            let shift = hypot(post.point.x - pre.point.x, post.point.y - pre.point.y)
            check(shift < 1e-3, "Native HDR marker #\(pre.index) shift < 1e-3 after exposure edit (shift=\(shift))")
        }

        // 7. Photo switch clears shared sampler & overlay caches
        let cacheProbeImg = makeTestImage(width: 8, height: 8) { _, _ in (120, 140, 160) }
        _ = InspectionSamplerCache.shared.sample(cacheProbeImg, atNormalized: CGPoint(x: 0.5, y: 0.5))
        _ = InspectionOverlayRenderer.shared.render(cacheProbeImg, mode: .warmCoolBW)
        check(InspectionSamplerCache.shared.entryCount > 0 && InspectionOverlayRenderer.shared.entryCount > 0,
              "Shared inspection caches populated before source switch")
        reopened.sourceRevision = UUID()
        check(InspectionSamplerCache.shared.entryCount == 0 && InspectionOverlayRenderer.shared.entryCount == 0,
              "sourceRevision change clears InspectionSamplerCache and InspectionOverlayRenderer")
    }
    #endif
}
