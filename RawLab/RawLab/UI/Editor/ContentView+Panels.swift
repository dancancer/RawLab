import PhotosUI
import SwiftUI

extension ContentView {
    @ToolbarContentBuilder
    var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Menu {
                Section { adjustmentTransferMenu }.disabled(!viewModel.hasImage || editorBusy)
                Button { photoInfoMode = photoInfoMode.next } label: {
                    Label(L10n.text("照片信息"), systemImage: "info.circle")
                }.disabled(!viewModel.hasImage)
                Menu(L10n.text("缩放与显示")) {
                    Toggle(L10n.text("照片四周留白"), isOn: $photoViewing.photoMargin)
                }.disabled(!viewModel.hasImage)
                Button { showingProcessingContext = true } label: {
                    Label(L10n.text("照片处理设置"), systemImage: "slider.horizontal.3")
                }.disabled(!viewModel.hasImage)
                Button { showingPrivacy = true } label: {
                    Label(L10n.text("隐私设置"), systemImage: "gearshape")
                }
                .accessibilityIdentifier("editor.privacy.open")
                Button { requestEditorImport(file: true) } label: {
                    Label(L10n.text("从文件导入"), systemImage: "folder.badge.plus")
                }
                .disabled(editorBusy)
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
            photoImportButton(isEnabled: !editorBusy)
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
            Button { photoViewing.toggleComparison() } label: {
                Image(systemName: "rectangle.split.2x1")
                    .foregroundStyle(photoViewing.enabled ? Color.yellow : .primary)
            }
            .accessibilityLabel(L10n.text(photoViewing.enabled ? "关闭对比" : "开启对比"))
            .accessibilityValue(L10n.text(photoViewing.preferredMode == .sideBySide ? "并排" : "分割线"))
            .help(L10n.text("对比"))
            .disabled(!viewModel.hasImage || isEditorDraftActive || editorBusy || (viewModel.basePreviewImage == nil && !photoViewing.enabled))
            .contextMenu { comparisonModeMenu }
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
                .disabled(!viewModel.hasImage || editorBusy || isEditorDraftActive || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || !viewModel.isLookAvailable(for: settings))
                Button(L10n.text("导出渲染型 DNG…")) {
                    singleExportFormat = .renderedDNG
                    exportLongEdge = nil
                    showingExportSize = true
                }
                .disabled(!viewModel.hasImage || editorBusy || isEditorDraftActive || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || !viewModel.isLookAvailable(for: settings))
                // 同时只有一个批量任务：已有任务时只给"查看"，不再并列一个同样打开旧任务的新建入口
                if batchModel == nil {
                    Button(L10n.text("使用当前调整批量导出…"), action: openBatchExport)
                        .disabled(!viewModel.hasImage || editorBusy || isEditorDraftActive || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || !viewModel.isLookAvailable(for: settings))
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
                    ZoomablePhoto(image: image, referenceImage: viewModel.basePreviewImage,
                                  label: L10n.text("调整后"), viewing: $photoViewing, viewport: $photoViewport,
                                  isDraft: isEditorDraftActive,
                                  interactionEnabled: !editorBusy && !draftExitPresented && !resetConfirmationPresented && !showingFileImporter && !showingLookImporter,
                                  overlayAvoidanceRect: photoComparisonControlBounds,
                                  onPreviewSizeChange: { viewModel.updatePreviewSize($0, settings: draftPreviewSettings) },
                                  hslTarget: hslTargetActive ? hslTargetInput : nil, hslTargetPoint: hslTargetPoint)
                        .id(viewModel.sourceRevision)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(!geometrySelected)
                        .overlay {
                            if geometrySelected && !geometryPerspective {
                                EditorCropOverlay(settings: geometryDraftBinding, imageSize: image.size,
                                                  aspectRatio: geometryDraftAspectRatio,
                                                  isEnabled: !editorBusy && viewModel.hasImage,
                                                  sourceRevision: viewModel.sourceRevision,
                                                  onEditingChanged: setSliderEditing, showsGrid: geometryGrid)
                                    .padding(PhotoZoomGeometry.marginInset(viewport: geometry.size,
                                        margin: photoViewing.photoMargin ? PhotoZoomGeometry.defaultMargin : 0))
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
                if viewModel.hasImage && !photoViewing.previewOnly {
                    FloatingHistogram(histogram: currentHistogram, showingBefore: showingBefore,
                                      availableSize: geometry.size, expanded: $histogramExpanded)
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
                .opacity(photoViewing.previewOnly ? 0 : rulerFocusOpacity)
                .allowsHitTesting(!photoViewing.previewOnly)
                .accessibilityHidden(photoViewing.previewOnly)
            }
            .overlay(alignment: .top) {
                if viewModel.hasImage && (editorBusy || viewModel.previewRendering || viewModel.previewResizePending) {
                    previewProgressLine
                }
            }
            .overlay(alignment: .bottomLeading) {
                if viewModel.previewFailed {
                    Button { viewModel.retryPreview(settings: draftPreviewSettings) } label: {
                        Label(L10n.text("预览未更新") + " · " + L10n.text("重试"), systemImage: "arrow.clockwise")
                            .font(.caption).padding(8).frame(minHeight: 44)
                    }
                    .background(.regularMaterial)
                    .padding(12)
                    .accessibilityIdentifier("editor.preview.retry")
                } else if case .failed = viewModel.editSaveState {
                    editSaveStatus.padding(8).background(.regularMaterial).padding(12)
                }
            }
            .overlay(alignment: .topTrailing) {
                if photoViewing.previewOnly {
                    Button { photoViewing.togglePreview(isDraft: false) } label: {
                        Image(systemName: "chevron.backward").frame(minWidth: 44, minHeight: 44)
                    }
                    .background(.regularMaterial, in: Circle())
                    .padding(12)
                    .accessibilityLabel(L10n.text("退出纯预览"))
                    .accessibilityIdentifier("editor.preview.exit")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if photoViewing.enabled && !photoViewing.previewOnly && !isEditorDraftActive {
                    Menu { comparisonModeMenu } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 22)).frame(minWidth: 44, minHeight: 44)
                    }
                    .background(.regularMaterial, in: Circle())
                    .background {
                        GeometryReader { control in
                            Color.clear.preference(key: PhotoComparisonControlBoundsKey.self,
                                value: control.frame(in: .named("editor.photo.canvas")))
                        }
                    }
                    .padding(12)
                    .accessibilityLabel(L10n.text("对比方式"))
                    .accessibilityIdentifier("editor.compare.mode")
                }
            }
            .coordinateSpace(name: "editor.photo.canvas")
            .onPreferenceChange(PhotoComparisonControlBoundsKey.self) { photoComparisonControlBounds = $0 }
            .clipped()
        }
    }

    @ViewBuilder
    var comparisonModeMenu: some View {
        Button(L10n.text("并排")) { photoViewing.selectMode(.sideBySide) }
            .accessibilityIdentifier("editor.compare.sideBySide")
            .disabled(viewModel.basePreviewImage == nil || isEditorDraftActive)
        Button(L10n.text("分割线")) { photoViewing.selectMode(.wipe) }
            .accessibilityIdentifier("editor.compare.wipe")
            .disabled(viewModel.basePreviewImage == nil || isEditorDraftActive)
        Button(L10n.text("重置分割线")) { photoViewing.setSplit(0.5) }
        Button(L10n.text("关闭对比")) { if photoViewing.enabled { photoViewing.toggleComparison() } }
            .accessibilityIdentifier("editor.compare.close")
    }

    var previewProgressLine: some View {
        GeometryReader { geometry in
            if reduceMotion {
                Rectangle().fill(Color.yellow).frame(height: 2)
            } else {
                ProgressView().progressViewStyle(.linear)
                    .frame(width: geometry.size.width, height: 2).clipped()
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityLabel(L10n.text("正在显影…"))
        .accessibilityIdentifier("editor.preview.updating")
    }

    var adjustmentPanel: some View {
        valuePanel.disabled(resetDraftSuspended)
            .environment(\.adjustmentFine, adjustmentFine)
            .environment(\.adjustmentInputContext, parameterInputContext)
            .padding(.vertical, 8)
    }

    private var adjustmentHeader: some View {
        HStack(spacing: 4) {
            if currentEditorTool != .film && currentEditorTool != .lens {
                Toggle(L10n.text("精细"), isOn: $adjustmentFine)
                    .toggleStyle(.switch).font(.caption).fixedSize()
                    .frame(minHeight: 44)
                    .accessibilityHint(L10n.text(adjustmentFine ? "四分之一灵敏度" : "标准灵敏度") + " " + L10n.text("拖动灵敏度为普通模式的四分之一。"))
                    .accessibilityIdentifier("editor.fine")
            }
        Menu {
            if currentEditorTool == .adjustment(.colorGrading) {
                Button(L10n.text("重置当前分区")) { requestEditorReset(.gradingZone(gradingZone)) }
                    .disabled(!resetModified(.gradingZone(gradingZone)))
                Button(L10n.text("重置颜色分级")) { requestEditorReset(.allGrading) }
                    .disabled(!resetModified(.allGrading))
            } else if currentEditorTool == .adjustment(.hsl) {
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.parameterHeader")
        .opacity(rulerFocusOpacity)
    }

    var processingContextSheet: some View {
            NavigationStack {
                Form {
                    Text(selectedFilmName)
                    editSaveStatus
                    if viewModel.sourceKind == .raw {
                        Picker(L10n.text("曝光基准"), selection: $settings.exposureMode) {
                            ForEach(RawExposureMode.allCases) { Text($0.title).tag($0) }
                        }.disabled(isEditorDraftActive || editorBusy)
                    }
                }
                .navigationTitle(L10n.text("照片处理设置"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("关闭")) { showingProcessingContext = false } } }
            }.presentationDetents([.medium, .large])
    }

    private var parameterInputContext: AdjustmentInputContext {
        let source = viewModel.sourceRevision
        let tool = currentEditorTool
        let channel = hslChannel
        let grading = gradingZone
        let perspective = geometryPerspective
        return AdjustmentInputContext(id: "\(source).\(tool.stableID).\(channel).\(grading.rawValue).\(perspective)", isCurrent: {
            viewModel.sourceRevision == source && currentEditorTool == tool && adjustmentsExpanded &&
                (tool != .adjustment(.hsl) || hslChannel == channel) &&
                (tool != .adjustment(.colorGrading) || gradingZone == grading) &&
                (tool != .geometry || geometryPerspective == perspective)
        }, canChange: { !viewModel.adjustmentInteractionRejected }, onInteractionCancelled: {
            if viewModel.sourceRevision == source && currentEditorTool == tool &&
                (tool != .adjustment(.hsl) || hslChannel == channel) &&
                (tool != .adjustment(.colorGrading) || gradingZone == grading) &&
                (tool != .geometry || geometryPerspective == perspective) {
                cancelSliderInteraction()
            }
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

    func groupNavigation(side: Bool, singleLine: Bool = false) -> some View {
        let buttonWidth = groupNavigationButtonWidth
        let buttonHeight = singleLine ? singleLineGroupNavigationHeight : groupNavigationButtonHeight
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
                    ForEach(EditorAdjustmentGroup.allCases, id: \.rawValue) { group in
                        let width = singleLine ? max(44, ceil((group.title as NSString).size(withAttributes:
                            [.font: UIFont.preferredFont(forTextStyle: .caption1)]).width) + 16) : buttonWidth
                        groupNavigationButton(group, width: width, height: buttonHeight, singleLine: singleLine)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: buttonHeight * (side && !adjustmentsExpanded ? 2 : 1))
        .disabled(editorBusy || resetDraftSuspended)
        .accessibilityIdentifier("editor.groups")
    }

    private func groupNavigationButton(_ group: EditorAdjustmentGroup, width: CGFloat, height: CGFloat,
                                       singleLine: Bool = false) -> some View {
        Button { selectEditorGroup(group) } label: {
            VStack(spacing: 4) {
                Text(group.title).font(.caption).lineLimit(singleLine ? 1 : 2)
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
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(EditorAdjustmentRules.tools(selectedGroup), id: \.self) { tool in
                            Button { if tool == .geometry { geometryPerspective = false }; selectEditorTool(tool) } label: {
                                AdjustmentToolLabel(title: tool == .geometry ? L10n.text("裁切") : tool.title, symbol: tool.symbol, selected: currentEditorTool == tool && !(tool == .geometry && geometryPerspective),
                                    progress: tool.scalar.map(adjustmentProgress) ?? (resetModified(.tool(tool)) ? 1 : 0), width: toolWidth, height: editorToolHeight)
                            }
                            .disabled((tool == .lens && viewModel.sourceKind != .raw) ||
                                      (tool == .adjustment(.strength) && !settings.hasLook))
                            .accessibilityLabel(tool.title)
                            .accessibilityValue(editorToolAccessibilityValue(tool))
                            .accessibilityHint(resetModified(.tool(tool)) ? L10n.text("已调整") : "")
                            .accessibilityAddTraits(currentEditorTool == tool && !(tool == .geometry && geometryPerspective) ? .isSelected : [])
                            .accessibilityIdentifier("tool.\(tool.stableID)")
                            .contextMenu {
                                Button(L10n.format("重置%@", tool.title)) { requestEditorReset(.tool(tool)) }
                                    .disabled(!resetModified(.tool(tool)) || editorBusy || resetDraftSuspended ||
                                              ((tool == .geometry || tool == .lens) && (!isEditorDraftActive || currentEditorTool != tool)))
                            }
                            .id(tool.stableID)
                            if tool == .geometry {
                                Button { geometryPerspective = true; selectEditorTool(.geometry) } label: {
                                    AdjustmentToolLabel(title: L10n.text("透视"), symbol: "perspective", selected: geometrySelected && geometryPerspective,
                                        progress: 0, width: toolWidth, height: editorToolHeight)
                                }.accessibilityLabel(L10n.text("透视")).accessibilityIdentifier("tool.perspective")
                                    .accessibilityAddTraits(geometrySelected && geometryPerspective ? .isSelected : [])
                            }
                        }
                        if selectedGroup == .looks {
                            Button { adjustmentSheet = .presets } label: {
                                AdjustmentToolLabel(title: L10n.text("我的预设"), symbol: "bookmark", selected: false,
                                    progress: 0, width: toolWidth, height: editorToolHeight)
                            }.disabled(editorBusy).accessibilityLabel(L10n.text("我的预设"))
                                .accessibilityIdentifier("preset.library")
                        }
                    }.padding(.horizontal, 12)
                }
                .frame(height: editorToolHeight)
                .accessibilityIdentifier("editor.tools")
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
                    proxy.scrollTo(currentEditorTool.stableID, anchor: .center)
                }
                .onChange(of: currentEditorTool) { _, tool in proxy.scrollTo(tool.stableID, anchor: .center) }
            }
            .buttonStyle(.plain)
            .disabled(editorBusy || resetDraftSuspended)
            adjustmentHeader.padding(.trailing, 8)
        }
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

private struct PhotoComparisonControlBoundsKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
