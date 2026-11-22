import RawLabKit
import SwiftUI

struct MacInspectionHUD: View {
    @ObservedObject var model: EditorModel
    let showingBefore: Bool
    @Environment(\.locale) private var localizationLocale

    var body: some View {
        let _ = localizationLocale
        let live = model.inspectionLiveSample(showingBefore: showingBefore)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L10n.text("取样监视"))
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Toggle(isOn: $model.inspection.pinModeEnabled) {
                    Image(systemName: "plus.viewfinder")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .foregroundStyle(model.inspection.pinModeEnabled ? Color.yellow : Color.secondary)
                .help(L10n.text("添加锚点"))
                .accessibilityLabel(L10n.text("添加锚点"))
                .accessibilityIdentifier("inspection.pinMode")
                .disabled(model.result == nil || !model.inspection.canPinMore)

                Button {
                    _ = model.pinInspectionAnchor()
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("添加锚点"))
                .accessibilityLabel(L10n.text("添加锚点"))
                .accessibilityIdentifier("inspection.pinNow")
                .disabled(model.result == nil || !model.inspection.canPinMore)

                if !model.inspection.anchors.isEmpty {
                    Button {
                        model.inspection.clearAnchors()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("清除锚点"))
                    .accessibilityLabel(L10n.text("清除锚点"))
                    .accessibilityIdentifier("inspection.clearAnchors")
                }
            }

            HStack(spacing: 8) {
                if let live {
                    Circle()
                        .fill(Color(red: Double(live.r) / 255.0, green: Double(live.g) / 255.0, blue: Double(live.b) / 255.0))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 0.75))
                    Text("RGB \(live.rgbText)")
                    Spacer(minLength: 4)
                    Text("\(L10n.text("色相"))/\(L10n.text("饱和度"))/\(L10n.text("明度")) \(live.hsbText)")
                } else {
                    Text("RGB -- -- --")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text("--° --% --%")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2.monospacedDigit())
            .lineLimit(1)
            .accessibilityIdentifier("inspection.liveReadout")

            if !model.inspection.anchors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.inspection.anchors.enumerated()), id: \.element.id) { index, anchor in
                        anchorRow(index: index + 1, anchor: anchor)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspection.hud")
    }

    @ViewBuilder
    private func anchorRow(index: Int, anchor: InspectionAnchor) -> some View {
        let outPoint = model.inspectionDisplayPoint(for: anchor)
        let beforeSample = outPoint.flatMap { model.sampleInspectionBefore(atOutputPoint: $0) }
        let afterSample = outPoint.flatMap { model.sampleInspectionAfter(atOutputPoint: $0) }
        let selected = model.inspection.selectedAnchorID == anchor.id
        HStack(spacing: 6) {
            Button {
                model.inspection.selectedAnchorID = anchor.id
            } label: {
                HStack(spacing: 5) {
                    Text("#\(index)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(selected ? .yellow : .primary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(L10n.text("调整前")) \(sampleSummary(beforeSample))")
                            .foregroundStyle(.secondary)
                        Text("\(L10n.text("调整后")) \(sampleSummary(afterSample))")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                model.inspection.removeAnchor(id: anchor.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(L10n.text("移除"))
            .accessibilityLabel(L10n.text("移除"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(selected ? Color.white.opacity(0.08) : Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }

    private func sampleSummary(_ sample: InspectionColorSample?) -> String {
        guard let sample else { return "--" }
        return "\(sample.rgbText) · \(sample.hsbText)"
    }
}

struct MacInspectionReadoutPill: View {
    @ObservedObject var model: EditorModel
    let showingBefore: Bool
    let showLiveReadout: Bool
    @Environment(\.locale) private var localizationLocale

    var body: some View {
        let _ = localizationLocale
        let live = showLiveReadout ? model.inspectionLiveSample(showingBefore: showingBefore) : nil
        let hasOverlay = model.inspection.overlay != .none
        if live != nil || hasOverlay {
            HStack(spacing: 10) {
                if let live {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(red: Double(live.r) / 255.0, green: Double(live.g) / 255.0, blue: Double(live.b) / 255.0))
                            .frame(width: 10, height: 10)
                        Text("RGB \(live.rgbText) · \(live.hsbText)")
                            .font(.caption.monospacedDigit())
                    }
                }
                if hasOverlay {
                    HStack(spacing: 6) {
                        Text("\(L10n.text("观察层")): \(L10n.text(model.inspection.overlay.titleKey))")
                            .font(.caption.weight(.medium))
                        Button(L10n.text("关闭观察层")) {
                            model.inspection.selectOverlay(.none)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityIdentifier("inspection.overlay.clear")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("inspection.pill")
        }
    }
}
