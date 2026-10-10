import PhotosUI
import SwiftUI

extension ContentView {
    @ToolbarContentBuilder
    var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            photoImportButton(isEnabled: !editorBusy)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showingBefore.toggle() } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(!viewModel.hasImage ? Color.secondary : showingBefore ? .yellow : .primary)
            }
            .accessibilityLabel("前后对比")
            .accessibilityValue(showingBefore ? "调整前" : "调整后")
            .help("切换调整前后")
            .disabled(!viewModel.hasImage)
            .accessibilityIdentifier("editor.compare")

            Button { adjustmentsExpanded.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(!viewModel.hasImage ? Color.secondary : adjustmentsExpanded ? .yellow : .primary)
            }
            .accessibilityLabel(!viewModel.hasImage ? "调整" : adjustmentsExpanded ? "收起调整栏" : "展开调整栏")
            .help("显示或收起调整栏")
            .disabled(!viewModel.hasImage)
            .accessibilityIdentifier("editor.adjustments")

            Menu {
                Button("保存当前照片") {
                    exportLongEdge = nil
                    showingExportSize = true
                }
                .disabled(!viewModel.hasImage || editorBusy || !viewModel.isLookAvailable(for: settings))
                Button("使用当前调整批量导出…", action: openBatchExport)
                    .disabled(viewModel.sourceKind != .raw || !viewModel.hasImage || editorBusy || !viewModel.isLookAvailable(for: settings))
                    .accessibilityIdentifier("editor.batchExport")
                if batchModel != nil { Button("查看批量任务") { showingBatchExport = true } }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("导出")
            .help("导出照片")
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
                                  label: showingBefore ? "调整前的照片" : "调整后的照片")
                        .id(viewModel.basePreviewImage)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text("RAW 照片").font(.title2.weight(.semibold))
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                                Label {
                                    Text("导入照片")
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
                            .accessibilityLabel("导入照片")
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
                    Text("调整前").font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: viewModel.hasImage ? .topLeading : .center) {
                if editorBusy {
                    ProgressView(isImporting ? "正在导入" : isSaving ? "正在保存" : "正在处理")
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
                    Button("重置全部调整", role: .destructive) {
                        applySettingsChange(.default)
                    }
                    if let adjustment = selectedAdjustment {
                        Button("重置\(adjustment.title)") { reset(adjustment) }
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("重置调整")
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
            Label("已恢复上次调整", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        case .saved:
            Label("调整已保存", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        case .failed(let message):
            Button {
                viewModel.retrySave(settings: settings)
            } label: {
                Label("调整未保存，点击重试", systemImage: "exclamationmark.triangle.fill")
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
                    Button { selectedAdjustment = nil } label: {
                        AdjustmentToolLabel(title: "胶片", symbol: "film", selected: selectedAdjustment == nil,
                                            progress: 0, width: toolWidth, height: toolHeight)
                    }
                    .accessibilityValue(selectedFilmName)
                    .accessibilityAddTraits(selectedAdjustment == nil ? .isSelected : [])
                    .accessibilityIdentifier("tool.film")
                    .id("film")
                    ForEach(AdjustmentKind.allCases) { adjustment in
                        Button { selectedAdjustment = adjustment } label: {
                            AdjustmentToolLabel(title: adjustment.title, symbol: adjustment.iconName,
                                                selected: selectedAdjustment == adjustment,
                                                progress: adjustmentProgress(adjustment),
                                                width: toolWidth, height: toolHeight)
                        }
                        .disabled(adjustment == .strength && settings.lutID == nil)
                        .accessibilityValue(adjustment.valueLabel(for: adjustment.value(from: settings)))
                        .accessibilityAddTraits(selectedAdjustment == adjustment ? .isSelected : [])
                        .accessibilityIdentifier("tool.\(adjustment.rawValue)")
                        .contextMenu {
                            Button("重置\(adjustment.title)") { reset(adjustment) }
                            .disabled(!viewModel.hasImage || adjustmentProgress(adjustment) == 0 || editingLocked)
                        }
                        .id(adjustment.rawValue)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: toolHeight)
            .onChange(of: selectedAdjustment) { _, adjustment in
                proxy.scrollTo(adjustment?.rawValue ?? "film", anchor: .center)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var valuePanel: some View {
        if selectedAdjustment == .noiseReduction {
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
                    Text(adjustment.valueLabel(for: adjustment.value(from: settings)))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(adjustmentProgress(adjustment) == 0 ? Color.secondary : .yellow)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("adjustment.value")
                    Button { reset(adjustment) } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("重置\(adjustment.title)")
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
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
                .disabled(!viewModel.hasImage || editingLocked || (adjustment == .strength && settings.lutID == nil))
                }
        } else {
            filmPanel(imageSize: filmSize)
        }
    }

    var whiteBalancePanel: some View {
        VStack(spacing: 8) {
            Picker("白平衡模式", selection: Binding(
                get: { settings.whiteBalanceMode },
                set: { setWhiteBalanceMode($0) }
            )) {
                Text("拍摄时").tag(RawWhiteBalanceMode.camera)
                Text("自定义").tag(RawWhiteBalanceMode.custom)
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.rawWhiteBalance == nil)
            .accessibilityIdentifier("whiteBalance.mode")

            HStack {
                Text("色温").font(.subheadline)
                Spacer()
                if settings.whiteBalanceMode == .camera, viewModel.rawWhiteBalance == nil {
                    Text("拍摄时设置").foregroundStyle(.secondary)
                } else {
                    TextField("色温", value: temperatureNumberBinding(), format: .number.precision(.fractionLength(0)))
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
                    .accessibilityLabel("色温")
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
                Text("色调").font(.subheadline)
                Spacer()
                TextField("色调", value: Binding(
                    get: { displayedTint },
                    set: { value in
                        var updated = settings
                        updated.tint = min(max(value.rounded(), RawSettings.tintRange.lowerBound), RawSettings.tintRange.upperBound)
                        updated.whiteBalanceMode = .custom
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
                    .disabled(settings.whiteBalanceMode == .camera || viewModel.rawWhiteBalance == nil)
            }
            .disabled(settings.whiteBalanceMode == .camera || viewModel.rawWhiteBalance == nil)
            if let whiteBalance = viewModel.rawWhiteBalance {
                Text(settings.whiteBalanceMode == .camera
                     ? String(format: "拍摄时：%.0f K · 色调 %+.0f", whiteBalance.temperature, whiteBalance.tint)
                     : "自定义白平衡")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("缺少有效相机校准，保留拍摄时白平衡")
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
                    filmButton(name: "中性", id: nil, imageSize: imageSize)
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
                ProgressView("正在加载胶片").padding(8).background(.regularMaterial)
            } else if viewModel.availableLUTs.isEmpty {
                Text("未找到胶片 LUT").font(.caption).foregroundStyle(.secondary)
                    .padding(8).background(.regularMaterial)
            }
        }
        .disabled(!viewModel.hasImage || editingLocked || viewModel.isLoadingLUTs)
    }

    func filmButton(name: String, id: String?, imageSize: CGFloat) -> some View {
        Button {
            var updated = settings
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
    @Binding var settings: RawDenoiseSettings
    let onEditingChanged: (Bool) -> Void
    private let parameters: [(String, WritableKeyPath<RawDenoiseSettings, Double>, Double)] = [
        ("亮度降噪", \.luma, 0), ("色彩降噪", \.chroma, 46), ("粗色斑抑制", \.coarse, 50)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("降噪", isOn: $settings.enabled).fixedSize()
                    .accessibilityIdentifier("denoise.enabled")
                Spacer(minLength: 4)
                Picker("预设", selection: Binding(get: { settings.preset }, set: { settings.apply($0) })) {
                    Text(RawDenoisePreset.detail.rawValue).tag(RawDenoisePreset.detail)
                    Text(RawDenoisePreset.clean.rawValue).tag(RawDenoisePreset.clean)
                    if settings.preset == .custom { Text("自定义").tag(RawDenoisePreset.custom) }
                }.pickerStyle(.menu).accessibilityIdentifier("denoise.preset")
                Button { settings = RawDenoiseSettings() } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 36, height: 44)
                }.accessibilityLabel("重置降噪")
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
                        .accessibilityLabel("\(parameter.0)数值").accessibilityIdentifier("denoise.value.\(index)")
                    Button { value.wrappedValue = parameter.2 } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 30, height: 44)
                    }.accessibilityLabel("重置\(parameter.0)").disabled(value.wrappedValue == parameter.2)
                }.disabled(!settings.enabled).frame(minHeight: 44)
            }
        }
    }
}
