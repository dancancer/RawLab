import PhotosUI
import SwiftUI

extension ContentView {
    @ToolbarContentBuilder
    var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            photoImportButton(isEnabled: !editorBusy && !isEditorDraftChanged)
                .opacity(rulerFocusOpacity)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker(L10n.text("语言"), selection: $languagePreference) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0.rawValue) }
                }
                .id(localizationLocale.identifier)
                Toggle(L10n.text("调整触觉反馈"), isOn: $adjustmentHapticsEnabled)
            } label: { Image(systemName: "globe") }
                .accessibilityLabel(L10n.text("语言"))
                .accessibilityIdentifier("settings.language")
                .opacity(rulerFocusOpacity)
            Button { showingBefore.toggle() } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(!viewModel.hasImage ? Color.secondary : showingBefore ? .yellow : .primary)
            }
            .accessibilityLabel(L10n.text("前后对比"))
            .accessibilityValue(showingBefore ? L10n.text("调整前") : L10n.text("调整后"))
            .help(L10n.text("切换调整前后"))
            .disabled(!viewModel.hasImage)
            .accessibilityIdentifier("editor.compare")
            .opacity(rulerFocusOpacity)

            Button { adjustmentsExpanded.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(!viewModel.hasImage ? Color.secondary : adjustmentsExpanded ? .yellow : .primary)
            }
            .accessibilityLabel(!viewModel.hasImage ? L10n.text("调整") : adjustmentsExpanded ? L10n.text("收起调整栏") : L10n.text("展开调整栏"))
            .help(L10n.text("显示或收起调整栏"))
            .disabled(!viewModel.hasImage)
            .accessibilityIdentifier("editor.adjustments")
            .opacity(rulerFocusOpacity)

            Menu {
                Button(L10n.text("保存当前照片")) {
                    singleExportFormat = .jpeg
                    exportLongEdge = nil
                    showingExportSize = true
                }
                .disabled(!viewModel.hasImage || editorBusy || isEditorDraftChanged || viewModel.previewRendering || viewModel.previewResizePending || !viewModel.isLookAvailable(for: settings))
                Button(L10n.text("导出渲染型 DNG…")) {
                    singleExportFormat = .renderedDNG
                    exportLongEdge = nil
                    showingExportSize = true
                }
                .disabled(!viewModel.hasImage || editorBusy || isEditorDraftChanged || viewModel.previewRendering || viewModel.previewResizePending || !viewModel.isLookAvailable(for: settings))
                Button(L10n.text("使用当前调整批量导出…"), action: openBatchExport)
                    .disabled(viewModel.sourceKind != .raw || !viewModel.hasImage || editorBusy || isEditorDraftChanged || viewModel.previewRendering || viewModel.previewResizePending || !viewModel.isLookAvailable(for: settings))
                    .accessibilityIdentifier("editor.batchExport")
                if batchModel != nil { Button(L10n.text("查看批量任务")) { showingBatchExport = true } }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel(L10n.text("导出"))
            .help(L10n.text("导出照片"))
            .disabled(isEditorDraftChanged || ((!viewModel.hasImage || editorBusy) && batchModel == nil))
            .accessibilityIdentifier("editor.export")
            .opacity(rulerFocusOpacity)
        }
    }

    var previewSection: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.12)
                if let image = currentPreviewImage {
                    ZoomablePhoto(image: image, referenceImage: viewModel.basePreviewImage ?? image,
                                  label: showingBefore ? L10n.text("调整前的照片") : L10n.text("调整后的照片"),
                                  onPreviewSizeChange: { viewModel.updatePreviewSize($0, settings: draftPreviewSettings) })
                        .id(viewModel.basePreviewImage)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(!geometrySelected)
                        .overlay {
                            if geometrySelected && !showingBefore {
                                EditorCropOverlay(settings: geometryDraftBinding, imageSize: image.size,
                                                  aspectRatio: geometryDraftAspectRatio,
                                                  onEditingChanged: setSliderEditing)
                            }
                        }
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
                        .opacity(rulerFocusOpacity)
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
                .opacity(rulerFocusOpacity)
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
            .overlay(alignment: .bottomTrailing) {
                if viewModel.hasImage && !editorBusy && (viewModel.previewRendering || viewModel.previewResizePending) {
                    ProgressView(L10n.text("正在生成效果预览…"))
                        .font(.caption)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("editor.preview.updating")
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
                    Button(L10n.text("重置所有调整并返回中性"), role: .destructive) {
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
                .disabled(!viewModel.hasImage || editingLocked || settings == .default || geometrySelected || lensSelected)
            }
            .padding(.horizontal, 16)
            .opacity(rulerFocusOpacity)

            editSaveStatus
                .opacity(rulerFocusOpacity)

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
                    Button { selectEditorTool(.film) } label: {
                        AdjustmentToolLabel(title: L10n.text("胶片"), symbol: "film", selected: selectedAdjustment == nil && !choosingMasterRecipe && !lensSelected && !geometrySelected,
                                            progress: 0, width: toolWidth, height: editorToolHeight)
                    }
                    .accessibilityValue(selectedFilmName)
                    .accessibilityAddTraits(selectedAdjustment == nil && !choosingMasterRecipe && !lensSelected && !geometrySelected ? .isSelected : [])
                    .accessibilityIdentifier("tool.film")
                    .opacity(selectedAdjustment == nil && !choosingMasterRecipe && !lensSelected && !geometrySelected ? 1 : rulerFocusOpacity)
                    .id("film")
                    Button { selectEditorTool(.recipe) } label: {
                        AdjustmentToolLabel(title: L10n.text("大师配方"), symbol: "square.stack.3d.up", selected: choosingMasterRecipe,
                                            progress: settings.masterRecipeID == nil ? 0 : 1, width: toolWidth, height: editorToolHeight)
                    }.accessibilityIdentifier("tool.masterRecipe").accessibilityValue(settings.masterRecipe?.name ?? L10n.text("无配方"))
                        .accessibilityAddTraits(choosingMasterRecipe ? .isSelected : [])
                        .opacity(choosingMasterRecipe ? 1 : rulerFocusOpacity)
                        .id("masterRecipe")
                    Button { selectEditorTool(.lens) } label: {
                        AdjustmentToolLabel(title: L10n.text("镜头"), symbol: "viewfinder", selected: lensSelected,
                                            progress: settings.lensSettings.isEnabled ? 1 : 0,
                                            width: toolWidth, height: editorToolHeight)
                    }.disabled(viewModel.sourceKind != .raw)
                        .accessibilityIdentifier("tool.lens")
                        .opacity(lensSelected ? 1 : rulerFocusOpacity)
                        .accessibilityAddTraits(lensSelected ? .isSelected : []).id("lens")
                    Button { selectEditorTool(.geometry) } label: {
                        AdjustmentToolLabel(title: L10n.text("几何"), symbol: "crop.rotate", selected: geometrySelected,
                                            progress: settings.geometry.isIdentity ? 0 : 1, width: toolWidth, height: editorToolHeight)
                    }
                    .accessibilityIdentifier("tool.geometry")
                    .opacity(geometrySelected ? 1 : rulerFocusOpacity)
                    .accessibilityAddTraits(geometrySelected ? .isSelected : []).id("geometry")
                    ForEach(AdjustmentKind.allCases) { adjustment in
                        Button { selectEditorTool(.adjustment(adjustment)) } label: {
                            AdjustmentToolLabel(title: adjustment.title, symbol: adjustment.iconName,
                                                selected: selectedAdjustment == adjustment && !lensSelected && !geometrySelected,
                                                progress: adjustmentProgress(adjustment),
                                                width: toolWidth, height: editorToolHeight,
                                                currentValue: selectedAdjustment == adjustment && !lensSelected && !geometrySelected ? selectedScalarBadge(adjustment) : nil)
                        }
                        .disabled(adjustment == .strength && !settings.hasLook)
                        .accessibilityValue(adjustment.valueLabel(for: adjustment.value(from: settings)))
                        .accessibilityAddTraits(selectedAdjustment == adjustment && !lensSelected && !geometrySelected ? .isSelected : [])
                        .accessibilityIdentifier("tool.\(adjustment.rawValue)")
                        .opacity(selectedAdjustment == adjustment && !lensSelected && !geometrySelected ? 1 : rulerFocusOpacity)
                        .contextMenu {
                            Button(L10n.format("重置%@", String(describing: adjustment.title))) { reset(adjustment) }
                            .disabled(!viewModel.hasImage || adjustmentProgress(adjustment) == 0 || editingLocked || lensSelected || geometrySelected)
                        }
                        .id(adjustment.rawValue)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: editorToolHeight)
            .onGeometryChange(for: CGFloat.self) { geometry in geometry.size.width } action: { _ in
                proxy.scrollTo(geometrySelected ? "geometry" : lensSelected ? "lens" : choosingMasterRecipe ? "masterRecipe" : selectedAdjustment?.rawValue ?? "film", anchor: .center)
            }
            .onChange(of: selectedAdjustment) { _, adjustment in
                proxy.scrollTo(geometrySelected ? "geometry" : lensSelected ? "lens" : choosingMasterRecipe ? "masterRecipe" : adjustment?.rawValue ?? "film", anchor: .center)
            }
            .onChange(of: lensSelected) { _, selected in
                if selected { proxy.scrollTo("lens", anchor: .center) }
            }
            .onChange(of: geometrySelected) { _, selected in
                if selected { proxy.scrollTo("geometry", anchor: .center) }
            }
            .onChange(of: choosingMasterRecipe) { _, selected in
                if selected { proxy.scrollTo("masterRecipe", anchor: .center) }
            }
        }
        .buttonStyle(.plain)
    }

}
