import SwiftUI

struct AdjustmentScopeEditor: View {
    @Binding var scope: String
    @Binding var fields: Set<AdjustmentTransferField>
    let preview: Result<AdjustmentTransferPayload, Error>
    let lookName: (String, String) -> String?
    let errorMessage: (Error) -> String
    var identifier = "adjustment.copy"
    var titleKey = "复制范围"
    var allowed = AdjustmentTransferField.legacyFields

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L10n.text(titleKey), selection: $scope) {
                Text(L10n.text("全部")).tag("all")
                Text(L10n.text("仅已修改")).tag("modified")
                Text(L10n.text("自定义")).tag("custom")
            }.pickerStyle(.segmented).accessibilityIdentifier(identifier + ".scope")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    AdjustmentScopeSummaryView(preview: preview, modified: scope == "modified", lookName: lookName,
                        errorMessage: errorMessage, identifier: identifier + ".summary", showsGroups: scope != "custom")
                    if scope == "custom" {
                        Divider()
                        Button(L10n.text("清空选择")) { fields.removeAll() }.disabled(fields.isEmpty)
                            .accessibilityIdentifier(identifier + ".clear")
                        ForEach(["looks", "light", "color", "effects", "detail", "geometry"].filter { group in allowed.contains { $0.group==group } }, id: \.self) { group in
                            DisclosureGroup {
                                let members = AdjustmentTransferField.allCases.filter { $0.group == group && allowed.contains($0) }
                                Toggle(L10n.text("选择此组"), isOn: groupBinding(members)).fontWeight(.medium)
                                ForEach(members.filter { $0.hslLocation == nil }, id: \.rawValue) { fieldToggle($0) }
                                if members.contains(where:{ $0.hslLocation != nil }) {
                                    ForEach(HSLAxis.allCases) { axis in
                                        DisclosureGroup("HSL · \(axis.title)") {
                                            let items = members.filter { $0.hslLocation?.axis == axis.rawValue }
                                            Toggle(L10n.text("选择此组"), isOn: groupBinding(items))
                                            ForEach(items, id: \.rawValue) { fieldToggle($0) }
                                        }.padding(.leading, 12)
                                    }
                                }
                            } label: {
                                let members = AdjustmentTransferField.allCases.filter { $0.group == group && allowed.contains($0) }
                                Text(AdjustmentTransferField.groupTitle(group) + " · \(members.filter { fields.contains($0) }.count)/\(members.count)")
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }.padding(.trailing, 8).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: compactEmpty ? 80 : 220, maxHeight: compactEmpty ? 120 : 400)
        }
    }
    private var compactEmpty: Bool { scope != "custom" && (try? preview.get()) == nil }

    private func groupBinding(_ members: [AdjustmentTransferField]) -> Binding<Bool> {
        Binding(get: { Set(members).isSubset(of: fields) }, set: { if $0 { fields.formUnion(members) } else { fields.subtract(members) } })
    }
    private func fieldToggle(_ field: AdjustmentTransferField) -> some View {
        Toggle(isOn: Binding(get: { fields.contains(field) }, set: {
            if $0 { fields.insert(field) } else { fields.remove(field) }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.displayTitle)
                if let payload = try? preview.get(), payload.fields.contains(field) {
                    Text(AdjustmentTransferSummary(payload: payload).valueText(for: field, lookName: lookName))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(identifier + ".summary.value." + field.rawValue)
                }
            }
        }.padding(.leading, 12).accessibilityIdentifier(identifier + "." + field.rawValue)
    }
}
