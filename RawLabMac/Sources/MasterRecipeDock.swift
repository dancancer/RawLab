import SwiftUI

struct MasterRecipeDock: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geometry in
            let cardHeight = max(66, geometry.size.height - 6)
            let cardWidth: CGFloat = 142
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    // None / Off
                    recipeButton(
                        title: "无配方",
                        subtitle: "中性直出",
                        badge: nil,
                        isSelected: model.settings.masterRecipeID == nil,
                        accentGradient: nil,
                        action: { model.selectMasterRecipe(nil) }
                    )
                    .frame(width: 88, height: cardHeight)

                    // Master recipes
                    ForEach(MasterRecipe.allRecipes) { recipe in
                        recipeButton(
                            title: recipe.name,
                            subtitle: recipe.subtitle,
                            badge: badgeText(for: recipe.id),
                            isSelected: model.settings.masterRecipeID == recipe.id,
                            accentGradient: accentGradient(for: recipe.id),
                            action: { model.selectMasterRecipe(recipe) }
                        )
                        .frame(width: cardWidth, height: cardHeight)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minWidth: geometry.size.width)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(.yellow)
    }

    private func recipeButton(
        title: String,
        subtitle: String,
        badge: String?,
        isSelected: Bool,
        accentGradient: LinearGradient?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let gradient = accentGradient {
                        Circle()
                            .fill(gradient)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
                    } else {
                        Image(systemName: "circle.slash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                        .lineLimit(1)
                    Spacer()
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.yellow.opacity(isSelected ? 0.25 : 0.12), in: Capsule())
                            .foregroundStyle(isSelected ? Color.yellow : Color.secondary)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.yellow.opacity(0.08) : Color.white.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.yellow : Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accentGradient(for id: String) -> LinearGradient {
        switch id {
        case "hamada_daylight_v2":
            return LinearGradient(colors: [Color(red: 0.35, green: 0.72, blue: 0.88), Color(red: 0.94, green: 0.96, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "takashi_yasui_zen":
            return LinearGradient(colors: [Color(red: 0.20, green: 0.25, blue: 0.30), Color(red: 0.85, green: 0.65, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "takahiro_sakai_blue":
            return LinearGradient(colors: [Color(red: 0.50, green: 0.75, blue: 0.95), Color(red: 0.95, green: 0.97, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "withluke_epic":
            return LinearGradient(colors: [Color(red: 0.18, green: 0.45, blue: 0.52), Color(red: 0.40, green: 0.55, blue: 0.38)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "daniel_casson_autumn":
            return LinearGradient(colors: [Color(red: 0.82, green: 0.55, blue: 0.18), Color(red: 0.45, green: 0.28, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "billy_dinh_cinema":
            return LinearGradient(colors: [Color(red: 0.90, green: 0.70, blue: 0.25), Color(red: 0.12, green: 0.14, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "rkrkrk_cyberpunk":
            return LinearGradient(colors: [Color(red: 0.10, green: 0.80, blue: 0.85), Color(red: 0.95, green: 0.20, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "samalive_vintage":
            return LinearGradient(colors: [Color(red: 0.75, green: 0.35, blue: 0.25), Color(red: 0.35, green: 0.40, blue: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "iwona_fairy_tale":
            return LinearGradient(colors: [Color(red: 0.95, green: 0.68, blue: 0.30), Color(red: 0.35, green: 0.22, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "cinestill_800t":
            return LinearGradient(colors: [Color(red: 0.95, green: 0.25, blue: 0.20), Color(red: 0.10, green: 0.35, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "wilson_lee_golden":
            return LinearGradient(colors: [Color(red: 0.92, green: 0.78, blue: 0.35), Color(red: 0.55, green: 0.68, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "luizclas_portrait":
            return LinearGradient(colors: [Color(red: 0.95, green: 0.72, blue: 0.25), Color(red: 0.45, green: 0.25, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "ivan_ivanchenko_twilight":
            return LinearGradient(colors: [Color(red: 0.92, green: 0.60, blue: 0.50), Color(red: 0.30, green: 0.55, blue: 0.52)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "jungraphy_neon":
            return LinearGradient(colors: [Color(red: 0.15, green: 0.70, blue: 0.85), Color(red: 0.75, green: 0.35, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [Color.yellow, Color.orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func badgeText(for id: String) -> String {
        switch id {
        case "hamada_daylight_v2": return "日系高调"
        case "takashi_yasui_zen": return "禅意街拍"
        case "takahiro_sakai_blue": return "清透水光"
        case "withluke_epic": return "史诗风光"
        case "daniel_casson_autumn": return "秋日油画"
        case "billy_dinh_cinema": return "电影光影"
        case "rkrkrk_cyberpunk": return "赛博朋克"
        case "samalive_vintage": return "复古胶片"
        case "iwona_fairy_tale": return "童话微光"
        case "cinestill_800t": return "电影光晕"
        case "wilson_lee_golden": return "漫射金光"
        case "luizclas_portrait": return "质感人像"
        case "ivan_ivanchenko_twilight": return "暮色黄昏"
        case "jungraphy_neon": return "霓虹夜景"
        default: return "大师配方"
        }
    }
}
