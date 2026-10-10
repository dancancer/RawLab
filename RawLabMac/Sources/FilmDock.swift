import SwiftUI

struct FilmDock: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        GeometryReader { geometry in
            let imageSize = max(32, min(96, geometry.size.height - 44))
            let itemHeight = max(66, geometry.size.height - 6)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        filmButton(name: "中性", id: "", imageSize: imageSize, height: itemHeight)
                        ForEach(model.films) { film in
                            filmButton(name: film.name, id: film.id, imageSize: imageSize, height: itemHeight,
                                       isCustom: film.managedID != nil)
                                .contextMenu {
                                    if film.managedID != nil {
                                        Text("用户外观 · \(film.url.pathExtension.uppercased())")
                                        if film.isAI {
                                            Button("导出 CUBE…", systemImage: "square.and.arrow.down") {
                                                AICubeActions.export(source: film.url, name: film.name,
                                                    protecting: model.films.map(\.url) + [model.file].compactMap { $0 },
                                                    onError: { model.error = $0 })
                                            }.disabled(model.lookLibraryBusy || model.exporting)
                                            Divider()
                                        }
                                        Button("重命名…", systemImage: "pencil") { model.renameLookPanel(film) }
                                            .disabled(model.lookLibraryBusy || model.exporting)
                                        Button("移除外观…", systemImage: "trash", role: .destructive) { model.removeLookPanel(film) }
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
                                Text("导入外观").font(.system(size: 11))
                            }.frame(width: max(88, imageSize + 12), height: itemHeight)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help("导入外观…").disabled(model.lookLibraryBusy || model.exporting)
                    }.padding(.horizontal, 16).frame(minWidth: geometry.size.width)
                }.scrollIndicators(.visible)
                    .onAppear { proxy.scrollTo(model.selectedFilmID, anchor: .center) }
                    .onChange(of: model.selectedFilmID) { _, id in proxy.scrollTo(id, anchor: .center) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).tint(.yellow)
    }

    private func filmButton(name: String, id: String, imageSize: CGFloat, height: CGFloat,
                            isCustom: Bool = false) -> some View {
        let selected = model.selectedFilmID == id
        return Button { model.selectedFilmID = id } label: {
            VStack(spacing: 5) {
                FilmPackageImage(name: name, neutral: id.isEmpty, isCustom: isCustom)
                    .frame(width: imageSize, height: imageSize)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(name).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 88, height: 28)
            }.frame(width: max(88, imageSize + 12), height: height)
                .contentShape(Rectangle())
                .foregroundStyle(selected ? Color.yellow : Color.primary)
                .background(selected ? Color.yellow.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.yellow : .clear, lineWidth: 1) }
        }.buttonStyle(.plain).id(id).help(name).accessibilityLabel(name)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct FilmPackageImage: View {
    let name: String
    let neutral: Bool
    let isCustom: Bool
    var body: some View {
        if neutral {
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 28)).foregroundStyle(.secondary)
        } else if let image = FilmArtwork.image(for: name, isCustom: isCustom) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().accessibilityHidden(true)
        } else {
            Image(systemName: "shippingbox").font(.system(size: 28)).foregroundStyle(.secondary)
        }
    }
}
