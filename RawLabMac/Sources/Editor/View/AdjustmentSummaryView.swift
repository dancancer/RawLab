import SwiftUI

struct AdjustmentSummaryView: View {
    let payload: AdjustmentTransferPayload
    let lookName: (String, String) -> String?
    var identifier = "adjustment.summary"
    var showsGroups = true

    var body: some View {
        let summary = AdjustmentTransferSummary(payload: payload)
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.format("将覆盖以下 %@ 项调整；其他调整保留目标原值。", String(summary.count)))
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(identifier + ".count")
            if payload.source.isHDR { Text("HDR · " + L10n.text("相对白平衡")).fontWeight(.medium) }
            Text(L10n.text(summary.includesGeometry ? "包含几何或镜头调整。" : "未包含几何与镜头。"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = summary.recipeNote {
                Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if showsGroups {
            ForEach(summary.groups) { group in
                DisclosureGroup {
                    ForEach(group.fields, id: \.rawValue) { field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.displayTitle).fontWeight(.medium)
                            Text(summary.valueText(for: field, lookName: lookName))
                                .foregroundStyle(.secondary).monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier(identifier + ".value." + field.rawValue)
                        }.padding(.vertical, 3).accessibilityElement(children: .combine)
                    }
                } label: {
                    Text(AdjustmentTransferField.groupTitle(group.id) + " · " + String(group.fields.count))
                }.accessibilityIdentifier(identifier + ".group." + group.id)
            }
            }
        }.font(.callout)
    }
}

struct AdjustmentScopeSummaryView: View {
    let preview: Result<AdjustmentTransferPayload, Error>
    let modified: Bool
    let lookName: (String, String) -> String?
    let errorMessage: (Error) -> String
    var identifier = "adjustment.summary"
    var showsGroups = true

    var body: some View {
        switch preview {
        case .success(let payload):
            AdjustmentSummaryView(payload: payload, lookName: lookName, identifier: identifier, showsGroups: showsGroups)
        case .failure(let error):
            let empty = error as? AdjustmentTransferError == .emptyScope
            Text(empty ? L10n.text(modified ? "尚无已修改的调整。" : "未选择任何调整。") : errorMessage(error))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier + (empty ? ".empty" : ".error"))
        }
    }
}
