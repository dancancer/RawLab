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
                    .foregroundStyle(showingBefore ? Color.yellow : Color.primary)
            }
            .accessibilityLabel("前后对比")
            .accessibilityValue(showingBefore ? "调整前" : "调整后")
            .help("切换调整前后")
            .disabled(!viewModel.hasImage)
            .accessibilityIdentifier("editor.compare")

            Button { adjustmentsExpanded.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(adjustmentsExpanded ? Color.yellow : Color.primary)
            }
            .accessibilityLabel(adjustmentsExpanded ? "收起调整栏" : "展开调整栏")
            .help("显示或收起调整栏")
            .accessibilityIdentifier("editor.adjustments")

            Button(action: exportJPEG) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("保存到照片")
            .help("保存到照片")
            .disabled(!viewModel.hasImage || editorBusy)
            .accessibilityIdentifier("editor.export")
        }
    }

    var previewSection: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.12)
                if let image = currentPreviewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityLabel(showingBefore ? "调整前的照片" : "调整后的照片")
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("RAW 照片").font(.headline)
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label("导入照片", systemImage: "photo.badge.plus")
                                .padding(.vertical, 8)
                        }
                        .disabled(editorBusy)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.hasImage {
                    FloatingHistogram(values: currentHistogram, expanded: $histogramExpanded)
                        .frame(maxWidth: min(220, geometry.size.width - 24), alignment: .trailing)
                        .padding(12)
                }
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
            .overlay {
                if editorBusy {
                    ProgressView(isImporting ? "正在导入" : isSaving ? "正在保存" : "正在处理")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .allowsHitTesting(false)
                }
            }
            .clipped()
        }
    }

    func adjustmentPanel(compact: Bool) -> some View {
        VStack(spacing: compact ? 0 : 8) {
            HStack {
                Text(selectedFilmName)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
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

            if compact {
                HStack(alignment: .top, spacing: 0) {
                    toolStrip.frame(maxWidth: .infinity)
                    valuePanel(compact: true).frame(maxWidth: .infinity)
                }
            } else {
                toolStrip
                valuePanel(compact: false)
            }
        }
        .padding(.bottom, 12)
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
                                                progress: adjustment.progress(in: settings),
                                                width: toolWidth, height: toolHeight)
                        }
                        .disabled(adjustment == .strength && settings.lutID == nil)
                        .accessibilityValue(adjustment.valueLabel(for: adjustment.value(from: settings)))
                        .accessibilityAddTraits(selectedAdjustment == adjustment ? .isSelected : [])
                        .accessibilityIdentifier("tool.\(adjustment.rawValue)")
                        .contextMenu {
                            Button("重置\(adjustment.title)") { reset(adjustment) }
                                .disabled(!viewModel.hasImage || adjustment.progress(in: settings) == 0 || editingLocked)
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
    func valuePanel(compact: Bool) -> some View {
        if let adjustment = selectedAdjustment {
            VStack(spacing: 4) {
                HStack {
                    Text(adjustment.title).font(.subheadline)
                    Spacer()
                    Text(adjustment.valueLabel(for: adjustment.value(from: settings)))
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button { reset(adjustment) } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("重置\(adjustment.title)")
                    .disabled(adjustment.progress(in: settings) == 0)
                }
                Slider(value: adjustmentBinding(adjustment), in: adjustment.range, step: adjustment.step,
                       onEditingChanged: setSliderEditing)
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
        } else {
            filmPanel(imageSize: compact ? filmSize * 0.6 : filmSize)
        }
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
