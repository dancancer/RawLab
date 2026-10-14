import SwiftUI

extension ContentView {
    func editorWorkspace(size: CGSize, accessibility: Bool) -> some View {
        let side = EditorLayoutPolicy.usesSidePanel(width: size.width, height: size.height,
                                                   accessibility: accessibility)
        let layout = side ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            VStack(spacing: 0) {
                previewSection.frame(maxWidth: .infinity, maxHeight: .infinity)
                if viewModel.hasImage && adjustmentsExpanded {
                    Divider()
                    toolStrip.background(Color(.secondarySystemBackground))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if viewModel.hasImage && adjustmentsExpanded {
                Divider()
                VStack(spacing: 0) {
                    ScrollView(.vertical) { adjustmentPanel }
                        .accessibilityIdentifier("editor.panel")
                    if geometrySelected || lensSelected {
                        Divider()
                        editorDraftActions.padding(.horizontal, 16).padding(.vertical, 8)
                    }
                }
                .frame(width: side ? min(320, size.width * 0.48) : nil,
                       height: side ? nil : adjustmentRegionHeight(size: size, accessibility: accessibility))
                .background(Color(.secondarySystemBackground))
            }
        }
        .background(Color(.systemBackground))
    }

    private func adjustmentRegionHeight(size: CGSize, accessibility: Bool) -> CGFloat {
        let extra: CGFloat = geometrySelected ? 160 : lensSelected ? 100 : selectedAdjustment == .hsl ? 130 : 0
        return min(panelHeight + extra, size.height * (accessibility ? 0.64 : 0.52))
    }
}
