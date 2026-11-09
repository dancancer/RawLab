import SwiftUI

struct FilmDock: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    var body: some View {
        let _ = localizationLocale
        let choices = FilmGroup.sections(model.filmChoices, group: { $0.group }).flatMap { $0 }
        let items = choices.map { LookBrowserItem(id: $0.browserID, name: $0.name, group: $0.group,
            isCustom: $0.managedID != nil && !$0.isIndependentRecipe) }
        let visible = model.lookBrowser.visibleIDs(in: items, recent: model.recentLooks.ids.filter(model.readableLookBrowserIDs.contains))
        let films = visible.compactMap { id in choices.first { $0.browserID == id } }
        let showsNeutral = model.lookBrowser.category == .all && model.lookBrowser.query.isEmpty
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker(L10n.text("外观分类"), selection: $model.lookBrowser.category) {
                    ForEach(LookBrowserCategory.allCases, id: \.self) { Text(L10n.text($0.titleKey)).tag($0) }
                }.labelsHidden().frame(maxWidth: .infinity).accessibilityIdentifier("looks.category")
                Button(action: model.importLUT) { Label(L10n.text("导入外观"), systemImage: "plus") }
                    .labelStyle(.iconOnly).help(L10n.text("导入外观"))
                    .disabled(model.lookLibraryBusy || model.exporting).accessibilityIdentifier("looks.import")
            }
            HStack(spacing: 8) {
                TextField(L10n.text("搜索外观"), text: $model.lookBrowser.query)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("looks.search")
                if !model.lookBrowser.query.isEmpty {
                    Button { model.lookBrowser.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help(L10n.text("清除搜索")).accessibilityLabel(L10n.text("清除搜索"))
                }
            }
            if films.isEmpty && !showsNeutral {
                VStack(spacing: 8) {
                    Text(L10n.text("没有匹配的外观")).foregroundStyle(.secondary)
                    Button(L10n.text(model.lookBrowser.query.isEmpty ? "全部外观" : "清除搜索")) {
                        if model.lookBrowser.query.isEmpty { model.lookBrowser.category = .all }
                        else { model.lookBrowser.query = "" }
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 10).accessibilityIdentifier("looks.empty")
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 5), count: 3), spacing: 7) {
                    if showsNeutral { filmButton(name: L10n.text("中性"), id: "") }
                    ForEach(films) { film in
                        filmButton(name: film.name, id: film.id, isCustom: film.managedID != nil,
                                   colorNotice: film.colorNotice, isCompatibility: film.isCompatibility)
                            .contextMenu {
                                if film.managedID != nil && !film.isIndependentRecipe {
                                    Text(L10n.format("用户外观 · %@", film.url.pathExtension.uppercased()))
                                    Button(L10n.text("重命名…"), systemImage: "pencil") { model.renameLookPanel(film) }
                                        .disabled(model.lookLibraryBusy || model.exporting)
                                    Button(L10n.text("移除外观…"), systemImage: "trash", role: .destructive) { model.removeLookPanel(film) }
                                        .disabled(model.lookLibraryBusy || model.exporting)
                                }
                            }
                    }
                }
            }
        }.frame(maxWidth: .infinity).controlSize(.small).tint(.yellow)
    }

    private func filmButton(name: String, id: String,
                            isCustom: Bool = false, colorNotice: String? = nil, isCompatibility: Bool = false) -> some View {
        let selected = model.settings.masterRecipeID == nil && model.selectedFilmID == id
        return Button { model.selectFilm(id) } label: {
            VStack(spacing: 5) {
                FilmPackageImage(name: name, neutral: id.isEmpty, isCustom: isCustom)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(alignment: .topTrailing) {
                        if isCompatibility {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.yellow)
                                .padding(3).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                                .padding(2).accessibilityHidden(true)
                        }
                    }
                VStack(spacing: 1) {
                    Text(name).font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .lineLimit(colorNotice == nil ? 2 : 1).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let colorNotice { Text(colorNotice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }.frame(height: 29)
            }.padding(4).frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .foregroundStyle(selected ? Color.yellow : Color.primary)
                .background(selected ? Color.yellow.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : .clear, lineWidth: 1) }
        }.buttonStyle(.plain).id(id).help(colorNotice.map { name + " · " + $0 } ?? name)
            .accessibilityLabel(colorNotice.map { name + " · " + $0 } ?? name)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct FilmPackageImage: View {
    @Environment(\.locale) private var localizationLocale
    @Environment(\.displayScale) private var displayScale
    let name: String
    let neutral: Bool
    let isCustom: Bool
    var body: some View {
        let _ = localizationLocale
        if neutral {
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 28)).foregroundStyle(.secondary)
        } else if let image = FilmArtwork.image(for: name, isCustom: isCustom, displayScale: displayScale) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().accessibilityHidden(true)
        } else {
            Image(systemName: "shippingbox").font(.system(size: 28)).foregroundStyle(.secondary)
        }
    }
}
