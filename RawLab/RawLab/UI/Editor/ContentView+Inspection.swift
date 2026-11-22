import RawLabKit
import CoreGraphics
import SwiftUI

extension ContentView {
    var effectiveInspectionSourceSize: CGSize? {
        if let src = viewModel.sourceNativeSize { return src }
        if let native = viewModel.nativeImageSize {
            if settings.geometrySettings.isIdentity { return native }
            let g = settings.geometrySettings
            let estW = native.width / max(0.01, g.cropWidth)
            let estH = native.height / max(0.01, g.cropHeight)
            return g.quarterTurns % 2 != 0 ? CGSize(width: estH, height: estW) : CGSize(width: estW, height: estH)
        }
        guard let image = viewModel.previewImage?.cgImage ?? viewModel.hdrPresentation?.sdrImage else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    var inspectionAfterCGImage: CGImage? {
        viewModel.hdrPresentation?.sdrImage ?? viewModel.previewImage?.cgImage
    }

    var inspectionBeforeCGImage: CGImage? {
        viewModel.hdrReference?.sdrImage ?? viewModel.basePreviewImage?.cgImage
    }

    func sampleInspectionAfter(atOutputPoint point: CGPoint) -> InspectionColorSample? {
        if !geometrySelected {
            for tile in viewModel.detailTiles.sorted(by: { ($0.tileKey?.level ?? 0) < ($1.tileKey?.level ?? 0) }) {
                if tile.normalizedRect.contains(point), tile.normalizedRect.width > 0, tile.normalizedRect.height > 0,
                   let cg = tile.cgImage ?? tile.hdr?.sdrImage {
                    let local = CGPoint(
                        x: (point.x - tile.normalizedRect.minX) / tile.normalizedRect.width,
                        y: (point.y - tile.normalizedRect.minY) / tile.normalizedRect.height
                    )
                    return InspectionSamplerCache.shared.sample(cg, atNormalized: local, radiusPixels: 1)
                }
            }
            if let overlay = viewModel.detailOverlay,
               overlay.normalizedRect.contains(point), overlay.normalizedRect.width > 0, overlay.normalizedRect.height > 0,
               let cg = overlay.cgImage ?? overlay.hdr?.sdrImage {
                let local = CGPoint(
                    x: (point.x - overlay.normalizedRect.minX) / overlay.normalizedRect.width,
                    y: (point.y - overlay.normalizedRect.minY) / overlay.normalizedRect.height
                )
                return InspectionSamplerCache.shared.sample(cg, atNormalized: local, radiusPixels: 1)
            }
            if let backing = viewModel.detailBacking?.cgImage {
                return InspectionSamplerCache.shared.sample(backing, atNormalized: point, radiusPixels: 1)
            }
        }
        guard let base = inspectionAfterCGImage else { return nil }
        return InspectionSamplerCache.shared.sample(base, atNormalized: point, radiusPixels: 1)
    }

    func sampleInspectionBefore(atOutputPoint point: CGPoint) -> InspectionColorSample? {
        if !geometrySelected {
            for tile in viewModel.detailTiles.sorted(by: { ($0.tileKey?.level ?? 0) < ($1.tileKey?.level ?? 0) }) {
                if tile.normalizedRect.contains(point), tile.normalizedRect.width > 0, tile.normalizedRect.height > 0,
                   let cg = tile.beforeCGImage ?? tile.beforeHDR?.sdrImage {
                    let local = CGPoint(
                        x: (point.x - tile.normalizedRect.minX) / tile.normalizedRect.width,
                        y: (point.y - tile.normalizedRect.minY) / tile.normalizedRect.height
                    )
                    return InspectionSamplerCache.shared.sample(cg, atNormalized: local, radiusPixels: 1)
                }
            }
            if let overlay = viewModel.detailOverlay,
               overlay.normalizedRect.contains(point), overlay.normalizedRect.width > 0, overlay.normalizedRect.height > 0,
               let cg = overlay.beforeCGImage ?? overlay.beforeHDR?.sdrImage {
                let local = CGPoint(
                    x: (point.x - overlay.normalizedRect.minX) / overlay.normalizedRect.width,
                    y: (point.y - overlay.normalizedRect.minY) / overlay.normalizedRect.height
                )
                return InspectionSamplerCache.shared.sample(cg, atNormalized: local, radiusPixels: 1)
            }
            if let backing = viewModel.detailBacking?.beforeCGImage {
                return InspectionSamplerCache.shared.sample(backing, atNormalized: point, radiusPixels: 1)
            }
        }
        guard let base = inspectionBeforeCGImage else { return nil }
        return InspectionSamplerCache.shared.sample(base, atNormalized: point, radiusPixels: 1)
    }

    @discardableResult
    func pinInspectionAnchor(atOutputPoint point: CGPoint? = nil) -> InspectionAnchor? {
        guard let sourceSize = effectiveInspectionSourceSize else { return nil }
        let out = point ?? coordinator.inspection.liveOutputPoint ?? CGPoint(x: 0.5, y: 0.5)
        guard let src = GeometryCoordinateMapper.outputNormToSourceNorm(
            out,
            sourceSize: sourceSize,
            geometry: settings.geometrySettings
        ) else { return nil }
        return coordinator.inspection.pinAnchor(atSourcePoint: src)
    }

    func inspectionDisplayPoint(for anchor: InspectionAnchor) -> CGPoint? {
        guard let sourceSize = effectiveInspectionSourceSize else { return nil }
        return GeometryCoordinateMapper.sourceNormToOutputNorm(
            anchor.sourcePoint,
            sourceSize: sourceSize,
            geometry: settings.geometrySettings
        )
    }

    var inspectionMarkerPoints: [(index: Int, point: CGPoint, selected: Bool)] {
        guard !geometrySelected else { return [] }
        return coordinator.inspection.anchors.enumerated().compactMap { idx, anchor in
            guard let pt = inspectionDisplayPoint(for: anchor) else { return nil }
            return (idx + 1, pt, coordinator.inspection.selectedAnchorID == anchor.id)
        }
    }

    var inspectionLiveSample: InspectionColorSample? {
        guard !geometrySelected else { return nil }
        let point = coordinator.inspection.liveOutputPoint
            ?? (coordinator.inspection.monitorEnabled ? CGPoint(x: 0.5, y: 0.5) : nil)
        if let point {
            return showingBefore ? sampleInspectionBefore(atOutputPoint: point) : sampleInspectionAfter(atOutputPoint: point)
        }
        if let selectedID = coordinator.inspection.selectedAnchorID,
           let anchor = coordinator.inspection.anchors.first(where: { $0.id == selectedID }),
           let out = inspectionDisplayPoint(for: anchor) {
            return showingBefore ? sampleInspectionBefore(atOutputPoint: out) : sampleInspectionAfter(atOutputPoint: out)
        }
        return nil
    }

    var inspectionLuminanceCursor: Double? {
        inspectionLiveSample?.luminance
    }

    @ViewBuilder
    var iosInspectionHUD: some View {
        let state = coordinator.inspection
        let showPanel = state.monitorEnabled || !state.anchors.isEmpty || state.overlay != .none
        if viewModel.hasImage && !photoViewing.previewOnly && !geometrySelected && showPanel {
            let live = inspectionLiveSample
            VStack(alignment: .leading, spacing: 6) {
                if state.overlay != .none {
                    HStack(spacing: 8) {
                        Text(L10n.text(state.overlay.titleKey))
                            .font(.caption.weight(.semibold))
                        Button {
                            coordinator.inspection.selectOverlay(.none)
                        } label: {
                            Label(L10n.text("关闭观察层"), systemImage: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityIdentifier("inspection.overlay.clear")
                    }
                }
                if state.monitorEnabled || !state.anchors.isEmpty {
                    HStack(spacing: 8) {
                        if let live {
                            Circle()
                                .fill(Color(red: Double(live.r) / 255.0, green: Double(live.g) / 255.0, blue: Double(live.b) / 255.0))
                                .frame(width: 10, height: 10)
                            Text("RGB \(live.rgbText) · \(live.hsbText)")
                                .font(.caption2.monospacedDigit())
                                .lineLimit(1)
                        } else {
                            Text("RGB -- · --° --% --%")
                                .font(.caption2.monospacedDigit())
                        }
                        Button {
                            _ = pinInspectionAnchor()
                        } label: {
                            Image(systemName: "mappin.and.ellipse")
                                .frame(minWidth: 28, minHeight: 28)
                        }
                        .disabled(!state.canPinMore)
                        .accessibilityLabel(L10n.text("添加锚点"))
                        .accessibilityIdentifier("inspection.pinNow")

                        if !state.anchors.isEmpty {
                            Button {
                                coordinator.inspection.clearAnchors()
                            } label: {
                                Image(systemName: "trash")
                                    .frame(minWidth: 28, minHeight: 28)
                            }
                            .accessibilityLabel(L10n.text("清除锚点"))
                            .accessibilityIdentifier("inspection.clearAnchors")
                        }
                    }

                    ForEach(Array(state.anchors.enumerated()), id: \.element.id) { idx, anchor in
                        let pt = inspectionDisplayPoint(for: anchor)
                        let before = pt.flatMap { sampleInspectionBefore(atOutputPoint: $0) }
                        let after = pt.flatMap { sampleInspectionAfter(atOutputPoint: $0) }
                        HStack(spacing: 6) {
                            Text("#\(idx + 1)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(state.selectedAnchorID == anchor.id ? .yellow : .white)
                            Text("\(L10n.text("调整前")) \(before.map { "\($0.rgbText) \($0.hsbText)" } ?? "--") | \(L10n.text("调整后")) \(after.map { "\($0.rgbText) \($0.hsbText)" } ?? "--")")
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                            Button {
                                coordinator.inspection.removeAnchor(id: anchor.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .accessibilityLabel(L10n.text("移除"))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { coordinator.inspection.selectedAnchorID = anchor.id }
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.14), lineWidth: 1) }
            .accessibilityIdentifier("inspection.hud")
        }
    }
}
