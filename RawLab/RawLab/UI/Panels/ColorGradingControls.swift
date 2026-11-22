import RawLabKit
import SwiftUI

struct IOSColorGradingControls: View {
    @Binding var settings: ColorGradingSettings
    @Binding var zone: ColorGradingZone
    @Binding var globalSelected: Bool
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    @Environment(\.adjustmentInputContext) private var inputContext
    @Environment(\.adjustmentFine) private var fine
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum GradingTab: String, CaseIterable, Identifiable {
        case shadows, midtones, highlights, global
        var id: String { rawValue }
        var zone: ColorGradingZone? {
            switch self {
            case .shadows: return .shadows
            case .midtones: return .midtones
            case .highlights: return .highlights
            case .global: return nil
            }
        }
        var title: String { zone?.title ?? L10n.text("全局") }
    }

    private var activeTab: GradingTab {
        if globalSelected { return .global }
        switch zone {
        case .shadows: return .shadows
        case .midtones: return .midtones
        case .highlights: return .highlights
        }
    }

    private var activeWheelBinding: Binding<ColorGradingWheel> {
        if globalSelected {
            return Binding(get: { settings.global }, set: { settings.global = $0 })
        }
        let selected = zone
        return Binding(get: { settings[selected] }, set: { settings[selected] = $0 })
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(GradingTab.allCases) { target in
                    let wheelValue = target.zone.map { settings[$0] } ?? settings.global
                    Button {
                        onCancelled()
                        if let z = target.zone { globalSelected = false; zone = z }
                        else { globalSelected = true }
                    } label: {
                        Text(target.title).font(.subheadline).frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(activeTab == target ? Color.yellow : Color.secondary)
                    }.buttonStyle(.plain).accessibilityIdentifier("grading.zone.\(target.rawValue)")
                        .accessibilityAddTraits(activeTab == target ? .isSelected : [])
                        .accessibilityValue(L10n.text(wheelValue.isDefault ? "未调整" : "已调整"))
                }
            }
            wheel.frame(width: 130, height: 130).frame(maxWidth: .infinity)
            rows.environment(\.compactAdjustmentRows, true)
            VStack(spacing: 4) {
                AdjustmentControl(title: L10n.text("融合"), value: Binding(get: { settings.blending }, set: {
                    guard $0.isFinite, (0...100).contains($0) else { return }; settings.blending = $0
                }), range: 0...100, step: 0.1, defaultValue: 50, unit: "%",
                    formatter: { String(format: "%.1f", locale: L10n.locale, $0) }, identifier: "grading.blending", compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
                AdjustmentControl(title: L10n.text("平衡"), value: Binding(get: { settings.balance }, set: {
                    guard $0.isFinite, (-100...100).contains($0) else { return }; settings.balance = $0
                }), range: -100...100, step: 0.1, defaultValue: 0, unit: "",
                    formatter: { String(format: "%.1f", locale: L10n.locale, $0) }, identifier: "grading.balance", compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
            }.environment(\.compactAdjustmentRows, true)
        }.padding(.horizontal, 16)
            .onChange(of: zone) { _, _ in globalSelected = false }
    }

    private var wheel: some View {
        let tab = activeTab
        return ColorGradingWheelControl(value: activeWheelBinding,
            scope: "\(inputContext.id).\(tab.rawValue)", title: L10n.text("颜色分级") + " · " + tab.title,
            fine: fine, isCurrent: { inputContext.isCurrent() && activeTab == tab }, canChange: inputContext.canChange,
            onEditingChanged: onEditingChanged, onCancelled: onCancelled)
    }
    private var rows: some View {
        let tab = activeTab
        let binding = activeWheelBinding
        return VStack(spacing: 4) {
            AdjustmentControl(title: L10n.text("色相"), value: Binding(get: { binding.wrappedValue.hue }, set: {
                if let hue = ColorGradingWheel.inputHue($0) { binding.wrappedValue.hue = hue }
            }), range: 0...360, step: 0.1, defaultValue: 0, unit: "°",
                formatter: { String(format: "%.1f", locale: L10n.locale, $0) }, identifier: "grading.hue", compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("饱和度"), value: Binding(get: { binding.wrappedValue.saturation }, set: {
                guard $0.isFinite, (0...100).contains($0) else { return }; binding.wrappedValue.saturation = $0
            }), range: 0...100, step: 0.1, defaultValue: 0, unit: "%",
                formatter: { String(format: "%.1f", locale: L10n.locale, $0) }, identifier: "grading.saturation", compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("明亮度"), value: Binding(get: { binding.wrappedValue.luminance }, set: {
                guard $0.isFinite, (-100...100).contains($0) else { return }; binding.wrappedValue.luminance = $0
            }), range: -100...100, step: 0.1, defaultValue: 0, unit: "",
                formatter: { String(format: "%.1f", locale: L10n.locale, $0) }, identifier: "grading.luminance", compactNumber: false, compactDecimals: nil, onEditingChanged: onEditingChanged)
        }.id("\(inputContext.id).\(tab.rawValue)")
    }
}
