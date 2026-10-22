import PhotosUI
import SwiftUI

extension ContentView {
    @ToolbarContentBuilder
    var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Menu {
                Button { showingPrivacy = true } label: {
                    Label(L10n.text("隐私设置"), systemImage: "gearshape")
                }
                .accessibilityIdentifier("editor.privacy.open")
                Button { showingFileImporter = true } label: {
                    Label(L10n.text("从文件导入"), systemImage: "folder.badge.plus")
                }
                .disabled(editorBusy || isEditorDraftChanged)
                .accessibilityIdentifier("editor.import.file")
                Button { showingLookImporter = true } label: {
                    Label(L10n.text("导入外观"), systemImage: "camera.filters")
                }
                .disabled(editorBusy || isEditorDraftChanged || viewModel.isImportingLooks)
                .accessibilityIdentifier("editor.import.look")
            } label: {
                Image(systemName: "gearshape")
            }
            // 菜单里不止隐私设置（还有"从文件导入"），读屏名称按通用的"更多"
            .accessibilityLabel(L10n.text("更多")).help(L10n.text("更多"))
            .accessibilityIdentifier("editor.privacy")
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
            .accessibilityLabel(L10n.text("对比"))
            .accessibilityValue(showingBefore ? L10n.text("中性显影") : L10n.text("调整后"))
            .help(L10n.text("中性显影与调整后对比"))
            .disabled(!viewModel.hasImage)
            .accessibilityIdentifier("editor.compare")
            .opacity(rulerFocusOpacity)

            Button { requestAdjustmentExpansion(!adjustmentsExpanded) } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(!viewModel.hasImage ? Color.secondary : adjustmentsExpanded ? .yellow : .primary)
            }
            .accessibilityLabel(!viewModel.hasImage ? L10n.text("调整") : adjustmentsExpanded ? L10n.text("收起调整栏") : L10n.text("展开调整栏"))
            .help(L10n.text(adjustmentsExpanded ? "收起调整栏" : "展开调整栏"))
            .disabled(!viewModel.hasImage)
            .accessibilityIdentifier("editor.adjustments")
            .opacity(rulerFocusOpacity)

            Menu {
                Button(L10n.text("保存当前照片")) {
                    singleExportFormat = .jpeg
                    exportLongEdge = nil
                    showingExportSize = true
                }
                .disabled(!viewModel.hasImage || editorBusy || isEditorDraftActive || viewModel.previewRendering || viewModel.previewResizePending || !viewModel.isLookAvailable(for: settings))
                Button(L10n.text("导出渲染型 DNG…")) {
                    singleExportFormat = .renderedDNG
                    exportLongEdge = nil
                    showingExportSize = true
                }
                .disabled(!viewModel.hasImage || editorBusy || isEditorDraftActive || viewModel.previewRendering || viewModel.previewResizePending || !viewModel.isLookAvailable(for: settings))
                // 同时只有一个批量任务：已有任务时只给"查看"，不再并列一个同样打开旧任务的新建入口
                if batchModel == nil {
                    Button(L10n.text("使用当前调整批量导出…"), action: openBatchExport)
                        .disabled(!viewModel.hasImage || editorBusy || isEditorDraftActive || viewModel.previewRendering || viewModel.previewResizePending || !viewModel.isLookAvailable(for: settings))
                        .accessibilityIdentifier("editor.batchExport")
                } else {
                    Button(L10n.text("查看批量任务…")) { showingBatchExport = true }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel(L10n.text("导出"))
            .help(L10n.text("导出"))
            .disabled(isEditorDraftActive || ((!viewModel.hasImage || editorBusy) && batchModel == nil))
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
                                  label: showingBefore ? L10n.text("中性显影") : L10n.text("调整后"),
                                  onPreviewSizeChange: { viewModel.updatePreviewSize($0, settings: draftPreviewSettings) })
                        .id(viewModel.basePreviewImage)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(!geometrySelected)
                        .overlay {
                            if geometrySelected && !showingBefore {
                                EditorCropOverlay(settings: geometryDraftBinding, imageSize: image.size,
                                                  aspectRatio: geometryDraftAspectRatio,
                                                  isEnabled: !editorBusy && viewModel.hasImage,
                                                  sourceRevision: viewModel.sourceRevision,
                                                  onEditingChanged: setSliderEditing)
                                    .id(viewModel.sourceRevision)
                            }
                        }
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                                Text(L10n.text("导入照片"))
                                    .font(.headline)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(.black)
                            .disabled(editorBusy)
                            .accessibilityLabel(L10n.text("导入照片"))
                            .accessibilityIdentifier("editor.import.empty")
                            fileImportButton(isEnabled: !editorBusy && !isEditorDraftChanged)
                                .buttonStyle(.bordered)
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
                    Text(L10n.text("中性显影")).font(.caption)
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
            adjustmentHeader

            valuePanel.disabled(resetDraftSuspended)
                .environment(\.adjustmentFine, adjustmentFine)
                .environment(\.adjustmentInputContext, parameterInputContext)
        }
        .padding(.bottom, 12)
    }

    private var adjustmentHeader: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Text(selectedFilmName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .frame(maxWidth: geometry.size.width * 0.5, alignment: .leading)
                    Spacer(minLength: 8)
                    editSaveStatus
                    if currentEditorTool != .film && currentEditorTool != .lens {
                        Toggle(L10n.text("精细"), isOn: $adjustmentFine)
                            .toggleStyle(.switch).font(.subheadline).fixedSize()
                            .frame(minHeight: 44).layoutPriority(2)
                            .background(Color.clear.contentShape(Rectangle()).onTapGesture { adjustmentFine.toggle() })
                            .accessibilityHint(L10n.text(adjustmentFine ? "四分之一灵敏度" : "标准灵敏度") + " " + L10n.text("拖动灵敏度为普通模式的四分之一。"))
                            .accessibilityIdentifier("editor.fine")
                    }
                    Menu {
                        if currentEditorTool == .adjustment(.hsl) {
                            Button(L10n.format("重置当前颜色（%@）", L10n.text(HSLSettings.channelNames[hslChannel]))) {
                                requestEditorReset(.hslChannel(hslChannel))
                            }.disabled(!resetModified(.hslChannel(hslChannel)))
                            Button(L10n.text("重置全部 HSL…")) { requestEditorReset(.allHSL) }
                                .disabled(!resetModified(.allHSL))
                        } else {
                            Button(L10n.format("重置%@", currentEditorTool.title)) { requestEditorReset(.tool(currentEditorTool)) }
                                .disabled(!resetModified(.tool(currentEditorTool)))
                        }
                        Button(L10n.format("重置%@组…", selectedGroup.title)) { requestEditorReset(.group(selectedGroup)) }
                            .disabled(!resetModified(.group(selectedGroup)))
                        Button(L10n.text("重置全部调整…"), role: .destructive) { requestEditorReset(.all) }
                            .disabled(!resetModified(.all))
                    } label: {
                        // 这是一组重置选项（含"全部重置"），带下拉箭头，和参数行自己的重置按钮区分开
                        HStack(spacing: 1) {
                            Image(systemName: "arrow.counterclockwise")
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }
                        .fixedSize()
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(L10n.text("重置调整"))
                    .accessibilityIdentifier("editor.reset")
                    .disabled(!viewModel.hasImage || editorBusy || resetDraftSuspended)
                    .layoutPriority(2)
                }
                .frame(minWidth: geometry.size.width)
            }
            .defaultScrollAnchor(.trailing)
            .accessibilityIdentifier("editor.parameterHeader")
        }
        .frame(height: max(44, panelHeaderHeight))
        .padding(.horizontal, 16)
        .opacity(rulerFocusOpacity)
    }

    private var parameterInputContext: AdjustmentInputContext {
        let source = viewModel.sourceRevision
        let tool = currentEditorTool
        let channel = hslChannel
        return AdjustmentInputContext(id: "\(source).\(tool.stableID).\(channel)", isCurrent: {
            viewModel.sourceRevision == source && currentEditorTool == tool && adjustmentsExpanded &&
                (tool != .adjustment(.hsl) || hslChannel == channel)
        })
    }

    @ViewBuilder
    var editSaveStatus: some View {
        switch viewModel.editSaveState {
        case .idle:
            EmptyView()
        case .restored:
            editSaveLabel(L10n.text("已恢复上次调整"), symbol: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .saved:
            editSaveLabel(L10n.text("调整已保存"), symbol: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Button {
                retryEditorSave()
            } label: {
                editSaveLabel(L10n.text("调整未保存 · 重试"), symbol: "exclamationmark.triangle.fill")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .foregroundStyle(.orange)
            .accessibilityValue(message)
        }
    }

    private func editSaveLabel(_ title: String, symbol: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: symbol).fixedSize()
            Image(systemName: symbol)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    func groupNavigation(side: Bool) -> some View {
        let buttonWidth = groupNavigationButtonWidth
        let buttonHeight = groupNavigationButtonHeight
        return ScrollView(.horizontal, showsIndicators: false) {
            let layout = side && !adjustmentsExpanded
                ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                if side && !adjustmentsExpanded {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(Array(EditorAdjustmentGroup.allCases[(row * 3)..<(row * 3 + 3)]), id: \.rawValue) { group in
                                groupNavigationButton(group, width: buttonWidth, height: buttonHeight)
                            }
                        }
                    }
                } else {
                    ForEach(EditorAdjustmentGroup.allCases, id: \.rawValue) { group in groupNavigationButton(group, width: buttonWidth, height: buttonHeight) }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: buttonHeight * (side && !adjustmentsExpanded ? 2 : 1))
        .disabled(editorBusy || resetDraftSuspended)
        .accessibilityIdentifier("editor.groups")
    }

    private func groupNavigationButton(_ group: EditorAdjustmentGroup, width: CGFloat, height: CGFloat) -> some View {
        Button { selectEditorGroup(group) } label: {
            VStack(spacing: 4) {
                Text(group.title).font(.caption).lineLimit(2)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Circle().fill(resetModified(.group(group)) ? Color.yellow : .clear).frame(width: 4, height: 4)
            }
            .padding(.horizontal, 4)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .foregroundStyle(selectedGroup == group ? Color.yellow : .primary)
            .background(selectedGroup == group ? Color.yellow.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format(adjustmentsExpanded && selectedGroup == group ? "收起%@组" : "展开%@组", group.title))
        .accessibilityValue(resetModified(.group(group)) ? L10n.text("已调整") : "")
        .accessibilityAddTraits(selectedGroup == group ? .isSelected : [])
        .accessibilityIdentifier("editor.group.\(group.rawValue)")
    }

    func editorToolAccessibilityValue(_ tool: EditorToolSelection) -> String {
        switch tool {
        case .film: return selectedFilmName
        case .recipe: return settings.masterRecipe?.title ?? L10n.text("无配方")
        case .adjustment(let adjustment): return adjustment.valueLabel(for: adjustment.value(from: settings))
        default: return resetModified(.tool(tool)) ? L10n.text("已调整") : ""
        }
    }

    var toolStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(EditorAdjustmentRules.tools(selectedGroup), id: \.self) { tool in
                        Button { selectEditorTool(tool) } label: {
                            AdjustmentToolLabel(title: tool.title, symbol: tool.symbol, selected: currentEditorTool == tool,
                                progress: tool.scalar.map(adjustmentProgress) ?? (resetModified(.tool(tool)) ? 1 : 0), width: toolWidth, height: editorToolHeight,
                                currentValue: tool.scalar.flatMap(selectedScalarBadge))
                                .overlay(alignment: .bottom) {
                                    Circle().fill(resetModified(.tool(tool)) ? Color.yellow : .clear)
                                        .frame(width: 4, height: 4)
                                }
                        }
                        .disabled((tool == .lens && viewModel.sourceKind != .raw) ||
                                  (tool == .adjustment(.strength) && !settings.hasLook))
                        .accessibilityLabel(tool.title)
                        .accessibilityValue(editorToolAccessibilityValue(tool))
                        .accessibilityHint(resetModified(.tool(tool)) ? L10n.text("已调整") : "")
                        .accessibilityAddTraits(currentEditorTool == tool ? .isSelected : [])
                        .accessibilityIdentifier("tool.\(tool.stableID)")
                        .contextMenu {
                            Button(L10n.format("重置%@", tool.title)) { requestEditorReset(.tool(tool)) }
                                .disabled(!resetModified(.tool(tool)) || editorBusy || resetDraftSuspended ||
                                          ((tool == .geometry || tool == .lens) && (!isEditorDraftActive || currentEditorTool != tool)))
                        }
                        .id(tool.stableID)
                    }
                }.padding(.horizontal, 12)
            }
            .frame(height: editorToolHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
                proxy.scrollTo(currentEditorTool.stableID, anchor: .center)
            }
            .onChange(of: currentEditorTool) { _, tool in proxy.scrollTo(tool.stableID, anchor: .center) }
        }
        .buttonStyle(.plain)
        .disabled(editorBusy || resetDraftSuspended)
    }
}

extension EditorAdjustmentGroup {
    var title: String {
        switch self {
        case .looks: return L10n.text("外观")
        case .light: return L10n.text("光线")
        case .color: return L10n.text("颜色")
        case .effects: return L10n.text("效果")
        case .detail: return L10n.text("细节")
        case .geometry: return L10n.text("几何与镜头")
        }
    }
}

extension EditorToolSelection {
    var scalar: AdjustmentKind? { if case .adjustment(let value) = self { return value }; return nil }
    var stableID: String {
        switch self {
        case .film: return "film"
        case .recipe: return "masterRecipe"
        case .lens: return "lens"
        case .geometry: return "geometry"
        case .adjustment(let kind): return kind.rawValue
        }
    }
    var title: String {
        switch self {
        case .film: return L10n.text("胶片")
        case .recipe: return L10n.text("大师配方")
        case .lens: return L10n.text("镜头")
        case .geometry: return L10n.text("几何")
        case .adjustment(let kind): return kind.title
        }
    }
    var symbol: String {
        switch self {
        case .film: return "film"
        case .recipe: return "square.stack.3d.up"
        case .lens: return "viewfinder"
        case .geometry: return "crop.rotate"
        case .adjustment(let kind): return kind.iconName
        }
    }
}
