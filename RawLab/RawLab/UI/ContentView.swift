import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
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
    @ScaledMetric(relativeTo: .caption) var toolWidth = 62.0
    @ScaledMetric(relativeTo: .caption) var toolHeight = 82.0
    @ScaledMetric(relativeTo: .caption) var filmSize = 72.0
    @ScaledMetric(relativeTo: .body) var panelHeight = 264.0

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    previewSection
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if adjustmentsExpanded {
                        Divider()
                        ScrollView(.vertical) {
                            adjustmentPanel(compact: geometry.size.height < 400)
                        }
                        .frame(height: min(panelHeight, geometry.size.height * 0.48))
                        .background(Color(.secondarySystemBackground))
                    }
                }
                .background(Color(.systemBackground))
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
            showingBefore = false
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
        .onChange(of: viewModel.isBusy) { _, busy in
            if !busy { isImporting = false }
        }
        .onChange(of: adjustmentsExpanded) { _, expanded in
            if !expanded && isAdjustingSlider { setSliderEditing(false) }
        }
        .onChange(of: selectedAdjustment) { _, _ in
            if isAdjustingSlider { setSliderEditing(false) }
        }
        .onAppear {
            viewModel.loadLUTsIfNeeded()
            guard !didAutoLoadSample else { return }
            if ProcessInfo.processInfo.environment["RAWLAB_SMOKE_TEST"] == "1" {
                didAutoLoadSample = true
                viewModel.runBundledSampleSmokeTest(settings: settings)
            }
        }
    }
}

#Preview {
    ContentView()
}
