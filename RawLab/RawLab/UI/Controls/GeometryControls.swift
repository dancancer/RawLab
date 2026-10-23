import SwiftUI

struct IOSGeometryControls: View {
    @Environment(\.locale) private var localizationLocale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var settings: GeometrySettings
    @Binding var aspectPreset: CropAspectPreset
    @Binding var lockedRatio: Double?
    @Binding var aspectSwapped: Bool
    @Binding var showsGrid: Bool
    let onEditingChanged: (Bool) -> Void
    let canvasSize: CGSize
    let perspective: Bool
    @State private var showsDimensions = false

    init(settings: Binding<GeometrySettings>, onEditingChanged: @escaping (Bool) -> Void,
         canvasSize: CGSize = CGSize(width: 1, height: 1),
         aspectPreset: Binding<CropAspectPreset> = .constant(.free),
         lockedRatio: Binding<Double?> = .constant(nil), aspectSwapped: Binding<Bool> = .constant(false),
         showsGrid: Binding<Bool> = .constant(true), perspective: Bool = false) {
        _settings = settings; self.onEditingChanged = onEditingChanged; self.canvasSize = canvasSize
        _aspectPreset = aspectPreset; _lockedRatio = lockedRatio; _aspectSwapped = aspectSwapped
        _showsGrid = showsGrid; self.perspective = perspective
    }

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 8) {
            if perspective {
                perspectiveControl("水平透视", key: \.perspectiveHorizontal, identifier: "geometry.perspectiveHorizontal")
                perspectiveControl("垂直透视", key: \.perspectiveVertical, identifier: "geometry.perspectiveVertical")
            } else {
                HStack(spacing: 4) {
                    aspectMenu
                    iconButton("锁定当前比例", symbol: aspectRatio == nil ? "lock.open" : "lock", identifier: "geometry.lockAspect", selected: aspectRatio != nil) {
                        if aspectRatio != nil { clearAspect() }
                        else if canvasSize.width > 0, canvasSize.height > 0 {
                            lockedRatio = settings.cropWidth * Double(canvasSize.width) / (settings.cropHeight * Double(canvasSize.height))
                            aspectSwapped = false
                        }
                    }
                    iconButton("交换横纵比例", symbol: "arrow.left.arrow.right", identifier: "geometry.swapAspect") {
                        aspectSwapped.toggle(); fitAspect()
                    }.disabled(aspectRatio == nil || aspectRatio == 1)
                    iconButton("三分网格", symbol: "grid", identifier: "geometry.grid", selected: showsGrid) { showsGrid.toggle() }
                }.disabled(canvasSize.width <= 0 || canvasSize.height <= 0)
                HStack(spacing: 4) {
                    rotationButton(clockwise: false); rotationButton(clockwise: true)
                    iconButton("水平翻转", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", identifier: "geometry.flipHorizontal", selected: settings.flipHorizontal) { settings.flipHorizontal.toggle() }
                    iconButton("垂直翻转", symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", identifier: "geometry.flipVertical", selected: settings.flipVertical) { settings.flipVertical.toggle() }
                    Spacer(minLength: 0)
                    iconButton("重置本工具", symbol: "arrow.counterclockwise", identifier: "geometry.reset") {
                        clearAspect(); settings = GeometrySettings()
                    }.disabled(settings.isIdentity)
                }
                AdjustmentControl(title: L10n.text("拉直"), value: clampedBinding(\.straightenDegrees, range: -45...45),
                    range: -45...45, step: 0.1, defaultValue: 0, unit: "°", formatter: decimalValue,
                    identifier: "geometry.straighten", onEditingChanged: onEditingChanged)
                Button { showsDimensions.toggle() } label: {
                    HStack {
                        Text(L10n.text("位置与尺寸")).font(.subheadline)
                        Spacer()
                        Image(systemName: showsDimensions ? "chevron.down" : "chevron.right")
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(showsDimensions ? .isSelected : [])
                .accessibilityIdentifier("geometry.dimensions")
                if showsDimensions {
                    LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                        ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        cropControl("裁切左边", key: \.cropX, identifier: "geometry.cropX")
                        cropControl("裁切上边", key: \.cropY, identifier: "geometry.cropY")
                        cropControl("裁切宽度", key: \.cropWidth, identifier: "geometry.cropWidth")
                        cropControl("裁切高度", key: \.cropHeight, identifier: "geometry.cropHeight")
                    }
                }
            }
        }
        .onChange(of: canvasSize) { _, next in
            guard next.width > 0, next.height > 0, aspectRatio != nil else { return }
            let rect = CropInteraction.dragging(CropInteraction.rect(from: settings), handle: .bottomRight,
                translation: .zero, canvasSize: next, ratio: aspectRatio)
            settings = CropInteraction.applying(rect: rect, to: settings)
        }
    }

    private var aspectRatio: Double? {
        if let lockedRatio { return aspectSwapped ? 1 / lockedRatio : lockedRatio }
        return aspectPreset.ratio(for: canvasSize, swapped: aspectSwapped)
    }

    private func iconButton(_ title: String, symbol: String, identifier: String, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body).frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(selected ? Color.yellow : .primary)
                .background(selected ? Color.yellow.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L10n.text(title)).accessibilityIdentifier(identifier)
            .accessibilityValue(selected ? L10n.text("已启用") : "")
    }

    private func rotationButton(clockwise: Bool) -> some View {
        iconButton(clockwise ? "向右旋转 90°" : "向左旋转 90°", symbol: clockwise ? "rotate.right" : "rotate.left",
                   identifier: clockwise ? "geometry.rotateRight" : "geometry.rotateLeft") {
            settings.quarterTurns = (settings.quarterTurns + (clockwise ? 1 : 3)) % 4
        }
    }

    private func perspectiveControl(_ title: String, key: WritableKeyPath<GeometrySettings, Double>, identifier: String) -> some View {
        AdjustmentControl(title: L10n.text(title), value: clampedBinding(key, range: -1...1, scale: 100),
            range: -100...100, step: 1, defaultValue: 0,
            formatter: { String(format: "%.0f", locale: L10n.locale, $0) }, identifier: identifier, onEditingChanged: onEditingChanged)
    }

    private func cropControl(_ title: String, key: WritableKeyPath<GeometrySettings, Double>, identifier: String) -> some View {
        let dimension = key == \.cropWidth || key == \.cropHeight
        let range = cropRange(key)
        return AdjustmentControl(title: L10n.text(title), value: cropBinding(key), range: range, step: 0.01,
            defaultValue: dimension ? 100 : 0, unit: "%", formatter: cropValue, identifier: identifier,
            compactNumber: true, onEditingChanged: onEditingChanged)
            .disabled(range.lowerBound == range.upperBound)
    }

    private func cropRange(_ key: WritableKeyPath<GeometrySettings, Double>) -> ClosedRange<Double> {
        var maximum: Double
        switch key {
        case \.cropX: maximum = 1 - settings.cropWidth
        case \.cropY: maximum = 1 - settings.cropHeight
        case \.cropWidth: maximum = 1 - settings.cropX
        default: maximum = 1 - settings.cropY
        }
        if let ratio = aspectRatio, canvasSize.width > 0 {
            let normalized = ratio * Double(canvasSize.height / canvasSize.width)
            if key == \.cropWidth { maximum = min(maximum, (1 - settings.cropY) * normalized) }
            if key == \.cropHeight { maximum = min(maximum, (1 - settings.cropX) / normalized) }
        }
        let upper = min(1, max(0, maximum)) * 100
        let minimum = key == \.cropWidth || key == \.cropHeight ? 1.0 : 0
        return min(minimum, upper)...upper
    }

    private func cropBinding(_ key: WritableKeyPath<GeometrySettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: key] * 100 }, set: { value in
            guard value.isFinite, cropRange(key).contains(value) else { return }
            var next = settings
            next[keyPath: key] = value / 100
            if let ratio = aspectRatio, canvasSize.width > 0 {
                let normalized = ratio * Double(canvasSize.height / canvasSize.width)
                if key == \.cropWidth { next.cropHeight = next.cropWidth / normalized }
                if key == \.cropHeight { next.cropWidth = next.cropHeight * normalized }
            }
            settings = next
        })
    }

    private func clampedBinding(_ key: WritableKeyPath<GeometrySettings, Double>, range: ClosedRange<Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { settings[keyPath: key] * scale }, set: { value in
            guard value.isFinite else { return }
            settings[keyPath: key] = min(range.upperBound, max(range.lowerBound, value / scale))
        })
    }
    private func decimalValue(_ value: Double) -> String { String(format: "%.1f", locale: L10n.locale, value) }
    private func cropValue(_ value: Double) -> String {
        let formatter = NumberFormatter(); formatter.locale = L10n.locale
        formatter.minimumFractionDigits = 0; formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }
    private var aspectMenu: some View {
        Menu {
            ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                Button { clearAspect(); aspectPreset = preset; fitAspect() } label: {
                    if lockedRatio == nil && aspectPreset == preset { Label(L10n.text(preset.titleKey), systemImage: "checkmark") }
                    else { Text(L10n.text(preset.titleKey)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(L10n.text(lockedRatio == nil ? aspectPreset.titleKey : "锁定当前比例")).font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.accessibilityLabel(L10n.text("画面比例"))
            .accessibilityValue(L10n.text(lockedRatio == nil ? aspectPreset.titleKey : "锁定当前比例"))
            .accessibilityIdentifier("geometry.aspectRatio")
    }
    private func clearAspect() { aspectPreset = .free; lockedRatio = nil; aspectSwapped = false }
    private func fitAspect() {
        let rect = CropInteraction.fitting(ratio: aspectRatio, in: canvasSize, around: CropInteraction.rect(from: settings))
        settings = CropInteraction.applying(rect: rect, to: settings)
    }
}
