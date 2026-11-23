import RawLabKit
import PhotosUI
import SwiftUI

extension ContentView {
    @ToolbarContentBuilder
    var editorToolbar: some ToolbarContent {
        if !toolWorkspaceOpen {
            editorOverviewToolbar
        }
    }

    @ToolbarContentBuilder
    private var editorOverviewToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if viewModel.batchSelection.selection.current != nil {
                Button { requestCollectionNavigation(.returnToCollection) } label: { Image(systemName: "square.grid.2x2") }
                    .accessibilityLabel(L10n.text("返回批量集合")).accessibilityIdentifier("collection.return").disabled(editorBusy)
            }
            photoImportButton(isEnabled: !editorBusy)
                .opacity(rulerFocusOpacity)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                coordinator.presentCameraWorkspace()
            } label: { Image(systemName: "camera") }
                .disabled(editorBusy).accessibilityLabel(L10n.text("相机")).accessibilityIdentifier("editor.camera")
            if viewModel.isExportingHDR {
                Button(action: viewModel.cancelHDRExport) {
                    if viewModel.isStoppingHDRExport && !reduceMotion {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "xmark.circle")
                    }
                }
                .disabled(viewModel.isStoppingHDRExport)
                .accessibilityLabel(L10n.text("取消导出"))
                .help(L10n.text("取消导出"))
                .accessibilityIdentifier("editor.cancelExport")
            } else if isSaving {
                Group {
                    if !reduceMotion {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .accessibilityLabel(L10n.text("正在保存"))
                .accessibilityIdentifier("editor.exportSaving.toolbar")
            } else {
                Menu {
                    Button(L10n.text("保存当前照片")) {
                        requestSingleExport(settings.isHDREditing ? .hdrJPEG : .jpeg)
                    }
                    .disabled(!viewModel.hasImage || editorBusy || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || !viewModel.isLookAvailable(for: settings))
                    if settings.isHDREditing {
                        Button(L10n.text("保存 SDR JPEG")) {
                            requestSingleExport(.jpeg)
                        }.disabled(editorBusy || viewModel.previewRendering || viewModel.previewFailed || !viewModel.isLookAvailable(for: settings))
                        Button(BatchOutputFormat.png.title) {
                            requestSingleExport(.png)
                        }
                        .disabled(!viewModel.hasImage || editorBusy || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || !viewModel.isLookAvailable(for: settings))
                        if HDRImage.heifExportAvailable {
                            Button(BatchOutputFormat.hdrHEIF.title) {
                                requestSingleExport(.hdrHEIF)
                            }
                            .disabled(!viewModel.hasImage || editorBusy || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || !viewModel.isLookAvailable(for: settings))
                        }
                    } else {
                        Button(BatchOutputFormat.png.title) {
                            requestSingleExport(.png)
                        }
                        .disabled(!viewModel.hasImage || editorBusy || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || !viewModel.isLookAvailable(for: settings))
                    }
                    Button(L10n.text("导出渲染型 DNG…")) {
                        requestSingleExport(.renderedDNG)
                    }
                    .disabled(!viewModel.hasImage || editorBusy || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || !viewModel.isLookAvailable(for: settings))
                    // 同时只有一个批量任务：已有任务时只给"查看"，不再并列一个同样打开旧任务的新建入口
                    if batchModel == nil {
                        Button(L10n.text("使用当前调整批量导出…"), action: openBatchExport)
                            .disabled(!viewModel.hasImage || editorBusy || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || !viewModel.isLookAvailable(for: settings))
                            .accessibilityIdentifier("editor.batchExport")
                    } else {
                        Button(L10n.text("查看批量任务…")) { showingBatchExport = true }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(L10n.text("导出"))
                .help(L10n.text("导出"))
                .disabled((!viewModel.hasImage || editorBusy) && batchModel == nil)
                .accessibilityIdentifier("editor.export")
                .opacity(rulerFocusOpacity)
            }
            Menu {
                Section {
                    Button(action: showRecentPhotos) { Label(L10n.text("最近打开"), systemImage: "clock.arrow.circlepath") }
                        .disabled(editorBusy).accessibilityIdentifier("recents.open")
                    Button { requestEditorImport(file: true) } label: {
                        Label(L10n.text("从文件导入"), systemImage: "folder.badge.plus")
                    }
                    .disabled(editorBusy)
                    .accessibilityIdentifier("editor.import.file")
                    Button(action: requestLookImport) {
                        Label(L10n.text("导入外观"), systemImage: "camera.filters")
                    }
                    .disabled(editorBusy || isEditorDraftChanged || viewModel.isImportingLooks)
                    .accessibilityIdentifier("editor.import.look")
                    Button(L10n.text("批量编辑"), action: openBatchSelection)
                        .disabled(editorBusy).accessibilityIdentifier("collection.open")
                }
                Section { adjustmentTransferMenu }.disabled(!viewModel.hasImage || editorBusy)
                Section {
                    Button { coordinator.presentProcessingContext() } label: {
                        Label(L10n.text("照片处理设置"), systemImage: "slider.horizontal.3")
                    }.disabled(!viewModel.hasImage)
                    Toggle(L10n.text("直方图"), isOn: $coordinator.histogramExpanded)
                        .disabled(!viewModel.hasImage)
                    Menu(L10n.text("对比方式")) { comparisonModeMenu }
                        .disabled(!viewModel.hasImage)
                    Button { coordinator.photoInfoMode = coordinator.photoInfoMode.next } label: {
                        Label(L10n.text("照片信息"), systemImage: "info.circle")
                    }.disabled(!viewModel.hasImage)
                    Menu(L10n.text("缩放与显示")) {
                        Toggle(L10n.text("照片四周留白"), isOn: $coordinator.photoViewing.photoMargin)
                    }.disabled(!viewModel.hasImage)
                }
                Section {
                    Toggle(L10n.text("取样监视"), isOn: $coordinator.inspection.monitorEnabled)
                        .disabled(!viewModel.hasImage || geometrySelected)
                        .accessibilityIdentifier("inspection.monitor")
                    Button(L10n.text("添加锚点")) { _ = pinInspectionAnchor() }
                        .disabled(!viewModel.hasImage || geometrySelected || !coordinator.inspection.canPinMore)
                        .accessibilityIdentifier("inspection.pinAnchor")
                    Button(L10n.text("清除锚点")) { coordinator.inspection.clearAnchors() }
                        .disabled(coordinator.inspection.anchors.isEmpty)
                        .accessibilityIdentifier("inspection.clearAnchors.menu")
                    Button {
                        coordinator.inspection.toggleNeutralGray50()
                    } label: {
                        Label(L10n.text("50% 中性灰"), systemImage: coordinator.inspection.overlay == .neutralGray50 ? "checkmark.square.fill" : "square.lefthalf.filled")
                    }
                        .disabled(!viewModel.hasImage || geometrySelected)
                        .accessibilityIdentifier("inspection.gray50")
                    Menu(L10n.text("观察层")) {
                        ForEach(InspectionOverlayMode.allCases) { mode in
                            Button {
                                coordinator.inspection.selectOverlay(mode)
                            } label: {
                                if coordinator.inspection.overlay == mode {
                                    Label(L10n.text(mode.titleKey), systemImage: "checkmark")
                                } else {
                                    Text(L10n.text(mode.titleKey))
                                }
                            }
                        }
                    }.disabled(!viewModel.hasImage || geometrySelected)
                        .accessibilityIdentifier("inspection.overlay.menu")
                }
                Section {
                    Menu(L10n.text("语言")) {
                        Picker(L10n.text("语言"), selection: $languagePreference) {
                            ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0.rawValue) }
                        }
                    }.accessibilityIdentifier("settings.language")
                    Toggle(L10n.text("调整触觉反馈"), isOn: $adjustmentHapticsEnabled)
                        .accessibilityIdentifier("settings.haptics")
                    Button { coordinator.presentPrivacy() } label: {
                        Label(L10n.text("隐私设置"), systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("editor.privacy.open")
                    Button(action: exportErrorDiagnostics) {
                        Label(L10n.text("导出错误日志"), systemImage: "doc.text")
                    }
                    .disabled(!canStartFileExport)
                    .accessibilityIdentifier("diagnostics.export")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            // 菜单里不止隐私设置（还有"从文件导入"），读屏名称按通用的"更多"
            .accessibilityLabel(L10n.text("更多")).help(L10n.text("更多"))
            .accessibilityIdentifier("editor.privacy")
        }
    }

    var editorLoadingPresentation: EditorLoadingPresentation {
        EditorLoadingPresentation.resolve(
            hasImage: viewModel.hasImage,
            isImporting: isImporting,
            isViewModelBusy: viewModel.isBusy,
            isSaving: isSaving,
            isExportingHDR: viewModel.isExportingHDR,
            cameraHDRPreflight: viewModel.cameraHDRPreflight,
            isImportingLooks: viewModel.isImportingLooks,
            isLoadingLUTs: viewModel.isLoadingLUTs,
            previewRendering: viewModel.previewRendering,
            previewResizePending: viewModel.previewResizePending,
            matchingProcessing: viewModel.matchingProcessing,
            autoExposing: coordinator.autoExposing,
            isBatchExportRunning: coordinator.batchExportHandle?.isRunning == true,
            isAdjustingSlider: coordinator.isAdjustingSlider
        )
    }

    var previewSection: some View {
        let loading = editorLoadingPresentation
        let activityBannerKey = (loading.showsTopBannerImmediately || delayedActivityBannerVisible) ? loading.topBannerMessageKey : nil
        return GeometryReader { geometry in
            ZStack {
                Color(white: 0.12)
                if let image = currentPreviewImage {
                    editorPhotoCanvas(image, size: geometry.size,
                                      onPreviewSizeChange: { edge in
                        let apply = { viewModel.updatePreviewSize(edge, settings: draftPreviewSettings) }
                        if let hook = testHooks.onPreviewSizeChange { hook(edge, apply) } else { apply() }
                    })
                        .id(viewModel.sourceRevision)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .overlay(alignment: .bottom) {
                            if !adjustmentsExpanded && hslTargetActive {
                                HSLTargetCanvasControls(axis: coordinator.hslTargetAxis) {
                                    cancelHSLTarget(); coordinator.hslTargetEnabled = false
                                }.padding(8)
                            } else if !adjustmentsExpanded && curveTargetActive {
                                CurveTargetCanvasControls(channel: coordinator.curveTargetChannel) {
                                    cancelCurveTarget(); coordinator.curveTargetEnabled = false
                                }.padding(8)
                            }
                        }
                } else {
                    ZStack {
                        ScrollView {
                            VStack(spacing: 20) {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                    Text("RawLab")
                                        .font(.title2.weight(.semibold))
                                    Text(L10n.text("导入并打开一张照片后，可在这里继续编辑。"))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                VStack(spacing: 12) {
                                    Button { requestEditorImport(file: false) } label: {
                                        Text(L10n.text("导入照片"))
                                            .font(.headline)
                                            .multilineTextAlignment(.center)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.horizontal, 20)
                                            .frame(minHeight: 44)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .foregroundStyle(.black)
                                    .disabled(editorBusy)
                                    .accessibilityLabel(L10n.text("导入照片"))
                                    .accessibilityIdentifier("editor.import.empty")
                                    Button(L10n.text("最近打开"), action: showRecentPhotos)
                                        .buttonStyle(.bordered).disabled(editorBusy).accessibilityIdentifier("recents.open.empty")
                                    fileImportButton(isEnabled: !editorBusy && !isEditorDraftChanged)
                                        .buttonStyle(.bordered)
                                    Button { coordinator.presentCameraWorkspace() } label: {
                                        Label(L10n.text("从相机导入"), systemImage: "camera")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(editorBusy)
                                    .accessibilityIdentifier("editor.camera.empty")
                                }
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height)
                        }
                        .opacity(loading.showsEmptyCanvasLoading ? 0 : 1)
                        .allowsHitTesting(!loading.showsEmptyCanvasLoading)
                        .accessibilityHidden(loading.showsEmptyCanvasLoading)
                        if loading.showsEmptyCanvasLoading {
                            emptyCanvasLoadingView
                        }
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.hasImage && !photoViewing.previewOnly && coordinator.histogramExpanded {
                    FloatingHistogram(histogram: currentHistogram, showingBefore: showingBefore,
                                      availableSize: geometry.size, expanded: $coordinator.histogramExpanded,
                                      hdr:(showingBefore ? viewModel.hdrReference : viewModel.hdrPresentation)?.statistics,
                                      headroom:hdrDisplay.headroom,
                                      luminanceCursor: inspectionLuminanceCursor)
                        .frame(maxWidth: min(180, geometry.size.width * 0.48), alignment: .trailing)
                        .padding(12)
                        .padding(.top, 44)
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
                ), showsButton: false)
                .padding(.top, 44)
                .opacity(photoViewing.previewOnly ? 0 : rulerFocusOpacity)
                .allowsHitTesting(!photoViewing.previewOnly)
                .accessibilityHidden(photoViewing.previewOnly)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if loading.showsTopProgressLine {
                        previewProgressLine
                    }
                    if viewModel.isExportingHDR && !photoViewing.previewOnly {
                        hdrExportProgressBanner
                    } else if isSaving && !photoViewing.previewOnly {
                        exportSavingBanner
                    } else if let bannerKey = activityBannerKey, !photoViewing.previewOnly {
                        editorActivityBanner(titleKey: bannerKey)
                    }
                    if viewModel.previewFailed && !photoViewing.previewOnly {
                        Button { viewModel.retryPreview(settings: draftPreviewSettings) } label: {
                            Label(L10n.text("预览未更新") + " · " + L10n.text("重试"), systemImage: "arrow.clockwise")
                                .font(.caption).padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 44)
                        }
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityIdentifier("editor.preview.retry")
                    } else if case .failed = viewModel.editSaveState, !photoViewing.previewOnly {
                        editSaveStatus
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                iosInspectionHUD
                    .padding(12)
                    .padding(.bottom, (viewModel.hasImage && !photoViewing.previewOnly) ? 56 : 0)
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
            .coordinateSpace(name: "editor.photo.canvas")
            .onPreferenceChange(PhotoComparisonControlBoundsKey.self) { photoComparisonControlBounds = $0 }
            .clipped()
        }
        .onChange(of: loading.delayedBannerKey) { _, _ in
            delayedActivityBannerVisible = false
        }
        .task(id: loading.delayedBannerKey) {
            delayedActivityBannerVisible = false
            guard loading.delayedBannerKey != nil else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            delayedActivityBannerVisible = true
        }
    }

    @ViewBuilder private func editorPhotoCanvas(_ image: UIImage, size: CGSize,
                                                onPreviewSizeChange: @escaping (Int) -> Void) -> some View {
        if let projection = geometryProjection(for: image) {
            let margin = photoViewing.photoMargin ? PhotoZoomGeometry.defaultMargin : 0
            let inset = PhotoZoomGeometry.marginInset(viewport: size, margin: margin)
            let layout = projection.layout(in: size, margin: inset, editing: geometrySelected)
            let photo = GeometryDraftImage(image: image, hdr: viewModel.hdrPresentation, hdrDisplay: hdrDisplay, layout: layout)
            if geometrySelected {
                let sizing = PhotoZoomGeometry(pixels: projection.source, viewport: size, displayScale: displayScale, margin: margin)
                let edge = sizing.previewLongEdge(scale: sizing.fitScale, limit: viewModel.viewportPreviewLimit)
                ZStack {
                    photo
                    EditorCropOverlay(settings: geometryDraftBinding, imageSize: projection.safeSize,
                                      aspectRatio: geometryDraftAspectRatio, isEnabled: !editorBusy,
                                      sourceRevision: viewModel.sourceRevision, onEditingChanged: setSliderEditing,
                                                showsGrid: coordinator.geometryGrid, imageBounds: layout.safeBounds, imageOutline: layout.outline,
                                      showsHandles: !coordinator.geometryPerspective)
                }
                .clipped()
                .onChange(of: edge, initial: true) { _, edge in onPreviewSizeChange(edge) }
            } else {
                photo.mask { Path(layout.cropBounds) }.clipped()
            }
        } else {
            ZoomablePhoto(image: image, referenceImage: viewModel.basePreviewImage,
                          label: L10n.text("调整后"), viewing: $coordinator.photoViewing, viewport: $coordinator.photoViewport,
                          isDraft: geometrySelected,
                          interactionEnabled: !editorBusy && !draftExitPresented && !resetConfirmationPresented && !coordinator.showingDocumentImporter,
                          overlayAvoidanceRect: photoComparisonControlBounds,
                          onPreviewSizeChange: geometrySelected ? nil : onPreviewSizeChange,
                          hslTarget: wbProbeActive ? wbProbeInput : (hslTargetActive ? hslTargetInput : (curveTargetActive ? curveTargetInput : nil)),
                          hslTargetPoint: hslTargetActive ? coordinator.hslTargetPoint : (curveTargetActive ? coordinator.curveTargetPoint : nil),
                          nativePixelSize: viewModel.viewportNativeSize, previewSourceSize: viewModel.viewportPreviewSourceSize,
                          previewLongEdgeLimit: viewModel.viewportPreviewLimit,
                          detailOverlay: geometrySelected ? nil : viewModel.detailOverlay,
                          detailTiles: geometrySelected ? [] : viewModel.detailTiles,
                          detailBacking: geometrySelected ? nil : viewModel.detailBacking,
                          onDetailRequest: geometrySelected ? nil : { viewModel.updateDetailRequest($0) },
                          hdr: viewModel.hdrPresentation, referenceHDR: viewModel.hdrReference, hdrDisplay: hdrDisplay,
                          inspectionOverlay: geometrySelected ? .none : coordinator.inspection.overlay,
                          inspectionProbeEnabled: !geometrySelected && !hslTargetActive && !curveTargetActive && !wbProbeActive && coordinator.inspection.monitorEnabled,
                          inspectionPoint: coordinator.inspection.liveOutputPoint,
                          inspectionAnchors: inspectionMarkerPoints,
                          onInspectionPointChange: { pt in
                              if coordinator.inspection.liveOutputPoint != pt {
                                  coordinator.inspection.liveOutputPoint = pt
                              }
                          })
                .allowsHitTesting(!geometrySelected)
        }
    }

    @ViewBuilder
    var comparisonModeMenu: some View {
        Button(L10n.text("并排")) { photoViewing.selectMode(.sideBySide) }
            .accessibilityIdentifier("editor.compare.sideBySide")
            .disabled(viewModel.basePreviewImage == nil || geometrySelected)
        Button(L10n.text("分割线")) { photoViewing.selectMode(.wipe) }
            .accessibilityIdentifier("editor.compare.wipe")
            .disabled(viewModel.basePreviewImage == nil || geometrySelected)
        Button(L10n.text("重置分割线")) { photoViewing.setSplit(0.5) }
        Button(L10n.text("关闭对比")) { if photoViewing.enabled { photoViewing.toggleComparison() } }
            .accessibilityIdentifier("editor.compare.close")
    }

    var hdrExportProgressBanner: some View {
        HStack(spacing: 10) {
            if !reduceMotion {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(viewModel.isStoppingHDRExport ? L10n.text("正在停止…") : L10n.text("正在导出"))
                        .font(.caption.weight(.medium))
                    if let progress = viewModel.hdrExportProgress, !viewModel.isStoppingHDRExport {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !reduceMotion, let progress = viewModel.hdrExportProgress, !viewModel.isStoppingHDRExport {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                        .animation(.easeOut(duration: 0.2), value: progress)
                }
            }
            Button(L10n.text("取消导出"), action: viewModel.cancelHDRExport)
                .font(.caption.weight(.semibold))
                .disabled(viewModel.isStoppingHDRExport)
                .accessibilityIdentifier("editor.exportProgress.cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.exportProgress")
    }

    var exportSavingBanner: some View {
        HStack(spacing: 8) {
            if !reduceMotion {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
            Text(L10n.text("正在保存"))
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.exportSaving")
    }

    var emptyCanvasLoadingView: some View {
        VStack(spacing: 12) {
            if !reduceMotion {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.regular)
                    .tint(.yellow)
            }
            Text(L10n.text("正在导入照片…"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.empty.loading")
    }

    func editorActivityBanner(titleKey: String) -> some View {
        HStack(spacing: 8) {
            if !reduceMotion {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.yellow)
            }
            Text(L10n.text(titleKey))
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.activity.banner")
    }

    var previewProgressLine: some View {
        IndeterminateProgressLine(height: 3)
            .accessibilityLabel(L10n.text(editorLoadingPresentation.progressAccessibilityKey))
            .accessibilityIdentifier("editor.preview.updating")
    }

    @ViewBuilder var adjustmentPanel: some View {
        Group {
            if viewModel.quickPresetsVisible {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.isHDREditing {
                        let revision = viewModel.sourceRevision
                        HDRLookControls(settings: Binding(get: { settings.hdr ?? HDRSettings() },
                            set: { if viewModel.sourceRevision == revision && settings.isHDREditing && !isEditorDraftActive { settings.hdr = $0 } }
                        ), onEditingChanged: setSliderEditing, onCancelled: cancelSliderInteraction,
                           onResourceRestored: { viewModel.retryPreview(settings: settings) })
                            .padding(.horizontal, 16).id(revision).disabled(editorBusy || editingLocked || isEditorDraftActive)
                    }
                    IOSQuickPresetView(model: viewModel, requestAction: requestAdjustmentAction,
                        manage: { adjustmentSheet = .presets }, undo: undoQuickPreset, libraryRevision: coordinator.presetLibraryRevision)
                }
            } else { valuePanel }
        }.disabled(settings.isHDREditing && !viewModel.quickPresetsVisible && !supportsHDR(currentEditorTool))
            .environment(\.compactAdjustmentRows, [AdjustmentKind.temperature, .tint, .hsl, .vignette, .grain, .noiseReduction].contains(selectedAdjustment ?? .strength))
            .environment(\.adjustmentFine, adjustmentFine)
            .environment(\.adjustmentInputContext, parameterInputContext)
            .padding(.vertical, 4)
    }

    var usesNormalX3f: Bool { viewModel.sourceIsX3f && settings.x3fMode == .normal }

    var processingContextSheet: some View {
            NavigationStack {
                Form {
                    Text(selectedFilmName)
                    editSaveStatus
                    if let status = viewModel.processingMigrationStatus {
                        Text(L10n.text(status)).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("processing.migration.status")
                    }
                    if viewModel.processingMigrationReceipt?.status == .migrated {
                        Button(L10n.text("回到迁移前")) { coordinator.confirmingProcessingRollback = true }
                            .disabled(isEditorDraftActive || editorBusy || viewModel.matchingProcessing)
                            .accessibilityIdentifier("processing.migration.rollback")
                    }
                    if viewModel.sourceIsHDR || viewModel.sourceSupportsCameraHDR {
                        Toggle(L10n.text("HDR 编辑"),isOn:Binding(
                            get:{ settings.isHDREditing || viewModel.cameraHDRPreflight },
                            set:setHDREditing
                        ))
                            .disabled(isEditorDraftActive || editorBusy || viewModel.previewRendering)
                            .accessibilityIdentifier("hdr.editMode")
                    }
                    if settings.isHDREditing {
                        HDRMonitoringControls(state:hdrDisplay)
                        HDRRenditionControls(settings: Binding(
                            get: { settings.hdr?.renditionSettings ?? HDRRenditionSettings() },
                            set: { if settings.isHDREditing { settings.hdr?.renditionSettings = $0 } }
                        ), onEditingChanged: setSliderEditing, onCancelled: cancelSliderInteraction)
                            .id(viewModel.sourceRevision)
                            .disabled(isEditorDraftActive || editorBusy)
                        if viewModel.sourceSupportsCameraHDR, viewModel.sourceProRAW == nil, let hdr = settings.hdr {
                            HDRCameraDevelopmentControls(settings: hdr.cameraDevelopmentSettings,
                                supportsBayerDevelopment: viewModel.rawHDRSource?.supportsBayerDevelopment == true,
                                apply: applyHDRCameraDevelopment,
                                onResourceRestored: { viewModel.retryPreview(settings: settings) })
                                .id(viewModel.sourceRevision).disabled(isEditorDraftActive || editorBusy)
                        }
                    }
                    if viewModel.sourceIsX3f {
                        Picker(L10n.text("X3F 显影"), selection: Binding(get: { settings.x3fMode }, set: { mode in
                            var next = settings
                            next.selectX3fMode(mode)
                            settings = next
                        })) {
                            ForEach(X3fMode.allCases) { mode in
                                Text(mode.title).tag(mode).disabled(mode == .normal && sony2fuji_x3f_available() == 0)
                            }
                        }
                        .disabled(isEditorDraftActive || editorBusy)
                        .accessibilityIdentifier("x3f.mode")
                        Text(L10n.text(usesNormalX3f ? "以文件保存的显影为基准，白平衡作相对调整。" : "保留旧版的特殊色彩。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if viewModel.sourceKind == .raw && !settings.isHDREditing {
                        Picker(L10n.text("曝光基准"), selection: $coordinator.settings.exposureMode) {
                            ForEach(RawExposureMode.allCases) { Text($0.title).tag($0) }
                        }.disabled(isEditorDraftActive || editorBusy || usesNormalX3f)
                    }
                }
                .navigationTitle(L10n.text("照片处理设置"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("关闭")) { coordinator.dismissProcessingContext() } } }
            }.presentationDetents([.medium, .large])
                .alert(L10n.text("回到迁移前"), isPresented: $coordinator.confirmingProcessingRollback) {
                    Button(L10n.text("回到迁移前")) { viewModel.rollbackProcessingMigration(settings: settings) }
                    Button(L10n.text("取消"), role: .cancel) { }
                } message: { Text(L10n.text("将恢复迁移前的全部调整，之后的修改会被替换。")) }
    }

    private var parameterInputContext: AdjustmentInputContext {
        let source = viewModel.sourceRevision
        let tool = currentEditorTool
        let channel = hslChannel
        let grading = coordinator.gradingZone
        let gradingGlobal = coordinator.gradingGlobalSelected
        let perspective = coordinator.geometryPerspective, rotation = coordinator.geometryRotation
        let hdr = settings.isHDREditing
        return AdjustmentInputContext(id: "\(source).\(tool.stableID).\(channel).\(grading.rawValue).\(gradingGlobal).\(perspective).\(rotation).\(hdr)", isCurrent: {
            viewModel.sourceRevision == source && currentEditorTool == tool && adjustmentsExpanded && settings.isHDREditing == hdr &&
                (tool != .adjustment(.hsl) || hslChannel == channel) &&
                (tool != .adjustment(.colorGrading) || (coordinator.gradingZone == grading && coordinator.gradingGlobalSelected == gradingGlobal)) &&
                (tool != .geometry || coordinator.geometryPerspective == perspective && coordinator.geometryRotation == rotation)
        }, canChange: { !viewModel.adjustmentInteractionRejected }, onInteractionCancelled: {
            if viewModel.sourceRevision == source && currentEditorTool == tool && settings.isHDREditing == hdr &&
                (tool != .adjustment(.hsl) || hslChannel == channel) &&
                (tool != .adjustment(.colorGrading) || (coordinator.gradingZone == grading && coordinator.gradingGlobalSelected == gradingGlobal)) &&
                (tool != .geometry || coordinator.geometryPerspective == perspective && coordinator.geometryRotation == rotation) {
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

    func groupNavigation(side: Bool, singleLine: Bool = false, availableWidth: CGFloat = 0) -> some View {
        let buttonWidth = groupNavigationButtonWidth
        let buttonHeight: CGFloat = singleLine ? 48 : groupNavigationButtonHeight
        let rows = stride(from: 0, to: mobileEditorGroups.count, by: 3).map {
            Array(mobileEditorGroups[$0..<min($0 + 3, mobileEditorGroups.count)])
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            let layout = side && !adjustmentsExpanded
                ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                if side && !adjustmentsExpanded {
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(rows[row], id: \.rawValue) { group in
                                groupNavigationButton(group, width: buttonWidth, height: buttonHeight)
                            }
                        }
                    }
                } else {
                    ForEach(mobileEditorGroups, id: \.rawValue) { group in
                        let width = singleLine ? max(max(44, (availableWidth - 16) / CGFloat(max(mobileEditorGroups.count, 1))), ceil((group.title as NSString).size(withAttributes:
                            [.font: UIFont.preferredFont(forTextStyle: .caption1)]).width) + 16) : buttonWidth
                        groupNavigationButton(group, width: width, height: buttonHeight, singleLine: singleLine)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: buttonHeight * (side && !adjustmentsExpanded ? CGFloat(max(rows.count, 1)) : 1))
        .disabled(editorBusy)
        .accessibilityIdentifier("editor.groups")
    }

    private func groupNavigationButton(_ group: EditorAdjustmentGroup, width: CGFloat, height: CGFloat,
                                       singleLine: Bool = false) -> some View {
        Button { selectEditorGroup(group) } label: {
            VStack(spacing: 4) {
                Text(group.title).font(.caption).lineLimit(singleLine ? 1 : 2)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .modifier(OptionalGeometryObserver(action: testHooks.onGroupTextFrame.map { hook in
                        { frame in hook(group, frame) }
                    }))
                Circle().fill(resetModified(.group(group)) ? Color.yellow : .clear).frame(width: 4, height: 4)
            }
            .padding(.horizontal, 4)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .modifier(OptionalGeometryObserver(action: testHooks.onGroupButtonFrame.map { hook in
                { frame in hook(group, frame, height) }
            }))
            .foregroundStyle(selectedGroup == group ? Color.yellow : .primary)

        }
        .buttonStyle(.plain)
        .disabled(settings.isHDREditing && group != .looks && !EditorAdjustmentRules.tools(group).contains(where:supportsHDR))
        .accessibilityLabel(L10n.format(adjustmentsExpanded && selectedGroup == group ? "收起%@组" : "展开%@组", group.title))
        .accessibilityValue(resetModified(.group(group)) ? L10n.text("已调整") : "")
        .accessibilityAddTraits(selectedGroup == group ? .isSelected : [])
        .accessibilityIdentifier("editor.group.\(group.rawValue)")
    }

    func editorToolAccessibilityValue(_ tool: EditorToolSelection) -> String {
        switch tool {
        case .film: return selectedFilmName
        case .recipe: return settings.masterRecipe?.title ?? L10n.text("无配方")
        case .adjustment(.toneCurve) where !settings.editingCurveSettings.isDefault:
            return L10n.format("多点曲线（%d 个控制点）", settings.editingCurveSettings.labeledPoints.count)
        case .adjustment(let adjustment): return adjustment.valueLabel(for: adjustment.value(from: settings))
        case .hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation:
            guard let keyPath = tool.hdrRenditionKeyPath else { return "" }
            let value = settings.hdr?.renditionSettings[keyPath: keyPath] ?? 0
            let isEV = tool == .hdrPeakLimit || tool == .hdrSDRExposure
            let number = value == 0 ? "0" : String(format: isEV ? "%+.1f" : "%+.0f", locale: L10n.locale, value)
            return "\(number) \(isEV ? "EV" : "%")"
        default: return resetModified(.tool(tool)) ? L10n.text("已调整") : ""
        }
    }
}

struct EditorCompactActionStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 32)
            .foregroundStyle(selected ? Color.yellow : Color.secondary)
            .background(selected ? Color.yellow.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow.opacity(0.5) : Color.secondary.opacity(0.35)) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
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
        case .hdrPeakLimit: return "hdrPeakLimit"
        case .hdrSDRExposure: return "hdrSDRExposure"
        case .hdrSDRContrast: return "hdrSDRContrast"
        case .hdrSDRSaturation: return "hdrSDRSaturation"
        }
    }
    var title: String {
        switch self {
        case .film: return L10n.text("胶片")
        case .recipe: return L10n.text("大师配方")
        case .lens: return L10n.text("镜头")
        case .geometry: return L10n.text("几何")
        case .adjustment(let kind): return kind.title
        case .hdrPeakLimit: return L10n.text("HDR 亮度上限")
        case .hdrSDRExposure: return L10n.text("SDR 底图曝光")
        case .hdrSDRContrast: return L10n.text("SDR 底图对比度")
        case .hdrSDRSaturation: return L10n.text("SDR 底图饱和度")
        }
    }
    var symbol: String {
        switch self {
        case .film: return "film"
        case .recipe: return "square.stack.3d.up"
        case .lens: return "viewfinder"
        case .geometry: return "crop.rotate"
        case .adjustment(let kind): return kind.iconName
        case .hdrPeakLimit: return "sun.max"
        case .hdrSDRExposure: return "plusminus.circle"
        case .hdrSDRContrast: return "circle.lefthalf.filled"
        case .hdrSDRSaturation: return "drop.halffull"
        }
    }
}

private struct PhotoComparisonControlBoundsKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
