import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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

struct IOSDCPImportOptionsView: View {
    let source: URL
    let reason: DCPCompilerError
    let finish: (DCPImportOptions?) -> Void
    @State private var choosingCurve = false
    @State private var curveData: Data?
    @State private var curveFileName: String?
    @State private var omitAutomaticBlack = false
    @State private var errorMessage: String?

    private var requiresToneCurve: Bool { reason == .missingToneCurve }
    private var requiresAutomaticBlackChoice: Bool { reason == .automaticBlack }
    private var canImport: Bool {
        (!requiresToneCurve || curveData != nil) && (!requiresAutomaticBlackChoice || omitAutomaticBlack)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(source.lastPathComponent).font(.headline)
                    Text(reason.localizedDescription).foregroundStyle(.secondary)
                }
                if requiresToneCurve {
                    Section(L10n.text("色调曲线（JSON）")) {
                        Button {
                            choosingCurve = true
                        } label: {
                            Label(curveFileName ?? L10n.text("选择曲线文件…"), systemImage: "doc.text")
                        }
                    }
                }
                Section {
                    Toggle(L10n.text("省略自动黑位"), isOn: $omitAutomaticBlack)
                }
            }
            .navigationTitle(L10n.text("DCP 导入选项"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) { finish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("导入外观")) {
                        finish(DCPImportOptions(toneCurveJSON: curveData,
                                                omitAutomaticBlack: omitAutomaticBlack))
                    }.disabled(!canImport)
                }
            }
        }
        .fileImporter(isPresented: $choosingCurve, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            choosingCurve = false
            guard case .success(let urls) = result, let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 1024 * 1024 else {
                    errorMessage = L10n.text("DCP 文件或外观数据超过安全大小限制。")
                    return
                }
                curveData = data
                curveFileName = url.lastPathComponent
            } catch {
                errorMessage = L10n.text("无法读取外观文件。")
            }
        }
        .alert(L10n.text("DCP 导入选项"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L10n.text("确定")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .interactiveDismissDisabled(!canImport)
    }
}
