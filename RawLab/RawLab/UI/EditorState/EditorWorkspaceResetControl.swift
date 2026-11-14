import SwiftUI

extension EditorAdjustmentGroup {
    var title: String {
        switch self {
        case .looks: return L10n.text("外观")
        case .light: return L10n.text("光线")
        case .color: return L10n.text("颜色")
        case .effects: return L10n.text("效果")
        case .detail: return L10n.text("细节")
        case .geometry: return L10n.text("几何与镜头")
        case .hdrRendition: return L10n.text("HDR 输出与 SDR 底图")
        }
    }
}

struct EditorWorkspaceResetItem: Identifiable, Equatable {
    let id: String
    let title: String
    let scope: EditorAdjustmentScope
    let isEnabled: Bool
    var isDestructive = false
}

struct EditorWorkspaceResetPresentation: Equatable {
    enum Style: Equatable {
        case button(scope: EditorAdjustmentScope, isEnabled: Bool)
        case menu(items: [EditorWorkspaceResetItem], isEnabled: Bool)
    }

    let identifier: String
    let label: String
    let style: Style

    var isEnabled: Bool {
        switch style {
        case .button(_, let enabled), .menu(_, let enabled): return enabled
        }
    }

    static func make(toolWorkspaceOpen: Bool, quickPresetsVisible: Bool = false,
                     selectedGroup: EditorAdjustmentGroup,
                     currentTool: EditorToolSelection, hslChannel: Int,
                     gradingZone: ColorGradingZone, isAvailable: Bool,
                     isModified: (EditorAdjustmentScope) -> Bool) -> Self? {
        let label = L10n.text("重置调整")
        if !toolWorkspaceOpen {
            guard !quickPresetsVisible else { return nil }
            let groupScope = EditorAdjustmentScope.group(selectedGroup)
            let groupEnabled = isModified(groupScope)
            let allEnabled = isModified(.all)
            let items = [
                EditorWorkspaceResetItem(id: "editor.reset.group",
                    title: L10n.format("重置%@组…", selectedGroup.title),
                    scope: groupScope, isEnabled: groupEnabled),
                EditorWorkspaceResetItem(id: "editor.reset.all",
                    title: L10n.text("重置全部调整…"),
                    scope: .all, isEnabled: allEnabled, isDestructive: true),
            ]
            return Self(identifier: "editor.reset", label: label,
                        style: .menu(items: items, isEnabled: isAvailable && (groupEnabled || allEnabled)))
        }
        switch currentTool {
        case .adjustment(.hsl):
            let channelName = HSLSettings.channelNames.indices.contains(hslChannel)
                ? L10n.text(HSLSettings.channelNames[hslChannel]) : ""
            let channelScope = EditorAdjustmentScope.hslChannel(hslChannel)
            let channelEnabled = isModified(channelScope)
            let allHSLEnabled = isModified(.allHSL)
            let items = [
                EditorWorkspaceResetItem(id: "editor.draft.reset.hslChannel",
                    title: L10n.format("重置当前颜色（%@）", channelName),
                    scope: channelScope, isEnabled: channelEnabled),
                EditorWorkspaceResetItem(id: "editor.draft.reset.allHSL",
                    title: L10n.text("重置全部 HSL…"),
                    scope: .allHSL, isEnabled: allHSLEnabled),
            ]
            return Self(identifier: "editor.draft.reset", label: label,
                        style: .menu(items: items, isEnabled: isAvailable && (channelEnabled || allHSLEnabled)))
        case .adjustment(.colorGrading):
            let zoneScope = EditorAdjustmentScope.gradingZone(gradingZone)
            let zoneEnabled = isModified(zoneScope)
            let allGradingEnabled = isModified(.allGrading)
            let items = [
                EditorWorkspaceResetItem(id: "editor.draft.reset.gradingZone",
                    title: L10n.text("重置当前分区"),
                    scope: zoneScope, isEnabled: zoneEnabled),
                EditorWorkspaceResetItem(id: "editor.draft.reset.allGrading",
                    title: L10n.text("重置颜色分级"),
                    scope: .allGrading, isEnabled: allGradingEnabled),
            ]
            return Self(identifier: "editor.draft.reset", label: label,
                        style: .menu(items: items, isEnabled: isAvailable && (zoneEnabled || allGradingEnabled)))
        default:
            let scope = EditorAdjustmentScope.tool(currentTool)
            return Self(identifier: "editor.draft.reset", label: label,
                        style: .button(scope: scope, isEnabled: isAvailable && isModified(scope)))
        }
    }
}

struct EditorWorkspaceResetControl: View {
    let presentation: EditorWorkspaceResetPresentation?
    let onReset: (EditorAdjustmentScope) -> Void

    var body: some View {
        if let presentation {
            switch presentation.style {
            case .button(let scope, let isEnabled):
                Button { onReset(scope) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                }
                .disabled(!isEnabled)
                .accessibilityLabel(presentation.label)
                .accessibilityIdentifier(presentation.identifier)
            case .menu(let items, let isEnabled):
                Menu {
                    ForEach(items) { item in
                        Button(item.title, role: item.isDestructive ? .destructive : nil) {
                            onReset(item.scope)
                        }
                        .disabled(!item.isEnabled)
                        .accessibilityIdentifier(item.id)
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 20))
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!isEnabled)
                .accessibilityLabel(presentation.label)
                .accessibilityIdentifier(presentation.identifier)
            }
        }
    }
}
