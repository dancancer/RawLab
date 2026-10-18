import SwiftUI
import UIKit

// 界面显示用的名称：汉字写的人名按当前语言显示（翻译目录以原名为键）
extension MasterRecipe {
    var title: String { L10n.text(name) }
}

extension ContentView {
    func filmPanel(imageSize: CGFloat) -> some View {
        let sections = FilmGroup.sections(viewModel.availableLUTs, group: { FilmPresentation(fileName: $0.id).group })
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filmButton(name: L10n.text("中性"), id: nil, imageSize: imageSize)
                    ForEach(sections.indices, id: \.self) { index in
                        if index > 0 {
                            Divider().frame(height: imageSize + 30).padding(.horizontal, 12)
                                .accessibilityIdentifier("film.group-divider.\(index)")
                        }
                        ForEach(sections[index]) { lut in
                            filmButton(name: lut.name, id: lut.id, imageSize: imageSize)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .accessibilityIdentifier("film.choices")
            .onAppear { proxy.scrollTo(settings.lutID ?? "neutral", anchor: .center) }
            .onChange(of: settings.lutID) { _, id in proxy.scrollTo(id ?? "neutral", anchor: .center) }
        }
        .overlay {
            if viewModel.isLoadingLUTs {
                ProgressView(L10n.text("正在加载胶片")).padding(8).background(.regularMaterial)
            } else if viewModel.availableLUTs.isEmpty {
                Text(L10n.text("未找到胶片 LUT")).font(.caption).foregroundStyle(.secondary)
                    .padding(8).background(.regularMaterial)
            }
        }
        .disabled(!viewModel.hasImage || editingLocked || viewModel.isLoadingLUTs)
    }

    var masterRecipePanel: some View {
        let recipes = MasterRecipe.allRecipes
        let tileWidth = max(120, filmSize + 40)
        return VStack(alignment: .leading, spacing: 12) {
            // 当前配方名已在面板标题行显示，这里只补一句说明
            if settings.masterRecipe != nil {
                Text(L10n.text("配方会调整多个参数。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .opacity(rulerFocusOpacity)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        masterRecipeButton(nil, width: tileWidth).id("neutral")
                        ForEach(recipes) { recipe in masterRecipeButton(recipe, width: tileWidth).id(recipe.id) }
                    }
                    .padding(.horizontal, 16)
                }
                .onAppear { proxy.scrollTo(settings.masterRecipeID ?? "neutral", anchor: .center) }
                .onChange(of: settings.masterRecipeID) { _, id in proxy.scrollTo(id ?? "neutral", anchor: .center) }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("masterRecipe.choices")
            .opacity(rulerFocusOpacity)
            if settings.masterRecipeID != nil {
                AdjustmentControl(title: L10n.text("强度"), value: adjustmentBinding(.strength),
                                  range: RawSettings.lutStrengthRange, step: 0.01, defaultValue: 1,
                                  unit: "%", formatter: { String(format: "%.0f", locale: L10n.locale, $0 * 100) },
                                  identifier: "masterRecipe.strength", onEditingChanged: setSliderEditing)
                    .padding(.horizontal, 16)
                    .disabled(!viewModel.hasImage || editingLocked)
            }
        }
    }

    func masterRecipeButton(_ recipe: MasterRecipe?, width: CGFloat) -> some View {
        Button {
            var updated = settings
            if let recipe { updated.applyMasterRecipe(recipe) }
            else { updated.clearMasterRecipe(cameraTint: viewModel.rawWhiteBalance?.tint); updated.lutID = nil }
            applySettingsChange(updated)
        } label: {
            VStack(spacing: 6) {
                // 图片区固定一格：有插图显示插图，没有插图（含"无配方"）才用图标代替
                Group {
                    if let url = recipe?.artworkURL(), let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "square.stack.3d.up").font(.title2)
                    }
                }
                .frame(width: filmSize, height: filmSize)
                .accessibilityHidden(true)
                Text(recipe?.title ?? L10n.text("无配方"))
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44)
                Text(L10n.text(recipe?.subtitle ?? "中性直出"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: width)
            .padding(.vertical, 6)
            .foregroundStyle(settings.masterRecipeID == recipe?.id ? Color.yellow : Color.primary)
        }.disabled(!viewModel.hasImage || editingLocked)
            .accessibilityLabel(recipe?.title ?? L10n.text("无配方")).accessibilityIdentifier("recipe.\(recipe?.id ?? "neutral")")
            .accessibilityAddTraits(settings.masterRecipeID == recipe?.id ? .isSelected : [])
    }

    func filmButton(name: String, id: String?, imageSize: CGFloat) -> some View {
        Button {
            if settings.masterRecipeID != nil || settings.lutID != id {
                UsageAnalytics.shared.record(.filmSelected(id == nil ? .none : .builtIn))
            }
            var updated = settings
            updated.clearMasterRecipe(cameraTint: viewModel.rawWhiteBalance?.tint)
            updated.lutID = id
            applySettingsChange(updated)
        } label: {
            FilmLabel(name: name, artworkName: id.flatMap { FilmPresentation(fileName: $0).artworkName },
                      neutral: id == nil, selected: settings.lutID == id, imageSize: imageSize)
        }
        .buttonStyle(.plain)
        .id(id ?? "neutral")
        .accessibilityLabel(name)
        .accessibilityAddTraits(settings.lutID == id ? .isSelected : [])
    }
}
