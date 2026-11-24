import RawLabKit
import SwiftUI

private enum MacCurveSubMode: String, CaseIterable, Identifiable {
    case point, parametric
    var id: String { rawValue }
    var title: String {
        switch self {
        case .point: return L10n.text("点曲线")
        case .parametric: return L10n.text("参数曲线")
        }
    }
}

struct MacToneCurveControls: View {
    @Binding var settings: ToneCurveSettings
    @Binding var legacy: Double
    var usesExposureStops = false
    let source: String
    let isCurrent: () -> Bool
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    var activeChannel: Binding<ToneCurveChannel>? = nil
    var targetEnabled: Binding<Bool>? = nil
    var targetSample: HSLTargetSample? = nil
    var targetWaiting = false
    var targetNotice: HSLTargetAvailability? = nil
    var onCancelTarget: () -> Void = {}
    @State private var localChannel = ToneCurveChannel.rgb
    @State private var subMode = MacCurveSubMode.point

    private var channel: ToneCurveChannel { activeChannel?.wrappedValue ?? localChannel }
    private func setChannel(_ next: ToneCurveChannel) {
        if let activeChannel { activeChannel.wrappedValue = next }
        else { localChannel = next }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let targetEnabled, !(channel == .rgb && subMode == .parametric) {
                CurveTargetControls(enabled: targetEnabled, channel: channel, sample: targetSample,
                    waiting: targetWaiting, notice: targetNotice, onCancel: onCancelTarget)
            }
            HStack(spacing: 4) {
                ForEach(ToneCurveChannel.allCases) { item in
                    let modified = channelIsModified(item)
                    Button {
                        onCancelled(); onCancelTarget()
                        setChannel(item)
                    } label: {
                        HStack(spacing: 3) {
                            Text(channelLabel(item))
                                .font(.system(size: 12, weight: item == channel ? .semibold : .regular))
                                .fixedSize()
                            if modified {
                                Circle().fill(.yellow).frame(width: 3, height: 3).accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 26)
                    }
                    .buttonStyle(.bordered)
                    .tint(item == channel ? .yellow : .secondary)
                    .accessibilityIdentifier("curve.channel.\(item.rawValue)")
                    .accessibilityAddTraits(item == channel ? .isSelected : [])
                    .accessibilityValue(L10n.text(modified ? "已调整" : "未调整"))
                }
            }
            if channel == .rgb {
                Picker(L10n.text("参数曲线"), selection: $subMode) {
                    ForEach(MacCurveSubMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("curve.submode")
                Toggle(L10n.text("仅作用于明度"), isOn: Binding(
                    get: { settings.applyToLuminosity },
                    set: { next in
                        onCancelled(); onCancelTarget()
                        guard isCurrent(), ParameterValueField.commitPendingInputs() else { return }
                        onEditingChanged(true)
                        settings.applyToLuminosity = next
                        onEditingChanged(false)
                    }
                )).accessibilityIdentifier("curve.luminosity")
            }
            ToneCurveEditor(value: $settings, scope: source, channel: channel,
                showSplitMarkers: channel == .rgb && subMode == .parametric,
                usesExposureStops: usesExposureStops, isCurrent: isCurrent,
                prepareEditing: ParameterValueField.commitPendingInputs,
                onEditingChanged: { editing in
                    if editing { onCancelTarget() }
                    onEditingChanged(editing)
                }, onCancelled: onCancelled,
                coordinates: { index, point in coordinates(index, point: point) }, legacy: {
                    ParameterRow(title: L10n.text("S 曲线"), value: $legacy, range: -100...100, defaultValue: 0,
                        unit: "%", identifier: "value.toneCurve", onEditingChanged: { editing in
                            if editing { onCancelTarget() }
                            onEditingChanged(editing)
                        })
                })
            if channel == .rgb && subMode == .parametric {
                parametricControls
            }
        }
        .onAppear {
            subMode = !settings.parametric.isDefault && settings.mode == .legacy ? .parametric : .point
        }
        .onChange(of: subMode) { _, next in
            if next == .parametric { onCancelTarget() }
        }
        .onChange(of: source) { _, _ in
            setChannel(.rgb)
            subMode = !settings.parametric.isDefault && settings.mode == .legacy ? .parametric : .point
        }
    }

    private func channelIsModified(_ item: ToneCurveChannel) -> Bool {
        if item == .rgb {
            return !settings.shape(.rgb).isIdentity || !settings.parametric.isDefault ||
                (settings.mode == .legacy && abs(legacy) > 1e-6)
        }
        return !settings.shape(item).isIdentity
    }

    private func channelLabel(_ item: ToneCurveChannel) -> String {
        switch item {
        case .rgb: return "RGB"
        case .red: return L10n.text("红")
        case .green: return L10n.text("绿")
        case .blue: return L10n.text("蓝")
        }
    }

    private var editingShape: ToneCurveShape {
        let shape = settings.shape(channel)
        return shape.mode == .legacy ? .identity : shape
    }

    private func coordinates(_ index: Int, point: ToneCurvePoint) -> some View {
        VStack(spacing: 6) {
            coordinate(index, point: point, horizontal: true).disabled(!editingShape.isInterior(index))
            coordinate(index, point: point, horizontal: false).disabled(!editingShape.canMoveY(index))
        }
    }

    private func coordinate(_ index: Int, point: ToneCurvePoint, horizontal: Bool) -> some View {
        let title = L10n.text(horizontal ? "输入坐标" : "输出坐标")
        let range = usesExposureStops ? ToneCurveSettings.hdrExposureRange : 0...1
        let span = range.upperBound - range.lowerBound
        let owner = channel
        let binding = Binding<Double>(get: {
            let s = settings.shape(owner)
            let shape = s.mode == .legacy ? ToneCurveShape.identity : s
            guard shape.points.indices.contains(index) else { return 0 }
            let value = horizontal ? shape.points[index].x : shape.points[index].y
            return range.lowerBound + value * span
        }, set: { next in
            guard isCurrent() else { return }
            let s = settings.shape(owner)
            let shape = s.mode == .legacy ? ToneCurveShape.identity : s
            if horizontal { guard shape.isInterior(index) else { return } }
            else { guard shape.canMoveY(index) else { return } }
            let pt = shape.points[index]
            let value = (next - range.lowerBound) / span
            let updated = shape.moving(index: index, x: horizontal ? value : pt.x, y: horizontal ? pt.y : value)
            settings = settings.replacing(owner, with: updated)
        })
        return HStack {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            ParameterValueField(value: binding, range: range, precision: usesExposureStops ? .exposure : .curveCoordinate,
                title: title, unit: usesExposureStops ? "EV" : "", identifier: horizontal ? "curve.value.x" : "curve.value.y",
                defaultValue: range.lowerBound + point.x * span, inputScope: "\(source).\(owner.rawValue).\(index)",
                onEditingChanged: onEditingChanged)
                .frame(width: 122, height: 30)
        }
    }

    private var parametricControls: some View {
        let sub = AdjustmentFieldSpec.SubFields.LightCurveParametric.self
        let minGap = sub.splitMinGap
        let shadowMax = min(sub.splitShadowRange.upperBound, settings.parametric.splitMidtone - minGap)
        let midMin = max(sub.splitMidtoneRange.lowerBound, settings.parametric.splitShadow + minGap)
        let midMax = min(sub.splitMidtoneRange.upperBound, settings.parametric.splitHighlight - minGap)
        let highMin = max(sub.splitHighlightRange.lowerBound, settings.parametric.splitMidtone + minGap)
        return VStack(alignment: .leading, spacing: 4) {
            ParameterRow(title: L10n.text("高光"), value: parametricBinding(\.highlights, in: sub.bandRange),
                range: sub.bandRange, defaultValue: sub.bandDefault, identifier: "value.curve.highlights",
                onEditingChanged: onEditingChanged)
            ParameterRow(title: L10n.text("亮部"), value: parametricBinding(\.lights, in: sub.bandRange),
                range: sub.bandRange, defaultValue: sub.bandDefault, identifier: "value.curve.lights",
                onEditingChanged: onEditingChanged)
            ParameterRow(title: L10n.text("暗部"), value: parametricBinding(\.darks, in: sub.bandRange),
                range: sub.bandRange, defaultValue: sub.bandDefault, identifier: "value.curve.darks",
                onEditingChanged: onEditingChanged)
            ParameterRow(title: L10n.text("阴影"), value: parametricBinding(\.shadows, in: sub.bandRange),
                range: sub.bandRange, defaultValue: sub.bandDefault, identifier: "value.curve.shadows",
                onEditingChanged: onEditingChanged)
            Text(L10n.text("拆分点")).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            ParameterRow(title: L10n.text("阴影拆分"), value: parametricPercentBinding(\.splitShadow, in: sub.splitShadowRange.lowerBound...shadowMax),
                range: (sub.splitShadowRange.lowerBound * 100)...(shadowMax * 100), defaultValue: sub.splitShadowDefault * 100,
                unit: "%", precision: .cropPercent, identifier: "value.curve.splitShadow", onEditingChanged: onEditingChanged)
            ParameterRow(title: L10n.text("中间调拆分"), value: parametricPercentBinding(\.splitMidtone, in: midMin...midMax),
                range: (midMin * 100)...(midMax * 100), defaultValue: sub.splitMidtoneDefault * 100,
                unit: "%", precision: .cropPercent, identifier: "value.curve.splitMidtone", onEditingChanged: onEditingChanged)
            ParameterRow(title: L10n.text("高光拆分"), value: parametricPercentBinding(\.splitHighlight, in: highMin...sub.splitHighlightRange.upperBound),
                range: (highMin * 100)...(sub.splitHighlightRange.upperBound * 100), defaultValue: sub.splitHighlightDefault * 100,
                unit: "%", precision: .cropPercent, identifier: "value.curve.splitHighlight", onEditingChanged: onEditingChanged)
            HStack {
                Spacer()
                Button(L10n.text("重置参数曲线")) {
                    onCancelled(); onCancelTarget()
                    guard isCurrent(), ParameterValueField.commitPendingInputs(), !settings.parametric.isDefault else { return }
                    onEditingChanged(true)
                    settings.parametric = ToneCurveParametric()
                    onEditingChanged(false)
                }
                .disabled(settings.parametric.isDefault)
                .accessibilityIdentifier("curve.parametric.reset")
            }
        }
    }

    private func parametricPercentBinding(_ keyPath: WritableKeyPath<ToneCurveParametric, Double>, in range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { settings.parametric[keyPath: keyPath] * 100 },
            set: { next in
                guard isCurrent() else { return }
                var copy = settings.parametric
                copy[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, next / 100))
                guard copy.isValid else { return }
                settings.parametric = copy
            }
        )
    }

    private func parametricBinding(_ keyPath: WritableKeyPath<ToneCurveParametric, Double>, in range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { settings.parametric[keyPath: keyPath] },
            set: { next in
                guard isCurrent() else { return }
                var copy = settings.parametric
                copy[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, next))
                guard copy.isValid else { return }
                settings.parametric = copy
            }
        )
    }
}

private struct CurveTargetControls: View {
    @Binding var enabled: Bool
    let channel: ToneCurveChannel
    var sample: HSLTargetSample?
    var waiting = false
    var notice: HSLTargetAvailability?
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                onCancel(); enabled.toggle()
            } label: { Label(L10n.text("目标调整"), systemImage: "scope") }
                .buttonStyle(.bordered).tint(enabled ? .yellow : .secondary)
                .accessibilityIdentifier("curve.target")
                .accessibilityValue(L10n.text(enabled ? "开启" : "关闭"))
            if enabled {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("curve.target.status")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String {
        if waiting { return L10n.text("正在取色…") }
        switch notice {
        case .outside: return L10n.text("请在调整后的照片区域取色。")
        case .stale: return L10n.text("预览已变化，请重新取色。")
        case .nonfinite: return L10n.text("此像素不可取样。")
        case .failed: return L10n.text("取色失败，请重试。")
        default:
            return L10n.text("上下拖动调整，方向键微调，Esc 取消")
        }
    }
}
