import SwiftUI
import UIKit

struct ExportSizePicker: View {
    @Binding var longEdge: Int?
    var title = "导出尺寸"
    var onValidityChanged: (Bool) -> Void = { _ in }
    @State private var customText = ""
    @State private var choice = 0

    private var customSelected: Bool { choice == -1 }
    private var customValueIsValid: Bool {
        !customSelected || (Int(customText).map { ExportSize.isValid($0) } == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(title, selection: $choice) {
                Text("原始分辨率").tag(0)
                ForEach(ExportSize.presets, id: \.self) { edge in
                    Text("长边 \(edge) px").tag(edge)
                }
                Text("自定义…").tag(-1)
            }
            .pickerStyle(.menu)

            if customSelected {
                TextField("长边（1–65535 px）", text: $customText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customText) { _, value in
                        longEdge = ExportSize.normalized(Int(value))
                        onValidityChanged(customValueIsValid)
                    }
                if !customValueIsValid {
                    Text("请输入 1–65535 之间的像素数")
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
    @Binding var longEdge: Int?
    let onExport: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sizeIsValid = true

    private var canExport: Bool {
        sizeIsValid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ExportSizePicker(longEdge: $longEdge) { sizeIsValid = $0 }
                }
            }
            .navigationTitle("保存当前照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导出") { onExport() }
                        .disabled(!canExport)
                        .accessibilityIdentifier("editor.export.confirm")
                }
            }
        }
        .presentationDetents([.height(250)])
        .preferredColorScheme(.dark)
        .tint(.yellow)
    }
}
