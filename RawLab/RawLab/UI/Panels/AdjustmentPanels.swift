import RawLabKit
import SwiftUI

extension ContentView {
    @ViewBuilder
    var valuePanel: some View {
        if geometrySelected {
            HStack(spacing: 0) {
                ForEach(0..<3) { tab in
                    Button {
                        cancelSliderInteraction(); coordinator.geometryPerspective = tab == 2; coordinator.geometryRotation = tab == 1
                    } label: {
                        Text(L10n.text(["裁切", "旋转", "透视"][tab])).font(.subheadline)
                            .foregroundStyle((coordinator.geometryPerspective ? 2 : coordinator.geometryRotation ? 1 : 0) == tab ? Color.yellow : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.plain).accessibilityIdentifier("geometry.tab.\(tab)")
                }
            }.padding(.horizontal, 16)
            IOSGeometryControls(settings: geometryDraftBinding, onEditingChanged: setSliderEditing,
                                    canvasSize: geometryEditingCanvasSize, aspectPreset: $coordinator.geometryAspectPreset,
                                    lockedRatio: $coordinator.geometryLockedRatio, aspectSwapped: $coordinator.geometryAspectSwapped,
                                    showsGrid: $coordinator.geometryGrid, perspective: coordinator.geometryPerspective, rotation: coordinator.geometryRotation)
            .padding(.horizontal, 16)
            .disabled(geometryEditingCanvasSize == .zero || editingLocked)
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
                usesExposureStops: workingSettings.isHDREditing, onEditingChanged: setSliderEditing, onCancelled: cancelSliderInteraction,
                activeChannel: $coordinator.curveTargetChannel, targetEnabled: $coordinator.curveTargetEnabled,
                targetWaiting: coordinator.curveTargetInteraction.isWaiting, targetNotice: coordinator.curveTargetNotice,
                onCancelTarget: cancelCurveTarget)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .colorGrading {
            IOSColorGradingControls(settings: Binding(get: { workingSettings.editingGradingSettings }, set: { workingSettings.editingGradingSettings = $0 }),
                zone: $coordinator.gradingZone, globalSelected: $coordinator.gradingGlobalSelected,
                onEditingChanged: setSliderEditing, onCancelled: cancelSliderInteraction)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .hsl {
            VStack(spacing: 8) {
                if coordinator.hslTargetEnabled { HSLTargetControls(enabled: $coordinator.hslTargetEnabled, axis: $coordinator.hslTargetAxis,
                    sample: coordinator.hslTargetInteraction.selection, waiting: coordinator.hslTargetInteraction.isWaiting,
                    notice: coordinator.hslTargetNotice, onCancel: cancelHSLTarget).padding(.horizontal, 16) }
                IOSHSLMixer(settings: Binding(get: { workingSettings.editingHSLSettings }, set: { workingSettings.editingHSLSettings = $0 }),
                    onEditingChanged: { editing in
                        if editing { cancelHSLTarget() }
                        setSliderEditing(editing)
                    }, channel: $coordinator.hslChannel)
            }.disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .vignette || selectedAdjustment == .grain {
            IOSPhotoEffectsControls(effect: selectedAdjustment ?? .vignette, value: { parameter in
                Binding(get: { workingSettings.editingEffectValue(parameter) }, set: { workingSettings.setEditingEffect(parameter, to: $0) })
            }, onEditingChanged: setSliderEditing)
                .padding(.horizontal, 16)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .noiseReduction && !workingSettings.isHDREditing {
            IOSDenoiseControls(settings: Binding(
                get: { workingSettings.denoise },
                set: { workingSettings.denoise = $0 }
            ), onEditingChanged: setSliderEditing)
                .padding(.horizontal, 16)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if let hdrTool = selectedHDRRenditionTool, let keyPath = hdrTool.hdrRenditionKeyPath {
            hdrRenditionPanel(hdrTool, keyPath: keyPath)
        } else if let adjustment = selectedAdjustment {
            if adjustment == .temperature || adjustment == .tint {
                whiteBalancePanel
                    .disabled(!viewModel.hasImage || editingLocked)
            } else if adjustment == .sharpening && !workingSettings.isHDREditing {
                sharpeningV2Panel
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

    var geometryEditingCanvasSize: CGSize {
        currentPreviewImage.flatMap { geometryProjection(for: $0)?.safeSize } ?? .zero
    }

    var geometryDraftAspectRatio: Double? {
        if let locked = coordinator.geometryLockedRatio { return coordinator.geometryAspectSwapped ? 1 / locked : locked }
        return coordinator.geometryAspectPreset.ratio(for: geometryEditingCanvasSize, swapped: coordinator.geometryAspectSwapped)
    }

    var editorDraftActions: some View {
        let changed = isEditorDraftChanged
        let title = settings.isHDREditing && currentEditorTool == .film ? L10n.text("外观") : currentEditorTool.title
        return HStack(spacing: 8) {
            Button(action: cancelEditorDraft) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
                .accessibilityLabel(L10n.text("取消"))
                .accessibilityIdentifier("editor.draft.cancel")
            Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            Button(action: applyEditorDraft) {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: changed ? .semibold : .regular))
                    .foregroundStyle(changed ? Color.yellow : Color.secondary)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
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

    func hdrRenditionPanel(_ tool: EditorToolSelection, keyPath: WritableKeyPath<HDRRenditionSettings, Double>) -> some View {
        let isEV = tool == .hdrPeakLimit || tool == .hdrSDRExposure
        let range: ClosedRange<Double> = tool == .hdrPeakLimit ? 0...6 : (isEV ? -4...4 : -100...100)
        let step = isEV ? 0.1 : 1.0
        let formatter: (Double) -> String = { value in
            let number = value == 0 ? 0 : value
            return String(format: (number != 0 ? "%+" : "%") + (isEV ? ".1f" : ".0f"), locale: L10n.locale, number)
        }
        return VStack(alignment: .leading, spacing: 8) {
            AdjustmentControl(title: tool.title,
                              value: Binding(
                                get: { workingSettings.hdr?.renditionSettings[keyPath: keyPath] ?? 0 },
                                set: { newValue in
                                    guard workingSettings.isHDREditing, var state = workingSettings.hdr, newValue.isFinite else { return }
                                    state.renditionSettings[keyPath: keyPath] = newValue
                                    guard state.isValid else { return }
                                    workingSettings.hdr = state
                                }
                              ),
                              range: range, step: step, defaultValue: 0,
                              unit: isEV ? "EV" : "%", formatter: formatter,
                              reciprocal: false, displayScale: 1,
                              identifier: "adjustment", onEditingChanged: setSliderEditing)
                .id(tool.stableID)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .disabled(!viewModel.hasImage || editingLocked || !workingSettings.isHDREditing)
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
            .disabled(coordinator.autoExposing || viewModel.isBusy)
            .accessibilityIdentifier("exposure.auto")
        }
    }

    var sharpeningV2Panel: some View {
        let v2 = workingSettings.sharpenV2Settings
        return VStack(alignment: .leading, spacing: 10) {
            AdjustmentControl(
                title: AdjustmentKind.sharpening.title,
                value: Binding(
                    get: { workingSettings.sharpening },
                    set: { newValue in
                        var next = workingSettings
                        next.applySharpenV2Edit(amount: newValue)
                        applySettingsChange(next)
                    }
                ),
                range: AdjustmentKind.sharpening.range,
                step: AdjustmentKind.sharpening.step,
                defaultValue: 0,
                unit: AdjustmentKind.sharpening.unit,
                formatter: AdjustmentKind.sharpening.formatted,
                identifier: "adjustment.sharpening",
                onEditingChanged: setSliderEditing
            )
            Toggle(L10n.text("明度锐化"), isOn: Binding(
                get: { v2.luminanceV2 },
                set: { enabled in
                    var next = workingSettings
                    next.applySharpenV2Edit(luminanceV2: enabled)
                    applySettingsChange(next)
                }
            ))
            .frame(minHeight: 44)
            .accessibilityIdentifier("sharpening.luminanceV2")
            Group {
                AdjustmentControl(
                    title: L10n.text("锐化半径"),
                    value: Binding(
                        get: { workingSettings.sharpenV2Settings.radius },
                        set: { value in
                            var next = workingSettings
                            next.applySharpenV2Edit(radius: value)
                            applySettingsChange(next)
                            viewModel.updateSharpenMaskPreviewIfNeeded(
                                radius: next.sharpenV2Settings.radius,
                                masking: next.sharpenV2Settings.masking
                            )
                        }
                    ),
                    range: SharpenV2Settings.radiusRange,
                    step: 0.05,
                    defaultValue: 1.0,
                    formatter: { String(format: "%.2f", locale: L10n.locale, $0) },
                    identifier: "adjustment.sharpeningRadius",
                    onEditingChanged: setSliderEditing
                )
                AdjustmentControl(
                    title: L10n.text("锐化细节"),
                    value: Binding(
                        get: { workingSettings.sharpenV2Settings.detail },
                        set: { value in
                            var next = workingSettings
                            next.applySharpenV2Edit(detail: value)
                            applySettingsChange(next)
                        }
                    ),
                    range: SharpenV2Settings.detailRange,
                    step: 1,
                    defaultValue: 25,
                    formatter: { String(format: "%.0f", locale: L10n.locale, $0) },
                    identifier: "adjustment.sharpeningDetail",
                    onEditingChanged: setSliderEditing
                )
                AdjustmentControl(
                    title: L10n.text("锐化蒙版"),
                    value: Binding(
                        get: { workingSettings.sharpenV2Settings.masking },
                        set: { value in
                            var next = workingSettings
                            next.applySharpenV2Edit(masking: value)
                            applySettingsChange(next)
                            viewModel.updateSharpenMaskPreviewIfNeeded(
                                radius: next.sharpenV2Settings.radius,
                                masking: next.sharpenV2Settings.masking
                            )
                        }
                    ),
                    range: SharpenV2Settings.maskingRange,
                    step: 1,
                    defaultValue: 0,
                    formatter: { String(format: "%.0f", locale: L10n.locale, $0) },
                    identifier: "adjustment.sharpeningMasking",
                    onEditingChanged: { editing in
                        setSliderEditing(editing)
                        if !editing { viewModel.setSharpenMaskPreview(false, settings: workingSettings) }
                    }
                )
            }
            .environment(\.compactAdjustmentRows, true)
            Text(L10n.text("边缘蒙版预览"))
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(viewModel.sharpenMaskPreviewActive ? Color.yellow.opacity(0.25) : Color(.secondarySystemFill))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(viewModel.sharpenMaskPreviewActive ? Color.yellow : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !viewModel.sharpenMaskPreviewActive {
                                viewModel.setSharpenMaskPreview(true, settings: workingSettings)
                            }
                        }
                        .onEnded { _ in
                            viewModel.setSharpenMaskPreview(false, settings: workingSettings)
                        }
                )
                .accessibilityIdentifier("sharpening.maskPreview")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .onDisappear { viewModel.setSharpenMaskPreview(false, settings: workingSettings) }
    }

    var whiteBalancePanel: some View {
        let isRaster = viewModel.sourceKind == .raster && !workingSettings.isHDREditing
        let rasterRecipeLocked = isRaster && workingSettings.masterRecipeID != nil
        let canUseEyedropper = !workingSettings.isHDREditing &&
            ((isRaster && !rasterRecipeLocked) || (viewModel.sourceKind == .raw && viewModel.rawWhiteBalance != nil))
        return VStack(alignment: .leading, spacing: 12) {
            if workingSettings.isHDREditing || isRaster {
                Text(L10n.text("相对白平衡")).font(.caption).foregroundStyle(.secondary)
            }
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

            if !workingSettings.isHDREditing {
                Button {
                    coordinator.wbProbeNotice = nil
                    coordinator.wbEyedropperEnabled.toggle()
                } label: {
                    Label(L10n.text("白平衡吸管"), systemImage: "eyedropper")
                }
                .buttonStyle(.bordered)
                .tint(coordinator.wbEyedropperEnabled ? .yellow : .secondary)
                .disabled(!canUseEyedropper || viewModel.isBusy)
                .accessibilityIdentifier("wb.eyedropper")
                .accessibilityValue(L10n.text(coordinator.wbEyedropperEnabled ? "开启" : "关闭"))

                if let noticeText = wbProbeNoticeText {
                    Text(noticeText).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wb.eyedropper.status")
                }
            }

            AdjustmentControl(title: L10n.text("色温"), value: whiteBalanceTemperatureBinding,
                              range: RawSettings.temperatureRange, step: 10,
                              defaultValue: whiteBalanceTemperatureDefault,
                              unit: "K", formatter: { String(format: "%.0f", locale: L10n.locale, $0) },
                              reciprocal: true, identifier: "whiteBalance.temperature",
                              onEditingChanged: setSliderEditing)
                .disabled((viewModel.sourceKind == .raw && viewModel.rawWhiteBalance == nil) || rasterRecipeLocked)
            AdjustmentControl(title: L10n.text(workingSettings.masterRecipeID == nil ? "色调" : "色调偏移"), value: whiteBalanceTintBinding,
                              range: RawSettings.tintRange, step: 1,
                              defaultValue: whiteBalanceTintDefault,
                              formatter: { String(format: $0 == 0 ? "%.0f" : "%+.0f", locale: L10n.locale, $0) },
                              identifier: "whiteBalance.tint", onEditingChanged: setSliderEditing)
                .disabled((viewModel.sourceKind == .raw && viewModel.rawWhiteBalance == nil) ||
                          (viewModel.sourceKind == .raw && workingSettings.whiteBalanceMode == .camera && workingSettings.masterRecipeID == nil) ||
                          rasterRecipeLocked)

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

    private var wbProbeNoticeText: String? {
        if coordinator.wbProbeSampling { return L10n.text("正在取色…") }
        switch coordinator.wbProbeNotice {
        case .overexposed: return L10n.text("此像素不可取样。")
        case .outside: return L10n.text("请在调整后的照片区域取色。")
        case .stale: return L10n.text("预览已变化，请重新取色。")
        case .unavailable, .failed: return L10n.text("取色失败，请重试。")
        case nil: return nil
        }
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
