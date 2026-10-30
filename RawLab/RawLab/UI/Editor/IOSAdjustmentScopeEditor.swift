import SwiftUI

struct IOSAdjustmentScopeEditor: View {
    @Binding var scope: String
    @Binding var fields: Set<AdjustmentTransferField>
    let preview: Result<AdjustmentTransferPayload, Error>
    let lookName: (String, String) -> String?
    let errorMessage: (Error) -> String
    var identifier = "adjustment.copy"
    var fieldIdentifier = "adjustment"
    var titleKey = "复制范围"
    var sourceName: String?
    var allowed = AdjustmentTransferField.legacyFields

    var body: some View {
        Section {
            if let sourceName { Text(sourceName).font(.headline) }
            Picker(L10n.text(titleKey), selection: $scope) {
                Text(L10n.text("全部")).tag("all")
                Text(L10n.text("仅已修改")).tag("modified")
                Text(L10n.text("自定义")).tag("custom")
            }.accessibilityIdentifier("\(identifier).scope")
            IOSAdjustmentScopeSummaryView(preview: preview, modified: scope == "modified", lookName: lookName,
                errorMessage: errorMessage, identifier: identifier + ".summary", showsGroups: scope != "custom")
        }
        if scope == "custom" {
            Section {
                Button(L10n.text("清空选择")) { fields.removeAll() }.accessibilityIdentifier("\(identifier).clear")
                ForEach(["looks", "light", "color", "effects", "detail", "geometry"].filter { group in allowed.contains { $0.group==group } }, id: \.self) { group in
                    DisclosureGroup {
                        let members = AdjustmentTransferField.allCases.filter { $0.group == group && allowed.contains($0) }
                        Toggle(L10n.text("选择此组"), isOn: groupBinding(members))
                        ForEach(members.filter { $0.hslLocation == nil }, id: \.rawValue) { fieldToggle($0) }
                        if members.contains(where:{ $0.hslLocation != nil }) {
                            ForEach(HSLAxis.allCases) { axis in
                                DisclosureGroup {
                                    let channelFields = members.filter { $0.hslLocation?.axis == axis.rawValue }
                                    Toggle(L10n.text("选择此组"), isOn: groupBinding(channelFields))
                                    ForEach(channelFields, id: \.rawValue) { fieldToggle($0) }
                                } label: {
                                    Text("HSL · \(axis.title)").accessibilityIdentifier("\(fieldIdentifier).axis.\(axis.rawValue)")
                                }
                            }
                        }
                    } label: {
                        let members = allowed.filter { $0.group == group }
                        Text(AdjustmentTransferField.groupTitle(group) + " · " + String(members.filter { fields.contains($0) }.count) + "/" + String(members.count)).accessibilityIdentifier("\(fieldIdentifier).group.\(group)")
                    }
                }
            }
        }
    }

    private func fieldToggle(_ field: AdjustmentTransferField) -> some View {
        Toggle(isOn: groupBinding([field])) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.displayTitle)
                if let payload = try? preview.get(), payload.fields.contains(field) {
                    Text(AdjustmentTransferSummary(payload: payload).valueText(for: field, lookName: lookName))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(identifier + ".summary.value." + field.rawValue)
                }
            }
        }.accessibilityIdentifier("\(fieldIdentifier).field.\(field.rawValue)")
    }
    private func groupBinding(_ members: [AdjustmentTransferField]) -> Binding<Bool> {
        Binding(get: { Set(members).isSubset(of: fields) }, set: {
            if $0 { fields.formUnion(members) } else { fields.subtract(members) }
        })
    }
}
