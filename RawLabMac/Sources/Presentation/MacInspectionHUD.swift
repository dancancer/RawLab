import RawLabKit
import SwiftUI

struct MacInspectionHUD: View {
    @ObservedObject var model: EditorModel
    let showingBefore: Bool
    @Environment(\.locale) private var localizationLocale

    private var expanded: Bool {
        model.inspection.monitorEnabled || !model.inspection.anchors.isEmpty
    }

    var body: some View {
        let _ = localizationLocale
        let live = expanded ? model.inspectionLiveSample(showingBefore: showingBefore) : nil
        let canToggle = model.result != nil && model.geometryDraft == nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    model.inspection.monitorEnabled.toggle()
                    if !model.inspection.monitorEnabled {
                        model.inspection.pinModeEnabled = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 11)
                        Text(L10n.text("取样监视"))
                            .font(.system(size: 12, weight: .semibold))
                        if !model.inspection.anchors.isEmpty {
                            Text("(\(model.inspection.anchors.count))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text(expanded ? "收起取样监视" : "展开取样监视"))
                .accessibilityLabel(L10n.text(expanded ? "收起取样监视" : "展开取样监视"))
                .accessibilityIdentifier("inspection.toggle")

                Spacer(minLength: 4)

                Toggle(isOn: Binding(
                    get: { model.inspection.pinModeEnabled },
                    set: { enabled in
                        if enabled { model.inspection.monitorEnabled = true }
                        model.inspection.pinModeEnabled = enabled
                    }
                )) {
                    Image(systemName: "plus.viewfinder")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .foregroundStyle(model.inspection.pinModeEnabled ? Color.yellow : Color.secondary)
                .help(L10n.text("点选添加锚点"))
                .accessibilityLabel(L10n.text("点选添加锚点"))
                .accessibilityIdentifier("inspection.pinMode")
                .disabled(!canToggle || !model.inspection.canPinMore)

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

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    if let live {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(red: Double(live.r) / 255.0, green: Double(live.g) / 255.0, blue: Double(live.b) / 255.0))
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 0.75))
                            Text("RGB \(live.rgbText)")
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 6) {
                            Color.clear.frame(width: 10, height: 1)
                            Text("HSB \(live.hsbText)")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    } else {
                        Text("RGB -- -- --")
                            .foregroundStyle(.secondary)
                        Text("HSB --° --% --%")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .accessibilityElement(children: .combine)
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
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.tail)
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
        .padding(.vertical, 4)
        .background(selected ? Color.yellow.opacity(0.12) : Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(selected ? Color.yellow.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }

    private func sampleSummary(_ sample: InspectionColorSample?) -> String {
        guard let sample else { return "--" }
        return "\(sample.rgbText) · \(sample.hsbText)"
    }
}

struct MacInspectionOverlayChip: View {
    @ObservedObject var model: EditorModel
    @Environment(\.locale) private var localizationLocale

    var body: some View {
        let _ = localizationLocale
        if model.inspection.overlay != .none {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("inspection.overlay.chip")
        }
    }
}

struct MacInspectionReadoutPill: View {
    @ObservedObject var model: EditorModel
    let showingBefore: Bool
    let showLiveReadout: Bool
    @Environment(\.locale) private var localizationLocale

    var body: some View {
        let _ = localizationLocale
        let live = showLiveReadout && (model.inspection.monitorEnabled || !model.inspection.anchors.isEmpty)
            ? model.inspectionLiveSample(showingBefore: showingBefore)
            : nil
        if let live {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: Double(live.r) / 255.0, green: Double(live.g) / 255.0, blue: Double(live.b) / 255.0))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text("RGB \(live.rgbText)")
                    Text("HSB \(live.hsbText)").foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("inspection.pill")
        }
    }
}
