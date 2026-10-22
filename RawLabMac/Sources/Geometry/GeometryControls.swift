import AppKit
import SwiftUI

struct GeometryControls: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    var tab: MacGeometryTab = .crop
    @State private var showsPreciseCrop = false
    @State private var rotationResetRevision = 0
    @State private var rotationValidationMessage: String?
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
            HStack(alignment: .center, spacing: 16) {
                aspectControls.frame(width: 160)
                rotationControls.frame(minWidth: 220, maxWidth: .infinity)
                gridControl.frame(width: 120, alignment: .leading)
            }
            DisclosureGroup(isExpanded: Binding(get: { showsPreciseCrop }, set: { expanded in
                if !expanded { ParameterValueField.cancelPendingInputs() }
                showsPreciseCrop = expanded
            })) {
                VStack(spacing: 0) {
                    ForEach([GeometryParameter.cropX, .cropY, .cropWidth, .cropHeight]) { parameter in
                        parameterRow(parameter).disabled(!model.geometryDraftPreviewReady)
                    }
                }.padding(.top, 4)
            } label: {
                Text(L10n.text("精确调整")).font(.system(size: 13))
                    .accessibilityIdentifier("geometry.preciseCrop")
            }
        }
    }

    private var aspectControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("画面比例")).font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Picker(L10n.text("画面比例"), selection: Binding(get: { model.cropAspectPreset }, set: {
                    commitFocusedInput()
                    model.selectCropAspect($0)
                })) {
                    ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                        Text(L10n.text(preset.titleKey)).tag(preset)
                    }
                }
                .labelsHidden().controlSize(.small)
                .accessibilityLabel(L10n.text("画面比例"))
                .accessibilityIdentifier("geometry.cropAspect")
                Button {
                    commitFocusedInput()
                    model.swapCropAspect()
                } label: {
                    Image(systemName: "arrow.left.arrow.right").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(model.cropAspectPreset == .free || model.cropAspectPreset == .square)
                .help(L10n.text("交换横纵比例"))
                .accessibilityLabel(L10n.text("交换横纵比例"))
                .accessibilityIdentifier("geometry.swapCropAspect")
            }.disabled(!model.geometryDraftPreviewReady)
            HStack(spacing: 8) {
                flipButton(horizontal: true)
                flipButton(horizontal: false)
                rotationButton(clockwise: false)
                rotationButton(clockwise: true)
            }
        }
    }

    private var rotationControls: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(GeometryParameter.straightenDegrees.title).font(.system(size: textSize))
                    .modifier(ParameterResetGesture(action: resetRotation))
                ParameterValueField(value: value(.straightenDegrees), range: -45...45,
                                    precision: .standard, title: GeometryParameter.straightenDegrees.title,
                                    unit: "°", identifier: "geometry.value.straightenDegrees",
                                    defaultValue: 0, fontSize: textSize,
                                    onValidationMessage: { rotationValidationMessage = $0 },
                                    resetRevision: model.geometryDraftRevision &+ rotationResetRevision,
                                    onEditingChanged: model.setInteracting,
                                    invalidInputPolicy: .retain,
                                    onValidityChange: { model.setGeometryDraftInputValidity(identifier: "geometry.value.straightenDegrees", isValid: $0) })
                    .frame(minWidth: 72, minHeight: max(26, textSize + 13))
                Text("°").font(.system(size: 13)).foregroundStyle(.secondary).accessibilityHidden(true)

            }
            MacRotationRuler(value: value(.straightenDegrees), onEditingChanged: model.setInteracting)
                .frame(height: 52)
                .modifier(ParameterResetGesture(action: resetRotation))
                .accessibilityAction(named: L10n.format("重置%@", GeometryParameter.straightenDegrees.title), resetRotation)
            if let rotationValidationMessage {
                Text(rotationValidationMessage).font(.system(size: textSize)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.contextMenu { Button(L10n.format("重置%@", GeometryParameter.straightenDegrees.title), action: resetRotation) }
    }

    private func resetRotation() {
        ParameterValueField.cancelPendingInputs()
        model.setGeometryDraftParameter(.straightenDegrees, to: 0)
        rotationResetRevision += 1
        model.setGeometryDraftInputValidity(identifier: "geometry.value.straightenDegrees", isValid: true)
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
            commitFocusedInput()
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
            commitFocusedInput()
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

    private func commitFocusedInput() { NSApp.keyWindow?.makeFirstResponder(nil) }
}
