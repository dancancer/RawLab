import PhotosUI
import SwiftUI

struct IOSLUTCompatibilityView: View {
    let source: URL
    let draft: LUTCompatibility
    let initialPhoto: LUTPreviewSource?
    let finish: (LUTCompatibility?) -> Void
    @StateObject private var selection = IOSLUTLibrarySelection()
    @State private var choosingPhoto = false
    @State private var items: [PhotosPickerItem] = []
    @State private var selectedPhoto: ((LUTPreviewSource) -> Void)?

    var body: some View {
        ZStack {
            LUTCompatibilityView(fileName: source.lastPathComponent, sourceURL: source, draft: draft,
                initialPhoto: initialPhoto, chooseLibraryPhoto: { completion in
                    selectedPhoto = completion; items = []; choosingPhoto = true
                }, finish: finish)
                .disabled(selection.loading)
            if selection.loading {
                VStack(spacing: 16) {
                    ProgressView(L10n.text("正在准备照片…"))
                    Button(L10n.text("取消")) { selection.cancel(); selectedPhoto = nil }
                }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("look.compatibility.library.loading")
            }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $items, maxSelectionCount: 1,
                      matching: .images, preferredItemEncoding: .current, photoLibrary: .shared())
        .onChange(of: items) { _, values in
            guard let item = values.first else { return }
            items = []
            selection.load(using: { try await PhotoImportFile.load(from: item) }) { photo in
                // 预览队列读完之前，闭包保留图库下载副本；不调用编辑器的照片导入。
                selectedPhoto?(LUTPreviewSource(name: photo.name) { try photo.copy(to: $0) })
                selectedPhoto = nil
            }
        }
        .alert(L10n.text("Failed to load the selected photo."), isPresented: Binding(
            get: { selection.error != nil }, set: { if !$0 { selection.error = nil } })) {
                Button(L10n.text("确定")) { selection.error = nil }
            } message: { Text(selection.error ?? "") }
        .onDisappear { selection.cancel(); selectedPhoto = nil }
    }
}
