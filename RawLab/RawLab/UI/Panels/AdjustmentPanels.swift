import SwiftUI

extension ContentView {
    @ViewBuilder
    var valuePanel: some View {
        if geometrySelected {
            IOSGeometryControls(settings: geometryDraftBinding, onEditingChanged: setSliderEditing,
                                    canvasSize: geometryEditingCanvasSize, aspectPreset: $geometryAspectPreset,
                                    lockedRatio: $geometryLockedRatio, aspectSwapped: $geometryAspectSwapped,
                                    showsGrid: $geometryGrid, perspective: geometryPerspective)
            .padding(.horizontal, 16)
            .disabled(!viewModel.hasImage || editingLocked)
        } else if lensSelected {
            IOSLensControls(settings: lensDraftBinding, info: viewModel.lensInfo)
            .padding(.horizontal, 16)
            .disabled(!viewModel.hasImage || editingLocked || viewModel.sourceKind != .raw)
        } else if choosingMasterRecipe {
            masterRecipePanel
        } else if selectedAdjustment == .toneCurve {
            IOSToneCurveControls(settings: Binding(get: { settings.curveSettings }, set: { settings.curveSettings = $0 }),
                legacy: $settings.toneCurve, onEditingChanged: setSliderEditing, onCancelled: cancelSliderInteraction)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .colorGrading {
            IOSColorGradingControls(settings: Binding(get: { settings.gradingSettings }, set: { settings.gradingSettings = $0 }),
                zone: $gradingZone, onEditingChanged: setSliderEditing, onCancelled: cancelSliderInteraction)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .hsl {
            VStack(spacing: 8) {
                HSLTargetControls(enabled: $hslTargetEnabled, axis: $hslTargetAxis,
                    sample: hslTargetInteraction.selection, waiting: hslTargetInteraction.isWaiting,
                    notice: hslTargetNotice, onCancel: cancelHSLTarget).padding(.horizontal, 16)
                IOSHSLMixer(settings: Binding(get: { settings.hsl }, set: { settings.hsl = $0 }),
                    onEditingChanged: { editing in
                        if editing { cancelHSLTarget() }
                        setSliderEditing(editing)
                    }, channel: $hslChannel)
            }.disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .vignette || selectedAdjustment == .grain {
            IOSPhotoEffectsControls(effect: selectedAdjustment ?? .vignette, settings: Binding(
                get: { settings.photoEffects }, set: { settings.photoEffects = $0 }
            ), onEditingChanged: setSliderEditing,
                onReset: { requestEditorReset(.tool(currentEditorTool)) },
                resetEnabled: resetModified(.tool(currentEditorTool)))
                .padding(.horizontal, 16)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .noiseReduction {
            IOSDenoiseControls(settings: Binding(
                get: { settings.denoise },
                set: { settings.denoise = $0; settings.noiseReduction = 0 }
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
        HStack(spacing: 12) {
            Button(action: cancelEditorDraft) {
                Text(L10n.text("取消")).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("editor.draft.cancel")
            Button(action: applyEditorDraft) {
                Text(L10n.text("应用")).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
                .disabled(!isEditorDraftChanged || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || isAdjustingSlider)
                .accessibilityIdentifier("editor.draft.apply")
        }
    }

    func scalarAdjustmentPanel(_ adjustment: AdjustmentKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AdjustmentControl(title: adjustment.title, value: adjustmentBinding(adjustment),
                              range: adjustment.range, step: adjustment.step,
                              defaultValue: adjustment.value(from: .default),
                              unit: adjustment.unit,
                              formatter: adjustment.formatted,
                              reciprocal: adjustment == .temperature, displayScale: adjustment == .strength ? 100 : 1,
                              identifier: "adjustment", onEditingChanged: setSliderEditing)
                .id(adjustment.rawValue)
            if adjustment == .exposure {
                exposureActions
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .disabled(!viewModel.hasImage || editingLocked || (adjustment == .strength && !settings.hasLook))
    }

    private var exposureActions: some View {
        let layout = UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if viewModel.sourceKind == .raw {
                Menu {
                    Picker(L10n.text("曝光基准"), selection: $settings.exposureMode) {
                        ForEach(RawExposureMode.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(settings.exposureMode.title)
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
                .accessibilityValue(settings.exposureMode.title)
                .accessibilityIdentifier("exposure.mode")
            }
            Button(action: autoExposure) {
                Label(L10n.text("自动"), systemImage: "wand.and.stars")
                    .fixedSize()
            }
            .buttonStyle(EditorCompactActionStyle())
            .disabled(autoExposing || viewModel.isBusy || settings.isHDREditing)
            .accessibilityIdentifier("exposure.auto")
        }
    }

    var whiteBalancePanel: some View {
        let isRaster = viewModel.sourceKind == .raster && !settings.isHDREditing
        return VStack(alignment: .leading, spacing: 12) {
            if settings.isHDREditing { Text(L10n.text("相对白平衡")).font(.caption).foregroundStyle(.secondary) }
            if viewModel.sourceKind == .raw {
                Picker(L10n.text("白平衡"), selection: Binding(
                    get: { settings.whiteBalanceMode }, set: { setWhiteBalanceMode($0) }
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
            AdjustmentControl(title: L10n.text(settings.masterRecipeID == nil ? "色调" : "色调偏移"), value: whiteBalanceTintBinding,
                              range: RawSettings.tintRange, step: 1,
                              defaultValue: whiteBalanceTintDefault,
                              formatter: { String(format: $0 == 0 ? "%.0f" : "%+.0f", locale: L10n.locale, $0) },
                              identifier: "whiteBalance.tint", onEditingChanged: setSliderEditing)
                .disabled(isRaster || (viewModel.sourceKind == .raw && viewModel.rawWhiteBalance == nil) ||
                          (viewModel.sourceKind == .raw && settings.whiteBalanceMode == .camera && settings.masterRecipeID == nil))

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
        guard viewModel.sourceKind == .raw else { return nil }
        guard let camera = viewModel.rawWhiteBalance else { return L10n.text("缺少有效相机校准，保留拍摄时白平衡") }
        return AdjustmentKind.asShotNote(for: settings, cameraTemperature: camera.temperature, cameraTint: camera.tint)
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
        return settings.masterRecipeID == nil ? whiteBalance.tint : 0
    }

    private var whiteBalanceTintBinding: Binding<Double> {
        Binding(get: { displayedTint }, set: { value in
            guard value.isFinite else { return }
            if value == whiteBalanceTintDefault {
                reset(.tint)
                return
            }
            var updated = settings
            AdjustmentKind.tint.setValue(min(max(value.rounded(),RawSettings.tintRange.lowerBound),RawSettings.tintRange.upperBound),in:&updated)
            if viewModel.sourceKind == .raw, updated.masterRecipeID == nil { updated.whiteBalanceMode = .custom }
            applySettingsChange(updated)
        })
    }
}
