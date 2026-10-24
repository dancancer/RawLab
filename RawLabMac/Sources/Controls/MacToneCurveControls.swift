import SwiftUI

struct MacToneCurveControls: View {
    @Binding var settings: ToneCurveSettings
    @Binding var legacy: Double
    let source: String
    let isCurrent: () -> Bool
    let onEditingChanged: (Bool) -> Void
    let onCancelled: () -> Void

    var body: some View {
        ToneCurveEditor(value: $settings, scope: source, isCurrent: isCurrent,
            prepareEditing: ParameterValueField.commitPendingInputs,
            onEditingChanged: onEditingChanged, onCancelled: onCancelled,
            coordinates: { index, point in coordinates(index, point: point) }, legacy: {
                ParameterRow(title: L10n.text("S 曲线"), value: $legacy, range: -100...100, defaultValue: 0,
                    unit: "%", identifier: "value.toneCurve", onEditingChanged: onEditingChanged)
            })
    }
    private func coordinates(_ index: Int, point: ToneCurvePoint) -> some View {
        VStack(spacing: 6) {
            coordinate(index, point: point, horizontal: true)
            coordinate(index, point: point, horizontal: false)
        }.disabled(!settings.isInterior(index))
    }
    private func coordinate(_ index: Int, point: ToneCurvePoint, horizontal: Bool) -> some View {
        let title = L10n.text(horizontal ? "输入坐标" : "输出坐标")
        let binding = Binding<Double>(get: {
            guard settings.points.indices.contains(index) else { return 0 }
            return horizontal ? settings.points[index].x : settings.points[index].y
        }, set: { next in
            guard isCurrent(), settings.isInterior(index) else { return }
            let point = settings.points[index]
            settings = settings.moving(index: index, x: horizontal ? next : point.x, y: horizontal ? point.y : next)
        })
        return HStack {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            ParameterValueField(value: binding, range: 0...1, precision: .curveCoordinate,
                title: title, unit: "", identifier: horizontal ? "curve.value.x" : "curve.value.y",
                defaultValue: point.x, inputScope: "\(source).\(index)", onEditingChanged: onEditingChanged)
                .frame(width: 122, height: 30)
        }
    }
}
