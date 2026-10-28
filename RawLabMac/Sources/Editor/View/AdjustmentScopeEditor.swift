import SwiftUI

struct AdjustmentScopeEditor: View {
    @Binding var scope: String
    @Binding var fields: Set<AdjustmentTransferField>
    var identifier = "adjustment.copy"
    var titleKey = "复制范围"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L10n.text(titleKey), selection: $scope) {
                Text(L10n.text("全部")).tag("all")
                Text(L10n.text("仅已修改")).tag("modified")
                Text(L10n.text("自定义")).tag("custom")
            }.pickerStyle(.segmented).accessibilityIdentifier(identifier + ".scope")
            Text(L10n.text("几何与镜头仅在“全部”或显式选择时包含。")).font(.callout).foregroundStyle(.secondary)
            if scope == "custom" {
                HStack {
                    Text(L10n.format("已选 %@ 项", String(fields.count))).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("清空选择")) { fields.removeAll() }.disabled(fields.isEmpty)
                        .accessibilityIdentifier(identifier + ".clear")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(["looks", "light", "color", "effects", "detail", "geometry"], id: \.self) { group in
                            DisclosureGroup {
                                let members = AdjustmentTransferField.allCases.filter { $0.group == group }
                                Toggle(L10n.text("选择此组"), isOn: groupBinding(members)).fontWeight(.medium)
                                ForEach(members.filter { $0.hslLocation == nil }, id: \.rawValue) { fieldToggle($0) }
                                if group == "color" {
                                    ForEach(HSLAxis.allCases) { axis in
                                        DisclosureGroup("HSL · \(axis.title)") {
                                            let items = members.filter { $0.hslLocation?.axis == axis.rawValue }
                                            Toggle(L10n.text("选择此组"), isOn: groupBinding(items))
                                            ForEach(items, id: \.rawValue) { fieldToggle($0) }
                                        }.padding(.leading, 12)
                                    }
                                }
                            } label: {
                                let members = AdjustmentTransferField.allCases.filter { $0.group == group }
                                Text(AdjustmentTransferField.groupTitle(group) + " · \(members.filter { fields.contains($0) }.count)/\(members.count)")
                                    .fontWeight(.medium)
                            }
                        }
                    }.padding(.trailing, 8)
                }.frame(minHeight: 220, maxHeight: 400)
            }
        }
    }
    private func groupBinding(_ members: [AdjustmentTransferField]) -> Binding<Bool> {
        Binding(get: { Set(members).isSubset(of: fields) }, set: { if $0 { fields.formUnion(members) } else { fields.subtract(members) } })
    }
    private func fieldToggle(_ field: AdjustmentTransferField) -> some View {
        Toggle(field.displayTitle, isOn: Binding(get: { fields.contains(field) }, set: {
            if $0 { fields.insert(field) } else { fields.remove(field) }
        })).padding(.leading, 12).accessibilityIdentifier(identifier + "." + field.rawValue)
    }
}
