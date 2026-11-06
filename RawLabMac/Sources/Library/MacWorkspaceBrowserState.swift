import SwiftUI

final class MacWorkspaceBrowserState: ObservableObject {
    struct Location: Hashable {
        let root: URL
        let folder: URL
    }

    private struct MouseSelection {
        let photo: URL
        let selection: [URL]
        let rangeAnchor: URL?
    }

    @Published private(set) var path: [PhotoFolder] = []
    @Published private(set) var selection: [URL] = []
    @Published private(set) var treeReveal = UUID()
    @Published private(set) var photoReveal = UUID()
    private var checked = Set<URL>()
    private var sidebarAnchors: [Location: URL] = [:]
    private var gridAnchors: [Location: URL] = [:]
    private var rangeAnchor: URL?
    private var previousMouseSelection: MouseSelection?
    private var pendingLocate: UUID?

    var folder: PhotoFolder? { path.last }
    var location: Location? {
        guard let root = path.first, let folder else { return nil }
        return Location(root: root.url, folder: folder.url)
    }

    func reconcile(with library: PhotoLibrary) {
        if let root = path.first, library.roots.contains(where: { $0 === root }) { return }
        if let root = library.roots.first { browse([root]) }
        else { browse([]) }
    }

    func browse(_ target: [PhotoFolder], load: Bool = true) {
        pendingLocate = nil
        if path.map(\.url) != target.map(\.url) || path.first !== target.first {
            rangeAnchor = nil
            previousMouseSelection = nil
            path = target
        }
        if load { folder?.load() }
    }

    func goUp(load: Bool = true) {
        guard path.count > 1 else { return }
        browse(Array(path.dropLast()), load: load)
    }

    func collapseBranch() { path.reversed().first(where: \.isExpandedInTree)?.expanded = false }

    func collapseAll(in library: PhotoLibrary) {
        func collapse(_ folder: PhotoFolder) {
            folder.expanded = false
            for child in folder.folders { collapse(child) }
        }
        for root in library.roots { collapse(root) }
    }

    func revealInTree() {
        for folder in path.dropLast() {
            folder.expanded = true
            folder.load()
        }
        treeReveal = UUID()
    }

    func anchor(in location: Location, grid: Bool) -> URL? {
        grid ? gridAnchors[location] : sidebarAnchors[location]
    }

    func remember(_ photo: URL, in location: Location, grid: Bool) {
        if grid { gridAnchors[location] = photo }
        else { sidebarAnchors[location] = photo }
    }

    func restoreAnchor(in location: Location, grid: Bool, photos: [URL]) -> URL? {
        guard let previous = anchor(in: location, grid: grid), let last = photos.last else { return nil }
        if photos.contains(previous) { return previous }
        let nearest = photos.first {
            $0.lastPathComponent.localizedStandardCompare(previous.lastPathComponent) != .orderedAscending
        } ?? last
        remember(nearest, in: location, grid: grid)
        return nearest
    }

    func includes(_ url: URL) -> Bool { checked.contains(url) }

    // A double-click opens the photo and restores the marks from before its first click.
    func activate(_ url: URL, in ordered: [URL], extending: Bool, mouseClickCount: Int?) -> Bool {
        if let mouseClickCount, mouseClickCount >= 2 {
            if let previousMouseSelection, previousMouseSelection.photo == url {
                selection = previousMouseSelection.selection
                checked = Set(selection)
                rangeAnchor = previousMouseSelection.rangeAnchor
            }
            previousMouseSelection = nil
            return true
        }
        let snapshot = mouseClickCount == 1 ? MouseSelection(photo: url, selection: selection, rangeAnchor: rangeAnchor) : nil
        toggle(url, in: ordered, extending: extending)
        previousMouseSelection = snapshot
        return false
    }

    private func toggle(_ url: URL, in ordered: [URL], extending: Bool) {
        if extending, let rangeAnchor, let first = ordered.firstIndex(of: rangeAnchor), let last = ordered.firstIndex(of: url) {
            let added = ordered[min(first, last)...max(first, last)].filter { checked.insert($0).inserted }
            if !added.isEmpty { selection.append(contentsOf: added) }
        } else if checked.contains(url) {
            removeSelection([url])
        } else {
            checked.insert(url); selection.append(url)
        }
        rangeAnchor = url
    }

    func removeSelection(_ urls: [URL]) {
        previousMouseSelection = nil
        let removed = Set(urls)
        checked.subtract(removed)
        selection.removeAll { removed.contains($0) }
        if let rangeAnchor, removed.contains(rangeAnchor) { self.rangeAnchor = nil }
    }

    func clearSelection() {
        checked.removeAll(); selection.removeAll(); rangeAnchor = nil; previousMouseSelection = nil
    }

    func containsDirectory(of photo: URL) -> Bool {
        guard let folder else { return false }
        return folder.url.standardizedFileURL.path == photo.deletingLastPathComponent().standardizedFileURL.path
    }

    func locate(_ photo: URL, in library: PhotoLibrary, otherwise: @escaping () -> Void) {
        let target = photo.deletingLastPathComponent().standardizedFileURL.pathComponents
        let roots = library.roots.filter { target.starts(with: $0.url.standardizedFileURL.pathComponents) }
        let root = roots.first { $0 === path.first }
            ?? roots.max { $0.url.pathComponents.count < $1.url.pathComponents.count }
        guard let root else { otherwise(); return }
        let token = UUID()
        pendingLocate = token
        locate(photo, below: [root], components: target.dropFirst(root.url.standardizedFileURL.pathComponents.count),
               in: library, token: token, otherwise: otherwise)
    }

    private func locate(_ photo: URL, below path: [PhotoFolder], components: ArraySlice<String>,
                        in library: PhotoLibrary, token: UUID, otherwise: @escaping () -> Void) {
        guard let folder = path.last else { return }
        folder.load { [weak self, weak library, weak folder] in
            guard let self, let library, let folder, self.pendingLocate == token,
                  library.roots.contains(where: { $0 === path.first }) else { return }
            if let component = components.first {
                guard let child = folder.folders.first(where: { $0.url.lastPathComponent == component }) else {
                    self.pendingLocate = nil; otherwise(); return
                }
                self.locate(photo, below: path + [child], components: components.dropFirst(), in: library,
                            token: token, otherwise: otherwise)
            } else {
                self.browse(path, load: false)
                self.revealInTree()
                if let location = self.location,
                   let item = folder.photos.first(where: { $0.standardizedFileURL.path == photo.standardizedFileURL.path }) {
                    self.remember(item, in: location, grid: false)
                    self.remember(item, in: location, grid: true)
                    self.photoReveal = UUID()
                }
            }
        }
    }
}
