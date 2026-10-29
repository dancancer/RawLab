import SwiftUI
import UIKit

struct AdjustmentInputContext {
    var id: AnyHashable = 0
    var isCurrent: () -> Bool = { true }
    var canChange: () -> Bool = { true }
    var onInteractionCancelled: () -> Void = {}
}

private struct AdjustmentInputContextKey: EnvironmentKey {
    static let defaultValue = AdjustmentInputContext()
}
private struct AdjustmentFineKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var adjustmentInputContext: AdjustmentInputContext {
        get { self[AdjustmentInputContextKey.self] }
        set { self[AdjustmentInputContextKey.self] = newValue }
    }
    var adjustmentFine: Bool {
        get { self[AdjustmentFineKey.self] }
        set { self[AdjustmentFineKey.self] = newValue }
    }
}

struct AdjustmentControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    let unit: String
    let formatter: (Double) -> String
    let reciprocal: Bool
    let displayScale: Double
    let identifier: String
    let directionColors: [Color]
    let directionHint: String
    let compactNumber: Bool
    let compactDecimals: Int?
    let onEditingChanged: (Bool) -> Void
    @State private var showingWheel = false
    @State private var wheelOriginal = 0.0
    @State private var wheelID: UUID?
    @AccessibilityFocusState private var valueFocused: Bool
    @ScaledMetric(relativeTo: .caption) private var unitWidth = 24
    @AppStorage("rawlab.adjustmentHaptics.enabled") private var haptics = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.adjustmentFine) private var fine
    @Environment(\.adjustmentInputContext) private var inputContext

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1,
         defaultValue: Double, unit: String = "", formatter: @escaping (Double) -> String,
         reciprocal: Bool = false, displayScale: Double = 1, identifier: String,
         directionColors: [Color] = [], directionHint: String = "",
         compactNumber: Bool = false, compactDecimals: Int? = 2,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; _value = value; self.range = range; self.step = step
        self.defaultValue = defaultValue; self.unit = unit; self.formatter = formatter
        self.reciprocal = reciprocal; self.displayScale = displayScale; self.identifier = identifier
        self.directionColors = directionColors; self.directionHint = directionHint
        self.compactNumber = compactNumber; self.compactDecimals = compactDecimals
        self.onEditingChanged = onEditingChanged
    }

    private var scale: AdjustmentScale { AdjustmentScale(range: range, step: step, reciprocal: reciprocal, compactDecimals: compactNumber ? compactDecimals : nil) }
    private var validDefault: Double? { scale.contains(defaultValue) ? defaultValue : nil }
    private var modified: Bool { validDefault.map { value != $0 } ?? false }
    private func number(_ value: Double) -> String {
        scale.completeText(value, displayScale: displayScale, locale: L10n.locale, formatter: formatter)
    }
    private func complete(_ value: Double) -> String { "\(number(value)) \(unit)".trimmingCharacters(in: .whitespaces) }
    private var help: String {
        L10n.format("默认值：%@；范围：%@ 至 %@；步进：%@。", validDefault.map(complete) ?? "—",
                    complete(range.lowerBound), complete(range.upperBound), step * displayScale == 0.001 ? "1/1000 " + unit : complete(step))
    }

    var body: some View {
        Group {
            if compactNumber {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { titleLabel; Spacer(minLength: 0); valueAndUnit }
                    VStack(alignment: .leading, spacing: 0) { titleLabel; valueAndUnit.frame(maxWidth: .infinity, alignment: .trailing) }
                }
                .padding(.horizontal, 8)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(spacing: 4) {
                    HStack(spacing: 8) { titleLabel; Spacer(minLength: 8); valueAndUnit }
                    ruler.frame(height: rulerHeight)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: inputContext.id) { _, _ in cancelInput() }
        .onChange(of: value) { _, next in if showingWheel && next != wheelOriginal { cancelInput() } }
        .onDisappear { cancelInput() }
        .onChange(of: showingWheel) { _, presented in if !presented { valueFocused = true } }
    }

    private var titleLabel: some View {
        Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
            .modifier(AdjustmentResetGesture(enabled: !voiceOver, action: reset))
            .accessibilityAction(named: L10n.text("恢复默认"), reset)
            .accessibilityHint(voiceOver ? help : help + " " + L10n.text("双击名称或轨道恢复默认值。"))
            .accessibilityIdentifier("\(identifier).title")
    }

    private var rulerHeight: CGFloat {
        guard dynamicTypeSize.isAccessibilitySize else { return 44 }
        // 原生标尺的刻度文字从 y=47 开始绘制，辅助字号需要容纳完整行高。
        return max(76, 47 + ceil(UIFont.preferredFont(forTextStyle: .caption2).lineHeight))
    }

    private var ruler: some View {
        AdjustmentRuler(value: Binding(get: { value }, set: { if inputContext.isCurrent() && inputContext.canChange() { value = $0 } }), scale: scale, defaultValue: validDefault, title: title,
                        formatter: complete, identifier: "\(identifier).ruler", fine: fine,
                        haptics: haptics, reduceMotion: reduceMotion, interactionID: inputContext.id, directionColors: directionColors,
                        directionHint: directionHint,
                        onEditingCancelled: inputContext.onInteractionCancelled,
                        onEditingChanged: { editing in if inputContext.isCurrent() { onEditingChanged(editing) } })
            .modifier(AdjustmentResetGesture(enabled: !voiceOver, action: reset))
    }

    private var valueAndUnit: some View {
        HStack(spacing: 4) {
            valueButton
            Text(unit.isEmpty ? " " : unit).font(.caption).foregroundStyle(.secondary)
                .fixedSize().frame(width: unitWidth, alignment: .leading).accessibilityHidden(true).accessibilityIdentifier("\(identifier).unit")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var valueButton: some View {
        Button {
            valueFocused = false; wheelOriginal = value; wheelID = UUID(); showingWheel = true
        } label: {
            Text(number(value)).font(.body.weight(.semibold)).monospacedDigit()
                .fixedSize(horizontal: true, vertical: false).frame(minWidth: 44, minHeight: 44)
                .frame(width: compactNumber ? nil : stableValueWidth)
                .foregroundStyle(modified ? Color.yellow : Color.primary)
                .overlay(alignment: .bottom) { if modified { Circle().fill(.yellow).frame(width: 4, height: 4) } }
        }
        .accessibilityLabel(L10n.format("%@数值", title))
        .accessibilityValue(complete(value))
        .accessibilityHint(L10n.text(modified ? "已调整" : "未调整") + " " + help + " " + directionHint)
        .accessibilityIdentifier("\(identifier).value")
        .accessibilityFocused($valueFocused)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(scale.increment(value, direction: 1))
            case .decrement: commit(scale.increment(value, direction: -1))
            @unknown default: break
            }
        }
        .accessibilityAction(named: L10n.text("恢复默认"), reset)
        .sheet(isPresented: wheelSheetPresented) { wheelEditor }
        .popover(isPresented: wheelPopoverPresented) { wheelEditor }
    }

    private var stableValueWidth: CGFloat {
        let font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
        let format = NumberFormatter()
        format.locale = L10n.locale
        format.numberStyle = .decimal
        format.usesGroupingSeparator = false
        format.minimumFractionDigits = 2
        format.maximumFractionDigits = 2
        if number(range.upperBound).hasPrefix("+") { format.positivePrefix = "+" }
        // 保留范围内完整数字及历史小数的空间，避免符号或位数变化挤动名称和标尺。
        let widths = [range.lowerBound, range.upperBound].map { bound in
            let text = format.string(from: NSNumber(value: bound * displayScale)) ?? number(bound)
            return (text as NSString).size(withAttributes: [.font: font]).width
        }
        return max(44, ceil(widths.max() ?? 0))
    }

    private var wheelSheetPresented: Binding<Bool> {
        Binding(get: { showingWheel && UIDevice.current.userInterfaceIdiom != .pad }, set: { showingWheel = $0 })
    }
    private var wheelPopoverPresented: Binding<Bool> {
        Binding(get: { showingWheel && UIDevice.current.userInterfaceIdiom == .pad }, set: { showingWheel = $0 })
    }
    private var wheelEditor: some View {
        let session = wheelID
        let context = inputContext
        return NativeValueWheel(title: title, original: wheelOriginal, scale: scale,
                                defaultValue: validDefault, unit: unit, formatter: number,
                                help: help, onCancel: cancelInput, onApply: { draft in
            guard showingWheel, session == wheelID, context.isCurrent(), context.id == inputContext.id else { cancelInput(); return }
            if draft != wheelOriginal { commit(draft) }
            cancelInput()
        })
    }
    private func cancelInput() { showingWheel = false; wheelID = nil }
    private func reset() {
        guard let validDefault, value != validDefault else { return }
        AdjustmentFeedback.reset(enabled: haptics); commit(validDefault)
    }
    private func commit(_ newValue: Double) {
        guard inputContext.isCurrent(), scale.contains(newValue), newValue != value else { return }
        onEditingChanged(true)
        if inputContext.canChange() { value = newValue }
        onEditingChanged(false)
    }
}

private struct AdjustmentResetGesture: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.onTapGesture(count: 2, perform: action) }
        else { content }
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
