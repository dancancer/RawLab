import SwiftUI

struct AdjustmentRow: View {
    @Environment(\.locale) private var localizationLocale
    let parameter: AdjustmentParameter
    @Binding var value: Double
    var showsTicks = false
    var specOverride: AdjustmentSpec?
    var whiteBalanceMode: Binding<WhiteBalanceMode>?
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onAuto: (() -> Void)?
    var autoBusy = false
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var editing: Bool
    private var spec: AdjustmentSpec { specOverride ?? parameter.spec }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                if let whiteBalanceMode {
                    Picker(L10n.text("白平衡"), selection: whiteBalanceMode) {
                        ForEach(WhiteBalanceMode.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 160).id(localizationLocale.identifier)
                        .accessibilityLabel(L10n.text("白平衡"))
                } else {
                    Text(spec.title).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let onAuto {
                    Button(action: onAuto) { Label(L10n.text("自动"), systemImage: "wand.and.stars") }
                        .controlSize(.small).disabled(autoBusy)
                        .accessibilityIdentifier("exposure.auto").help(L10n.text("自动调整曝光"))
                }
                TextField(spec.title, text: $draft)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                    .frame(width: 66).focused($editing)
                    .accessibilityLabel(L10n.format("%@数值", String(describing: spec.title)))
                    .accessibilityIdentifier("value.\(parameter.rawValue)")
                    .onSubmit(commit)
                    .onChange(of: editing) { _, focused in if !focused { commit() } }
                    .onExitCommand { draft = spec.text(value); invalid = false; editing = false }
                    .overlay { if invalid { RoundedRectangle(cornerRadius: 4).stroke(.red, lineWidth: 1) } }
                    .help(invalid ? L10n.text("请输入有效数字") : L10n.format("%@ 至 %@ %@", String(describing: spec.text(spec.range.lowerBound)), String(describing: spec.text(spec.range.upperBound)), String(describing: spec.unit)))
                Text(spec.unit).font(.caption).foregroundStyle(.secondary).frame(width: 19, alignment: .leading)
                Button {
                    value = spec.defaultValue; draft = spec.text(value); invalid = false
                } label: { Image(systemName: "arrow.counterclockwise").frame(width: 16, height: 18) }
                .buttonStyle(.borderless).disabled(value == spec.defaultValue && !invalid)
                .help(L10n.format("重置%@", String(describing: spec.title))).accessibilityLabel(L10n.format("重置%@", String(describing: spec.title)))
            }
            Slider(value: Binding(get: { spec.position(for: value) }, set: { value = spec.value(at: $0) }),
                   in: 0...1, onEditingChanged: onEditingChanged)
                .accessibilityLabel(spec.title).accessibilityIdentifier("slider.\(parameter.rawValue)")
                .accessibilityValue("\(spec.text(value)) \(spec.unit)")
            if showsTicks {
                Canvas { context, size in
                    for index in 0...40 {
                        let x = 7 + (size.width - 14) * Double(index) / 40
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: 0))
                        tick.addLine(to: CGPoint(x: x, y: index % 5 == 0 ? 8 : 4))
                        context.stroke(tick, with: .color(.white.opacity(index % 5 == 0 ? 0.55 : 0.25)), lineWidth: 1)
                    }
                    let origin = spec.position(for: spec.defaultValue)
                    let x = 7 + (size.width - 14) * origin
                    context.fill(Path(ellipseIn: CGRect(x: x - 2, y: 9, width: 4, height: 4)), with: .color(.yellow))
                }.frame(height: 13).accessibilityHidden(true)
            }
        }
        .font(.callout)
        .onAppear { draft = spec.text(value) }
        .onChange(of: value) { _, current in draft = spec.text(current); invalid = false }
    }

    private func commit() {
        if let parsed = spec.parse(draft) { value = parsed; invalid = false }
        else { invalid = true }
        draft = spec.text(value)
    }
}
