import SwiftUI

struct ToneCurveEditor<Coordinates: View, Legacy: View>: View {
    @Binding var value: ToneCurveSettings
    let scope: String
    var fine = false
    var isCurrent: () -> Bool = { true }
    var canChange: () -> Bool = { true }
    var prepareEditing: () -> Bool = { true }
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onCancelled: () -> Void = {}
    @ViewBuilder let coordinates: (Int, ToneCurvePoint) -> Coordinates
    @ViewBuilder let legacy: () -> Legacy
    @State private var selected = 0
    @State private var switching = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { modeTitle; Spacer(minLength: 12); switchButton }
                VStack(alignment: .leading) { modeTitle; switchButton }
            }
            if value.mode == .custom {
                ViewThatFits(in: .horizontal) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        HStack(spacing: 16) { canvas.frame(width: 232, height: 164); pointControls.frame(minWidth: 180) }
                    }
                    VStack(spacing: 8) { canvas.frame(maxWidth: 320).frame(height: 164); pointControls }
                }
                Text(L10n.text("点击曲线区域添加控制点，拖动中间点调整。"))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    HStack { addButton; removeButton; Spacer(minLength: 4); resetButton }
                    VStack(alignment: .leading) { HStack { addButton; removeButton }; resetButton }
                }
            } else { legacy() }
        }
        .frame(maxWidth: 720)
        .alert(L10n.text("切换曲线模式"), isPresented: $switching) {
            Button(L10n.text("取消"), role: .cancel) {}
            Button(L10n.text("切换")) { commit { $0.mode == .legacy ? .identity : ToneCurveSettings() }; selected = 0 }
        } message: {
            Text(L10n.text(value.mode == .legacy ? "多点曲线将从直线开始，旧 S 曲线数值会保留。" : "切换到 S 曲线将移除当前控制点，可撤销此操作。"))
        }
        .onChange(of: scope) { _, _ in switching = false; selected = 0 }
        .onChange(of: value.points.count) { _, count in selected = max(0, min(selected, count - 1)) }
    }
    private var modeTitle: some View {
        Text(L10n.text(value.mode == .legacy ? "S 曲线" : "多点曲线"))
            .font(.subheadline.weight(.semibold)).accessibilityIdentifier("curve.mode")
    }
    private var switchButton: some View {
        Button(L10n.text(value.mode == .legacy ? "多点曲线" : "S 曲线")) {
            onCancelled()
            if isCurrent(), canChange(), prepareEditing() { switching = true }
        }.accessibilityIdentifier("curve.switch")
    }
    private var canvas: some View {
        ToneCurveCanvas(value: $value, selected: $selected, scope: scope, fine: fine,
            isCurrent: isCurrent, canChange: canChange, prepareEditing: prepareEditing,
            onEditingChanged: onEditingChanged, onCancelled: onCancelled)
    }
    private var pointControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(value.points.indices, id: \.self) { index in
                        Button {
                            onCancelled()
                            if isCurrent(), prepareEditing() { selected = index }
                        } label: {
                            Text("\(index + 1)").monospacedDigit().frame(minWidth: 32, minHeight: 32)
                                .background(index == selected ? Color.yellow.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain).accessibilityLabel(L10n.format("控制点 %d", index + 1))
                            .accessibilityIdentifier("curve.point.\(index)")
                            .accessibilityAddTraits(index == selected ? .isSelected : [])
                    }
                }
            }
            if value.points.indices.contains(selected) {
                coordinates(selected, value.points[selected]).id("\(scope).\(selected)")
                if !value.isInterior(selected) { Text(L10n.text("端点固定")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private var addButton: some View {
        Button { commit { curve in
            guard let next = curve.points.indices.dropFirst().max(by: {
                curve.points[$0].x - curve.points[$0 - 1].x < curve.points[$1].x - curve.points[$1 - 1].x
            }) else { return curve }
            let a = curve.points[next - 1], b = curve.points[next]
            let result = curve.inserting(x: a.x + (b.x - a.x) / 2, y: a.y + (b.y - a.y) / 2)
            if result != curve { selected = next }; return result
        } } label: { Label(L10n.text("添加控制点"), systemImage: "plus") }
            .disabled(value.points.count >= 33).accessibilityIdentifier("curve.add")
    }
    private var removeButton: some View {
        Button { commit { $0.removing(index: selected) } } label: { Label(L10n.text("删除控制点"), systemImage: "minus") }
            .disabled(!value.isInterior(selected)).accessibilityIdentifier("curve.remove")
    }
    private var resetButton: some View {
        Button(L10n.text("重置为直线")) { commit { _ in .identity }; selected = 0 }
            .disabled(value == .identity).accessibilityIdentifier("curve.reset")
    }
    private func commit(_ operation: (ToneCurveSettings) -> ToneCurveSettings) {
        onCancelled()
        guard isCurrent(), canChange(), prepareEditing() else { return }
        let next = operation(value)
        guard next != value else { return }
        onEditingChanged(true)
        guard canChange() else { onCancelled(); return }
        value = next; onEditingChanged(false)
    }
}
