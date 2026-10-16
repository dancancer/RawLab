import SwiftUI
import UIKit

struct AdjustmentControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    let unit: String
    let formatter: (Double) -> String
    let reciprocal: Bool
    let showsReset: Bool
    let identifier: String
    let onEditingChanged: (Bool) -> Void
    @State private var fine = false
    @State private var showingWheel = false
    @State private var wheelOriginal = 0.0
    @AccessibilityFocusState private var valueFocused: Bool
    @AppStorage("rawlab.adjustmentHaptics.enabled") private var haptics = true
    @ScaledMetric(relativeTo: .caption2) private var rulerLabelHeight = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1,
         defaultValue: Double, unit: String = "", formatter: @escaping (Double) -> String,
         reciprocal: Bool = false, showsReset: Bool = true, identifier: String,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.unit = unit
        self.formatter = formatter
        self.reciprocal = reciprocal
        self.showsReset = showsReset
        self.identifier = identifier
        self.onEditingChanged = onEditingChanged
    }

    private var scale: AdjustmentScale { AdjustmentScale(range: range, step: step, reciprocal: reciprocal) }
    private var validDefault: Double? { scale.contains(defaultValue) ? defaultValue : nil }
    private var completeValue: String { "\(formatter(value)) \(unit)".trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { titleLabel; Spacer(minLength: 0); valueButton; if showsReset { resetButton } }
                VStack(alignment: .leading, spacing: 4) {
                    titleLabel
                    HStack(spacing: 12) { valueButton; Spacer(minLength: 0); if showsReset { resetButton } }
                }
            }
            AdjustmentRuler(value: $value, scale: scale, defaultValue: validDefault,
                            title: title, formatter: { "\(formatter($0)) \(unit)".trimmingCharacters(in: .whitespaces) },
                            identifier: "\(identifier).ruler", fine: fine, haptics: haptics,
                            reduceMotion: reduceMotion, onEditingChanged: onEditingChanged)
                .frame(height: 60 + rulerLabelHeight)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { fineButton; Spacer(minLength: 0); referenceLabel }
                VStack(alignment: .leading, spacing: 2) { fineButton; referenceLabel }
            }
        }
        .onChange(of: showingWheel) { _, presented in
            if !presented { valueFocused = true }
        }
    }

    private var titleLabel: some View { Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true) }

    private var valueButton: some View {
        Button {
            valueFocused = false
            wheelOriginal = value
            showingWheel = true
        } label: {
            Text(completeValue).font(.body.weight(.semibold)).monospacedDigit()
                .fixedSize(horizontal: true, vertical: false).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(L10n.format("%@数值", title))
        .accessibilityValue(completeValue)
        .accessibilityIdentifier("\(identifier).value")
        .accessibilityFocused($valueFocused)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(scale.increment(value, direction: 1))
            case .decrement: commit(scale.increment(value, direction: -1))
            @unknown default: break
            }
        }
        .sheet(isPresented: wheelSheetPresented) { wheelEditor }
        .popover(isPresented: wheelPopoverPresented) { wheelEditor }
    }

    private var wheelSheetPresented: Binding<Bool> {
        Binding(get: { showingWheel && UIDevice.current.userInterfaceIdiom != .pad },
                set: { showingWheel = $0 })
    }

    private var wheelPopoverPresented: Binding<Bool> {
        Binding(get: { showingWheel && UIDevice.current.userInterfaceIdiom == .pad },
                set: { showingWheel = $0 })
    }

    private var wheelEditor: some View {
        NativeValueWheel(title: title, original: wheelOriginal, scale: scale,
                         defaultValue: validDefault, unit: unit, formatter: formatter,
                         onCancel: { showingWheel = false }, onApply: { draft in
            if draft != wheelOriginal { commit(draft) }
            showingWheel = false
        })
    }

    private var resetButton: some View {
        Button {
            guard let validDefault, value != validDefault else { return }
            AdjustmentFeedback.reset(enabled: haptics)
            commit(validDefault)
        } label: {
            Image(systemName: "arrow.counterclockwise").frame(minWidth: 44, minHeight: 44)
        }
        .disabled(validDefault == nil || value == validDefault)
        .accessibilityLabel(L10n.format("重置%@", title))
        .accessibilityIdentifier("\(identifier).reset")
    }

    private var fineButton: some View {
        Button { fine.toggle() } label: {
            Label(L10n.text("精细"), systemImage: "scope")
                .font(.subheadline).frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(fine ? .yellow : .secondary)
        .accessibilityValue(fine ? L10n.text("四分之一灵敏度") : L10n.text("标准灵敏度"))
        .accessibilityAddTraits(fine ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).fine")
    }

    private var referenceLabel: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let validDefault { Text("\(L10n.text("默认")) \(formatter(validDefault)) \(unit)") }
            Text("\(L10n.text("范围")) \(formatter(range.lowerBound)) – \(formatter(range.upperBound)) \(unit)")
            if value == range.lowerBound { Text(L10n.text("已到下限")) }
            if value == range.upperBound { Text(L10n.text("已到上限")) }
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("\(identifier).reference")
    }

    private func commit(_ newValue: Double) {
        guard scale.contains(newValue), newValue != value else { return }
        value = newValue
    }
}

// MARK: - One shared event gate; native pickers retain system feedback

enum AdjustmentFeedback {
    private static var lastEvent = -Double.infinity

    static func change(from old: Double, to new: Double, scale: AdjustmentScale,
                       defaultValue: Double?, enabled: Bool) {
        guard enabled, !UIAccessibility.isVoiceOverRunning, old != new else { return }
        if scale.crossesDefault(from: old, to: new, defaultValue: defaultValue) {
            play(.soft)
        } else if new == scale.range.lowerBound || new == scale.range.upperBound {
            play(.light)
        } else if scale.crossesMajor(from: old, to: new) {
            guard acceptEvent() else { return }
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    static func reset(enabled: Bool) {
        if enabled && !UIAccessibility.isVoiceOverRunning { play(.soft) }
    }

    private static func play(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard acceptEvent() else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private static func acceptEvent() -> Bool {
        let now = CACurrentMediaTime()
        guard now - lastEvent >= 0.125 else { return false }
        lastEvent = now
        return true
    }
}
