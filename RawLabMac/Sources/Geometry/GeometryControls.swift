import AppKit
import SwiftUI

struct GeometryControls: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    var tab: MacGeometryTab = .crop
    @State private var showsPreciseCrop = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var textSize: CGFloat { ParameterRow.textSize(for: dynamicTypeSize) }

    private var settings: GeometrySettings { model.geometryDraftSettings }

    init(model: EditorModel, tab: MacGeometryTab = .crop, showsPreciseCrop: Bool = false) {
        self.model = model
        self.tab = tab
        _showsPreciseCrop = State(initialValue: showsPreciseCrop)
    }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 8) {
            if tab == .perspective {
                ForEach([GeometryParameter.perspectiveHorizontal, .perspectiveVertical]) { parameter in
                    parameterRow(parameter)
                }
            } else {
                cropControls
            }
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    private var cropControls: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { aspectControls; transformControls; gridControl }
                VStack(alignment: .leading, spacing: 6) {
                    aspectControls
                    HStack(spacing: 14) { transformControls; gridControl }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            parameterRow(.straightenDegrees)
            DisclosureGroup(isExpanded: Binding(get: { showsPreciseCrop }, set: { expanded in
                if !expanded && !ParameterValueField.commitPendingInputs() { return }
                showsPreciseCrop = expanded
            })) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16)], spacing: 8) {
                    ForEach([GeometryParameter.cropX, .cropY, .cropWidth, .cropHeight]) { parameter in
                        CropDimensionField(model: model, parameter: parameter)
                            .disabled(!model.geometryDraftPreviewReady)
                    }
                }.padding(.top, 6)
            } label: {
                Text(L10n.text("位置与尺寸")).font(.system(size: textSize))
                    .accessibilityIdentifier("geometry.preciseCrop")
            }
        }
    }

    private var aspectControls: some View {
        HStack(spacing: 6) {
            Picker(L10n.text("画面比例"), selection: Binding(get: {
                model.cropLockedRatio == nil ? model.cropAspectPreset.rawValue : "current"
            }, set: { raw in
                guard commitFocusedInput(), let preset = CropAspectPreset(rawValue: raw) else { return }
                model.selectCropAspect(preset)
            })) {
                if model.cropLockedRatio != nil { Text(L10n.text("锁定当前比例")).tag("current") }
                ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                    Text(L10n.text(preset.titleKey)).tag(preset.rawValue)
                }
            }.labelsHidden().controlSize(.small).frame(minWidth: 100, maxWidth: 200)
                .accessibilityLabel(L10n.text("画面比例")).accessibilityIdentifier("geometry.cropAspect")
            Button {
                guard commitFocusedInput() else { return }
                model.toggleCropAspectLock()
            } label: { Image(systemName: model.cropAspectRatio == nil ? "lock.open" : "lock").frame(width: 28, height: 28) }
                .buttonStyle(.borderless).help(L10n.text("锁定当前比例"))
                .accessibilityLabel(L10n.text("锁定当前比例"))
                .accessibilityValue(L10n.text(model.cropAspectRatio == nil ? "已停用" : "已启用"))
                .accessibilityIdentifier("geometry.lockCropAspect")
            Button {
                guard commitFocusedInput() else { return }
                model.swapCropAspect()
            } label: { Image(systemName: "arrow.left.arrow.right").frame(width: 28, height: 28) }
                .buttonStyle(.borderless).disabled(model.cropAspectRatio == nil || model.cropAspectRatio == 1)
                .help(L10n.text("交换横纵比例"))
                .accessibilityLabel(L10n.text("交换横纵比例"))
                .accessibilityIdentifier("geometry.swapCropAspect")
        }.disabled(!model.geometryDraftPreviewReady)
    }

    private var transformControls: some View {
        HStack(spacing: 6) {
            rotationButton(clockwise: false); rotationButton(clockwise: true)
            flipButton(horizontal: true); flipButton(horizontal: false)
        }
    }

    private var gridControl: some View {
        Toggle(isOn: $model.cropGridEnabled) {
            Label(L10n.text("三分网格"), systemImage: "grid")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
        .help(L10n.text("显示裁剪三分网格"))
        .accessibilityIdentifier("geometry.cropGrid")
    }

    private func rotationButton(clockwise: Bool) -> some View {
        let title = L10n.text(clockwise ? "向右旋转 90°" : "向左旋转 90°")
        return Button {
            guard commitFocusedInput() else { return }
            model.updateGeometryDraft { $0.quarterTurns = ($0.quarterTurns + (clockwise ? 1 : 3)) % 4 }
        } label: {
            Image(systemName: clockwise ? "rotate.right" : "rotate.left").frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
        .accessibilityIdentifier(clockwise ? "geometry.rotateRight" : "geometry.rotateLeft")
        .accessibilityValue(String(format: "%d°", settings.quarterTurns * 90))
    }

    private func flipButton(horizontal: Bool) -> some View {
        let title = L10n.text(horizontal ? "水平翻转" : "垂直翻转")
        let enabled = horizontal ? settings.flipHorizontal : settings.flipVertical
        return Button {
            guard commitFocusedInput() else { return }
            model.updateGeometryDraft {
                if horizontal { $0.flipHorizontal.toggle() } else { $0.flipVertical.toggle() }
            }
        } label: {
            Image(systemName: horizontal ? "arrow.left.and.right.righttriangle.left.righttriangle.right" :
                  "arrow.up.and.down.righttriangle.up.righttriangle.down")
                .frame(width: 28, height: 28)
                .foregroundStyle(enabled ? .yellow : .primary)
                .overlay { if enabled { RoundedRectangle(cornerRadius: 4).stroke(.yellow, lineWidth: 1) } }
        }
        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
        .accessibilityValue(enabled ? L10n.text("已启用") : L10n.text("已停用"))
        .accessibilityIdentifier(horizontal ? "geometry.flipHorizontal" : "geometry.flipVertical")
    }

    private func value(_ parameter: GeometryParameter) -> Binding<Double> {
        Binding(get: { settings[keyPath: parameter.keyPath] * parameter.multiplier }, set: { displayedValue in
            model.setGeometryDraftParameter(parameter, to: displayedValue / parameter.multiplier)
        })
    }

    private func parameterRow(_ parameter: GeometryParameter) -> some View {
        let range = parameter.range(for: settings)
        let identifier = "geometry.value.\(parameter.rawValue)"
        return ParameterRow(title: parameter.title, value: value(parameter),
                            range: (range.lowerBound * parameter.multiplier)...(range.upperBound * parameter.multiplier),
                            defaultValue: parameter.defaultValue * parameter.multiplier, unit: parameter.unit,
                            identifier: identifier, onEditingChanged: model.setInteracting,
                            invalidInputPolicy: .retain,
                            onValidityChange: { model.setGeometryDraftInputValidity(identifier: identifier, isValid: $0) },
                            externalResetRevision: model.geometryDraftRevision)
    }

    private func commitFocusedInput() -> Bool { ParameterValueField.commitPendingInputs() }
}

private struct CropDimensionField: View {
    @ObservedObject var model: EditorModel
    let parameter: GeometryParameter
    @State private var error: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var settings: GeometrySettings { model.geometryDraftSettings }
    private var identifier: String { "geometry.value.\(parameter.rawValue)" }
    private var value: Binding<Double> {
        Binding(get: { settings[keyPath: parameter.keyPath] * 100 }, set: {
            model.setGeometryDraftParameter(parameter, to: $0 / 100)
        })
    }
    private func reset() {
        guard model.geometryDraftParameterRange(parameter).contains(parameter.defaultValue) else { return }
        ParameterValueField.cancelPendingInputs()
        model.setGeometryDraftParameter(parameter, to: parameter.defaultValue)
        model.geometryDraftRevision &+= 1
    }
    var body: some View {
        let range = model.geometryDraftParameterRange(parameter)
        let size = ParameterRow.textSize(for: dynamicTypeSize)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(parameter.title).font(.system(size: size)).fixedSize(horizontal: false, vertical: true)
                    .modifier(ParameterResetGesture(action: reset))
                Spacer(minLength: 0)
                ParameterValueField(value: value, range: (range.lowerBound * 100)...(range.upperBound * 100),
                    precision: .cropPercent, title: parameter.title, unit: "%", identifier: identifier,
                    defaultValue: parameter.defaultValue * 100, fontSize: size,
                    onValidationMessage: { error = $0 }, resetRevision: model.geometryDraftRevision,
                    onEditingChanged: model.setInteracting, invalidInputPolicy: .retain,
                    onValidityChange: { model.setGeometryDraftInputValidity(identifier: identifier, isValid: $0) })
                    .frame(width: max(72, size * 5), height: max(28, size + 13))
                Text("%").font(.system(size: size)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            if let error { Text(error).font(.system(size: size)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }.contextMenu {
            Button(L10n.format("重置%@", parameter.title), action: reset)
                .disabled(!range.contains(parameter.defaultValue))
        }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(parameter.title)
            .accessibilityValue(ParameterPrecision.cropPercent.text(value.wrappedValue) + "%")
            .accessibilityIdentifier("geometry.adjustment.\(parameter.rawValue)")
            .accessibilityAdjustableAction { direction in
                guard ParameterValueField.commitPendingInputs() else { return }
                let step: Int
                switch direction {
                case .increment: step = 1
                case .decrement: step = -1
                @unknown default: return
                }
                value.wrappedValue = ParameterPrecision.cropPercent.stepped(value.wrappedValue,
                    direction: step, fine: true, in: (range.lowerBound * 100)...(range.upperBound * 100))
            }
            .accessibilityAction(named: L10n.format("重置%@", parameter.title), reset)
    }
}
