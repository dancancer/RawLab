import SwiftUI

struct IOSToneCurveControls: View {
    @Binding var settings: ToneCurveSettings
    @Binding var legacy: Double
    var usesExposureStops = false
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    @Environment(\.adjustmentInputContext) private var inputContext
    @Environment(\.adjustmentFine) private var fine
    @State private var channel = ToneCurveChannel.rgb
    @State private var selected = 0
    @State private var showPointEditor = false
    @State private var showLegacy = false

    private var scope: String { "\(inputContext.id).\(channel.rawValue)" }
    private var selectedCurve: ToneCurveSettings {
        let shape = settings.shape(channel)
        return shape.mode == .legacy ? .identity : .init(mode: shape.mode, points: shape.points)
    }
    private var curveBinding: Binding<ToneCurveSettings> {
        let owner = channel, context = inputContext
        return Binding(get: { selectedCurve }, set: { next in
            guard owner == channel, context.isCurrent(), context.canChange(), next.isValid else { return }
            settings = settings.replacing(owner, with: next.master)
        })
    }
    private var point: ToneCurvePoint { selectedCurve.points[min(selected, selectedCurve.points.count - 1)] }
    private var legacyActive: Bool { channel == .rgb && settings.mode == .legacy && legacy != 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(ToneCurveChannel.allCases) { item in
                    Button {
                        onCancelled(); channel = item; selected = 0; showPointEditor = false; showLegacy = false
                    } label: {
                        Text(label(item)).font(.subheadline.weight(item == channel ? .semibold : .regular))
                            .foregroundStyle(item == channel ? Color.yellow : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.plain).accessibilityIdentifier("curve.channel.\(item.rawValue)")
                        .accessibilityAddTraits(item == channel ? .isSelected : [])
                }
            }
            if legacyActive {
                VStack(spacing: 12) {
                    Text(L10n.text("S 曲线")).font(.subheadline)
                    Text(String(format: "%.1f%%", locale: L10n.locale, legacy)).monospacedDigit()
                    Button(L10n.text("多点曲线")) { commit(.identity) }.accessibilityIdentifier("curve.switch")
                }.frame(height: 170)
            } else {
                ToneCurveCanvas(value: curveBinding, selected: $selected, scope: scope, fine: fine,
                    isCurrent: inputContext.isCurrent, canChange: inputContext.canChange,
                    onEditingChanged: onEditingChanged, onCancelled: onCancelled)
                    .frame(width: 194, height: 194)
                if usesExposureStops {
                    HStack { Text("−8 EV"); Spacer(); Text("0 EV"); Spacer(); Text("+8 EV") }
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 170)
                        .accessibilityIdentifier("curve.hdr.ev-axis")
                }
            }
            HStack {
                Text("\(L10n.text("输入坐标")) \(coordinateText(point.x)) · \(L10n.text("输出坐标")) \(coordinateText(point.y))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Button(L10n.text("编辑控制点")) { showPointEditor = true }
                    .font(.subheadline).foregroundStyle(.yellow).frame(minHeight: 48)
                    .accessibilityIdentifier("curve.edit-point")
            }.padding(.horizontal, 18)
        }
        .sheet(isPresented: $showPointEditor) { pointEditor }
        .onChange(of: String(describing: inputContext.id)) { _, _ in
            channel = .rgb; selected = 0; showPointEditor = false; showLegacy = false
        }
        .onChange(of: selectedCurve.points.count) { _, count in selected = min(selected, max(0, count - 1)) }
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
            guard channel == owner, inputContext.isCurrent(), inputContext.canChange(), selectedCurve.isInterior(index) else { return }
            let p = selectedCurve.points[index], value = (next - range.lowerBound) / span
            curveBinding.wrappedValue = selectedCurve.moving(index: index, x: horizontal ? value : p.x, y: horizontal ? p.y : value)
        })
        return AdjustmentControl(title: L10n.text(horizontal ? "输入坐标" : "输出坐标"), value: binding,
            range: range, step: usesExposureStops ? 0.01 : 0.001, defaultValue: range.lowerBound + point.x * span,
            unit: usesExposureStops ? "EV" : "", formatter: { String(format: "%.2f", locale: L10n.locale, $0) },
            identifier: horizontal ? "curve.x" : "curve.y", compactNumber: true, compactDecimals: nil,
            onEditingChanged: onEditingChanged).disabled(!selectedCurve.isInterior(selected))
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
