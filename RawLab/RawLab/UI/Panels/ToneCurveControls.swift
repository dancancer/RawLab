import SwiftUI

struct IOSToneCurveControls: View {
    @Binding var settings: ToneCurveSettings
    @Binding var legacy: Double
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void
    @Environment(\.adjustmentInputContext) private var inputContext
    @Environment(\.adjustmentFine) private var fine

    var body: some View {
        ToneCurveEditor(value: $settings, scope: String(describing: inputContext.id), fine: fine,
            isCurrent: inputContext.isCurrent, canChange: inputContext.canChange,
            onEditingChanged: onEditingChanged, onCancelled: onCancelled,
            coordinates: { index, point in coordinates(index, point: point) }, legacy: {
                AdjustmentControl(title: L10n.text("S 曲线"), value: Binding(get: { legacy * 100 }, set: { legacy = $0 / 100 }),
                    range: -100...100, step: 0.1, defaultValue: 0, unit: "%",
                    formatter: { String(format: "%.1f", locale: L10n.locale, $0) }, identifier: "adjustment", onEditingChanged: onEditingChanged)
            }).padding(.horizontal, 16)
    }
    private func coordinates(_ index: Int, point: ToneCurvePoint) -> some View {
        VStack(spacing: 4) {
            coordinate(index, point: point, horizontal: true)
            coordinate(index, point: point, horizontal: false)
        }.disabled(!settings.isInterior(index))
    }
    private func coordinate(_ index: Int, point: ToneCurvePoint, horizontal: Bool) -> some View {
        let binding = Binding<Double>(get: {
            guard settings.points.indices.contains(index) else { return 0 }
            return horizontal ? settings.points[index].x : settings.points[index].y
        }, set: { next in
            guard inputContext.isCurrent(), inputContext.canChange(), settings.isInterior(index) else { return }
            let point = settings.points[index]
            settings = settings.moving(index: index, x: horizontal ? next : point.x, y: horizontal ? point.y : next)
        })
        return AdjustmentControl(title: L10n.text(horizontal ? "输入坐标" : "输出坐标"), value: binding,
            range: 0...1, step: 0.001, defaultValue: point.x,
            formatter: { String(format: "%.2f", locale: L10n.locale, $0) }, identifier: horizontal ? "curve.x" : "curve.y",
            compactNumber: true, compactDecimals: nil, onEditingChanged: onEditingChanged)
    }
}
