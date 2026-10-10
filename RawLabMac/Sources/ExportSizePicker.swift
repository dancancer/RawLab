import SwiftUI

struct ExportSizeAccessory: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        ExportSizePicker(longEdge: $model.exportLongEdge)
    }
}

struct ExportSizePicker: View {
    @Binding var longEdge: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("导出尺寸", selection: Binding(get: { longEdge != nil }, set: { longEdge = $0 ? 2048 : nil })) {
                Text("原始尺寸").tag(false)
                Text("指定长边").tag(true)
            }
            .pickerStyle(.segmented)
            if longEdge != nil {
                HStack(spacing: 8) {
                    Text("长边")
                    TextField("像素", value: Binding(get: { longEdge ?? 2048 }, set: {
                        longEdge = min(65535, max(1, $0))
                    }), format: .number.grouping(.never))
                        .frame(width: 80).textFieldStyle(.roundedBorder).accessibilityLabel("导出长边像素")
                    Text("px").foregroundStyle(.secondary)
                    Menu {
                        ForEach([2048, 3000, 4096], id: \.self) { edge in
                            Button("\(edge) px") { longEdge = edge }
                        }
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize().help("常用尺寸").accessibilityLabel("常用导出尺寸")
                }
            }
        }
    }
}
