import RawLabKit
import SwiftUI

private enum IOSCurveSubMode: String, CaseIterable, Identifiable {
    case point, parametric
    var id: String { rawValue }
    var title: String {
        switch self {
        case .point: return L10n.text("点曲线")
        case .parametric: return L10n.text("参数曲线")
        }
    }
}

struct IOSToneCurveControls: View {
    @Binding var settings: ToneCurveSettings
    @Binding var legacy: Double
    var usesExposureStops = false
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    var activeChannel: Binding<ToneCurveChannel>? = nil
    var targetEnabled: Binding<Bool>? = nil
    var targetWaiting = false
    var targetNotice: HSLTargetAvailability? = nil
    var onCancelTarget: () -> Void = {}
    @Environment(\.adjustmentInputContext) private var inputContext
    @Environment(\.adjustmentFine) private var fine
    @State private var localChannel = ToneCurveChannel.rgb
    @State private var subMode = IOSCurveSubMode.point
    @State private var selected = 0
    @State private var showPointEditor = false
    @State private var showLegacy = false

    private var channel: ToneCurveChannel { activeChannel?.wrappedValue ?? localChannel }
    private func setChannel(_ next: ToneCurveChannel) {
        if let activeChannel { activeChannel.wrappedValue = next }
        else { localChannel = next }
    }

    private var scope: String { "\(inputContext.id).\(channel.rawValue)" }
    private var selectedCurve: ToneCurveSettings {
        let shape = settings.shape(channel)
        let effective = shape.mode == .legacy ? ToneCurveShape.identity : shape
        return .init(
            mode: effective.mode,
            points: effective.points,
            channels: settings.channels,
            applyToLuminosity: settings.applyToLuminosity,
            parametric: settings.parametric
        )
    }
    private var curveBinding: Binding<ToneCurveSettings> {
        let owner = channel, context = inputContext
        return Binding(get: { selectedCurve }, set: { next in
            guard owner == channel, context.isCurrent(), context.canChange(), next.isValid else { return }
            settings = settings.replacing(owner, with: next.master)
        })
    }
    private var point: ToneCurvePoint { selectedCurve.points[min(selected, selectedCurve.points.count - 1)] }
    private var legacyActive: Bool { channel == .rgb && settings.mode == .legacy && legacy != 0 && subMode == .point }
    private var isParametricSubMode: Bool { channel == .rgb && subMode == .parametric }
    private var pointCurveIsModified: Bool {
        !settings.shape(.rgb).isIdentity || (settings.mode == .legacy && abs(legacy) > 1e-6)
    }
    private var parametricIsModified: Bool { !settings.parametric.isDefault }
    private var preferredInitialSubMode: IOSCurveSubMode {
        parametricIsModified && !pointCurveIsModified ? .parametric : .point
    }
    private func channelIsModified(_ item: ToneCurveChannel) -> Bool {
        item == .rgb ? (pointCurveIsModified || parametricIsModified) : !settings.shape(item).isIdentity
    }
    private func subModeLabel(_ mode: IOSCurveSubMode) -> String {
        let modified = mode == .point ? pointCurveIsModified : parametricIsModified
        return modified ? "\(mode.title) •" : mode.title
    }

    var body: some View {
        VStack(spacing: 0) {
            if let targetEnabled, targetEnabled.wrappedValue, !isParametricSubMode {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        onCancelTarget(); targetEnabled.wrappedValue.toggle()
                    } label: { Label(L10n.text("目标调整"), systemImage: "scope") }
                        .buttonStyle(.bordered).tint(.yellow)
                        .accessibilityIdentifier("curve.target")
                    Text(targetStatus)
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("curve.target.status")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.bottom, 4)
            }
            HStack(spacing: 0) {
                ForEach(ToneCurveChannel.allCases) { item in
                    let modified = channelIsModified(item)
                    Button {
                        onCancelled(); onCancelTarget(); setChannel(item); selected = 0; showPointEditor = false; showLegacy = false
                    } label: {
                        HStack(spacing: 3) {
                            Text(label(item)).font(.subheadline.weight(item == channel ? .semibold : .regular))
                                .foregroundStyle(item == channel ? Color.yellow : Color.secondary)
                            if modified {
                                Circle().fill(Color.yellow).frame(width: 4, height: 4).accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.plain).accessibilityIdentifier("curve.channel.\(item.rawValue)")
                        .accessibilityAddTraits(item == channel ? .isSelected : [])
                        .accessibilityValue(L10n.text(modified ? "已调整" : "未调整"))
                }
            }
            if channel == .rgb {
                Picker(L10n.text("参数曲线"), selection: $subMode) {
                    ForEach(IOSCurveSubMode.allCases) { mode in
                        Text(subModeLabel(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 18).padding(.bottom, 6)
                .accessibilityIdentifier("curve.submode")
            }
            if legacyActive {
                VStack(spacing: 12) {
                    Text(L10n.text("S 曲线")).font(.subheadline)
                    Text(String(format: "%.1f%%", locale: L10n.locale, legacy)).monospacedDigit()
                    Button(L10n.text("多点曲线")) { commit(.identity) }.accessibilityIdentifier("curve.switch")
                }.frame(height: 170)
            } else {
                ToneCurveCanvas(value: curveBinding, selected: $selected, scope: scope,
                    channel: channel, showSplitMarkers: isParametricSubMode,
                    allowsPointEditing: !isParametricSubMode, fine: fine,
                    isCurrent: inputContext.isCurrent, canChange: inputContext.canChange,
                    onEditingChanged: { editing in
                        if editing { onCancelTarget() }
                        onEditingChanged(editing)
                    }, onCancelled: onCancelled)
                    .frame(width: 194, height: 194)
                if usesExposureStops {
                    HStack { Text("−8 EV"); Spacer(); Text("0 EV"); Spacer(); Text("+8 EV") }
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 170)
                        .accessibilityIdentifier("curve.hdr.ev-axis")
                }
            }
            Toggle(L10n.text("仅作用于明度"), isOn: Binding(
                get: { settings.applyToLuminosity },
                set: { next in
                    onCancelled(); onCancelTarget()
                    guard inputContext.isCurrent(), inputContext.canChange() else { return }
                    onEditingChanged(true)
                    settings.applyToLuminosity = next
                    onEditingChanged(false)
                }
            ))
            .padding(.horizontal, 18).padding(.vertical, 4)
            .accessibilityIdentifier("curve.luminosity")
            if isParametricSubMode {
                parametricControls
            } else {
                HStack(spacing: 8) {
                    Text("\(L10n.text("输入坐标")) \(coordinateText(point.x)) · \(L10n.text("输出坐标")) \(coordinateText(point.y))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Button {
                        commit(selectedCurve.removing(index: selected))
                    } label: {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedCurve.isInterior(selected) ? Color.red : Color.secondary.opacity(0.35))
                    .disabled(!selectedCurve.isInterior(selected))
                    .accessibilityLabel(L10n.text("删除控制点"))
                    .accessibilityIdentifier("curve.quick-remove")
                    Button(L10n.text("编辑控制点")) { showPointEditor = true }
                        .font(.subheadline).foregroundStyle(.yellow).frame(minHeight: 48)
                        .accessibilityIdentifier("curve.edit-point")
                }.padding(.horizontal, 18)
            }
        }
        .sheet(isPresented: $showPointEditor) { pointEditor }
        .onAppear {
            subMode = preferredInitialSubMode
        }
        .onChange(of: subMode) { _, next in
            if next == .parametric {
                onCancelTarget()
                if targetEnabled?.wrappedValue == true {
                    targetEnabled?.wrappedValue = false
                }
            }
        }
        .onChange(of: targetEnabled?.wrappedValue ?? false) { _, enabled in
            if enabled && isParametricSubMode {
                subMode = .point
            }
        }
        .onChange(of: String(describing: inputContext.id)) { _, _ in
            setChannel(.rgb); subMode = preferredInitialSubMode
            selected = 0; showPointEditor = false; showLegacy = false
        }
        .onChange(of: selectedCurve.points.count) { _, count in selected = min(selected, max(0, count - 1)) }
    }

    private var targetStatus: String {
        if targetWaiting { return L10n.text("正在取色…") }
        switch targetNotice {
        case .outside: return L10n.text("请在调整后的照片区域取色。")
        case .stale: return L10n.text("预览已变化，请重新取色。")
        case .nonfinite: return L10n.text("此像素不可取样。")
        case .failed: return L10n.text("取色失败，请重试。")
        default: return L10n.text("在照片上取色并上下拖动")
        }
    }

    private var parametricControls: some View {
        let sub = AdjustmentFieldSpec.SubFields.LightCurveParametric.self
        let minGap = sub.splitMinGap
        let shadowMax = min(sub.splitShadowRange.upperBound, settings.parametric.splitMidtone - minGap)
        let midMin = max(sub.splitMidtoneRange.lowerBound, settings.parametric.splitShadow + minGap)
        let midMax = min(sub.splitMidtoneRange.upperBound, settings.parametric.splitHighlight - minGap)
        let highMin = max(sub.splitHighlightRange.lowerBound, settings.parametric.splitMidtone + minGap)
        return VStack(spacing: 6) {
            AdjustmentControl(title: L10n.text("高光"), value: parametricBinding(\.highlights, in: sub.bandRange),
                range: sub.bandRange, step: 1, defaultValue: sub.bandDefault, unit: "",
                formatter: { String(format: "%.0f", locale: L10n.locale, $0) }, identifier: "curve.parametric.highlights",
                compactNumber: true, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("亮部"), value: parametricBinding(\.lights, in: sub.bandRange),
                range: sub.bandRange, step: 1, defaultValue: sub.bandDefault, unit: "",
                formatter: { String(format: "%.0f", locale: L10n.locale, $0) }, identifier: "curve.parametric.lights",
                compactNumber: true, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("暗部"), value: parametricBinding(\.darks, in: sub.bandRange),
                range: sub.bandRange, step: 1, defaultValue: sub.bandDefault, unit: "",
                formatter: { String(format: "%.0f", locale: L10n.locale, $0) }, identifier: "curve.parametric.darks",
                compactNumber: true, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("阴影"), value: parametricBinding(\.shadows, in: sub.bandRange),
                range: sub.bandRange, step: 1, defaultValue: sub.bandDefault, unit: "",
                formatter: { String(format: "%.0f", locale: L10n.locale, $0) }, identifier: "curve.parametric.shadows",
                compactNumber: true, compactDecimals: nil, onEditingChanged: onEditingChanged)
            Text(L10n.text("拆分点")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            AdjustmentControl(title: L10n.text("阴影"), value: parametricBinding(\.splitShadow, in: sub.splitShadowRange.lowerBound...shadowMax),
                range: sub.splitShadowRange.lowerBound...shadowMax, step: 0.01, defaultValue: sub.splitShadowDefault, unit: "",
                formatter: { String(format: "%.2f", locale: L10n.locale, $0) }, identifier: "curve.parametric.splitShadow",
                compactNumber: true, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("中间调"), value: parametricBinding(\.splitMidtone, in: midMin...midMax),
                range: midMin...midMax, step: 0.01, defaultValue: sub.splitMidtoneDefault, unit: "",
                formatter: { String(format: "%.2f", locale: L10n.locale, $0) }, identifier: "curve.parametric.splitMidtone",
                compactNumber: true, compactDecimals: nil, onEditingChanged: onEditingChanged)
            AdjustmentControl(title: L10n.text("高光"), value: parametricBinding(\.splitHighlight, in: highMin...sub.splitHighlightRange.upperBound),
                range: highMin...sub.splitHighlightRange.upperBound, step: 0.01, defaultValue: sub.splitHighlightDefault, unit: "",
                formatter: { String(format: "%.2f", locale: L10n.locale, $0) }, identifier: "curve.parametric.splitHighlight",
                compactNumber: true, compactDecimals: nil, onEditingChanged: onEditingChanged)
            Button(L10n.text("重置参数曲线")) {
                onCancelled(); onCancelTarget()
                guard inputContext.isCurrent(), inputContext.canChange(), !settings.parametric.isDefault else { return }
                onEditingChanged(true)
                settings.parametric = ToneCurveParametric()
                onEditingChanged(false)
            }
            .disabled(settings.parametric.isDefault)
            .frame(minHeight: 44)
            .accessibilityIdentifier("curve.parametric.reset")
        }
        .padding(.horizontal, 18)
    }

    private func parametricBinding(_ keyPath: WritableKeyPath<ToneCurveParametric, Double>, in range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { settings.parametric[keyPath: keyPath] },
            set: { next in
                guard inputContext.isCurrent(), inputContext.canChange() else { return }
                var copy = settings.parametric
                copy[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, next))
                guard copy.isValid else { return }
                settings.parametric = copy
            }
        )
    }

    private var pointEditor: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(selectedCurve.points.indices, id: \.self) { index in
                                Button("\(index + 1)") { onCancelled(); selected = index }
                                    .frame(minWidth: 44, minHeight: 44)
                                    .foregroundStyle(index == selected ? Color.yellow : Color.primary)
                                    .accessibilityIdentifier("curve.point.\(index)")
                            }
                        }
                    }
                    coordinate(horizontal: true)
                    coordinate(horizontal: false)
                    HStack {
                        Button { addPoint() } label: { Label(L10n.text("添加控制点"), systemImage: "plus") }
                            .disabled(selectedCurve.points.count >= 33).accessibilityIdentifier("curve.add")
                        Spacer()
                        Button { commit(selectedCurve.removing(index: selected)) } label: {
                            Label(L10n.text("删除控制点"), systemImage: "minus")
                        }.disabled(!selectedCurve.isInterior(selected)).accessibilityIdentifier("curve.remove")
                    }.frame(minHeight: 44)
                    Button(L10n.text("重置为直线")) { commit(.identity); selected = 0 }
                        .frame(minHeight: 44).accessibilityIdentifier("curve.reset")
                    if channel == .rgb {
                        Button(L10n.text("S 曲线")) { showLegacy.toggle() }.frame(minHeight: 44)
                        if showLegacy {
                            AdjustmentControl(title: L10n.text("S 曲线"), value: Binding(get: { legacy }, set: { next in
                                guard inputContext.isCurrent(), inputContext.canChange() else { return }
                                settings = settings.replacing(.rgb, with: .init()); legacy = next
                            }), range: -100...100, step: 0.1, defaultValue: 0, unit: "%",
                                formatter: { String(format: "%.1f", locale: L10n.locale, $0) }, identifier: "curve.legacy",
                                onEditingChanged: onEditingChanged)
                        }
                    }
                }.padding(20)
            }
            .navigationTitle(L10n.text("编辑控制点"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { showPointEditor = false } } }
        }.presentationDetents([.medium, .large])
    }

    private func label(_ value: ToneCurveChannel) -> String {
        switch value { case .rgb: return "RGB"; case .red: return L10n.text("红"); case .green: return L10n.text("绿"); case .blue: return L10n.text("蓝") }
    }
    private func coordinateText(_ value: Double) -> String {
        usesExposureStops ? String(format: "%.2f", locale: L10n.locale, value * 16 - 8) : String(format: "%.0f", locale: L10n.locale, value * 255)
    }
    private func coordinate(horizontal: Bool) -> some View {
        let range = usesExposureStops ? ToneCurveSettings.hdrExposureRange : 0...1
        let span = range.upperBound - range.lowerBound
        let owner = channel, index = selected
        let binding = Binding<Double>(get: {
            let p = selectedCurve.points[min(index, selectedCurve.points.count - 1)]
            return range.lowerBound + (horizontal ? p.x : p.y) * span
        }, set: { next in
            guard channel == owner, inputContext.isCurrent(), inputContext.canChange() else { return }
            if horizontal { guard selectedCurve.canMoveX(index) else { return } }
            else { guard selectedCurve.canMoveY(index) else { return } }
            let p = selectedCurve.points[index], value = (next - range.lowerBound) / span
            curveBinding.wrappedValue = selectedCurve.moving(index: index, x: horizontal ? value : p.x, y: horizontal ? p.y : value)
        })
        let allowed = horizontal ? selectedCurve.canMoveX(selected) : selectedCurve.canMoveY(selected)
        let defaultCoord = horizontal
            ? (selected == 0 ? 0.0 : (selected == selectedCurve.points.count - 1 ? 1.0 : point.x))
            : point.x
        return AdjustmentControl(title: L10n.text(horizontal ? "输入坐标" : "输出坐标"), value: binding,
            range: range, step: usesExposureStops ? 0.01 : 0.001, defaultValue: range.lowerBound + defaultCoord * span,
            unit: usesExposureStops ? "EV" : "", formatter: { String(format: "%.2f", locale: L10n.locale, $0) },
            identifier: horizontal ? "curve.x" : "curve.y", compactNumber: true, compactDecimals: nil,
            onEditingChanged: onEditingChanged).disabled(!allowed)
    }
    private func commit(_ next: ToneCurveSettings) {
        onCancelled()
        guard inputContext.isCurrent(), inputContext.canChange(), next.master != settings.shape(channel) else { return }
        onEditingChanged(true); curveBinding.wrappedValue = next; onEditingChanged(false)
    }
    private func addPoint() {
        let curve = selectedCurve
        guard let index = curve.points.indices.dropFirst().max(by: {
            curve.points[$0].x - curve.points[$0 - 1].x < curve.points[$1].x - curve.points[$1 - 1].x
        }) else { return }
        let a = curve.points[index - 1], b = curve.points[index]
        commit(curve.inserting(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)); selected = index
    }
}
