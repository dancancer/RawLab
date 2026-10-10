import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var viewModel = RawEditorViewModel()
    @State var settings = RawSettings.default
    @State private var didAutoLoadSample = false
    @State var showingBefore = false
    @State var selectedAdjustment: AdjustmentKind? = .exposure
    @State var adjustmentsExpanded = true
    @State var histogramExpanded = false
    @State var isImporting = false
    @State var isSaving = false
    @State var isAdjustingSlider = false
    @State var selectedPhotoItem: PhotosPickerItem?
    @State private var checkedBatchRecovery = false
    @State var showingBatchExport = false
    @State var batchModel: BatchExportModel?
    @ScaledMetric(relativeTo: .caption) var toolWidth = 62.0
    @ScaledMetric(relativeTo: .caption) var toolHeight = 82.0
    @ScaledMetric(relativeTo: .caption) var filmSize = 72.0
    @ScaledMetric(relativeTo: .body) var panelHeight = 256.0

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height && !dynamicTypeSize.isAccessibilitySize
                let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    previewSection
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if viewModel.hasImage && adjustmentsExpanded {
                        Divider()
                        ScrollView(.vertical) {
                            adjustmentPanel
                        }
                        .accessibilityIdentifier("editor.panel")
                        .frame(width: landscape ? min(360, geometry.size.width * 0.44) : nil,
                               height: landscape ? nil : min(panelHeight + (selectedAdjustment == nil ? 32 : selectedAdjustment == .noiseReduction ? 80 : 0),
                                                            geometry.size.height * 0.6))
                        .background(Color(.secondarySystemBackground))
                    }
                }
                .background(Color(.systemBackground))
            }
            .safeAreaInset(edge: .top) {
                if let batchModel, !showingBatchExport {
                    Button { showingBatchExport = true } label: {
                        HStack {
                            Image(systemName: "square.stack.3d.up")
                            Text("查看批量任务 · \(batchModel.job.targets.count) 张")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.font(.subheadline).padding(12)
                    }.background(Color(.secondarySystemBackground)).accessibilityIdentifier("batch.resume")
                }
            }
            .navigationTitle("RawLab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .toolbarBackground(Color(.secondarySystemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .tint(.yellow)
        .alert("RawLab", isPresented: Binding(
            get: { viewModel.statusMessage != nil },
            set: { if !$0 { viewModel.statusMessage = nil } }
        )) {
            Button("关闭", role: .cancel) { viewModel.statusMessage = nil }
        } message: {
            Text(viewModel.statusMessage ?? "")
        }
        .onChange(of: settings) { _, newValue in
            if viewModel.consumeRestoredSettings(newValue) { return }
            showingBefore = false
            viewModel.queueSettingsSave(newValue)
            if isAdjustingSlider {
                viewModel.schedulePreviewUpdate(
                    settings: newValue,
                    delay: 0.08,
                    includeHistogram: false,
                    quality: .interactive
                )
            } else {
                viewModel.updatePreview(settings: newValue, includeHistogram: true, quality: .final)
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await importFromPhotoItem(newItem)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                viewModel.saveCurrentSettings(settings)
            }
            if phase == .background { batchModel?.cancel(forBackground: true) }
        }
        .onChange(of: viewModel.isBusy) { _, busy in
            if !busy { isImporting = false }
        }
        .onChange(of: viewModel.hasImage) { _, hasImage in
            if hasImage { adjustmentsExpanded = true }
        }
        .onChange(of: adjustmentsExpanded) { _, expanded in
            if !expanded && isAdjustingSlider { setSliderEditing(false) }
        }
        .onChange(of: selectedAdjustment) { _, _ in
            if isAdjustingSlider { setSliderEditing(false) }
        }
        .onAppear {
            viewModel.loadLUTsIfNeeded()
            if !checkedBatchRecovery { checkedBatchRecovery = true; recoverBatchExport() }
            guard !didAutoLoadSample else { return }
            if ProcessInfo.processInfo.environment["RAWLAB_SMOKE_TEST"] == "1" {
                didAutoLoadSample = true
                viewModel.runBundledSampleSmokeTest(settings: settings)
            }
        }
        .sheet(isPresented: $showingBatchExport) {
            if let batchModel {
                BatchExportView(model: batchModel)
            }
        }
    }
}

#Preview {
    ContentView()
}
