import SwiftUI

struct FilmDock: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    var body: some View {
        let _ = localizationLocale
        GeometryReader { geometry in
            let itemHeight = max(66, geometry.size.height - 16)
            let imageSize = max(32, min(96, itemHeight - 34))
            HorizontalPicker(selectedID: model.selectedFilmID, name: L10n.text("胶片")) {
                HStack(spacing: 8) {
                    filmButton(name: L10n.text("中性"), id: "", imageSize: imageSize, height: itemHeight)
                    ForEach(model.films) { film in
                        filmButton(name: film.name, id: film.id, imageSize: imageSize, height: itemHeight,
                                   isCustom: film.managedID != nil)
                            .contextMenu {
                                if film.managedID != nil {
                                    Text(L10n.format("用户外观 · %@", String(describing: film.url.pathExtension.uppercased())))
                                    Button(L10n.text("重命名…"), systemImage: "pencil") { model.renameLookPanel(film) }
                                        .disabled(model.lookLibraryBusy || model.exporting)
                                    Button(L10n.text("移除外观…"), systemImage: "trash", role: .destructive) { model.removeLookPanel(film) }
                                        .disabled(model.lookLibraryBusy || model.exporting)
                                }
                            }
                    }
                    Button(action: model.importLUT) {
                        VStack(spacing: 5) {
                            Group {
                                if model.lookLibraryBusy { ProgressView().controlSize(.small) }
                                else { Image(systemName: "plus.circle").font(.system(size: 26)) }
                            }.frame(height: imageSize)
                            Text(L10n.text("导入外观")).font(.system(size: 11))
                        }.frame(width: max(88, imageSize + 12), height: itemHeight)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(L10n.text("导入外观…")).disabled(model.lookLibraryBusy || model.exporting)
                }.scrollTargetLayout().padding(.horizontal, 16)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).tint(.yellow)
    }

    private func filmButton(name: String, id: String, imageSize: CGFloat, height: CGFloat,
                            isCustom: Bool = false) -> some View {
        let selected = model.settings.masterRecipeID == nil && model.selectedFilmID == id
        let labelWidth: CGFloat = !isCustom && BundledLook.all.contains(where: { $0.name == name }) ? 132 : 88
        return Button { model.selectFilm(id) } label: {
            VStack(spacing: 5) {
                FilmPackageImage(name: name, neutral: id.isEmpty, isCustom: isCustom)
                    .frame(width: imageSize, height: imageSize)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(name).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(width: labelWidth, height: 28)
            }.frame(width: max(labelWidth, imageSize + 12), height: height)
                .contentShape(Rectangle())
                .foregroundStyle(selected ? Color.yellow : Color.primary)
                .background(selected ? Color.yellow.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : .clear, lineWidth: 1) }
        }.buttonStyle(.plain).id(id).help(name).accessibilityLabel(name)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct FilmPackageImage: View {
    @Environment(\.locale) private var localizationLocale
    let name: String
    let neutral: Bool
    let isCustom: Bool
    var body: some View {
        let _ = localizationLocale
        if neutral {
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 28)).foregroundStyle(.secondary)
        } else if let image = FilmArtwork.image(for: name, isCustom: isCustom) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().accessibilityHidden(true)
        } else {
            Image(systemName: "shippingbox").font(.system(size: 28)).foregroundStyle(.secondary)
        }
    }
}
