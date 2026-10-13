import PhotosUI
import SwiftUI

extension ContentView {
    @ToolbarContentBuilder
    var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            photoImportButton(isEnabled: !editorBusy)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker(L10n.text("语言"), selection: $languagePreference) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0.rawValue) }
                }
                .id(localizationLocale.identifier)
            } label: { Image(systemName: "globe") }
                .accessibilityLabel(L10n.text("语言"))
                .accessibilityIdentifier("settings.language")
            Button { showingBefore.toggle() } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(!viewModel.hasImage ? Color.secondary : showingBefore ? .yellow : .primary)
            }
            .accessibilityLabel(L10n.text("前后对比"))
            .accessibilityValue(showingBefore ? L10n.text("调整前") : L10n.text("调整后"))
            .help(L10n.text("切换调整前后"))
            .disabled(!viewModel.hasImage)
            .accessibilityIdentifier("editor.compare")

            Button { adjustmentsExpanded.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(!viewModel.hasImage ? Color.secondary : adjustmentsExpanded ? .yellow : .primary)
            }
            .accessibilityLabel(!viewModel.hasImage ? L10n.text("调整") : adjustmentsExpanded ? L10n.text("收起调整栏") : L10n.text("展开调整栏"))
            .help(L10n.text("显示或收起调整栏"))
            .disabled(!viewModel.hasImage)
            .accessibilityIdentifier("editor.adjustments")

            Menu {
                Button(L10n.text("保存当前照片")) {
                    singleExportFormat = .jpeg
                    exportLongEdge = nil
                    showingExportSize = true
                }
                .disabled(!viewModel.hasImage || editorBusy || viewModel.previewRendering || viewModel.previewResizePending || !viewModel.isLookAvailable(for: settings))
                Button(L10n.text("导出渲染型 DNG…")) {
                    singleExportFormat = .renderedDNG
                    exportLongEdge = nil
                    showingExportSize = true
                }
                .disabled(!viewModel.hasImage || editorBusy || viewModel.previewRendering || viewModel.previewResizePending || !viewModel.isLookAvailable(for: settings))
                Button(L10n.text("使用当前调整批量导出…"), action: openBatchExport)
                    .disabled(viewModel.sourceKind != .raw || !viewModel.hasImage || editorBusy || viewModel.previewRendering || viewModel.previewResizePending || !viewModel.isLookAvailable(for: settings))
                    .accessibilityIdentifier("editor.batchExport")
                if batchModel != nil { Button(L10n.text("查看批量任务")) { showingBatchExport = true } }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel(L10n.text("导出"))
            .help(L10n.text("导出照片"))
            .disabled((!viewModel.hasImage || editorBusy) && batchModel == nil)
            .accessibilityIdentifier("editor.export")
        }
    }

    var previewSection: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.12)
                if let image = currentPreviewImage {
                    ZoomablePhoto(image: image, referenceImage: viewModel.basePreviewImage ?? image,
                                  label: showingBefore ? L10n.text("调整前的照片") : L10n.text("调整后的照片"),
                                  onPreviewSizeChange: { viewModel.updatePreviewSize($0, settings: settings) })
                        .id(viewModel.basePreviewImage)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(L10n.text("RAW 照片")).font(.title2.weight(.semibold))
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                                Label {
                                    Text(L10n.text("导入照片"))
                                } icon: {
                                    Image(systemName: "photo.badge.plus").accessibilityHidden(true)
                                }
                                    .font(.headline)
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(.black)
                            .disabled(editorBusy)
                            .accessibilityLabel(L10n.text("导入照片"))
                            .accessibilityIdentifier("editor.import.empty")
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                    }
                    .opacity(editorBusy ? 0 : 1)
                    .accessibilityHidden(editorBusy)
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.hasImage {
                    FloatingHistogram(values: currentHistogram, expanded: $histogramExpanded)
                        .frame(maxWidth: min(180, geometry.size.width * 0.48), alignment: .trailing)
                        .padding(12)
                }
            }
            .overlay(alignment: .topLeading) {
                photoInfoOverlay(maxWidth: min(
                    360,
                    min(
                        geometry.size.width * 0.38,
                        max(80, geometry.size.width - min(180, geometry.size.width * 0.48) - 56)
                    )
                ))
            }
            .overlay(alignment: .bottomLeading) {
                if showingBefore && viewModel.hasImage {
                    Text(L10n.text("调整前")).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: viewModel.hasImage ? .topLeading : .center) {
                if editorBusy {
                    ProgressView(isImporting ? L10n.text("正在导入") : isSaving ? L10n.text("正在保存") : L10n.text("正在处理"))
                        .font(.caption)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
        }
    }

    var adjustmentPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text(selectedFilmName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Menu {
                    Button(L10n.text("重置全部调整"), role: .destructive) {
                        applySettingsChange(.default)
                    }
                    if let adjustment = selectedAdjustment {
                        Button(L10n.format("重置%@", String(describing: adjustment.title))) { reset(adjustment) }
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(L10n.text("重置调整"))
                .disabled(!viewModel.hasImage || editingLocked || settings == .default)
            }
            .padding(.horizontal, 16)

            editSaveStatus

            toolStrip
            valuePanel
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    var editSaveStatus: some View {
        switch viewModel.editSaveState {
        case .idle:
            EmptyView()
        case .restored:
            Label(L10n.text("已恢复上次调整"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        case .saved:
            Label(L10n.text("调整已保存"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        case .failed(let message):
            Button {
                viewModel.retrySave(settings: settings)
            } label: {
                Label(L10n.text("调整未保存，点击重试"), systemImage: "exclamationmark.triangle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityValue(message)
            .padding(.horizontal, 16)
        }
    }

    var toolStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button { lensSelected = false; choosingMasterRecipe = false; selectedAdjustment = nil } label: {
                        AdjustmentToolLabel(title: L10n.text("胶片"), symbol: "film", selected: selectedAdjustment == nil && !choosingMasterRecipe && !lensSelected,
                                            progress: 0, width: toolWidth, height: toolHeight)
                    }
                    .accessibilityValue(selectedFilmName)
                    .accessibilityAddTraits(selectedAdjustment == nil && !choosingMasterRecipe && !lensSelected ? .isSelected : [])
                    .accessibilityIdentifier("tool.film")
                    .id("film")
                    Button { lensSelected = false; choosingMasterRecipe = true; selectedAdjustment = nil } label: {
                        AdjustmentToolLabel(title: L10n.text("大师配方"), symbol: "photo.stack", selected: choosingMasterRecipe,
                                            progress: settings.masterRecipeID == nil ? 0 : 1, width: toolWidth, height: toolHeight)
                    }.accessibilityIdentifier("tool.masterRecipe").accessibilityValue(settings.masterRecipe?.name ?? L10n.text("无配方"))
                        .id("masterRecipe")
                    Button { lensSelected = true; choosingMasterRecipe = false; selectedAdjustment = nil } label: {
                        AdjustmentToolLabel(title: L10n.text("镜头"), symbol: "viewfinder", selected: lensSelected,
                                            progress: settings.lensSettings.isEnabled ? 1 : 0,
                                            width: toolWidth, height: toolHeight)
                    }.disabled(viewModel.sourceKind != .raw)
                        .accessibilityIdentifier("tool.lens")
                        .accessibilityAddTraits(lensSelected ? .isSelected : []).id("lens")
                    ForEach(AdjustmentKind.allCases) { adjustment in
                        Button { lensSelected = false; choosingMasterRecipe = false; selectedAdjustment = adjustment } label: {
                            AdjustmentToolLabel(title: adjustment.title, symbol: adjustment.iconName,
                                                selected: selectedAdjustment == adjustment && !lensSelected,
                                                progress: adjustmentProgress(adjustment),
                                                width: toolWidth, height: toolHeight)
                        }
                        .disabled(adjustment == .strength && !settings.hasLook)
                        .accessibilityValue(adjustment.valueLabel(for: adjustment.value(from: settings)))
                        .accessibilityAddTraits(selectedAdjustment == adjustment && !lensSelected ? .isSelected : [])
                        .accessibilityIdentifier("tool.\(adjustment.rawValue)")
                        .contextMenu {
                            Button(L10n.format("重置%@", String(describing: adjustment.title))) { reset(adjustment) }
                            .disabled(!viewModel.hasImage || adjustmentProgress(adjustment) == 0 || editingLocked)
                        }
                        .id(adjustment.rawValue)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: toolHeight)
            .onGeometryChange(for: CGFloat.self) { geometry in geometry.size.width } action: { _ in
                proxy.scrollTo(lensSelected ? "lens" : choosingMasterRecipe ? "masterRecipe" : selectedAdjustment?.rawValue ?? "film", anchor: .center)
            }
            .onChange(of: selectedAdjustment) { _, adjustment in
                proxy.scrollTo(lensSelected ? "lens" : choosingMasterRecipe ? "masterRecipe" : adjustment?.rawValue ?? "film", anchor: .center)
            }
            .onChange(of: lensSelected) { _, selected in
                if selected { proxy.scrollTo("lens", anchor: .center) }
            }
            .onChange(of: choosingMasterRecipe) { _, selected in
                if selected { proxy.scrollTo("masterRecipe", anchor: .center) }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var valuePanel: some View {
        if lensSelected {
            IOSLensControls(settings: $settings, info: viewModel.lensInfo)
                .padding(.horizontal, 16)
                .disabled(!viewModel.hasImage || editingLocked || viewModel.sourceKind != .raw)
        } else if choosingMasterRecipe {
            masterRecipePanel
        } else if selectedAdjustment == .hsl {
            HSLMixer(settings: Binding(get: { settings.hsl }, set: { settings.hsl = $0 }),
                     onEditingChanged: setSliderEditing)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .vignette {
            IOSPhotoEffectsControls(effect: .vignette, settings: Binding(
                get: { settings.photoEffects },
                set: { settings.photoEffects = $0 }
            ), onEditingChanged: setSliderEditing)
                .padding(.horizontal, 16)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .grain {
            IOSPhotoEffectsControls(effect: .grain, settings: Binding(
                get: { settings.photoEffects },
                set: { settings.photoEffects = $0 }
            ), onEditingChanged: setSliderEditing)
                .padding(.horizontal, 16)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if selectedAdjustment == .noiseReduction {
            IOSDenoiseControls(settings: Binding(
                get: { settings.denoise },
                set: { settings.denoise = $0; settings.noiseReduction = 0 }
            ), onEditingChanged: setSliderEditing)
                .padding(.horizontal, 16)
                .disabled(!viewModel.hasImage || editingLocked)
        } else if let adjustment = selectedAdjustment {
            if (adjustment == .temperature || adjustment == .tint), viewModel.sourceKind == .raw {
                whiteBalancePanel
            } else {
                VStack(spacing: 4) {
                HStack {
                    Text(adjustment.title).font(.subheadline)
                    Spacer()
                    if adjustment == .exposure {
                        Button(action: autoExposure) { Label(L10n.text("自动"), systemImage: "wand.and.stars") }
                            .font(.caption).disabled(autoExposing || viewModel.isBusy)
                            .accessibilityIdentifier("exposure.auto")
                    }
                    Text(adjustment.valueLabel(for: adjustment.value(from: settings)))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(adjustmentProgress(adjustment) == 0 ? Color.secondary : .yellow)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("adjustment.value")
                    Button { reset(adjustment) } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L10n.format("重置%@", String(describing: adjustment.title)))
                    .disabled(adjustmentProgress(adjustment) == 0)
                }
                Slider(value: adjustmentBinding(adjustment), in: adjustment.range, step: adjustment.step,
                       onEditingChanged: setSliderEditing)
                    .frame(minHeight: 44)
                    .accessibilityLabel(adjustment.title)
                    .accessibilityValue(adjustment.valueLabel(for: adjustment.value(from: settings)))
                    .accessibilityIdentifier("adjustment.slider")
                    .overlay(alignment: .bottom) {
                        DefaultValueMarker(range: adjustment.range, value: adjustment.value(from: .default))
                            .frame(height: 4).offset(y: 5).allowsHitTesting(false)
                    }
                if adjustment == .exposure, viewModel.sourceKind == .raw {
                    Picker(L10n.text("曝光基准"), selection: $settings.exposureMode) {
                        ForEach(RawExposureMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).id(localizationLocale.identifier).accessibilityIdentifier("exposure.mode")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
                .disabled(!viewModel.hasImage || editingLocked || (adjustment == .strength && !settings.hasLook))
                }
        } else {
            filmPanel(imageSize: filmSize)
        }
    }

    var whiteBalancePanel: some View {
        VStack(spacing: 8) {
            Picker(L10n.text("白平衡模式"), selection: Binding(
                get: { settings.whiteBalanceMode },
                set: { setWhiteBalanceMode($0) }
            )) {
                Text(L10n.text("拍摄时")).tag(RawWhiteBalanceMode.camera)
                Text(L10n.text("自定义")).tag(RawWhiteBalanceMode.custom)
            }
            .pickerStyle(.segmented)
            .id(localizationLocale.identifier)
            .disabled(viewModel.rawWhiteBalance == nil)
            .accessibilityIdentifier("whiteBalance.mode")

            HStack {
                Text(L10n.text("色温")).font(.subheadline)
                Spacer()
                if settings.whiteBalanceMode == .camera, viewModel.rawWhiteBalance == nil {
                    Text(L10n.text("拍摄时设置")).foregroundStyle(.secondary)
                } else {
                    TextField(L10n.text("色温"), value: temperatureNumberBinding(), format: .number.precision(.fractionLength(0)))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("whiteBalance.temperature")
                    Text("K")
                }
            }
            if settings.whiteBalanceMode == .custom || viewModel.rawWhiteBalance != nil {
                Slider(value: reciprocalTemperatureBinding(), in: 0...1, step: 0.001,
                       onEditingChanged: setSliderEditing)
                    .frame(minHeight: 44)
                    .accessibilityLabel(L10n.text("色温"))
                    .disabled(settings.whiteBalanceMode == .camera || viewModel.rawWhiteBalance == nil)
                    .overlay(alignment: .bottom) {
                        DefaultValueMarker(range: 0...1, value: RawSettings.reciprocalSliderValue(for: RawSettings.default.temperature))
                            .frame(height: 4).offset(y: 5).allowsHitTesting(false)
                    }
                HStack {
                    Text("2000 K")
                    Spacer()
                    Text("50000 K")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.text("色调")).font(.subheadline)
                Spacer()
                TextField(L10n.text("色调"), value: Binding(
                    get: { displayedTint },
                    set: { value in
                        var updated = settings
                        updated.tint = min(max(value.rounded(), RawSettings.tintRange.lowerBound), RawSettings.tintRange.upperBound)
                        if updated.masterRecipeID == nil { updated.whiteBalanceMode = .custom }
                        applySettingsChange(updated)
                    }
                ), format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("whiteBalance.tint")
                Slider(value: adjustmentBinding(.tint), in: RawSettings.tintRange, step: 1,
                       onEditingChanged: setSliderEditing)
                    .frame(minHeight: 44)
                    .disabled((settings.whiteBalanceMode == .camera && settings.masterRecipeID == nil) || viewModel.rawWhiteBalance == nil)
            }
            .disabled((settings.whiteBalanceMode == .camera && settings.masterRecipeID == nil) || viewModel.rawWhiteBalance == nil)
            if let whiteBalance = viewModel.rawWhiteBalance {
                Text(settings.whiteBalanceMode == .camera
                     ? String(format: L10n.text("拍摄时：%.0f K · 色调 %+.0f"), whiteBalance.temperature, whiteBalance.tint)
                     : L10n.text("自定义白平衡"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(L10n.text("缺少有效相机校准，保留拍摄时白平衡"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    func filmPanel(imageSize: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filmButton(name: L10n.text("中性"), id: nil, imageSize: imageSize)
                    ForEach(viewModel.availableLUTs) { lut in
                        filmButton(name: lut.name, id: lut.id, imageSize: imageSize)
                    }
                }
                .padding(.horizontal, 16)
            }
            .accessibilityIdentifier("film.choices")
            .onAppear { proxy.scrollTo(settings.lutID ?? "neutral", anchor: .center) }
            .onChange(of: settings.lutID) { _, id in proxy.scrollTo(id ?? "neutral", anchor: .center) }
        }
        .overlay {
            if viewModel.isLoadingLUTs {
                ProgressView(L10n.text("正在加载胶片")).padding(8).background(.regularMaterial)
            } else if viewModel.availableLUTs.isEmpty {
                Text(L10n.text("未找到胶片 LUT")).font(.caption).foregroundStyle(.secondary)
                    .padding(8).background(.regularMaterial)
            }
        }
        .disabled(!viewModel.hasImage || editingLocked || viewModel.isLoadingLUTs)
    }

    var masterRecipePanel: some View {
        let recipes = MasterRecipe.allRecipes
        let tileWidth = max(120, filmSize + 40)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    masterRecipeButton(nil, width: tileWidth).id("neutral")
                    ForEach(recipes) { recipe in masterRecipeButton(recipe, width: tileWidth).id(recipe.id) }
                }
                .padding(.horizontal, 16)
            }
            .onAppear { proxy.scrollTo(settings.masterRecipeID ?? "neutral", anchor: .center) }
        }.buttonStyle(.plain).accessibilityIdentifier("masterRecipe.choices")
    }

    func masterRecipeButton(_ recipe: MasterRecipe?, width: CGFloat) -> some View {
        Button {
            var updated = settings
            if let recipe { updated.applyMasterRecipe(recipe) }
            else { updated.clearMasterRecipe(cameraTint: viewModel.rawWhiteBalance?.tint); updated.lutID = nil }
            applySettingsChange(updated)
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let url = recipe?.artworkURL(), let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else { Image(systemName: "circle.lefthalf.filled").font(.title) }
                }.frame(width: filmSize, height: filmSize)
                Text(recipe?.name ?? L10n.text("无配方")).font(.caption).lineLimit(2).frame(height: 32)
                    .foregroundStyle(settings.masterRecipeID == recipe?.id ? Color.yellow : Color.primary)
                Text(L10n.text(recipe?.subtitle ?? "中性直出")).font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(height: 32)
            }.frame(width: width)
        }.disabled(!viewModel.hasImage || editingLocked)
            .accessibilityLabel(recipe?.name ?? L10n.text("无配方")).accessibilityIdentifier("recipe.\(recipe?.id ?? "neutral")")
            .accessibilityAddTraits(settings.masterRecipeID == recipe?.id ? .isSelected : [])
    }

    func filmButton(name: String, id: String?, imageSize: CGFloat) -> some View {
        Button {
            var updated = settings
            updated.clearMasterRecipe(cameraTint: viewModel.rawWhiteBalance?.tint)
            updated.lutID = id
            applySettingsChange(updated)
        } label: {
            FilmLabel(name: name, artworkName: id.flatMap { FilmPresentation(fileName: $0).artworkName },
                      neutral: id == nil, selected: settings.lutID == id, imageSize: imageSize)
        }
        .buttonStyle(.plain)
        .id(id ?? "neutral")
        .accessibilityLabel(name)
        .accessibilityAddTraits(settings.lutID == id ? .isSelected : [])
    }
}

private struct IOSDenoiseControls: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var settings: RawDenoiseSettings
    let onEditingChanged: (Bool) -> Void
    private var parameters: [(String, WritableKeyPath<RawDenoiseSettings, Double>, Double)] { [
        (L10n.text("亮度降噪"), \.luma, 0), (L10n.text("色彩降噪"), \.chroma, 46), (L10n.text("粗色斑抑制"), \.coarse, 50)
    ] }

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            HStack {
                Toggle(L10n.text("降噪"), isOn: $settings.enabled).fixedSize()
                    .accessibilityIdentifier("denoise.enabled")
                Spacer(minLength: 4)
                Button { settings = RawDenoiseSettings() } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 36, height: 44)
                }.accessibilityLabel(L10n.text("重置降噪"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("预设")).font(.subheadline)
                Picker(L10n.text("预设"), selection: Binding(get: { settings.preset }, set: { settings.apply($0) })) {
                    Text(RawDenoisePreset.detail.title).tag(RawDenoisePreset.detail)
                    Text(RawDenoisePreset.clean.title).tag(RawDenoisePreset.clean)
                    if settings.preset == .custom { Text(L10n.text("自定义")).tag(RawDenoisePreset.custom) }
                }.labelsHidden().pickerStyle(.menu).id(localizationLocale.identifier).accessibilityIdentifier("denoise.preset")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            ForEach(parameters.indices, id: \.self) { index in
                let parameter = parameters[index]
                let value = Binding(get: { settings[keyPath: parameter.1] }, set: { number in
                    if number.isFinite { settings[keyPath: parameter.1] = min(100, max(0, number.rounded())) }
                })
                HStack(spacing: 6) {
                    Text(parameter.0).font(.caption).frame(width: 78, alignment: .leading)
                    Slider(value: value, in: 0...100, step: 1, onEditingChanged: onEditingChanged)
                        .accessibilityLabel(parameter.0).accessibilityIdentifier("denoise.slider.\(index)")
                    TextField(parameter.0, value: value, format: .number.precision(.fractionLength(0)))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder).frame(width: 42)
                        .accessibilityLabel(L10n.format("%@数值", String(describing: parameter.0))).accessibilityIdentifier("denoise.value.\(index)")
                    Button { value.wrappedValue = parameter.2 } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 30, height: 44)
                    }.accessibilityLabel(L10n.format("重置%@", String(describing: parameter.0))).disabled(value.wrappedValue == parameter.2)
                }.disabled(!settings.enabled).frame(minHeight: 44)
            }
        }
    }
}

private struct IOSPhotoEffectsControls: View {
    let effect: AdjustmentKind
    @Binding var settings: PhotoEffectsSettings
    let onEditingChanged: (Bool) -> Void

    private var parameters: [PhotoEffectParameter] {
        PhotoEffectParameter.allCases.filter { $0.isVignette == (effect == .vignette) }
    }

    private var effectIsDefault: Bool {
        parameters.allSatisfy { settings[keyPath: $0.keyPath] == $0.defaultValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(effect.title).font(.subheadline)
                Spacer(minLength: 4)
                Button { resetEffect() } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 36, height: 44)
                }
                .accessibilityLabel(L10n.format("重置%@", String(describing: effect.title)))
                .disabled(effectIsDefault)
            }
            ForEach(parameters) { parameter in
                let value = binding(for: parameter)
                HStack(spacing: 6) {
                    Text(parameter.title).font(.caption).frame(width: 72, alignment: .leading)
                    Slider(value: value, in: parameter.range, step: 1, onEditingChanged: onEditingChanged)
                        .accessibilityLabel(parameter.title)
                        .accessibilityIdentifier("effects.\(effect.rawValue).slider.\(parameter.rawValue)")
                    TextField(parameter.title, value: value,
                              format: .number.precision(.fractionLength(0)))
                        .keyboardType(parameter.range.lowerBound < 0 ? .numbersAndPunctuation : .numberPad)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                        .accessibilityLabel(L10n.format("%@数值", String(describing: parameter.title)))
                        .accessibilityIdentifier("effects.\(effect.rawValue).value.\(parameter.rawValue)")
                    Button { value.wrappedValue = parameter.defaultValue } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 30, height: 44)
                    }
                    .accessibilityLabel(L10n.format("重置%@", String(describing: parameter.title)))
                    .disabled(value.wrappedValue == parameter.defaultValue)
                }
                .disabled(parameter == .vignetteHighlights && settings.vignetteAmount >= 0)
                .frame(minHeight: 44)
            }
        }
    }

    private func binding(for parameter: PhotoEffectParameter) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: parameter.keyPath] },
            set: { value in
                guard value.isFinite else { return }
                settings[keyPath: parameter.keyPath] = min(parameter.range.upperBound,
                                                           max(parameter.range.lowerBound, value.rounded()))
            }
        )
    }

    private func resetEffect() {
        if effect == .vignette {
            settings.resetVignette()
        } else {
            settings.resetGrain()
        }
    }
}
