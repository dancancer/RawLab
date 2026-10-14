import SwiftUI
import UIKit

struct NativeValueWheel: View {
    let title: String
    let original: Double
    let scale: AdjustmentScale
    let defaultValue: Double?
    let unit: String
    let formatter: (Double) -> String
    let onCancel: () -> Void
    let onApply: (Double) -> Void
    @State private var draft: Double
    @State private var values: [Double]
    @State private var presentationSpace = WheelPresentationSpace.current
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(title: String, original: Double, scale: AdjustmentScale, defaultValue: Double?, unit: String,
         formatter: @escaping (Double) -> String, onCancel: @escaping () -> Void,
         onApply: @escaping (Double) -> Void) {
        self.title = title
        self.original = original
        self.scale = scale
        self.defaultValue = defaultValue
        self.unit = unit
        self.formatter = formatter
        self.onCancel = onCancel
        self.onApply = onApply
        _draft = State(initialValue: original)
        _values = State(initialValue: scale.values(including: [original] + (defaultValue.map { [$0] } ?? [])))
    }

    private var rangeLabel: String {
        "\(L10n.text("范围")) \(formatter(scale.range.lowerBound)) – \(formatter(scale.range.upperBound)) \(unit)"
    }

    private var popoverHeight: CGFloat? {
        guard presentationSpace.regularPopover else { return nil }
        return min(dynamicTypeSize.isAccessibilitySize ? 600 : 440, presentationSpace.availableHeight)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(L10n.text("取消"), action: onCancel)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("adjustment.wheel.cancel")
                Spacer(minLength: 12)
                Button(L10n.text("应用")) { onApply(draft) }
                    .fontWeight(.semibold)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("adjustment.wheel.apply")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        Text(title).font(.headline).multilineTextAlignment(.center)
                        Text(rangeLabel).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text("\(L10n.text("临时选择")) \(formatter(draft)) \(unit)")
                            .font(.body).monospacedDigit().multilineTextAlignment(.center)
                            .accessibilityIdentifier("adjustment.wheel.draft")
                        WholeValuePicker(value: $draft, values: values, title: title, unit: unit, formatter: formatter)
                            .frame(height: dynamicTypeSize.isAccessibilitySize ? 264 : 220)
                            .id("native-value-wheel")
                        if let defaultValue {
                            Button("\(L10n.text("默认")) \(formatter(defaultValue)) \(unit)") { draft = defaultValue }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("adjustment.wheel.default")
                        }
                    }
                }
                .onAppear { proxy.scrollTo("native-value-wheel", anchor: .center) }
                .onChange(of: presentationSpace) { _, _ in proxy.scrollTo("native-value-wheel", anchor: .center) }
            }
        }
        .padding(16)
        .frame(minWidth: 280, idealWidth: 360, maxWidth: 480)
        .frame(height: popoverHeight)
        .background(WheelPresentationSpaceReader(space: $presentationSpace).allowsHitTesting(false))
        .interactiveDismissDisabled(draft != original)
        .presentationCompactAdaptation(.sheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Measure the presenting window rather than the popover content

private struct WheelPresentationSpace: Equatable {
    let availableHeight: CGFloat
    let regularPopover: Bool

    init(window: UIWindow) {
        availableHeight = max(0, window.bounds.height - window.safeAreaInsets.top - window.safeAreaInsets.bottom - 40)
        regularPopover = window.traitCollection.userInterfaceIdiom == .pad &&
            window.traitCollection.horizontalSizeClass == .regular
    }

    static var current: Self {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        if let window = windows.first(where: \.isKeyWindow) ?? windows.first(where: { !$0.isHidden }) {
            return Self(window: window)
        }
        return Self(availableHeight: 440, regularPopover: false)
    }

    private init(availableHeight: CGFloat, regularPopover: Bool) {
        self.availableHeight = availableHeight
        self.regularPopover = regularPopover
    }
}

private struct WheelPresentationSpaceReader: UIViewRepresentable {
    @Binding var space: WheelPresentationSpace

    func makeUIView(context: Context) -> WindowReaderView { WindowReaderView() }

    func updateUIView(_ view: WindowReaderView, context: Context) {
        view.onChange = { space = $0 }
        view.reportSpace()
    }

    final class WindowReaderView: UIView {
        var onChange: (WheelPresentationSpace) -> Void = { _ in }
        private var lastSpace: WheelPresentationSpace?

        override func didMoveToWindow() { super.didMoveToWindow(); reportSpace() }
        override func layoutSubviews() { super.layoutSubviews(); reportSpace() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); reportSpace() }

        func reportSpace() {
            guard let window, window.bounds.height > 0 else { return }
            let space = WheelPresentationSpace(window: window)
            guard space != lastSpace else { return }
            lastSpace = space
            DispatchQueue.main.async { [weak self] in self?.onChange(space) }
        }
    }
}

// MARK: - Single complete-value column

private struct WholeValuePicker: UIViewRepresentable {
    @Binding var value: Double
    let values: [Double]
    let title: String
    let unit: String
    let formatter: (Double) -> String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.accessibilityIdentifier = "adjustment.wheel"
        picker.accessibilityLabel = title
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        let changed = context.coordinator.parent.values != values
        context.coordinator.parent = self
        if changed { picker.reloadAllComponents() }
        let index = values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) } ?? 0
        if picker.selectedRow(inComponent: 0) != index { picker.selectRow(index, inComponent: 0, animated: false) }
        picker.accessibilityLabel = title
        picker.accessibilityValue = "\(formatter(value)) \(unit)".trimmingCharacters(in: .whitespaces)
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: WholeValuePicker
        init(_ parent: WholeValuePicker) { self.parent = parent }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int { parent.values.count }
        func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat {
            max(44, UIFont.preferredFont(forTextStyle: .body).lineHeight + 16)
        }

        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int,
                        reusing view: UIView?) -> UIView {
            let label = view as? UILabel ?? UILabel()
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
            label.textAlignment = .center
            label.text = parent.formatter(parent.values[row])
            label.accessibilityLabel = "\(parent.title), \(label.text ?? "") \(parent.unit)".trimmingCharacters(in: .whitespaces)
            return label
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            parent.value = parent.values[row]
        }
    }
}
