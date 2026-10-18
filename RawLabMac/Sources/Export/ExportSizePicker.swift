import SwiftUI

struct ExportSizeAccessory: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    var body: some View {
        let _ = localizationLocale
        ExportSizePicker(longEdge: $model.exportLongEdge)
    }
}

struct ExportSizePicker: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var longEdge: Int?
    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("导出尺寸")).font(.subheadline)
            Picker(L10n.text("导出尺寸"), selection: Binding(get: { longEdge != nil }, set: { longEdge = $0 ? 2048 : nil })) {
                Text(L10n.text("原始尺寸")).tag(false)
                Text(L10n.text("指定长边")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .id(localizationLocale.identifier)
            if longEdge != nil {
                HStack(spacing: 8) {
                    Text(L10n.text("长边"))
                    TextField(L10n.text("像素"), value: Binding(get: { longEdge ?? 2048 }, set: {
                        longEdge = min(65535, max(1, $0))
                    }), format: .number.grouping(.never))
                        .frame(width: 80).textFieldStyle(.roundedBorder).accessibilityLabel(L10n.text("导出长边像素"))
                    Text("px").foregroundStyle(.secondary)
                    Menu {
                        ForEach([2048, 3000, 4096], id: \.self) { edge in
                            Button("\(edge) px") { longEdge = edge }
                        }
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize().help(L10n.text("常用尺寸")).accessibilityLabel(L10n.text("常用导出尺寸"))
                }
            }
        }
    }
}
