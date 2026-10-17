import SwiftUI

struct MasterRecipeDock: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geometry in
            // 留出水平滚动条的位置，避免覆盖底部文字。
            let height = max(54, geometry.size.height - 16)
            let showsSubtitle = height >= 90
            let imageSize = max(32, min(96, height - (showsSubtitle ? 64 : 36)))
            HorizontalPicker(selectedID: model.settings.masterRecipeID ?? "", name: L10n.text("大师配方")) {
                HStack(spacing: 8) {
                    recipeButton(recipe: nil, imageSize: imageSize, height: height, showsSubtitle: showsSubtitle)
                    ForEach(MasterRecipe.allRecipes) { recipe in
                        recipeButton(recipe: recipe, imageSize: imageSize, height: height, showsSubtitle: showsSubtitle)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(.yellow)
    }

    private func recipeButton(recipe: MasterRecipe?, imageSize: CGFloat, height: CGFloat,
                              showsSubtitle: Bool) -> some View {
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
                .frame(width: imageSize, height: imageSize)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(recipe?.title ?? L10n.text("无配方"))
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .lineLimit(2).multilineTextAlignment(.center)
                        .frame(width: 112, height: 28)
                    if showsSubtitle {
                        Text(L10n.text(recipe?.subtitle ?? "中性直出"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 112, height: 24, alignment: .top)
                    }
                }
            }
            .frame(width: max(112, imageSize + 12), height: height)
            .foregroundStyle(selected ? Color.yellow : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(recipe?.id ?? "")
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
