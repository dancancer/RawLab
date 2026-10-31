import SwiftUI
import UIKit

// 界面显示用的名称：汉字写的人名按当前语言显示（翻译目录以原名为键）
extension MasterRecipe {
    var title: String { L10n.text(name) }
}

extension ContentView {
    func filmPanel(imageSize: CGFloat) -> some View {
        let choices = FilmGroup.sections(viewModel.availableLUTs, group: { FilmPresentation(fileName: $0.id).group }).flatMap { $0 }
        let items = choices.map { LookBrowserItem(id: $0.id, name: $0.name, group: FilmPresentation(fileName: $0.id).group,
            isCustom: viewModel.lutMap[$0.id]?.isCustom == true) }
        let visible = viewModel.lookBrowser.visibleIDs(in: items, recent: viewModel.recentLooks.ids.filter(viewModel.readableLookBrowserIDs.contains))
        let looks = visible.compactMap { id in choices.first { $0.id == id } }
        let showsNeutral = viewModel.lookBrowser.category == .all && viewModel.lookBrowser.query.isEmpty
        return VStack(spacing: 4) {
            HStack(spacing: 8) {
                TextField(L10n.text("搜索外观"), text: $viewModel.lookBrowser.query)
                    .textFieldStyle(.roundedBorder).frame(minHeight: 44)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("looks.search")
                if !viewModel.lookBrowser.query.isEmpty {
                    Button { viewModel.lookBrowser.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                    }.accessibilityLabel(L10n.text("清除搜索")).accessibilityIdentifier("looks.search.clear")
                }
                Button { showingLookImporter = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .accessibilityLabel(L10n.text("导入外观")).accessibilityIdentifier("looks.import")
                    .disabled(editorBusy || isEditorDraftChanged || viewModel.isImportingLooks)
            }.padding(.horizontal, 16)
            Menu {
                Picker(L10n.text("外观分类"), selection: $viewModel.lookBrowser.category) {
                    ForEach(LookBrowserCategory.allCases, id: \.self) { Text(L10n.text($0.titleKey)).tag($0) }
                }
            } label: {
                HStack {
                    Label(L10n.text(viewModel.lookBrowser.category.titleKey), systemImage: "line.3.horizontal.decrease")
                    Spacer();Image(systemName: "chevron.down").font(.caption)
                }.frame(minHeight: 44).padding(.horizontal, 16).contentShape(Rectangle())
            }.accessibilityLabel(L10n.text("外观分类")).accessibilityValue(L10n.text(viewModel.lookBrowser.category.titleKey))
                .accessibilityIdentifier("looks.category")
            if looks.isEmpty && !showsNeutral && !viewModel.isLoadingLUTs {
                VStack(spacing: 4) {
                    Text(L10n.text("没有匹配的外观")).font(.subheadline).foregroundStyle(.secondary)
                    Button {
                        if viewModel.lookBrowser.query.isEmpty { viewModel.lookBrowser.category = .all }
                        else { viewModel.lookBrowser.query = "" }
                    } label: { Text(L10n.text(viewModel.lookBrowser.query.isEmpty ? "全部外观" : "清除搜索")).frame(minHeight: 44) }
                }.frame(maxWidth: .infinity).accessibilityIdentifier("looks.empty")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            if showsNeutral { filmButton(name: L10n.text("中性"), id: nil, imageSize: imageSize) }
                            ForEach(looks) { lut in
                                filmButton(name: lut.name, id: lut.id, imageSize: imageSize, colorNotice: lut.colorNotice, isCompatibility: lut.isCompatibility)
                                    .contextMenu {
                                        if viewModel.lutMap[lut.id]?.isCustom == true {
                                            Button(L10n.text("重命名外观"), systemImage: "pencil") {
                                                renamingLUT = lut; renamedLUTName = lut.name; showingLookRename = true
                                            }.disabled(editingLocked || viewModel.isImportingLooks)
                                        }
                                    }
                            }
                        }.padding(.horizontal, 16)
                    }.accessibilityIdentifier("film.choices")
                        .onAppear { proxy.scrollTo(settings.lutID ?? "neutral", anchor: .center) }
                        .onChange(of: settings.lutID) { _, id in proxy.scrollTo(id ?? "neutral", anchor: .center) }
                }
            }
        }
        .overlay {
            if viewModel.isLoadingLUTs { ProgressView(L10n.text("正在加载胶片")).padding(8).background(.regularMaterial) }
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
                                  displayScale: 100, identifier: "masterRecipe.strength", onEditingChanged: setSliderEditing)
                    .padding(.horizontal, 16)
                    .disabled(!viewModel.hasImage || editingLocked)
            }
        }
    }

    func masterRecipeButton(_ recipe: MasterRecipe?, width: CGFloat) -> some View {
        Button {
            var updated = settings
            if let recipe { updated.applyMasterRecipe(recipe) }
            else {
                if let reason = updated.clearMasterRecipe(context: resetContext) {
                    viewModel.statusMessage = resetBlockedMessage(reason); return
                }
                updated.lutID = nil
            }
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
            .overlay(alignment: .topTrailing) {
                if settings.masterRecipeID == recipe?.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.yellow).padding(4).accessibilityHidden(true)
                }
            }
        }.disabled(!viewModel.hasImage || editingLocked)
            .accessibilityLabel(recipe?.title ?? L10n.text("无配方")).accessibilityIdentifier("recipe.\(recipe?.id ?? "neutral")")
            .accessibilityAddTraits(settings.masterRecipeID == recipe?.id ? .isSelected : [])
    }

    func filmButton(name: String, id: String?, imageSize: CGFloat, colorNotice: String? = nil, isCompatibility: Bool = false) -> some View {
        Button {
            if settings.masterRecipeID != nil || settings.lutID != id {
                let kind: UsageFilmKind = id == nil ? .none :
                    (id.flatMap { viewModel.lutMap[$0]?.isCustom } == true ? .custom : .builtIn)
                UsageAnalytics.shared.record(.filmSelected(kind))
            }
            var updated = settings
            if let reason = updated.clearMasterRecipe(context: resetContext) {
                viewModel.statusMessage = resetBlockedMessage(reason); return
            }
            updated.lutID = id
            applySettingsChange(updated)
        } label: {
            FilmLabel(name: name, artworkName: id.flatMap { FilmPresentation(fileName: $0).artworkName },
                      neutral: id == nil, selected: settings.lutID == id, imageSize: imageSize, colorNotice: colorNotice, isCompatibility: isCompatibility)
        }
        .buttonStyle(.plain)
        .id(id ?? "neutral")
        .accessibilityLabel(colorNotice.map { name + " · " + $0 } ?? name)
        .accessibilityAddTraits(settings.lutID == id ? .isSelected : [])
    }
}
