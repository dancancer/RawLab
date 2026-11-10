import SwiftUI

extension ContentView {
    @ViewBuilder
    var valuePanel: some View {
        if geometrySelected {
            HStack(spacing: 0) {
                ForEach(0..<3) { tab in
                    Button {
                        cancelSliderInteraction(); geometryPerspective = tab == 2; geometryRotation = tab == 1
                    } label: {
                        Text(L10n.text(["裁切", "旋转", "透视"][tab])).font(.subheadline)
                            .foregroundStyle((geometryPerspective ? 2 : geometryRotation ? 1 : 0) == tab ? Color.yellow : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.plain).accessibilityIdentifier("geometry.tab.\(tab)")
                }
            }.padding(.horizontal, 16)
            IOSGeometryControls(settings: geometryDraftBinding, onEditingChanged: setSliderEditing,
                                    canvasSize: geometryEditingCanvasSize, aspectPreset: $geometryAspectPreset,
                                    lockedRatio: $geometryLockedRatio, aspectSwapped: $geometryAspectSwapped,
                                    showsGrid: $geometryGrid, perspective: geometryPerspective, rotation: geometryRotation)
            .padding(.horizontal, 16)
            .disabled(!viewModel.hasImage || editingLocked)
        } else if lensSelected {
            IOSLensControls(settings: lensDraftBinding, info: viewModel.lensInfo)
            .padding(.horizontal, 16)
            .disabled(!viewModel.hasImage || editingLocked || usesNormalX3f)
        } else if choosingMasterRecipe {
            masterRecipePanel
        } else if selectedAdjustment == .toneCurve {
            IOSToneCurveControls(settings: Binding(get: { workingSettings.editingCurveSettings }, set: { workingSettings.editingCurveSettings = $0 }),
                legacy: Binding(get: { AdjustmentKind.toneCurve.value(from: workingSettings) },
                                set: { AdjustmentKind.toneCurve.setValue($0, in: &workingSettings) }),
                usesExposureStops: workingSettings.isHDREditing, onEditingChanged: setSliderEditing, onCancelled: cancelSliderInteraction)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .colorGrading {
            IOSColorGradingControls(settings: Binding(get: { workingSettings.editingGradingSettings }, set: { workingSettings.editingGradingSettings = $0 }),
                zone: $gradingZone, onEditingChanged: setSliderEditing, onCancelled: cancelSliderInteraction)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .hsl {
            VStack(spacing: 8) {
                if hslTargetEnabled { HSLTargetControls(enabled: $hslTargetEnabled, axis: $hslTargetAxis,
                    sample: hslTargetInteraction.selection, waiting: hslTargetInteraction.isWaiting,
                    notice: hslTargetNotice, onCancel: cancelHSLTarget).padding(.horizontal, 16) }
                IOSHSLMixer(settings: Binding(get: { workingSettings.editingHSLSettings }, set: { workingSettings.editingHSLSettings = $0 }),
                    onEditingChanged: { editing in
                        if editing { cancelHSLTarget() }
                        setSliderEditing(editing)
                    }, channel: $hslChannel)
            }.disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .vignette || selectedAdjustment == .grain {
            IOSPhotoEffectsControls(effect: selectedAdjustment ?? .vignette, value: { parameter in
                Binding(get: { workingSettings.editingEffectValue(parameter) }, set: { workingSettings.setEditingEffect(parameter, to: $0) })
            }, onEditingChanged: setSliderEditing,
                onReset: { requestEditorReset(.tool(currentEditorTool)) },
                resetEnabled: resetModified(.tool(currentEditorTool)))
                .padding(.horizontal, 16)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .noiseReduction && !workingSettings.isHDREditing {
            IOSDenoiseControls(settings: Binding(
                get: { workingSettings.denoise },
                set: { workingSettings.denoise = $0; workingSettings.noiseReduction = 0 }
            ), onEditingChanged: setSliderEditing,
                onReset: { requestEditorReset(.tool(currentEditorTool)) },
                resetEnabled: resetModified(.tool(currentEditorTool)))
                .padding(.horizontal, 16)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if let adjustment = selectedAdjustment {
            if adjustment == .temperature || adjustment == .tint {
                whiteBalancePanel
                    .disabled(!viewModel.hasImage || editingLocked)
            } else {
                scalarAdjustmentPanel(adjustment)
            }
        } else if workingSettings.isHDREditing {
            HDRLookControls(settings: Binding(get: { workingSettings.hdr ?? HDRSettings() }, set: { workingSettings.hdr = $0 }),
                onEditingChanged: setSliderEditing, onCancelled: cancelSliderInteraction,
                onResourceRestored: { viewModel.retryPreview(settings: workingSettings) }).padding(.horizontal, 16)
        } else {
            filmPanel(imageSize: filmSize)
        }
    }

    var geometrySourceCanvasSize: CGSize {
        guard let buffer = viewModel.draftBuffer else { return .zero }
        return buffer.nativeSize ?? CGSize(width: buffer.width, height: buffer.height)
    }

    var geometryEditingCanvasSize: CGSize {
        viewModel.nativeImageSize ?? currentPreviewImage?.size ?? geometrySourceCanvasSize
    }

    var geometryDraftAspectRatio: Double? {
        if let geometryLockedRatio { return geometryAspectSwapped ? 1 / geometryLockedRatio : geometryLockedRatio }
        return geometryAspectPreset.ratio(for: geometryEditingCanvasSize, swapped: geometryAspectSwapped)
    }

    var editorDraftActions: some View {
        HStack(spacing: 8) {
            Button(action: cancelEditorDraft) { Image(systemName: "xmark").frame(width: 48, height: 48) }
                .accessibilityLabel(L10n.text("取消"))
                .accessibilityIdentifier("editor.draft.cancel")
            Text(currentEditorTool.title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            Button(action: applyEditorDraft) { Image(systemName: "checkmark").frame(width: 48, height: 48) }
                .accessibilityLabel(L10n.text("应用"))
                .disabled(viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || isAdjustingSlider || editorBusy)
                .accessibilityIdentifier("editor.draft.apply")
        }.buttonStyle(.plain)
    }

    func scalarAdjustmentPanel(_ adjustment: AdjustmentKind) -> some View {
        let hdrDenoise = adjustment == .noiseReduction
        let formatter: (Double) -> String = hdrDenoise
            ? { String(format: "%.0f", locale: L10n.locale, $0 * 100) }
            : adjustment.formatted
        return VStack(alignment: .leading, spacing: 8) {
            AdjustmentControl(title: adjustment.title, value: adjustmentBinding(adjustment),
                              range: workingSettings.isHDREditing && adjustment == .exposure ? -4...4 : adjustment.range, step: adjustment.step,
                              defaultValue: adjustment.value(from: .default),
                              unit: hdrDenoise ? "%" : adjustment.unit,
                              formatter: formatter,
                              reciprocal: adjustment == .temperature,
                              displayScale: adjustment == .strength || hdrDenoise ? 100 : 1,
                              identifier: "adjustment", onEditingChanged: setSliderEditing)
                .id(adjustment.rawValue)
            if adjustment == .exposure {
                exposureActions
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .disabled(!viewModel.hasImage || editingLocked || (adjustment == .strength && !workingSettings.hasLook))
    }

    private var exposureActions: some View {
        let layout = UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if viewModel.sourceKind == .raw && !workingSettings.isHDREditing {
                Menu {
                    Picker(L10n.text("曝光基准"), selection: workingSettingsBinding.exposureMode) {
                        ForEach(RawExposureMode.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(workingSettings.exposureMode.title)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(localizationLocale.identifier)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityLabel(L10n.text("曝光基准"))
                .accessibilityValue(workingSettings.exposureMode.title)
                .accessibilityIdentifier("exposure.mode")
                .disabled(usesNormalX3f)
            }
            Button(action: autoExposure) {
                Label(L10n.text("自动"), systemImage: "wand.and.stars")
                    .fixedSize()
            }
            .buttonStyle(EditorCompactActionStyle())
            .disabled(autoExposing || viewModel.isBusy)
            .accessibilityIdentifier("exposure.auto")
        }
    }

    var whiteBalancePanel: some View {
        let isRaster = viewModel.sourceKind == .raster && !workingSettings.isHDREditing
        return VStack(alignment: .leading, spacing: 12) {
            if workingSettings.isHDREditing { Text(L10n.text("相对白平衡")).font(.caption).foregroundStyle(.secondary) }
            if viewModel.sourceKind == .raw && !workingSettings.isHDREditing {
                Picker(L10n.text("白平衡"), selection: Binding(
                    get: { workingSettings.whiteBalanceMode }, set: { setWhiteBalanceMode($0) }
                )) {
                    Text(L10n.text("拍摄时设置")).tag(RawWhiteBalanceMode.camera)
                    Text(L10n.text("自定义")).tag(RawWhiteBalanceMode.custom)
                }
                .pickerStyle(.segmented)
                .id(localizationLocale.identifier)
                .frame(minHeight: 44)
                .disabled(viewModel.rawWhiteBalance == nil)
                .accessibilityIdentifier("whiteBalance.mode")
            }

            AdjustmentControl(title: L10n.text("色温"), value: whiteBalanceTemperatureBinding,
                              range: RawSettings.temperatureRange, step: 10,
                              defaultValue: whiteBalanceTemperatureDefault,
                              unit: "K", formatter: { String(format: "%.0f", locale: L10n.locale, $0) },
                              reciprocal: true, identifier: "whiteBalance.temperature",
                              onEditingChanged: setSliderEditing)
                .disabled(isRaster || (viewModel.sourceKind == .raw && viewModel.rawWhiteBalance == nil))
            AdjustmentControl(title: L10n.text(workingSettings.masterRecipeID == nil ? "色调" : "色调偏移"), value: whiteBalanceTintBinding,
                              range: RawSettings.tintRange, step: 1,
                              defaultValue: whiteBalanceTintDefault,
                              formatter: { String(format: $0 == 0 ? "%.0f" : "%+.0f", locale: L10n.locale, $0) },
                              identifier: "whiteBalance.tint", onEditingChanged: setSliderEditing)
                .disabled(isRaster || (viewModel.sourceKind == .raw && viewModel.rawWhiteBalance == nil) ||
                          (viewModel.sourceKind == .raw && workingSettings.whiteBalanceMode == .camera && workingSettings.masterRecipeID == nil))

            if let note = whiteBalanceNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(rulerFocusOpacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // 底部说明：RAW 缺少相机校准时提示；有校准时给出拍摄时数值作参照
    private var whiteBalanceNote: String? {
        guard viewModel.sourceKind == .raw && !workingSettings.isHDREditing else { return nil }
        guard let camera = viewModel.rawWhiteBalance else { return L10n.text("缺少有效相机校准，保留拍摄时白平衡") }
        return AdjustmentKind.asShotNote(for: workingSettings, cameraTemperature: camera.temperature, cameraTint: camera.tint)
    }

    private var whiteBalanceTemperatureBinding: Binding<Double> {
        let number = temperatureNumberBinding()
        return Binding(get: { number.wrappedValue }, set: { value in
            if value == whiteBalanceTemperatureDefault {
                reset(.temperature)
            } else {
                number.wrappedValue = value
            }
        })
    }

    private var whiteBalanceTemperatureDefault: Double {
        viewModel.rawWhiteBalance?.temperature ?? RawSettings.default.temperature
    }

    private var whiteBalanceTintDefault: Double {
        guard let whiteBalance = viewModel.rawWhiteBalance else { return 0 }
        return workingSettings.masterRecipeID == nil ? whiteBalance.tint : 0
    }

    private var whiteBalanceTintBinding: Binding<Double> {
        Binding(get: { displayedTint }, set: { value in
            guard value.isFinite else { return }
            if value == whiteBalanceTintDefault {
                reset(.tint)
                return
            }
            var updated = workingSettings
            AdjustmentKind.tint.setValue(min(max(value.rounded(),RawSettings.tintRange.lowerBound),RawSettings.tintRange.upperBound),in:&updated)
            if !workingSettings.isHDREditing, viewModel.sourceKind == .raw, updated.masterRecipeID == nil {
                updated.whiteBalanceMode = .custom
            }
            applySettingsChange(updated)
        })
    }
}
