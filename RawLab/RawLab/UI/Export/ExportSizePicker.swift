import SwiftUI
import UIKit

struct ExportSizePicker: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var longEdge: Int?
    var title: String? = nil
    var onValidityChanged: (Bool) -> Void = { _ in }
    @State private var customText = ""
    @State private var choice = 0

    private var customSelected: Bool { choice == -1 }
    private var customValueIsValid: Bool {
        !customSelected || (Int(customText).map { ExportSize.isValid($0) } == true)
    }

    var body: some View {
        let _ = localizationLocale
        VStack(alignment: .leading, spacing: 8) {
            Picker(title ?? L10n.text("导出尺寸"), selection: $choice) {
                Text(L10n.text("原始尺寸")).tag(0)
                ForEach(ExportSize.presets, id: \.self) { edge in
                    Text(L10n.format("长边 %@ px", String(describing: edge))).tag(edge)
                }
                Text(L10n.text("指定长边")).tag(-1)
            }
            .pickerStyle(.menu)
            .id(localizationLocale.identifier)

            if customSelected {
                // 占位文字在填入数字后就不显示了，读屏名称要单独给
                TextField(L10n.text("长边（1–65535 px）"), text: $customText)
                    .accessibilityLabel(L10n.text("长边（1–65535 px）"))
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customText) { _, value in
                        longEdge = ExportSize.normalized(Int(value))
                        onValidityChanged(customValueIsValid)
                    }
                if !customValueIsValid {
                    Text(L10n.text("请输入 1–65535 之间的像素数"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            choice = selectionValue(for: longEdge)
            if let longEdge, choice == -1 { customText = String(longEdge) }
            onValidityChanged(customValueIsValid)
        }
        .onChange(of: choice) { _, value in
            if value == 0 {
                longEdge = nil
            } else if value > 0 {
                longEdge = value
            } else {
                longEdge = ExportSize.normalized(Int(customText))
            }
            onValidityChanged(customValueIsValid)
        }
        .onChange(of: longEdge) { _, value in
            guard !customSelected else { return }
            choice = selectionValue(for: value)
            if choice == -1, let value { customText = String(value) }
            onValidityChanged(customValueIsValid)
        }
    }

    private func selectionValue(for value: Int?) -> Int {
        guard let value else { return 0 }
        return ExportSize.presets.contains(value) ? value : -1
    }
}

struct ExportSizeSheet: View {
    @Environment(\.locale) private var localizationLocale
    @Binding var longEdge: Int?
    var title = "保存当前照片"
    let onExport: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sizeIsValid = true

    private var canExport: Bool {
        sizeIsValid
    }

    var body: some View {
        let _ = localizationLocale
        NavigationStack {
            // 标题放在表单顶部而不是导航栏：夹在"取消""导出"之间时，德语、法语等会被截成"…"
            Form {
                Section {
                    ExportSizePicker(longEdge: $longEdge) { sizeIsValid = $0 }
                } header: {
                    Text(L10n.text(title)).font(.headline).foregroundStyle(.primary)
                        .textCase(nil).fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("导出")) { onExport() }
                        .disabled(!canExport)
                        .accessibilityIdentifier("editor.export.confirm")
                }
            }
        }
        .presentationDetents([.height(290)])
        .preferredColorScheme(.dark)
        .tint(.yellow)
    }
}
