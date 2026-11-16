import SwiftUI

struct MasterRecipeDock: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel

    var body: some View {
        let _ = localizationLocale
        let card = AdjustmentPanelLayout.RecipeCard.self
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: card.columnSpacing, alignment: .top),
                count: card.columns
            ),
            spacing: card.rowSpacing
        ) {
            recipeButton(recipe: nil)
            ForEach(MasterRecipe.allRecipes) { recipe in
                recipeButton(recipe: recipe)
            }
        }
        .frame(maxWidth: .infinity)
        .controlSize(.small)
        .tint(.yellow)
    }

    private func recipeButton(recipe: MasterRecipe?) -> some View {
        let card = AdjustmentPanelLayout.RecipeCard.self
        let selected = model.settings.masterRecipeID == recipe?.id
        return Button { model.selectMasterRecipe(recipe) } label: {
            VStack(spacing: 5) {
                Group {
                    if let recipe, let image = MasterRecipeArtwork.image(for: recipe) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: recipe == nil ? "circle.slash" : "photo")
                            .font(.system(size: 28)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: card.artworkSize, height: card.artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(recipe?.title ?? L10n.text("无配方"))
                        .font(.system(size: card.titleSize, weight: selected ? .semibold : .regular))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text(recipe?.subtitle ?? "中性直出"))
                        .font(.system(size: card.subtitleSize))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(card.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .foregroundStyle(selected ? Color.yellow : Color.primary)
            .background(selected ? Color.yellow.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : .clear, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .id(recipe?.id ?? "")
        .accessibilityIdentifier("recipe.\(recipe?.id ?? "neutral")")
        .help(recipe.map { "\($0.title) · \(L10n.text($0.summary))" } ?? L10n.text("中性直出"))
        .accessibilityLabel(recipe.map { "\($0.title), \(L10n.text($0.subtitle))" } ?? L10n.text("无配方"))
        .accessibilityValue(selected ? L10n.text("已选中") : L10n.text("未选中"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private enum MasterRecipeArtwork {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for recipe: MasterRecipe) -> NSImage? {
        let key = recipe.id as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let url = recipe.artworkURL(), let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
