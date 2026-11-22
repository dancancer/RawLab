import RawLabKit
import SwiftUI

struct MacColorGradingControls: View {
    @Binding var settings: ColorGradingSettings
    @Binding var zone: ColorGradingZone
    let source: String
    let isCurrent: () -> Bool
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var globalSelected = false

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
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(GradingTab.allCases) { target in
                        let wheelValue = target.zone.map { settings[$0] } ?? settings.global
                        Button {
                            onCancelled()
                            ParameterValueField.cancelPendingInputs()
                            if let z = target.zone {
                                globalSelected = false
                                zone = z
                            } else {
                                globalSelected = true
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(target.title).fixedSize()
                                Circle().fill(wheelValue.isDefault ? .clear : Color.yellow).frame(width: 3, height: 3)
                            }.padding(.horizontal, 10).frame(minHeight: 30)
                                .background(activeTab == target ? Color.yellow.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("grading.zone.\(target.rawValue)")
                            .accessibilityAddTraits(activeTab == target ? .isSelected : [])
                            .accessibilityValue(L10n.text(wheelValue.isDefault ? "未调整" : "已调整"))
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                if !dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: 16) { wheel.frame(width: 156, height: 156); rows.frame(minWidth: 300) }
                }
                VStack(spacing: 8) { wheel.frame(width: compact ? 138 : 156, height: compact ? 138 : 156); rows }
            }
            VStack(spacing: 6) {
                ParameterRow(title: L10n.text("融合"), value: Binding(get: { settings.blending }, set: {
                    guard $0.isFinite, (0...100).contains($0) else { return }; settings.blending = $0
                }), range: 0...100, defaultValue: 50, unit: "%", identifier: "grading.value.blending", onEditingChanged: onEditingChanged,
                    accessibilityTitle: L10n.text("融合"), inputScope: "shared", compact: compact)
                ParameterRow(title: L10n.text("平衡"), value: Binding(get: { settings.balance }, set: {
                    guard $0.isFinite, (-100...100).contains($0) else { return }; settings.balance = $0
                }), range: -100...100, defaultValue: 0, unit: "", identifier: "grading.value.balance", onEditingChanged: onEditingChanged,
                    accessibilityTitle: L10n.text("平衡"), inputScope: "shared", compact: compact)
            }
        }.frame(maxWidth: 720)
            .onChange(of: zone) { _, _ in globalSelected = false }
    }

    private var wheel: some View {
        let tab = activeTab
        return ColorGradingWheelControl(value: activeWheelBinding,
            scope: "\(source).\(tab.rawValue)", title: L10n.text("颜色分级") + " · " + tab.title,
            isCurrent: { isCurrent() && activeTab == tab }, prepareEditing: ParameterValueField.commitPendingInputs,
            onEditingChanged: onEditingChanged, onCancelled: onCancelled)
    }
    private var rows: some View {
        let tab = activeTab
        let binding = activeWheelBinding
        return VStack(spacing: 6) {
            ParameterRow(title: L10n.text("色相"), value: Binding(get: { binding.wrappedValue.hue }, set: {
                if let hue = ColorGradingWheel.inputHue($0) { binding.wrappedValue.hue = hue }
            }), range: 0...360, defaultValue: 0, unit: "°", identifier: "grading.value.hue", onEditingChanged: onEditingChanged,
                accessibilityTitle: tab.title + " · " + L10n.text("色相"), inputScope: tab.rawValue, compact: compact)
            ParameterRow(title: L10n.text("饱和度"), value: Binding(get: { binding.wrappedValue.saturation }, set: {
                guard $0.isFinite, (0...100).contains($0) else { return }; binding.wrappedValue.saturation = $0
            }), range: 0...100, defaultValue: 0, unit: "%", identifier: "grading.value.saturation", onEditingChanged: onEditingChanged,
                accessibilityTitle: tab.title + " · " + L10n.text("饱和度"), inputScope: tab.rawValue, compact: compact)
            ParameterRow(title: L10n.text("明亮度"), value: Binding(get: { binding.wrappedValue.luminance }, set: {
                guard $0.isFinite, (-100...100).contains($0) else { return }; binding.wrappedValue.luminance = $0
            }), range: -100...100, defaultValue: 0, unit: "", identifier: "grading.value.luminance", onEditingChanged: onEditingChanged,
                accessibilityTitle: tab.title + " · " + L10n.text("明亮度"), inputScope: tab.rawValue, compact: compact)
        }.id("\(source).\(tab.rawValue)")
    }
}
